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
                VStack(alignment: .leading, spacing: 10) {
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
            else if targets.count == 1, targets.first?.provider == .qwen { mode = .tokens }
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
    @Environment(\.colorScheme) private var colorScheme
    @State private var selectedHour: Date?
    private var colors: HistoryChartColors { HistoryChartColors(dark: colorScheme == .dark) }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            chartHeading("Weekly limit", detail: summary)
            if let start = data.cycleStart, let latest = data.latest {
                weekly(start: start, latest: latest)
                weeklyLegend
            } else {
                Text("Waiting for an observation with a reported reset time.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            chartHeading("Quota used per hour · Last 72 hours", detail: "Sampled · up to 15 min between observations")
            let samples = data.hours.map { HourlyChartSample(time: $0.start, parts: $0.percentagePoints.map { [Double($0)] }) }
            HoursChart(samples: samples, colors: [colors.mint], guide: data.sustainablePerHour,
                       percent: true, selected: $selectedHour)
            HStack(spacing: 12) {
                swatch("Measured", colors.mint, fill: true)
                swatch("Missing sample", .secondary, fill: true)
                if let guide = data.sustainablePerHour {
                    swatch("\(formattedNumber(guide, fractionDigits: 2))%/h sustainable", colors.gold, dotted: true)
                }
            }
            if let selectedHour, let hour = data.hours.first(where: { $0.start == selectedHour }) {
                Text("\(historyHourText(hour.start)) · \(hour.percentagePoints.map { "\($0)% of weekly quota" } ?? "Missing sample")")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
    }

    private var summary: String {
        var items = data.pace.usedPercent.map { ["\($0)% used"] } ?? []
        switch data.pace.state {
        case .current:
            if let remaining = data.pace.timeToReset { items.append("\(WeeklyQuotaPace.countdownText(remaining)) to reset") }
            if data.forecasts.isEmpty { items.append("Collecting history") }
        case .stale: items.append("Stale measurement")
        case .resetPending: items.append("Reset due")
        case .partial: items.append("Reset time unavailable")
        case .unavailable: items.append("Weekly quota unavailable")
        }
        return items.joined(separator: " · ")
    }

    private func weekly(start: Date, latest: WeeklyQuotaObservation) -> some View {
        let days = (0...7).map { start.addingTimeInterval(Double($0) * WeeklyQuotaPace.daySeconds) }
        let top = min(170, max(110, ceil((data.forecasts.map(\.atReset).max() ?? 100) / 20) * 20 + 10))
        let shades = shadingSpans(cycleStart: start, days: days)
        return Chart {
            ForEach(shades) { shade in
                shadingMark(shade)
            }
            RuleMark(y: .value("Limit", 100))
                .foregroundStyle(colors.limit).lineStyle(StrokeStyle(lineWidth: 1))
            ForEach(days, id: \.self) { day in
                LineMark(x: .value("Day", day), y: .value("Budget", WeeklyQuotaPace.budget(at: day, cycleStart: start)),
                         series: .value("Series", "Daily budget"))
                    .interpolationMethod(.stepEnd).foregroundStyle(colors.budget).lineStyle(StrokeStyle(lineWidth: 1.3))
            }
            ForEach(Array(data.segments.enumerated()), id: \.offset) { section in
                ForEach(section.element, id: \.time) { sample in
                    LineMark(x: .value("Observed", sample.time), y: .value("Used", sample.used),
                             series: .value("Series", "Actual \(section.offset)"))
                        .interpolationMethod(.stepEnd).foregroundStyle(colors.actual).lineStyle(StrokeStyle(lineWidth: 2))
                }
                if let sample = section.element.last, section.element.count == 1 || sample == latest {
                    PointMark(x: .value("Observed", sample.time), y: .value("Used", sample.used))
                        .symbolSize(16).foregroundStyle(colors.actual)
                }
            }
            ForEach(data.forecasts) { forecast in
                let color = forecast.period == .window ? colors.gold : colors.coral
                ForEach([latest.time, latest.reset], id: \.self) { time in
                    LineMark(x: .value("Time", time),
                             y: .value("Projected used", time == latest.time ? Double(latest.used) : forecast.atReset),
                             series: .value("Series", forecast.period.rawValue))
                        .foregroundStyle(color).lineStyle(StrokeStyle(lineWidth: 2, dash: [2, 4]))
                }
            }
        }
        .chartLegend(.hidden)
        .chartXScale(domain: start...latest.reset)
        .chartYScale(domain: 0...top)
        .chartXAxis {
            AxisMarks(values: Array(days.dropLast())) {
                AxisGridLine().foregroundStyle(Color.secondary.opacity(0.18))
                AxisValueLabel(format: .dateTime.day().month(.abbreviated))
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading, values: .stride(by: 20)) { value in
                AxisGridLine().foregroundStyle(Color.secondary.opacity(0.18))
                AxisValueLabel {
                    if let percent = value.as(Double.self) { Text("\(formattedNumber(percent, fractionDigits: 0))%") }
                }
            }
        }
        .chartPlotStyle { $0.background(colors.plot).clipped() }
        .frame(height: 219)
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
            .foregroundStyle(color.opacity(0.16))
    }

    private var weeklyLegend: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 12) {
                swatch("Used", colors.actual)
                swatch("Daily budget", colors.budget)
                swatch("100% limit", colors.limit)
                if let points = data.pace.headroomPoints {
                    swatch("\(formattedNumber(abs(points), fractionDigits: 1)) pp \(points >= 0 ? "headroom" : "over plan")",
                           points >= 0 ? colors.mint : colors.limit, fill: true)
                }
            }
            if !data.forecasts.isEmpty {
                HStack(spacing: 12) {
                    ForEach(data.forecasts) { forecast in
                        let estimate = formattedNumber(forecast.atReset, fractionDigits: 0)
                        let end = forecast.exhaustion.map { " · limit " + historyHourText($0) } ?? ""
                        swatch("\(forecast.period.rawValue) \(estimate)%\(end)",
                               forecast.period == .window ? colors.gold : colors.coral, dotted: true)
                    }
                }
            }
        }
    }
}

