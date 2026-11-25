import Charts
import SwiftUI

struct QuotaHistoryTarget: Identifiable {
    let id: String
    let provider: StatisticsProvider
    let label: String
    let report: StatisticsProviderReport?

    @MainActor
    init?(row: MenuAccountConnection, codex: CodexMonitoringStore) {
        guard let provider = StatisticsProvider(rawValue: row.connection.providerID) else { return nil }
        self.provider = provider
        id = row.id
        label = row.isSetup ? provider.title : "\(provider.title) (\(row.accountScope))"
        report = row.statisticsReport(codex: codex)
    }
}

enum QuotaHistoryMode: String, CaseIterable, Identifiable {
    case quota = "Quota %"
    case tokens = "Local tokens"
    var id: Self { self }
}

struct QuotaHistoryRequest: Equatable {
    let targetID: String
    let provider: StatisticsProvider
    let mode: QuotaHistoryMode
    let windowID: String?
    let model: String?
}

@MainActor
final class QuotaHistoryNavigation: ObservableObject {
    static let shared = QuotaHistoryNavigation()
    @Published var request: QuotaHistoryRequest?
}

struct QuotaHistoryView: View {
    let targets: [QuotaHistoryTarget]
    var request: QuotaHistoryRequest? = nil
    var openInStatistics: ((QuotaHistoryRequest) -> Void)? = nil
    @ObservedObject private var quotaHistory = WeeklyQuotaHistoryStore.shared
    @State private var snapshot = UsageAnalyticsService.shared.snapshot
    @State private var mode: QuotaHistoryMode = .quota
    @State private var targetID: String?
    @State private var windowID: String?
    @State private var model: String?

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { timeline in
            if let target = targets.first(where: { $0.id == targetID }) ?? targets.first {
                let now = timeline.date
                let tokenHistory = mode == .tokens
                    ? LocalTokenHistory(snapshot: snapshot, provider: target.provider, model: model, now: now) : nil
                let windows = target.report?.weeklyWindows ?? []
                let window = windows.first { $0.id == windowID } ?? windows.first
                VStack(alignment: .leading, spacing: 7) {
                    controls(target: target, windows: windows, window: window, models: tokenHistory?.models ?? [])
                    if let tokenHistory {
                        LocalTokenChartView(history: tokenHistory)
                    } else if let report = target.report, let window {
                        WeeklyQuotaChartView(data: WeeklyQuotaChart(report: report, window: window,
                                                                   history: quotaHistory.history, now: now))
                    } else {
                        Text("No verified weekly quota for this connection.")
                            .font(.callout).foregroundStyle(.secondary).padding(.vertical, 12)
                    }
                    if let openInStatistics {
                        Button("Open in Statistics") {
                            openInStatistics(QuotaHistoryRequest(targetID: target.id, provider: target.provider,
                                mode: mode, windowID: window?.id, model: model))
                        }
                        .controlSize(.small)
                    }
                }
            }
        }
        .onReceive(UsageAnalyticsService.shared.$snapshot) { snapshot = $0 }
        .onAppear {
            if let request { apply(request) }
            else if targets.count == 1, targets.first?.report?.weeklyWindows.isEmpty != false { mode = .tokens }
        }
        .onChange(of: request) { if let request = $0 { apply(request) } }
    }

    @ViewBuilder
    private func controls(target: QuotaHistoryTarget, windows: [ProviderLimitWindow],
                          window: ProviderLimitWindow?, models: [String]) -> some View {
        let choices = mode == .tokens ? uniqueProviders : targets
        HStack(spacing: 9) {
            Picker("History source", selection: $mode) {
                ForEach(QuotaHistoryMode.allCases) { Text($0.rawValue).tag($0) }
            }
            .labelsHidden().pickerStyle(.segmented).frame(width: 151)
            if choices.count > 1 {
                Picker(mode == .tokens ? "Provider" : "Account", selection: Binding(
                    get: { mode == .tokens ? choices.first(where: { $0.provider == target.provider })?.id ?? target.id : target.id },
                    set: { value in targetID = value; windowID = nil; model = nil }
                )) {
                    ForEach(choices) { choice in
                        Text(mode == .tokens ? choice.provider.title : choice.label).tag(choice.id)
                    }
                }
                .labelsHidden().fixedSize()
            } else {
                Text(mode == .tokens ? target.provider.title : target.label)
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
            }
            if mode == .tokens, !models.isEmpty {
                Picker("Model", selection: Binding(get: { model.flatMap { models.contains($0) ? $0 : nil } },
                                                   set: { model = $0 })) {
                    Text("All models").tag(String?.none)
                    ForEach(models, id: \.self) { Text($0).tag(Optional($0)) }
                }
                .labelsHidden().fixedSize()
            } else if mode == .quota, windows.count > 1, let window {
                Picker("Quota window", selection: Binding(get: { window.id }, set: { windowID = $0 })) {
                    ForEach(windows) { scope in Text(scope.weeklyModel ?? "Account quota").tag(scope.id) }
                }
                .labelsHidden().fixedSize()
            } else if mode == .quota, let name = window?.weeklyModel {
                Text(name).font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            Text(mode == .quota ? "Provider reports" : "On this Mac")
                .font(.system(size: 11)).foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .controlSize(.small)
    }

    private var uniqueProviders: [QuotaHistoryTarget] {
        var seen = Set<StatisticsProvider>()
        return targets.filter { seen.insert($0.provider).inserted }
    }

    private func apply(_ request: QuotaHistoryRequest) {
        targetID = request.targetID
        mode = request.mode
        windowID = request.windowID
        model = request.model
    }
}

private struct WeeklyQuotaChartView: View {
    private struct Shade: Identifiable {
        let time: Range<Date>
        let used: Double
        let budget: Double
        var id: Date { time.lowerBound }
    }

    let data: WeeklyQuotaChart
    @State private var selectedHour: Date?
    private let colors = HistoryChartColors()

    var body: some View {
        let samples = data.hours.map { hour in
            HourlyChartSample(time: hour.start,
                parts: (hour.percentagePoints ?? hour.partialPercentagePoints).map { [Double($0)] },
                partial: hour.partialPercentagePoints != nil)
        }
        VStack(spacing: 5) {
            chartHeading(heading)
            if let start = data.cycleStart, let latest = data.latest {
                weekly(start: start, latest: latest)
            } else {
                Text("Waiting for a quota measurement with a reset time.")
                    .font(.system(size: 10)).foregroundStyle(colors.labels).padding(.vertical, 8)
            }
            chartHeading("Hourly usage, % of weekly limit · Last 72h")
            HoursChart(samples: samples, colors: [colors.mint], guide: data.sustainablePerHour,
                       percent: true, selected: $selectedHour, selectionText: selectedHourText)
        }
        .padding([.vertical, .leading], 7)
        .padding(.trailing, 13)
        .background(colors.canvas, in: RoundedRectangle(cornerRadius: 6))
    }

    private var heading: String {
        var items = ["Weekly limit"]
        if let used = data.pace.usedPercent { items.append("\(used)% used") }
        switch data.pace.state {
        case .current:
            if let remaining = data.pace.timeToReset {
                items.append("\(Int(ceil(remaining / UsageHours.hour)))h to reset")
            }
        case .stale: items.append("Stale measurement")
        case .resetPending: items.append("Reset due")
        case .partial: items.append("Reset time unavailable")
        case .unavailable: items.append("Unavailable")
        }
        return items.joined(separator: " · ")
    }

    private var selectedHourText: String? {
        guard let selectedHour, let hour = data.hours.first(where: { $0.start == selectedHour }) else { return nil }
        let text: String
        if let measured = hour.percentagePoints { text = "\(measured)% measured" }
        else if let partial = hour.partialPercentagePoints { text = "≥ \(partial)% observed" }
        else { text = "No sample" }
        return "\(historyHourText(hour.start)) · \(text)"
    }

    private func weekly(start: Date, latest: WeeklyQuotaObservation) -> some View {
        let days = (0...7).map { start.addingTimeInterval(Double($0) * WeeklyQuotaPace.daySeconds) }
        let calendar = Calendar.autoupdatingCurrent
        let firstDay = calendar.startOfDay(for: start)
        let ticks = (0...7).compactMap { calendar.date(byAdding: .day, value: $0, to: firstDay) }
            .filter { start <= $0 && $0 < latest.reset }
        let top = min(210, max(110, ceil((data.forecasts.map(\.atReset).max() ?? 100) / 20) * 20 + 10))
        let levels = Array(stride(from: 0.0, through: top, by: 20.0))
        let shades = shadingSpans(cycleStart: start, days: days)
        return Chart {
            ForEach(shades) { shade in
                shadingMark(shade)
            }
            plotGrid(times: ticks, levels: levels)
            ForEach(days, id: \.self) { day in
                LineMark(x: .value("Day", day), y: .value("Budget", WeeklyQuotaPace.budget(at: day, cycleStart: start)),
                         series: .value("Series", "Daily budget"))
                    .interpolationMethod(.stepEnd).foregroundStyle(colors.budget).lineStyle(StrokeStyle(lineWidth: 1))
            }
            RuleMark(y: .value("Limit", 100))
                .foregroundStyle(colors.limit).lineStyle(StrokeStyle(lineWidth: 0.9))
            ForEach(Array(data.segments.enumerated()), id: \.offset) { section in
                ForEach(section.element, id: \.time) { sample in
                    LineMark(x: .value("Observed", sample.time), y: .value("Used", sample.used),
                             series: .value("Series", "Actual \(section.offset)"))
                        .interpolationMethod(.stepEnd).foregroundStyle(colors.actual).lineStyle(StrokeStyle(lineWidth: 1.7))
                }
                if section.element.count == 1, let sample = section.element.first {
                    PointMark(x: .value("Observed", sample.time), y: .value("Used", sample.used))
                        .symbolSize(12).foregroundStyle(colors.actual)
                }
            }
            ForEach(data.forecasts) { forecast in
                let color = forecast.period == .window ? colors.gold : colors.coral
                ForEach([latest.time, latest.reset], id: \.self) { time in
                    LineMark(x: .value("Time", time),
                             y: .value("Projected used", time == latest.time ? Double(latest.used) : forecast.atReset),
                             series: .value("Series", forecast.period.rawValue))
                        .foregroundStyle(color).lineStyle(StrokeStyle(lineWidth: 1.3, lineCap: .round, dash: [0.2, 2.6]))
                }
            }
        }
        .chartLegend(.hidden)
        .chartXScale(domain: start...latest.reset)
        .chartYScale(domain: 0...top)
        .chartXAxis {
            AxisMarks(values: ticks) { value in
                AxisTick(centered: false, length: 3).foregroundStyle(colors.border)
                AxisValueLabel(centered: false, anchor: .top, collisionResolution: .disabled,
                               offsetsMarks: false, verticalSpacing: 3) {
                    if let date = value.as(Date.self) { axisLabel(historyAxisDate(date)) }
                }
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading, values: levels) { value in
                AxisTick(length: 3).foregroundStyle(colors.border)
                AxisValueLabel {
                    if let percent = value.as(Double.self) { yAxisLabel(formattedNumber(percent, fractionDigits: 0)) }
                }
            }
        }
        .chartPlotStyle { plot in
            plot.background(colors.plot).clipped().border(colors.border, width: 0.6)
                .overlay(alignment: .topLeading) { weeklyLegend.padding(4) }
        }
        .aspectRatio(2.66, contentMode: .fit)
        .accessibilityLabel("Weekly quota, cumulative use, daily budget, and projections")
    }

    private func shadingSpans(cycleStart: Date, days: [Date]) -> [Shade] {
        data.segments.flatMap { samples in
            zip(samples, samples.dropFirst()).flatMap { pair in
                let start = pair.0.time
                let end = pair.1.time
                let cuts = [start] + days.filter { start < $0 && $0 < end } + [end]
                return zip(cuts, cuts.dropFirst()).map { left, right in
                    Shade(time: left..<right, used: Double(pair.0.used),
                          budget: WeeklyQuotaPace.budget(at: left, cycleStart: cycleStart))
                }
            }
        }
    }

    private func shadingMark(_ shade: Shade) -> some ChartContent {
        let color = shade.used <= shade.budget ? colors.mint : colors.limit
        let lower = min(shade.used, shade.budget)
        let upper = max(shade.used, shade.budget)
        return RectangleMark(xStart: .value("Start", shade.time.lowerBound), xEnd: .value("End", shade.time.upperBound),
                             yStart: .value("Low", lower), yEnd: .value("High", upper))
            .foregroundStyle(color.opacity(0.17))
    }

    private var weeklyLegend: some View {
        insetLegend {
            swatch("Usage, %", colors.actual)
            swatch("Daily budget · 14.3%/day with carryover", colors.budget)
            if let points = data.pace.headroomPoints {
                let amount = formattedNumber(abs(points), fractionDigits: 1)
                swatch(points >= 0 ? "End-of-day headroom · \(amount) pp" : "Over today's budget · \(amount) pp",
                       (points >= 0 ? colors.mint : colors.limit).opacity(0.45), fill: true)
            }
            ForEach(data.forecasts) { forecast in
                let estimate = formattedNumber(forecast.atReset, fractionDigits: 0)
                let rate = forecast.period == .window ? "Week pace" : "24h pace"
                let limit = forecast.exhaustion.map { " · 100% " + historyHourText($0) } ?? ""
                swatch("\(rate) · \(estimate)% at reset\(limit)",
                       forecast.period == .window ? colors.gold : colors.coral, dotted: true)
            }
        }
    }
}

private struct LocalTokenChartView: View {
    let history: LocalTokenHistory
    @State private var selectedHour: Date?
    private let colors = HistoryChartColors()

    var body: some View {
        let samples = history.hours.map { hour in
            HourlyChartSample(time: hour.start, parts: hour.tokens.map {
                [Double($0.billableInputTokens), Double($0.cachedInputTokens) + Double($0.cacheWriteInputTokens), Double($0.outputTokens)]
            })
        }
        VStack(spacing: 5) {
            chartHeading("Local tokens per hour · Last 72h")
            HoursChart(samples: samples, colors: [colors.actual, colors.cache, colors.mint],
                       guide: nil, percent: false, selected: $selectedHour, selectionText: selectedHourText)
        }
        .padding([.vertical, .leading], 7)
        .padding(.trailing, 13)
        .background(colors.canvas, in: RoundedRectangle(cornerRadius: 6))
    }

    private var selectedHourText: String? {
        guard let selectedHour, let hour = history.hours.first(where: { $0.start == selectedHour }) else { return nil }
        let text = hour.tokens.map { "\(groupedInteger($0.totalTokens)) tokens" } ?? "No recorded data"
        return "\(historyHourText(hour.start)) · \(text)"
    }
}

private struct HourlyChartSample: Identifiable {
    let time: Date
    let parts: [Double]?
    var partial = false
    var id: Date { time }
}

private struct HoursChart: View {
    let samples: [HourlyChartSample]
    let colors: [Color]
    let guide: Double?
    let percent: Bool
    @Binding var selected: Date?
    let selectionText: String?
    private let palette = HistoryChartColors()

    var body: some View {
        let maximum = max(percent ? 1 : 10, samples.compactMap { $0.parts?.reduce(0, +) }.max() ?? 0, guide ?? 0)
        let levels = hourlyAxisLevels(maximum: maximum)
        let ceiling = (levels.last ?? maximum) * 1.05
        let ticks = samples.dropFirst(4).enumerated().filter { $0.offset.isMultiple(of: 12) }.map(\.element.time)
        Chart {
            plotGrid(times: ticks, levels: levels)
            ForEach(samples) { sample in
                if let parts = sample.parts {
                    ForEach(Array(parts.indices), id: \.self) { index in
                        let low = parts.prefix(index).reduce(0, +)
                        RectangleMark(xStart: .value("Hour", sample.time.addingTimeInterval(240)),
                                      xEnd: .value("Hour end", sample.time.addingTimeInterval(UsageHours.hour - 240)),
                                      yStart: .value("Subtotal", low), yEnd: .value("Total", low + parts[index]))
                            .foregroundStyle(colors[index].opacity(sample.partial ? 0.55 : 1))
                    }
                }
            }
            if let guide {
                RuleMark(y: .value("Sustainable pace", guide))
                    .foregroundStyle(palette.gold).lineStyle(StrokeStyle(lineWidth: 0.9, dash: [3, 2]))
            }
            if let selected {
                RuleMark(x: .value("Selected hour", selected.addingTimeInterval(UsageHours.hour / 2)))
                    .foregroundStyle(palette.labels.opacity(0.5))
            }
        }
        .chartLegend(.hidden)
        .chartXScale(domain: hourDomain)
        .chartYScale(domain: 0...ceiling)
        .chartXAxis {
            AxisMarks(values: ticks) { value in
                AxisTick(centered: false, length: 3).foregroundStyle(palette.border)
                AxisValueLabel(centered: false, anchor: .top, collisionResolution: .disabled,
                               offsetsMarks: false, verticalSpacing: 3) {
                    if let date = value.as(Date.self) { axisLabel(historyAxisDate(date, includingHour: true)) }
                }
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading, values: levels) { value in
                AxisTick(length: 3).foregroundStyle(palette.border)
                AxisValueLabel {
                    if let number = value.as(Double.self) {
                        yAxisLabel(percent ? formattedNumber(number, fractionDigits: ceiling <= 5 ? 1 : 0)
                            : compactCount(Int(min(number, Double(Int.max / 2)))), width: percent ? 20 : 27)
                    }
                }
            }
        }
        .chartPlotStyle { plot in
            plot.background(palette.plot).clipped().border(palette.border, width: 0.6)
                .overlay(alignment: .topLeading) { legend.padding(4) }
                .overlay {
                    if !samples.contains(where: { $0.parts != nil }) {
                        Text(percent ? "Collecting hourly quota history" : "No recorded tokens for this period")
                            .font(.system(size: 10)).foregroundStyle(palette.labels).padding(4)
                            .background(palette.plot.opacity(0.93), in: RoundedRectangle(cornerRadius: 3))
                    }
                }
                .overlay(alignment: .topTrailing) {
                    if let selectionText {
                        Text(selectionText).font(.system(size: 9)).foregroundStyle(palette.labels)
                            .lineLimit(1).padding(4)
                            .background(palette.plot, in: RoundedRectangle(cornerRadius: 3)).padding(4)
                    }
                }
        }
        .chartOverlay { proxy in
            GeometryReader { geometry in
                Rectangle().fill(.clear).contentShape(Rectangle())
                    .onContinuousHover { phase in
                        switch phase {
                        case .active(let point):
                            let plot = geometry[proxy.plotAreaFrame]
                            let date: Date? = plot.contains(point) ? proxy.value(atX: point.x - plot.minX) : nil
                            selected = date.flatMap { time in
                                samples.last(where: { $0.time <= time && time.timeIntervalSince($0.time) < UsageHours.hour })?.time
                            }
                        case .ended: selected = nil
                        }
                    }
            }
        }
        .aspectRatio(3.85, contentMode: .fit)
        .accessibilityLabel(percent ? "Hourly percentage of weekly quota" : "Hourly local input, cache, and output tokens")
    }

    private var hourDomain: ClosedRange<Date> {
        let first = samples.first?.time ?? .now
        let last = samples.last?.time ?? first
        return first...last.addingTimeInterval(UsageHours.hour)
    }

    @ViewBuilder private var legend: some View {
        if percent {
            if guide != nil || samples.contains(where: \.partial) {
                insetLegend {
                    if let guide {
                        swatch("Sustainable pace · \(formattedNumber(guide, fractionDigits: 2))%/h", palette.gold, dotted: true)
                    }
                    if samples.contains(where: \.partial) {
                        swatch("Observed part of hour", palette.mint.opacity(0.55), fill: true)
                    }
                }
            }
        } else if samples.contains(where: { $0.parts != nil }) {
            insetLegend {
                HStack(spacing: 7) {
                    swatch("Uncached input", palette.actual, fill: true)
                    swatch("Cache", palette.cache, fill: true)
                    swatch("Output", palette.mint, fill: true)
                }
            }
        }
    }
}

private struct HistoryChartColors {
    let canvas = chartColor(0x17181c)
    let plot = chartColor(0x1b1e24)
    let labels = chartColor(0xc7c9d0)
    let title = chartColor(0xe8e9ed)
    let grid = chartColor(0x2b2e36)
    let border = chartColor(0x414550)
    let actual = chartColor(0x7ba1fa)
    let budget = chartColor(0x969ba7)
    let limit = chartColor(0xe35d68)
    let gold = chartColor(0xffb75d)
    let coral = chartColor(0xef8157)
    let mint = chartColor(0x65d7a4)
    let cache = chartColor(0xa4b9ee)
}

private func chartColor(_ rgb: UInt32) -> Color {
    Color(red: Double((rgb >> 16) & 255) / 255, green: Double((rgb >> 8) & 255) / 255, blue: Double(rgb & 255) / 255)
}

@ChartContentBuilder
private func plotGrid(times: [Date], levels: [Double]) -> some ChartContent {
    let grid = HistoryChartColors().grid
    ForEach(times, id: \.self) { time in
        RuleMark(x: .value("Time", time)).foregroundStyle(grid).lineStyle(StrokeStyle(lineWidth: 0.5))
    }
    ForEach(levels, id: \.self) { level in
        RuleMark(y: .value("Level", level)).foregroundStyle(grid).lineStyle(StrokeStyle(lineWidth: 0.5))
    }
}

private func hourlyAxisLevels(maximum: Double) -> [Double] {
    let interval = maximum / 6
    let magnitude = pow(10, floor(log10(interval)))
    let factor = [1.0, 2, 2.5, 5, 10].first { $0 * magnitude >= interval } ?? 10
    let step = factor * magnitude
    return (0...Int(ceil(maximum / step))).map { Double($0) * step }
}

private func chartHeading(_ title: String) -> some View {
    Text(title).font(.system(size: 11)).foregroundStyle(HistoryChartColors().title)
        .lineLimit(1).frame(maxWidth: .infinity)
}

private func axisLabel(_ text: String) -> some View {
    Text(text).font(.system(size: 9)).foregroundStyle(HistoryChartColors().labels).fixedSize()
}

private func yAxisLabel(_ text: String, width: CGFloat = 20) -> some View {
    axisLabel(text).monospacedDigit().frame(width: width, alignment: .trailing)
}

private func insetLegend<Content: View>(@ViewBuilder content: () -> Content) -> some View {
    let palette = HistoryChartColors()
    return VStack(alignment: .leading, spacing: 1, content: content)
        .padding(.horizontal, 4).padding(.vertical, 3)
        .background(palette.plot.opacity(0.92), in: RoundedRectangle(cornerRadius: 2))
        .overlay(RoundedRectangle(cornerRadius: 2).strokeBorder(palette.border, lineWidth: 0.6))
}

private func swatch(_ label: String, _ color: Color, fill: Bool = false, dotted: Bool = false) -> some View {
    HStack(spacing: 4) {
        Canvas { context, size in
            if fill {
                context.fill(Path(CGRect(x: 0, y: 1, width: size.width, height: size.height - 2)), with: .color(color))
            } else {
                var line = Path()
                line.move(to: CGPoint(x: 0, y: size.height / 2))
                line.addLine(to: CGPoint(x: size.width, y: size.height / 2))
                context.stroke(line, with: .color(color), style: StrokeStyle(lineWidth: 1.1,
                    lineCap: .round, dash: dotted ? [0.2, 2.4] : []))
            }
        }
        .frame(width: 14, height: 7).accessibilityHidden(true)
        Text(label).lineLimit(1)
    }
    .font(.system(size: 9)).foregroundStyle(HistoryChartColors().labels)
}

private func historyAxisDate(_ date: Date, includingHour: Bool = false) -> String {
    let fields = Calendar.autoupdatingCurrent.dateComponents([.day, .month, .hour], from: date)
    let day = String(format: "%02d.%02d", fields.day ?? 0, fields.month ?? 0)
    return includingHour ? day + String(format: " %02dh", fields.hour ?? 0) : day
}

private func historyHourText(_ date: Date) -> String {
    date.formatted(.dateTime.day().month(.abbreviated).hour().minute().timeZone(.specificName(.short)))
}