private struct LocalTokenChartView: View {
    let history: LocalTokenHistory
    @Environment(\.colorScheme) private var colorScheme
    @State private var selectedHour: Date?

    var body: some View {
        let colors = HistoryChartColors(dark: colorScheme == .dark)
        let samples = history.hours.map { hour in
            HourlyChartSample(time: hour.start, parts: hour.tokens.map {
                [Double($0.billableInputTokens), Double($0.cachedInputTokens) + Double($0.cacheWriteInputTokens), Double($0.outputTokens)]
            })
        }
        VStack(alignment: .leading, spacing: 8) {
            chartHeading("Tokens per hour · Last 72 hours",
                         detail: history.scannedAt.map { "Scanned " + historyHourText($0) } ?? "Session timestamps")
            if history.models.isEmpty {
                Text("No recorded tokens for this period.").font(.callout).foregroundStyle(.secondary)
            }
            HoursChart(samples: samples, colors: [colors.actual, colors.cache, colors.mint],
                       guide: nil, percent: false, selected: $selectedHour)
            HStack(spacing: 12) {
                swatch("Uncached input", colors.actual, fill: true)
                swatch("Cache", colors.cache, fill: true)
                swatch("Output", colors.mint, fill: true)
            }
            if let selectedHour, let hour = history.hours.first(where: { $0.start == selectedHour }) {
                let text = hour.tokens.map { "\(groupedInteger($0.totalTokens)) tokens" } ?? "No recorded data"
                Text("\(historyHourText(hour.start)) · \(text)").font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
    }
}

private struct HourlyChartSample: Identifiable {
    let time: Date
    let parts: [Double]?
    var id: Date { time }
}

private struct HoursChart: View {
    let samples: [HourlyChartSample]
    let colors: [Color]
    let guide: Double?
    let percent: Bool
    @Binding var selected: Date?
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let palette = HistoryChartColors(dark: colorScheme == .dark)
        let ceiling = max(percent ? 1 : 10, samples.compactMap { $0.parts?.reduce(0, +) }.max() ?? 0, guide ?? 0) * 1.08
        Chart {
            ForEach(samples) { sample in
                let end = sample.time.addingTimeInterval(UsageHours.hour)
                if let parts = sample.parts {
                    ForEach(Array(parts.indices), id: \.self) { index in
                        let low = parts.prefix(index).reduce(0, +)
                        RectangleMark(xStart: .value("Hour", sample.time.addingTimeInterval(360)),
                                      xEnd: .value("Hour end", end.addingTimeInterval(-360)),
                                      yStart: .value("Subtotal", low), yEnd: .value("Total", low + parts[index]))
                            .foregroundStyle(colors[index])
                    }
                } else {
                    RectangleMark(xStart: .value("Hour", sample.time.addingTimeInterval(360)),
                                  xEnd: .value("Hour end", end.addingTimeInterval(-360)),
                                  yStart: .value("Base", 0), yEnd: .value("Gap", ceiling * 0.017))
                        .foregroundStyle(Color.secondary.opacity(0.45))
                }
            }
            if let guide {
                RuleMark(y: .value("Sustainable pace", guide))
                    .foregroundStyle(palette.gold).lineStyle(StrokeStyle(lineWidth: 1.3, dash: [4, 3]))
            }
            if let selected {
                RuleMark(x: .value("Selected hour", selected.addingTimeInterval(UsageHours.hour / 2)))
                    .foregroundStyle(Color.secondary.opacity(0.6))
            }
        }
        .chartLegend(.hidden)
        .chartYScale(domain: 0...ceiling)
        .chartXAxis {
            AxisMarks(values: samples.enumerated().filter { $0.offset.isMultiple(of: 12) }.map(\.element.time)) {
                AxisGridLine().foregroundStyle(Color.secondary.opacity(0.18))
                AxisValueLabel(format: .dateTime.day().month(.abbreviated).hour())
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading, values: .automatic(desiredCount: 5)) { value in
                AxisGridLine().foregroundStyle(Color.secondary.opacity(0.18))
                AxisValueLabel {
                    if let number = value.as(Double.self) {
                        Text(percent ? "\(formattedNumber(number, fractionDigits: ceiling <= 5 ? 1 : 0))%"
                            : compactCount(Int(min(number, Double(Int.max / 2)))))
                    }
                }
            }
        }
        .chartPlotStyle { $0.background(palette.plot) }
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
        .frame(height: 153)
        .accessibilityLabel(percent ? "Hourly percentage of weekly quota" : "Hourly local input, cache, and output tokens")
    }
}

private struct HistoryChartColors {
    let actual: Color
    let budget: Color
    let limit: Color
    let gold: Color
    let coral: Color
    let mint: Color
    let cache: Color
    let plot: Color

    init(dark: Bool) {
        func tone(_ light: UInt32, _ darkValue: UInt32) -> Color {
            let rgb = dark ? darkValue : light
            return Color(red: Double((rgb >> 16) & 255) / 255, green: Double((rgb >> 8) & 255) / 255, blue: Double(rgb & 255) / 255)
        }
        actual = tone(0x275eba, 0x77a6fd)
        budget = tone(0x596778, 0x8e939b)
        limit = tone(0xbd3840, 0xe8565d)
        gold = tone(0x955b06, 0xf4b558)
        coral = tone(0xb14728, 0xe9784c)
        mint = tone(0x157652, 0x5ed99c)
        cache = tone(0x5973ac, 0xa4b9ee)
        plot = tone(0xffffff, 0x1b1f25)
    }
}

private func chartHeading(_ title: String, detail: String) -> some View {
    HStack {
        Text(title).font(.system(size: 12, weight: .semibold))
        Spacer(minLength: 6)
        Text(detail).font(.system(size: 11)).foregroundStyle(.secondary)
    }
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
                context.stroke(line, with: .color(color), style: StrokeStyle(lineWidth: 1.5, dash: dotted ? [2, 2] : []))
            }
        }
        .frame(width: 14, height: 8).accessibilityHidden(true)
        Text(label)
    }
    .font(.system(size: 10.5)).foregroundStyle(.secondary)
}

private func historyHourText(_ date: Date) -> String {
    date.formatted(.dateTime.day().month(.abbreviated).hour().minute().timeZone(.specificName(.short)))
}
