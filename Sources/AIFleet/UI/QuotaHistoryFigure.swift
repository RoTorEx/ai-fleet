import AppKit
import CoreText
import SwiftUI

enum QuotaHistoryFigureData {
    case quota(WeeklyQuotaChart)
    case currentQuota(QuotaLimitReading)
    case unsupportedQuota
    case tokens(LocalTokenHistory, series: LocalTokenSeries? = nil)
}

private extension WeeklyQuotaChart.Forecast.Period {
    var strokeStyle: (color: CGColor, dash: [CGFloat], phase: CGFloat) {
        // Equal projections share a path. Complementary dashes leave both colors visible.
        switch self {
        case .window: return (Palette.amber, [3, 5], 0)
        case .day: return (Palette.coral, [1.5, 6.5], 4)
        }
    }
}

private extension LocalTokenSeries {
    var color: CGColor {
        switch self {
        case .uncachedInput: return Palette.uncachedInput
        case .cache: return Palette.cache
        case .output: return Palette.mint
        }
    }
}

struct QuotaHourTick: Equatable {
    let date: Date
    let hour: Int

    var isMajor: Bool { hour == 0 || hour == 12 }

    static func inDomain(_ domain: ClosedRange<Date>, calendar: Calendar = .autoupdatingCurrent) -> [Self] {
        var ticks: [Self] = []
        var day = calendar.startOfDay(for: domain.lowerBound)
        while day <= domain.upperBound {
            for hour in stride(from: 0, to: 24, by: 6) {
                if let date = calendar.date(bySettingHour: hour, minute: 0, second: 0, of: day, matchingPolicy: .strict),
                   calendar.isDate(date, inSameDayAs: day), domain.contains(date) {
                    ticks.append(Self(date: date, hour: hour))
                }
            }
            guard let nextDay = calendar.date(byAdding: .day, value: 1, to: day), nextDay > day else { break }
            day = calendar.startOfDay(for: nextDay)
        }
        return ticks
    }
}

enum QuotaHistoryPanel: Equatable {
    case overview
    case hourly

    var headerHeight: CGFloat { self == .overview ? 24 : 34 }
    var height: CGFloat { headerHeight + (self == .overview ? 144 : 98) }
}

struct QuotaChartCursor: Equatable {
    enum Source: Equatable { case overview, hourlyQuota, localTokens }

    let source: Source
    let time: Date
}

struct QuotaHistoryHeaderMetric {
    let label: String
    let color: CGColor
}

struct HourlyChartScale {
    let maximum: Double
    let levels: [Double]

    init(measuredMaximum: Double, minimum: Double) {
        let upper = max(measuredMaximum, minimum)
        let interval = upper / 5
        let magnitude = pow(10, floor(log10(interval)))
        let factor = [1.0, 2, 3, 4, 5, 6, 8, 10].first { $0 * magnitude >= interval } ?? 10
        let step = factor * magnitude
        let count = Int(ceil(upper / step - 1e-9))
        maximum = max(upper, Double(count) * step)
        levels = (0...count).map { Double($0) * step }
    }
}

struct QuotaHistoryFigure: View {
    let drawing: QuotaHistoryDrawing
    let panel: QuotaHistoryPanel
    @Binding var cursor: QuotaChartCursor?
    @State private var legendHovered = false
    @Environment(\.colorScheme) private var colorScheme

    private var source: QuotaChartCursor.Source {
        if panel == .overview { return .overview }
        return drawing.drawsQuota ? .hourlyQuota : .localTokens
    }

    var body: some View {
        let tracksHours = panel == .hourly && drawing.hasHourlySamples
        let selectedTime = legendHovered ? nil : cursor?.time
        let details = drawing.accessibilityDetails(for: panel, selectedTime: selectedTime)
        let description = selectedTime == nil ? details + ". " + drawing.legendDescription(for: panel) : details
        let chart = Canvas { graphics, size in
            graphics.withCGContext {
                drawing.draw(panel, in: $0, size: size, selectedTime: selectedTime, showsLegend: legendHovered,
                             colorScheme: colorScheme)
            }
        }
        .frame(height: panel.height)
        .accessibilityLabel(drawing.accessibilityTitle(for: panel))
        .accessibilityValue(description)

        Group {
            if tracksHours {
                chart.accessibilityAdjustableAction { direction in
                    switch direction {
                    case .increment: moveCursor(to: drawing.adjacentHour(to: cursor?.time, offset: 1))
                    case .decrement: moveCursor(to: drawing.adjacentHour(to: cursor?.time, offset: -1))
                    @unknown default: break
                    }
                }
            } else {
                chart
            }
        }
        .overlay {
            GeometryReader { geometry in
                let layout = FigureLayout(canvas: geometry.size, panel: panel)
                ZStack(alignment: .topLeading) {
                    Color.clear
                        .contentShape(Rectangle())
                        .onContinuousHover { phase in
                            switch phase {
                            case .active(let location):
                                moveCursor(to: drawing.selection(at: location, in: geometry.size, panel: panel))
                            case .ended:
                                moveCursor(to: nil)
                            }
                        }
                        .accessibilityHidden(true)
                    heading(drawing.heading(for: panel), metrics: drawing.headerMetrics(for: panel, colorScheme: colorScheme))
                        .frame(width: max(0, layout.plot.width), height: layout.plot.minY)
                        .offset(x: layout.plot.minX)
                }
            }
        }
        .onDisappear { moveCursor(to: nil) }
    }

    private func moveCursor(to time: Date?) {
        if let time {
            let next = QuotaChartCursor(source: source, time: time)
            if cursor != next { cursor = next }
        } else if cursor?.source == source {
            cursor = nil
        }
    }

    private func heading(_ title: String, metrics: [QuotaHistoryHeaderMetric]) -> some View {
        let label = Text(title)
            .font(.system(size: 13, weight: .bold))
            .foregroundStyle(.primary)
            .lineLimit(1)
            .minimumScaleFactor(0.85)
            .accessibilityHidden(true)
        return ZStack(alignment: .trailing) {
            VStack(spacing: 1) {
                label.padding(.horizontal, 22).frame(maxWidth: .infinity)
                if panel == .hourly {
                    HStack(spacing: 12) {
                        ForEach(metrics, id: \.label) { metric in
                            Text(metric.label)
                                .foregroundStyle(Color(cgColor: metric.color))
                                .lineLimit(1)
                        }
                    }
                    .font(.system(size: 10))
                    .monospacedDigit()
                    .minimumScaleFactor(0.85)
                    .padding(.trailing, 22)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .frame(height: 12)
                }
            }
            .frame(maxWidth: .infinity)
            Image(systemName: "info.circle")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(legendHovered ? Color.primary : Color.secondary)
                .frame(width: 20, height: 22)
                .contentShape(Rectangle())
                .onHover {
                    legendHovered = $0
                    if $0 { moveCursor(to: nil) }
                }
                .accessibilityHidden(true)
                .offset(y: panel == .hourly ? 5 : 0)
        }
    }
}

struct QuotaChartReadout: View {
    struct Values: Equatable {
        let timestamp: String
        let latest: Bool
        fileprivate let measurements: [ReadoutLine]
        fileprivate let details: [ReadoutLine]

        init?(quota: QuotaHistoryDrawing?, tokens: QuotaHistoryDrawing, overviewTime: Date?, hourlyTime: Date?,
              colorScheme: ColorScheme) {
            if let overviewTime,
               let lines = quota?.readout(for: .overview, at: overviewTime, colorScheme: colorScheme),
               let first = lines.first {
                timestamp = first.text
                latest = false
                measurements = Array(lines.dropFirst().prefix(2))
                details = Array(lines.dropFirst(3))
            } else {
                guard let hour = hourlyTime ?? tokens.latestHour else { return nil }
                let local = tokens.readout(for: .hourly, at: hour, colorScheme: colorScheme)
                guard let first = local.first, let reading = local.dropFirst().first else { return nil }
                timestamp = first.text
                latest = hourlyTime == nil
                if let quota {
                    let measured = quota.readout(for: .hourly, at: hour, colorScheme: colorScheme).dropFirst().first
                    measurements = [ReadoutLine("Account quota · \(measured?.displayText ?? "Unavailable")"), reading]
                } else {
                    measurements = [reading]
                }
                details = Array(local.dropFirst(2))
            }
        }
    }

    let values: Values?

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            if let values {
                timestampRow(values.timestamp, latest: values.latest)
                row(values.measurements)
                row(values.details)
            }
        }
        .font(.system(size: 11))
        .monospacedDigit()
        .padding(.horizontal, 8)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .frame(height: 47, alignment: .center)
        .background(Color(cgColor: Palette.rgb(colorScheme == .dark ? Palette.darkCanvas : Palette.lightCanvas)),
                    in: RoundedRectangle(cornerRadius: 4))
        .accessibilityHidden(true)
    }

    private func timestampRow(_ timestamp: String, latest: Bool) -> some View {
        HStack(spacing: 8) {
            Text(timestamp).fontWeight(.semibold)
            if latest { Text("Latest hour").foregroundStyle(.secondary) }
        }
        .lineLimit(1)
    }

    private func row(_ lines: [ReadoutLine]) -> some View {
        HStack(spacing: 12) {
            ForEach(Array(lines.enumerated()), id: \.offset) { _, item in
                line(item)
            }
        }
        .frame(height: 13, alignment: .leading)
    }

    private func line(_ item: ReadoutLine) -> some View {
        Text(item.displayText)
            .foregroundStyle(item.color.map { Color(cgColor: $0) } ?? .primary)
            .lineLimit(1)
            .minimumScaleFactor(0.88)
    }
}

final class QuotaChartReadoutState: ObservableObject {
    @Published var values: QuotaChartReadout.Values?
}

struct StatisticsQuotaReadout: View {
    @ObservedObject var readout: QuotaChartReadoutState

    var body: some View {
        QuotaChartReadout(values: readout.values)
            .frame(maxWidth: 740)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 12)
            .padding(.bottom, 6)
            .background(Color(nsColor: .windowBackgroundColor))
    }
}

/// Uses the VPM-40 chart styling with plot bounds measured in window points.
struct QuotaHistoryDrawing {
    private struct Hour {
        let start: Date
        let parts: [Double]?
        var partial = false
        var tokenTotals: UsageTotals? = nil
    }

    private struct HourlyStatistics {
        let mean: Double
        let median: Double

        init?(hours: [Hour], coveredThrough: Date?) {
            guard let coveredThrough else { return nil }
            let values = hours.compactMap { hour -> Double? in
                guard !hour.partial, hour.start.addingTimeInterval(UsageHours.hour) <= coveredThrough else { return nil }
                return hour.parts?.reduce(0, +)
            }.sorted()
            guard !values.isEmpty else { return nil }
            mean = values.reduce(0, +) / Double(values.count)
            median = (values[(values.count - 1) / 2] + values[values.count / 2]) / 2
        }
    }

    private struct HourlyGuide {
        let value: Double
        let label: String
        let definition: String
        let color: CGColor
        let dash: [CGFloat]
        let phase: CGFloat

        var key: LegendKey { LegendKey(definition, color, .line(1.1, dash)) }
    }

    private let data: QuotaHistoryFigureData
    private let hours: [Hour]
    fileprivate let drawsQuota: Bool
    private let calendar: Calendar
    private let tokenSeries: [LocalTokenSeries]
    private let hourlyStatistics: HourlyStatistics?
    private let hourlyScale: HourlyChartScale
    private let hourlyLevels: [(value: Double, label: String)]
    private let hoursDomain: ClosedRange<Date>
    private let clockTicks: [QuotaHourTick]
    private let hasPartialHours: Bool
    let hasHourlySamples: Bool

    init(data: QuotaHistoryFigureData, calendar: Calendar = .current, range: QuotaHistoryRange = .threeDays) {
        self.data = data
        self.calendar = calendar
        let coveredThrough: Date?
        switch data {
        case .quota(let quota):
            coveredThrough = quota.now
            drawsQuota = true
            tokenSeries = []
            hours = quota.hours.map { hour in
                Hour(start: hour.start,
                     parts: (hour.percentagePoints ?? hour.partialPercentagePoints).map { [Double($0)] },
                     partial: hour.partialPercentagePoints != nil)
            }
        case .currentQuota(let reading):
            coveredThrough = nil
            drawsQuota = true
            tokenSeries = []
            hours = UsageHours(now: reading.now, calendar: calendar, range: range).starts.map { Hour(start: $0, parts: nil) }
        case .unsupportedQuota:
            coveredThrough = nil
            drawsQuota = true
            tokenSeries = []
            hours = []
        case .tokens(let tokens, let series):
            coveredThrough = tokens.scannedThrough
            drawsQuota = false
            let visible = series.map { [$0] } ?? LocalTokenSeries.allCases
            tokenSeries = visible
            hours = tokens.hours.map { hour in
                guard let totals = hour.tokens else { return Hour(start: hour.start, parts: nil) }
                let counts = visible.compactMap { $0.count(in: totals) }
                guard counts.count == visible.count else { return Hour(start: hour.start, parts: nil) }
                return Hour(start: hour.start, parts: counts.map(Double.init), partial: hour.partial, tokenTotals: totals)
            }
        }
        let bins = hours
        hourlyStatistics = HourlyStatistics(hours: bins, coveredThrough: coveredThrough)
        hasHourlySamples = bins.contains { $0.parts != nil }
        hasPartialHours = bins.contains(where: \.partial)
        let isQuota = drawsQuota
        let maximum = bins.compactMap { $0.parts?.reduce(0, +) }.max() ?? 0
        let scale = HourlyChartScale(measuredMaximum: maximum, minimum: isQuota ? 1 : 10)
        hourlyScale = scale
        hourlyLevels = scale.levels.map { value in
            let label = isQuota ? "\(formattedNumber(value, fractionDigits: scale.maximum >= 10 ? 0 : 1))%"
                : compactCount(Int(min(value, Double(Int.max / 2))), trimsTrailingZeros: true)
            return (value: value, label: label)
        }
        let first = bins.first?.start ?? .now
        let last = bins.last?.start ?? first
        let domain = first...last.addingTimeInterval(UsageHours.hour)
        hoursDomain = domain
        clockTicks = QuotaHourTick.inDomain(domain, calendar: calendar)
    }

    var latestHour: Date? { hours.last?.start }

    private func formatHourlyStatistic(_ value: Double) -> String {
        if drawsQuota { return quotaPercent(value) }
        let count = Int(exactly: value.rounded()) ?? Int.max
        return "\(compactCount(count, trimsTrailingZeros: true))/h"
    }

    private var hourlyGuides: [HourlyGuide] {
        guard let statistics = hourlyStatistics else { return [] }
        return [
            HourlyGuide(value: statistics.mean, label: "Average \(formatHourlyStatistic(statistics.mean))",
                        definition: "Average · sum ÷ complete observed hours",
                        color: Palette.mean, dash: [3.5, 4.5], phase: 0),
            HourlyGuide(value: statistics.median, label: "Median \(formatHourlyStatistic(statistics.median))",
                        definition: "Median · middle of sorted hourly values",
                        color: Palette.median, dash: [1.5, 6.5], phase: 4)
        ]
    }

    private var weeklyDomain: ClosedRange<Date>? {
        guard case .quota(let quota) = data else { return nil }
        return quota.cycleRange
    }

    private var sustainableRate: Double? {
        guard case .quota(let quota) = data else { return nil }
        return quota.sustainablePerHour
    }

    func headerMetrics(for panel: QuotaHistoryPanel, colorScheme: ColorScheme = .light) -> [QuotaHistoryHeaderMetric] {
        guard panel == .hourly else { return [] }
        var metrics: [QuotaHistoryHeaderMetric] = []
        let collect = {
            metrics = hourlyGuides.map { QuotaHistoryHeaderMetric(label: $0.label, color: $0.color) }
            if let sustainableRate {
                let note = sustainableRate > hourlyScale.maximum ? " · above scale" : ""
                metrics.append(QuotaHistoryHeaderMetric(label: "Sustainable \(quotaPercent(sustainableRate))/h\(note)",
                                                        color: Palette.amber))
            }
        }
        if let appearance = colorScheme == .dark ? Palette.darkAppearance : Palette.lightAppearance {
            appearance.performAsCurrentDrawingAppearance(collect)
        } else {
            collect()
        }
        return metrics
    }

    func accessibilityTitle(for panel: QuotaHistoryPanel) -> String {
        if panel == .overview { return "Provider quota" }
        return drawsQuota ? "Hourly provider quota" : "Hourly local tokens"
    }

    fileprivate func heading(for panel: QuotaHistoryPanel) -> String {
        switch (panel, data) {
        case (.overview, .quota):
            return "Weekly quota"
        case (.overview, .currentQuota(let reading)):
            return reading.window.map { "\($0.quotaDisplayLabel) quota" } ?? "Provider quota"
        case (.overview, .unsupportedQuota): return "Provider quota"
        case (_, .tokens(_, let series)):
            return "\(series?.rawValue ?? "Local tokens") per hour on this Mac"
        case (.hourly, _):
            return "Account quota used per hour"
        }
    }

    fileprivate func legendDescription(for panel: QuotaHistoryPanel) -> String {
        return legendSections(for: panel).flatMap { $0 }.map(\.text).joined(separator: ". ")
    }

    func accessibilityDetails(for panel: QuotaHistoryPanel, selectedTime: Date?) -> String {
        if let selectedTime, let lines = readout(for: panel, at: selectedTime) {
            return lines.map(\.text).joined(separator: ". ")
        }
        if panel == .hourly {
            guard hasHourlySamples else { return emptyHoursText }
            let observed = hours.filter { $0.parts != nil }.count
            return "\(observed) hours with \(drawsQuota ? "quota observations" : "recorded tokens")"
        }
        if case .unsupportedQuota = data { return unsupportedQuotaText }
        return heading(for: panel)
    }

    func selection(at point: CGPoint, in canvas: CGSize, panel: QuotaHistoryPanel) -> Date? {
        let plot = FigureLayout(canvas: canvas, panel: panel).plot
        guard plot.contains(point) else { return nil }
        if panel == .hourly {
            guard !hours.isEmpty else { return nil }
            let time = PlotAxes(frame: plot, time: hoursDomain, maximum: 1).time(at: point.x)
            return hourIndex(at: time).map { hours[$0].start }
        }
        switch data {
        case .quota(let quota):
            guard let time = quota.cycleRange else { return nil }
            let axis = PlotAxes(frame: plot, time: time, maximum: 100)
            return quota.hoverTime(near: axis.time(at: point.x))
        case .currentQuota(let reading):
            return reading.usedPercent == nil ? nil : reading.measuredAt ?? reading.now
        case .unsupportedQuota, .tokens:
            return nil
        }
    }

    private func hourIndex(at time: Date) -> Int? {
        guard let first = hours.first else { return nil }
        let index = Int(floor(time.timeIntervalSince(first.start) / UsageHours.hour))
        return hours.indices.contains(index) ? index : nil
    }

    func adjacentHour(to hour: Date?, offset: Int) -> Date? {
        guard !hours.isEmpty else { return nil }
        let current = hour.flatMap { hourIndex(at: $0) } ?? hours.count - 1
        return hours[min(hours.count - 1, max(0, current + offset))].start
    }

    /// The caller provides an upper-left coordinate system.
    func draw(_ panel: QuotaHistoryPanel, in context: CGContext, size canvas: CGSize, selectedTime: Date? = nil,
              showsLegend: Bool = false, colorScheme: ColorScheme = .dark) {
        let draw = { render(panel, in: context, size: canvas, selectedTime: selectedTime, showsLegend: showsLegend) }
        if let appearance = colorScheme == .dark ? Palette.darkAppearance : Palette.lightAppearance {
            appearance.performAsCurrentDrawingAppearance(draw)
        } else {
            draw()
        }
    }

    private func render(_ panel: QuotaHistoryPanel, in context: CGContext, size canvas: CGSize,
                        selectedTime: Date?, showsLegend: Bool) {
        guard canvas.width > 0, canvas.height > 0 else { return }
        let layout = FigureLayout(canvas: canvas, panel: panel)
        let selectedHour = panel == .hourly && !showsLegend ? selectedTime.flatMap { hourIndex(at: $0) } : nil
        context.saveGState()
        context.setAllowsFontSmoothing(false)
        context.setShouldSmoothFonts(false)
        fill(CGRect(origin: .zero, size: canvas), Palette.canvas, in: context)
        switch (panel, data) {
        case (.overview, .quota(let quota)):
            drawWeek(quota, layout: layout, in: context)
        case (.overview, .currentQuota(let reading)):
            drawReading(reading, layout: layout, in: context)
        case (_, .unsupportedQuota):
            let plot = layout.plot
            fill(plot, Palette.plot, in: context)
            frame(plot, in: context)
            Label(panel == .overview ? unsupportedQuotaText : emptyHoursText,
                  size: layout.labelSize, maximumWidth: plot.width - 12)
                .draw(at: CGPoint(x: plot.midX, y: plot.midY + 4), alignment: 0.5, in: context)
        case (.hourly, _):
            drawHours(selectedHour: selectedHour, layout: layout, in: context)
        case (.overview, .tokens):
            break
        }
        if showsLegend {
            let area = layout.overlayArea
            let legend = Legend(legendSections(for: panel), fontSize: layout.labelSize, maximumWidth: area.width - 10)
            let x = area.maxX - 5 - legend.size.width
            context.saveGState()
            context.clip(to: area)
            legend.draw(at: CGPoint(x: x, y: area.minY + 2), in: context)
            context.restoreGState()
        } else if panel == .overview, let selectedTime {
            let plot = layout.plot
            context.saveGState()
            context.clip(to: plot)
            let x = weeklyDomain.map { PlotAxes(frame: plot, time: $0, maximum: 1).x(selectedTime) } ?? plot.midX
            drawCursor(at: x, in: plot, context: context)
            context.restoreGState()
        }
        context.restoreGState()
    }

    private func drawWeek(_ quota: WeeklyQuotaChart, layout: FigureLayout, in context: CGContext) {
        let plot = layout.plot
        fill(plot, Palette.plot, in: context)
        guard let time = quota.cycleRange, let latest = quota.latest else {
            Label("Waiting for a quota measurement with a reset time.", size: layout.labelSize, maximumWidth: plot.width - 12)
                .draw(at: CGPoint(x: plot.midX, y: plot.midY), alignment: 0.5, in: context)
            frame(plot, in: context)
            return
        }

        let start = time.lowerBound
        let axis = PlotAxes(frame: plot, time: time, maximum: 100)
        let days = (0...WeeklyQuotaPace.dayCount).map { start.addingTimeInterval(Double($0) * WeeklyQuotaPace.daySeconds) }
        let levels = stride(from: 0.0, through: 100, by: 20).map { (value: $0, label: String(Int($0))) }

        context.saveGState()
        context.clip(to: plot)
        if let reset = quota.earlyResetAt {
            let x = axis.x(reset)
            let ended = CGRect(x: x, y: plot.minY, width: plot.maxX - x, height: plot.height)
            fill(ended, Palette.frame.copy(alpha: 0.12) ?? Palette.canvas, in: context)
        }
        let headroom = CGMutablePath()
        let overspend = CGMutablePath()
        for segment in quota.segments {
            for (left, right) in zip(segment, segment.dropFirst()) {
                let cuts = [left.time] + days.filter { left.time < $0 && $0 < right.time } + [right.time]
                for (from, to) in zip(cuts, cuts.dropFirst()) {
                    let budget = WeeklyQuotaPace.budget(at: from, cycleStart: start)
                    let a = axis.y(Double(left.used))
                    let b = axis.y(budget)
                    let shading = Double(left.used) <= budget ? headroom : overspend
                    shading.addRect(CGRect(x: axis.x(from), y: min(a, b), width: axis.x(to) - axis.x(from), height: abs(a - b)))
                }
            }
        }
        context.addPath(headroom)
        context.setFillColor(Palette.headroom)
        context.fillPath()
        context.addPath(overspend)
        context.setFillColor(Palette.overspend)
        context.fillPath()
        grid(axis, dates: days, levels: levels.map(\.value), in: context)
        context.restoreGState()
        axes(axis, levels: levels, layout: layout, in: context)
        func planPoint(_ date: Date) -> CGPoint {
            let value = WeeklyQuotaPace.budget(at: date, cycleStart: start)
            let point = axis.point(date, value)
            // The limit rail and the seventh day's plan both represent 100%.
            return CGPoint(x: point.x, y: max(point.y, plot.minY + 1.7))
        }
        if let reset = quota.earlyResetAt {
            let before = days.filter { $0 < reset } + [reset]
            let after = [reset] + days.filter { $0 > reset }
            stroke(steps(before.map(planPoint)), Palette.budget, width: 1, in: context)
            stroke(steps(after.map(planPoint)), Palette.budget, width: 1, dash: [3, 3], in: context)
        } else {
            stroke(steps(days.map(planPoint)), Palette.budget, width: 1, in: context)
        }
        context.saveGState()
        context.clip(to: plot)
        for segment in quota.segments {
            let points = segment.map { axis.point($0.time, Double($0.used)) }
            if points.count == 1, let point = points.first {
                context.setFillColor(Palette.actual)
                context.fillEllipse(in: CGRect(x: point.x - 2, y: point.y - 2, width: 4, height: 4))
            } else {
                stroke(steps(points), Palette.actual, width: 1.5, in: context)
            }
        }
        for forecast in quota.forecasts {
            let endpoint = forecast.plotEndpoint(reset: latest.reset)
            guard endpoint.time > latest.time else { continue }
            let style = forecast.period.strokeStyle
            stroke([axis.point(latest.time, Double(latest.used)), axis.point(endpoint.time, endpoint.used)],
                   style.color, width: 1.2, dash: style.dash, phase: style.phase, in: context)
        }
        for crossing in quota.planCrossings {
            drawCross(at: planPoint(crossing), radius: 3, color: Palette.limit, in: context)
        }
        context.restoreGState()

        drawDateAxis(axis, dates: days, layout: layout, calendar: calendar, in: context)
        drawLimit(plot, in: context)
        if let reset = quota.earlyResetAt {
            let x = axis.x(reset)
            stroke([CGPoint(x: x, y: plot.minY + 1), CGPoint(x: x, y: plot.maxY)],
                   Palette.coral, width: 1.2, dash: [3, 2], in: context)
            let label = Label("Early reset", size: layout.labelSize, color: Palette.coral, maximumWidth: plot.width - 14)
            let left = max(plot.minX + 5, x + label.width + 10 <= plot.maxX ? x + 5 : x - label.width - 5)
            fill(CGRect(x: left - 2, y: plot.minY + 4, width: label.width + 4, height: 15), Palette.canvas, in: context)
            label.draw(at: CGPoint(x: left, y: plot.minY + 15), in: context)
        }
    }

    private func legendSections(for panel: QuotaHistoryPanel) -> [[LegendKey]] {
        let limit = LegendKey("100% limit", Palette.limit, .line(1))
        let measuredColor = Palette.mint.copy(alpha: 0.56) ?? Palette.mint
        let source: String
        var marks: [LegendKey]
        switch (panel, data) {
        case (.overview, .quota(let quota)):
            return weeklyLegendSections(quota, limit: limit)
        case (.overview, .currentQuota(let reading)):
            guard reading.usedPercent != nil else { return [[limit]] }
            let marker = reading.isStale ? LegendKey("Stale reading", Palette.budget, .point)
                : LegendKey("Latest reading", Palette.actual, .point)
            let reset = reading.window?.resetAt.map { LegendKey("Reset · \(chartTimestamp($0, calendar: calendar))", Palette.labels, .none) }
            return [reset.map { [$0] } ?? [], [marker, limit]]
        case (.hourly, .quota):
            source = "Saved quota readings · selected account"
            marks = [LegendKey("Complete measured hour", measuredColor, .block)]
        case (.hourly, .currentQuota):
            source = "Provider quota readings · selected account"
            marks = [LegendKey(emptyHoursText, Palette.labels, .none)]
        case (_, .unsupportedQuota):
            return [[LegendKey(unsupportedQuotaText, Palette.labels, .none)]]
        case (_, .tokens):
            source = "Cached local journals on this Mac · account unknown"
            marks = tokenSeries.map { LegendKey($0.rawValue, $0.color.copy(alpha: 0.56) ?? $0.color, .block) }
        }
        if hasPartialHours {
            marks.append(LegendKey("Partial hour · recorded portion", measuredColor, .hatched))
        }
        var statistics = hourlyGuides.map(\.key)
        if sustainableRate != nil {
            statistics.append(LegendKey("Sustainable rate · remaining quota ÷ hours left", Palette.amber, .line(1, [3, 2])))
        }
        return [[LegendKey(source, Palette.labels, .none)], marks + statistics]
    }

    private func weeklyLegendSections(_ quota: WeeklyQuotaChart, limit: LegendKey) -> [[LegendKey]] {
        let step = formattedNumber(WeeklyQuotaPace.budgetStepPercent, fractionDigits: 1)
        var bands = [
            LegendKey("Below daily plan", Palette.headroom, .block),
            LegendKey("Above daily plan", Palette.overspend, .block)
        ]
        var lines = [
            LegendKey("Measured usage", Palette.actual, .line(1.5)),
            LegendKey("Daily plan · \(step) percentage points per day", Palette.budget, .line(1)),
            limit
        ]
        if !quota.planCrossings.isEmpty {
            lines.insert(LegendKey("Daily plan crossed", Palette.limit, .cross), at: 1)
        }
        if quota.earlyResetAt != nil {
            bands.append(LegendKey("After early reset", Palette.frame.copy(alpha: 0.12) ?? Palette.canvas, .block))
            lines.append(LegendKey("Early reset", Palette.coral, .line(1.2, [3, 2])))
            lines.append(LegendKey("Plan after early reset", Palette.budget, .line(1, [3, 3])))
        }
        if !quota.isHistorical, quota.pace.state == .current {
            for period in WeeklyQuotaChart.Forecast.Period.allCases {
                let style = period.strokeStyle
                let name = period == .day ? "Trailing 24h forecast" : "Cycle-average forecast"
                let detail: String
                if let forecast = quota.forecasts.first(where: { $0.period == period }), let latest = quota.latest {
                    detail = forecastText(forecast, latest: latest)
                } else {
                    detail = period == .day ? "requires 24h of history" : "available after one hour"
                }
                let label = "\(name) · \(detail)"
                lines.append(LegendKey(label, style.color, .line(1.2, style.dash)))
            }
        }
        let period = quota.cycleLabel(calendar: calendar)
        let dates = period.map { [LegendKey($0, Palette.labels, .none)] } ?? []
        return [dates, bands, lines]
    }

    private func drawReading(_ reading: QuotaLimitReading, layout: FigureLayout, in context: CGContext) {
        let plot = layout.plot
        fill(plot, Palette.plot, in: context)

        // The reading supplies one observation. Only the percentage axis is known here.
        let axis = PlotAxes(frame: plot, time: reading.now...reading.now.addingTimeInterval(1), maximum: 100)
        let levels = stride(from: 0, through: 100, by: 20).map { (value: Double($0), label: String($0)) }
        grid(axis, dates: [], levels: levels.map(\.value), in: context)
        axes(axis, levels: levels, layout: layout, in: context)
        drawLimit(plot, in: context)
        guard let used = reading.usedPercent else {
            Label("Waiting for a quota reading", size: layout.labelSize)
                .draw(at: CGPoint(x: plot.midX, y: plot.midY), alignment: 0.5, in: context)
            return
        }

        let y = axis.y(Double(used))
        let color = reading.isStale ? Palette.budget : Palette.actual
        context.saveGState()
        context.clip(to: plot)
        context.setFillColor(color)
        context.fillEllipse(in: CGRect(x: plot.midX - 3, y: y - 3, width: 6, height: 6))
        context.restoreGState()
    }

    private func hourColumn(_ index: Int, in plot: CGRect) -> CGRect {
        let width = plot.width / CGFloat(hours.count)
        return CGRect(x: plot.minX + CGFloat(index) * width, y: plot.minY, width: width, height: plot.height)
    }

    private func drawHours(selectedHour: Int?, layout: FigureLayout, in context: CGContext) {
        let plot = layout.plot
        let scale = hourlyScale
        let axis = PlotAxes(frame: plot, time: hoursDomain, maximum: scale.maximum)
        let ticks = scale.levels
        let colors = drawsQuota ? [Palette.mint] : tokenSeries.map(\.color)
        let dates = clockTicks.filter(\.isMajor).map(\.date)
        let minorDates = clockTicks.filter { !$0.isMajor }.map(\.date)
        fill(plot, Palette.plot, in: context)

        context.saveGState()
        context.clip(to: plot)
        if let selectedHour { fill(hourColumn(selectedHour, in: plot), Palette.hourHighlight, in: context) }
        let halfBar = (axis.x(axis.time.lowerBound.addingTimeInterval(UsageHours.hour)) - plot.minX) * 0.42
        for (hourIndex, hour) in hours.enumerated() {
            guard let parts = hour.parts else { continue }
            let center = axis.x(hour.start.addingTimeInterval(UsageHours.hour / 2))
            let opacity: CGFloat = hourIndex == selectedHour ? 1 : 0.56
            var low = 0.0
            for (index, value) in parts.enumerated() {
                let bottom = axis.y(low)
                let top = axis.y(low + value)
                let color = colors[index].copy(alpha: opacity) ?? colors[index]
                if value > 0 {
                    fill(CGRect(x: center - halfBar, y: top, width: 2 * halfBar, height: bottom - top), color, in: context)
                }
                low += value
            }
            if hour.partial, low > 0 {
                let top = axis.y(low)
                hatchUsageBar(CGRect(x: center - halfBar, y: top, width: 2 * halfBar, height: plot.maxY - top), in: context)
            }
        }
        grid(axis, dates: dates, minorDates: minorDates, levels: ticks, in: context)
        if let guide = sustainableRate, guide <= scale.maximum {
            stroke([CGPoint(x: plot.minX, y: axis.y(guide)), CGPoint(x: plot.maxX, y: axis.y(guide))],
                   Palette.amber, width: 1, dash: [3, 2], in: context)
        }
        context.restoreGState()

        axes(axis, levels: hourlyLevels, layout: layout, in: context)
        for guide in hourlyGuides {
            let y = min(max(axis.y(guide.value), plot.minY + 0.6), plot.maxY - 0.6)
            stroke([CGPoint(x: plot.minX, y: y), CGPoint(x: plot.maxX, y: y)],
                   guide.color, width: 1.1, dash: guide.dash, phase: guide.phase, in: context)
        }
        drawHourAxis(axis, ticks: clockTicks, layout: layout, calendar: calendar, in: context)
        if !hasHourlySamples {
            Label(emptyHoursText, size: layout.labelSize, maximumWidth: plot.width - 12)
                .draw(at: CGPoint(x: plot.midX, y: plot.midY + 4), alignment: 0.5, in: context)
        }
    }

    private var emptyHoursText: String {
        switch data {
        case .quota: return "Collecting hourly quota history"
        case .currentQuota: return "Hourly history unavailable for this window"
        case .unsupportedQuota: return "No provider quota history"
        case .tokens: return "No recorded tokens for this period"
        }
    }

    private var unsupportedQuotaText: String { "This provider does not report quota in AI Fleet" }

    fileprivate func readout(for panel: QuotaHistoryPanel, at time: Date, colorScheme: ColorScheme) -> [ReadoutLine] {
        var lines: [ReadoutLine] = []
        let collect = { lines = readout(for: panel, at: time) ?? [] }
        if let appearance = colorScheme == .dark ? Palette.darkAppearance : Palette.lightAppearance {
            appearance.performAsCurrentDrawingAppearance(collect)
        } else {
            collect()
        }
        return lines
    }

    private func readout(for panel: QuotaHistoryPanel, at time: Date) -> [ReadoutLine]? {
        if panel == .hourly {
            guard let index = hourIndex(at: time) else { return nil }
            let hour = hours[index]
            let timestamp = ReadoutLine(chartHour(hour.start, calendar: calendar))
            return [timestamp] + hourReadout(hour)
        }
        let timestamp = ReadoutLine(chartTimestamp(time, calendar: calendar))
        switch data {
        case .quota(let quota):
            guard let cycle = quota.cycleRange, cycle.contains(time) else { return nil }
            return [timestamp] + weekReadout(quota, at: time, cycle: cycle, calendar: calendar)
        case .currentQuota(let reading):
            guard let used = reading.usedPercent, time == (reading.measuredAt ?? reading.now) else { return nil }
            let state = reading.isStale ? " used · Stale" : " used"
            return [timestamp, ReadoutLine(quotaPercent(Double(used)) + state)]
        case .unsupportedQuota, .tokens:
            return nil
        }
    }

    private func hourReadout(_ hour: Hour) -> [ReadoutLine] {
        if let totals = hour.tokenTotals {
            let total = totals.totalTokens
            let rows = tokenSeries.compactMap { series in
                series.count(in: totals).map { count in
                    let share = total > 0 ? Double(count) * 100 / Double(total) : 0
                    let percent = share > 0 && share < 0.1 ? "<" + quotaPercent(0.1) : quotaPercent(share)
                    let shortName = series == .uncachedInput ? "Uncached" : series.rawValue
                    let number = groupedInteger(count)
                    return ReadoutLine("\(series.rawValue) · \(number) tokens (\(percent))",
                                       color: series == .cache ? Palette.cacheLabel : series.color,
                                       compactText: "\(shortName) \(number) (\(percent))")
                }
            }
            let coverage = hour.partial ? " · partial hour" : ""
            let compactCoverage = hour.partial ? " (partial)" : ""
            let totalLabel = groupedInteger(total)
            return [ReadoutLine("Total · \(totalLabel) tokens\(coverage)",
                                compactText: "Local tokens · \(totalLabel) total\(compactCoverage)")] + rows
        }
        if case .tokens(let tokens, _) = data {
            guard let cutoff = tokens.scannedThrough else { return [ReadoutLine("Awaiting first local log scan")] }
            if hour.start >= cutoff {
                let scannedAt = tokens.scannedAt ?? cutoff
                return [
                    ReadoutLine("Awaiting local log scan"),
                    ReadoutLine("Last scan · \(chartTimestamp(scannedAt, calendar: calendar))",
                                compactText: "Cache through \(chartTimestamp(cutoff, calendar: calendar))")
                ]
            }
        }
        let amount: String
        if let value = hour.parts?.first {
            let coverage = hour.partial ? " · partial hour" : ""
            let compactCoverage = hour.partial ? " (partial)" : ""
            let percentage = quotaPercent(value)
            return [ReadoutLine("\(percentage) of weekly quota\(coverage)", compactText: "\(percentage) used\(compactCoverage)")]
        } else if !hasHourlySamples {
            let compact = if case .quota = data { "Collecting history" } else { "No hourly history" }
            return [ReadoutLine(emptyHoursText, compactText: drawsQuota ? compact : "No recorded tokens")]
        } else {
            amount = drawsQuota ? "No sample" : "No recorded data"
        }
        return [ReadoutLine(amount)]
    }
}

private struct FigureLayout {
    let canvas: CGSize
    let plot: CGRect
    let labelSize: CGFloat = 11
    var overlayArea: CGRect {
        CGRect(x: plot.minX, y: plot.minY, width: plot.width, height: max(0, canvas.height - plot.minY - 2))
    }

    init(canvas: CGSize, panel: QuotaHistoryPanel) {
        self.canvas = canvas
        let left = min(44, canvas.width * 0.23)
        let right = min(20, canvas.width * 0.1)
        let top = panel.headerHeight
        let bottom: CGFloat = panel == .hourly ? 33 : 22
        plot = CGRect(x: left, y: top, width: canvas.width - left - right, height: max(0, canvas.height - top - bottom))
    }
}

private struct PlotAxes {
    let frame: CGRect
    let time: ClosedRange<Date>
    let maximum: Double

    func x(_ date: Date) -> CGFloat {
        frame.minX + frame.width * date.timeIntervalSince(time.lowerBound) / time.upperBound.timeIntervalSince(time.lowerBound)
    }

    func y(_ value: Double) -> CGFloat { frame.maxY - frame.height * value / maximum }

    func point(_ date: Date, _ value: Double) -> CGPoint { CGPoint(x: x(date), y: y(value)) }

    func time(at x: CGFloat) -> Date {
        time.lowerBound.addingTimeInterval((x - frame.minX) / frame.width * time.upperBound.timeIntervalSince(time.lowerBound))
    }
}

private func grid(_ axis: PlotAxes, dates: [Date], minorDates: [Date] = [], levels: [Double], in context: CGContext) {
    let minorColor = Palette.grid.copy(alpha: 0.60) ?? Palette.grid
    for date in minorDates {
        let x = axis.x(date)
        stroke([CGPoint(x: x, y: axis.frame.minY), CGPoint(x: x, y: axis.frame.maxY)], minorColor, width: 0.4, in: context)
    }
    for date in dates {
        let x = axis.x(date)
        stroke([CGPoint(x: x, y: axis.frame.minY), CGPoint(x: x, y: axis.frame.maxY)], Palette.grid, width: 0.6, in: context)
    }
    for value in levels {
        let y = axis.y(value)
        stroke([CGPoint(x: axis.frame.minX, y: y), CGPoint(x: axis.frame.maxX, y: y)], Palette.grid, width: 0.6, in: context)
    }
}

private func axes(_ axis: PlotAxes, levels: [(value: Double, label: String)], layout: FigureLayout, in context: CGContext) {
    let plot = axis.frame
    frame(plot, in: context)
    for (value, label) in levels where value != 0 {
        let y = axis.y(value)
        stroke([CGPoint(x: plot.minX - 4, y: y), CGPoint(x: plot.minX, y: y)], Palette.labels, width: 0.6, in: context)
        Label(label, size: layout.labelSize, maximumWidth: plot.minX - 10)
            .draw(at: CGPoint(x: plot.minX - 7, y: y + layout.labelSize * 0.36), alignment: 1, in: context)
    }
}

private func drawDateAxis(_ axis: PlotAxes, dates: [Date], layout: FigureLayout, calendar: Calendar, in context: CGContext) {
    for date in dates {
        let x = axis.x(date)
        let y = axis.frame.maxY
        stroke([CGPoint(x: x, y: y), CGPoint(x: x, y: y + 4)], Palette.labels, width: 0.6, in: context)
        drawTimeLabel(axisDate(date, calendar: calendar), x: x, y: y + 15, layout: layout, in: context)
    }
}

private func drawHourAxis(_ axis: PlotAxes, ticks: [QuotaHourTick], layout: FigureLayout, calendar: Calendar, in context: CGContext) {
    let positions = ticks.map { axis.x($0.date) }
    let spacing = zip(positions, positions.dropFirst()).map { left, right in right - left }.min() ?? .infinity
    let showsMinutes = spacing >= Label("00:00", size: layout.labelSize).width + 4
    let showsEveryTick = spacing >= Label("00", size: layout.labelSize).width + 4
    let y = axis.frame.maxY
    for (tick, x) in zip(ticks, positions) {
        let height: CGFloat = tick.isMajor ? 4 : 2
        let color = tick.isMajor ? Palette.labels : Palette.budget
        stroke([CGPoint(x: x, y: y), CGPoint(x: x, y: y + height)], color, width: 0.6, in: context)
        if showsEveryTick || tick.isMajor {
            let hour = String(format: "%02d", tick.hour) + (showsMinutes ? ":00" : "")
            drawTimeLabel(hour, x: x, y: y + 15, layout: layout, in: context)
        }
    }

    // The second row names each visible day once, centered below its hours.
    var day = calendar.startOfDay(for: axis.time.lowerBound)
    while day < axis.time.upperBound,
          let next = calendar.date(byAdding: .day, value: 1, to: day), next > day {
        let left = axis.x(max(day, axis.time.lowerBound))
        let right = axis.x(min(next, axis.time.upperBound))
        let label = Label(axisDate(day, calendar: calendar), size: layout.labelSize, color: Palette.budget)
        if right - left >= label.width + 4 {
            label.draw(at: CGPoint(x: (left + right) / 2, y: y + 28), alignment: 0.5, in: context)
        }
        day = next
    }
}

private func drawTimeLabel(_ text: String, x: CGFloat, y: CGFloat, layout: FigureLayout, in context: CGContext) {
    let label = Label(text, size: layout.labelSize)
    let margin = label.width / 2 + 3
    let textX = min(max(x, margin), layout.canvas.width - margin)
    label.draw(at: CGPoint(x: textX, y: y), alignment: 0.5, in: context)
}

private func drawLimit(_ plot: CGRect, in context: CGContext) {
    let limit = plot.minY + 0.5
    stroke([CGPoint(x: plot.minX, y: limit), CGPoint(x: plot.maxX, y: limit)],
           Palette.limit, width: 1, in: context)
}

private func drawCursor(at x: CGFloat, in plot: CGRect, context: CGContext) {
    stroke([CGPoint(x: x, y: plot.minY), CGPoint(x: x, y: plot.maxY)], Palette.budget, width: 0.8, in: context)
}

private func drawCross(at point: CGPoint, radius: CGFloat, color: CGColor, in context: CGContext) {
    stroke([CGPoint(x: point.x - radius, y: point.y - radius), CGPoint(x: point.x + radius, y: point.y + radius)],
           color, width: 1.4, in: context)
    stroke([CGPoint(x: point.x - radius, y: point.y + radius), CGPoint(x: point.x + radius, y: point.y - radius)],
           color, width: 1.4, in: context)
}

fileprivate struct ReadoutLine: Equatable {
    let text: String
    let color: CGColor?
    let compactText: String?
    var displayText: String { compactText ?? text }

    init(_ text: String, color: CGColor? = nil, compactText: String? = nil) {
        self.text = text
        self.color = color
        self.compactText = compactText
    }
}

private func frame(_ rect: CGRect, in context: CGContext) {
    context.setStrokeColor(Palette.frame)
    context.setLineWidth(0.8)
    context.setLineDash(phase: 0, lengths: [])
    context.stroke(rect)
}

private func stroke(_ points: [CGPoint], _ color: CGColor, width: CGFloat, dash: [CGFloat] = [], phase: CGFloat = 0,
                    in context: CGContext) {
    guard let start = points.first, points.count > 1 else { return }
    context.beginPath()
    context.move(to: start)
    for point in points.dropFirst() { context.addLine(to: point) }
    context.setStrokeColor(color)
    context.setLineWidth(width)
    context.setLineCap(.butt)
    context.setLineJoin(.round)
    context.setLineDash(phase: phase, lengths: dash)
    context.strokePath()
}

private func steps(_ points: [CGPoint]) -> [CGPoint] {
    guard let first = points.first else { return [] }
    return [first] + zip(points, points.dropFirst()).flatMap { left, right in [CGPoint(x: right.x, y: left.y), right] }
}

private func fill(_ rect: CGRect, _ color: CGColor, in context: CGContext) {
    context.setFillColor(color)
    context.fill(rect)
}

private func hatchUsageBar(_ rect: CGRect, in context: CGContext) {
    context.saveGState()
    context.clip(to: rect)
    context.setStrokeColor(Palette.plot.copy(alpha: 0.78) ?? Palette.plot)
    context.setLineWidth(0.75)
    context.setLineDash(phase: 0, lengths: [])
    context.beginPath()
    for bottom in stride(from: rect.minY, to: rect.maxY + rect.width, by: 4) {
        context.move(to: CGPoint(x: rect.minX, y: bottom))
        context.addLine(to: CGPoint(x: rect.maxX, y: bottom - rect.width))
    }
    context.strokePath()
    context.restoreGState()
}

func quotaPercent(_ value: Double) -> String {
    "\(formattedNumber(value, fractionDigits: 1))%"
}

private func weekReadout(_ quota: WeeklyQuotaChart, at date: Date, cycle: ClosedRange<Date>, calendar: Calendar) -> [ReadoutLine] {
    let resetLabel = chartTimestamp(cycle.upperBound, calendar: calendar)
    let scheduledReset = ReadoutLine("Scheduled reset · \(resetLabel)", compactText: "Reset \(resetLabel)")
    if let reset = quota.earlyResetAt, date >= reset {
        return [
            ReadoutLine("Quota cycle ended"),
            ReadoutLine("Early reset · \(chartTimestamp(reset, calendar: calendar))", color: Palette.coral),
            scheduledReset
        ]
    }
    let measured = quota.measuredUse(at: date).map { "\(quotaPercent(Double($0))) used" } ?? "No quota sample"
    let budget = quotaPercent(WeeklyQuotaPace.budget(at: date, cycleStart: cycle.lowerBound))
    let projections = quota.projections(at: date).map { period, used in
        let label = period == .window ? "Cycle forecast" : "24h forecast"
        let value = quotaPercent(used)
        return ReadoutLine("\(period.rawValue) · \(value) projected", color: period.strokeStyle.color,
                           compactText: "\(label) \(value)")
    }
    return [ReadoutLine(measured), ReadoutLine("Pacing plan · \(budget)")] + projections + [scheduledReset]
}

private func forecastText(_ forecast: WeeklyQuotaChart.Forecast, latest: WeeklyQuotaObservation) -> String {
    if let exhaustion = forecast.exhaustion {
        let untilLimit = exhaustion.timeIntervalSince(latest.time)
        return untilLimit > 0 ? "100% in \(WeeklyQuotaPace.countdownText(untilLimit))" : "100% reached"
    }
    return "\(quotaPercent(forecast.atReset)) at reset"
}

private func axisDate(_ date: Date, calendar: Calendar) -> String {
    let fields = calendar.dateComponents([.day, .month], from: date)
    return String(format: "%02d.%02d", fields.day ?? 0, fields.month ?? 0)
}

func chartTimestamp(_ date: Date, calendar: Calendar, locale: Locale = .autoupdatingCurrent) -> String {
    var style = Date.FormatStyle.dateTime.day().month(.abbreviated).hour().minute()
    style.calendar = calendar
    style.timeZone = calendar.timeZone
    style.locale = locale
    return style.format(date)
}

func chartHour(_ date: Date, calendar: Calendar, locale: Locale = .autoupdatingCurrent) -> String {
    var day = Date.FormatStyle.dateTime.day().month(.abbreviated)
    day.calendar = calendar
    day.timeZone = calendar.timeZone
    day.locale = locale
    func clock(_ instant: Date) -> String {
        let hour = calendar.component(.hour, from: instant)
        let minute = calendar.component(.minute, from: instant)
        return minute == 0 ? String(format: "%02d", hour) : String(format: "%02d:%02d", hour, minute)
    }

    let end = date.addingTimeInterval(UsageHours.hour)
    let label = day.format(date)
    let first = clock(date)
    let last = clock(end)
    if !calendar.isDate(date, inSameDayAs: end) {
        return "\(label) \(first)–\(day.format(end)) \(last)"
    }
    if first == last {
        let firstZone = calendar.timeZone.abbreviation(for: date) ?? "first"
        let lastZone = calendar.timeZone.abbreviation(for: end) ?? "second"
        return "\(label) \(first) \(firstZone)–\(last) \(lastZone)"
    }
    return "\(label) \(first)–\(last)"
}

private struct LegendKey {
    enum Mark {
        case line(CGFloat, [CGFloat] = [])
        case block
        case hatched
        case point
        case cross
        case none
    }

    let text: String
    let color: CGColor
    let mark: Mark

    init(_ text: String, _ color: CGColor, _ mark: Mark) {
        self.text = text
        self.color = color
        self.mark = mark
    }
}

private struct Legend {
    private static let labelOffset: CGFloat = 23
    private static let entryPadding: CGFloat = 9
    private static let swatchWidth: CGFloat = 16
    private let rows: [(key: LegendKey, label: Label, center: CGFloat)]
    private let fontSize: CGFloat
    let size: CGSize

    init(_ sections: [[LegendKey]], fontSize: CGFloat, maximumWidth: CGFloat) {
        let entryOverhead = Self.labelOffset + Self.entryPadding
        self.fontSize = fontSize
        let rowHeight = fontSize + 1
        var rows: [(key: LegendKey, label: Label, center: CGFloat)] = []
        var top: CGFloat = 2
        for section in sections where !section.isEmpty {
            if !rows.isEmpty { top += 5 }
            for key in section {
                let label = Label(key.text, size: fontSize, maximumWidth: maximumWidth - entryOverhead)
                rows.append((key, label, top + rowHeight / 2))
                top += rowHeight
            }
        }
        self.rows = rows
        let width = rows.map { $0.label.width }.max() ?? 0
        size = CGSize(width: ceil(width + entryOverhead), height: top + 2)
    }

    func draw(at origin: CGPoint, in context: CGContext) {
        let rect = CGRect(origin: origin, size: size)
        let background = CGPath(roundedRect: rect, cornerWidth: 3, cornerHeight: 3, transform: nil)
        context.addPath(background)
        context.setFillColor(Palette.plot.copy(alpha: 0.95) ?? Palette.plot)
        context.setStrokeColor(Palette.legendBorder)
        context.setLineWidth(0.8)
        context.setLineDash(phase: 0, lengths: [])
        context.drawPath(using: .fillStroke)
        let left = origin.x + 5
        for row in rows {
            let center = origin.y + row.center
            switch row.key.mark {
            case .line(let width, let dash):
                stroke([CGPoint(x: left, y: center), CGPoint(x: left + Self.swatchWidth, y: center)], row.key.color,
                       width: width, dash: dash, in: context)
            case .block, .hatched:
                let swatch = CGRect(x: left, y: center - 3, width: Self.swatchWidth, height: 6)
                fill(swatch, row.key.color, in: context)
                if case .hatched = row.key.mark { hatchUsageBar(swatch, in: context) }
            case .point:
                context.setFillColor(row.key.color)
                context.fillEllipse(in: CGRect(x: left + Self.swatchWidth / 2 - 2.5, y: center - 2.5, width: 5, height: 5))
            case .cross:
                drawCross(at: CGPoint(x: left + Self.swatchWidth / 2, y: center), radius: 3,
                          color: row.key.color, in: context)
            case .none: break
            }
            row.label.draw(at: CGPoint(x: left + Self.labelOffset, y: center + fontSize * 0.33), in: context)
        }
    }
}

private struct Label {
    private static let typeface: CGFont? = {
        let url = Bundle.main.url(forResource: "DejaVuSans", withExtension: "ttf")
            ?? Bundle.module.url(forResource: "DejaVuSans", withExtension: "ttf")
        return url.flatMap { CGDataProvider(url: $0 as CFURL) }.flatMap { CGFont($0) }
    }()

    private let line: CTLine
    let width: CGFloat

    init(_ text: String, size: CGFloat, color: CGColor = Palette.labels, maximumWidth: CGFloat? = nil) {
        func makeLine(_ text: String) -> CTLine {
            let font = Self.typeface.map { CTFontCreateWithGraphicsFont($0, size, nil, nil) }
                ?? CTFontCreateWithName("Helvetica" as CFString, size, nil)
            return CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [
                NSAttributedString.Key(kCTFontAttributeName as String): font,
                NSAttributedString.Key(kCTForegroundColorAttributeName as String): color
            ]))
        }
        let preferred = makeLine(text)
        if let maximumWidth, CTLineGetTypographicBounds(preferred, nil, nil, nil) > maximumWidth {
            line = CTLineCreateTruncatedLine(preferred, max(1, maximumWidth), .end, makeLine("…")) ?? makeLine("")
        } else {
            line = preferred
        }
        width = CTLineGetTypographicBounds(line, nil, nil, nil)
    }

    func draw(at point: CGPoint, alignment: CGFloat = 0, in context: CGContext) {
        context.saveGState()
        context.translateBy(x: point.x - alignment * width, y: point.y)
        context.scaleBy(x: 1, y: -1)
        context.textMatrix = .identity
        context.textPosition = .zero
        CTLineDraw(line, context)
        context.restoreGState()
    }
}

private enum Palette {
    static let darkAppearance = NSAppearance(named: .darkAqua)
    static let lightAppearance = NSAppearance(named: .aqua)

    static let darkCanvas: UInt32 = 0x15171a
    static let lightCanvas: UInt32 = 0xedeff2
    static var canvas: CGColor { color(darkCanvas, lightCanvas) }
    static var plot: CGColor { color(0x1b1f25, 0xf3f4f6) }
    static var grid: CGColor { color(0x2c3036, 0xdde2ea) }
    static var frame: CGColor { color(0x3d4147, 0xaab3c0) }
    static var legendBorder: CGColor { color(0x30353b, 0xbbc3ce) }
    static var labels: CGColor { color(0xc7c9d0, 0x465268) }
    static var actual: CGColor { color(0x7da2fa, 0x245db8) }
    static var budget: CGColor { color(0x9499a3, 0x657286) }
    static var limit: CGColor { color(0xe8565d, 0xbd3541) }
    static var headroom: CGColor { color(0x26403b, 0xd9ede5) }
    static var overspend: CGColor { color(0x412b31, 0xf7dfe0) }
    static var mint: CGColor { color(0x5ed5a0, 0x177b59) }
    static var amber: CGColor { color(0xf4b558, 0x946010) }
    static var coral: CGColor { color(0xe9784c, 0xad4527) }
    static var uncachedInput: CGColor { color(0x6eabff, 0x2b6aba) }
    static var cache: CGColor { color(0xf2b66d, 0xb47629) }
    static var cacheLabel: CGColor { color(0xf2b66d, 0x875719) }
    static var mean: CGColor { color(0xc7abff, 0x6843ac) }
    static var median: CGColor { color(0x69d0e3, 0x176781) }
    static var hourHighlight: CGColor { color(0x293641, 0xe8eff8) }

    private static func color(_ dark: UInt32, _ light: UInt32) -> CGColor {
        let appearance = NSAppearance.currentDrawing().bestMatch(from: [.darkAqua, .aqua])
        return rgb(appearance == .darkAqua ? dark : light)
    }

    static func rgb(_ value: UInt32) -> CGColor {
        return CGColor(srgbRed: Double((value >> 16) & 255) / 255,
                       green: Double((value >> 8) & 255) / 255, blue: Double(value & 255) / 255, alpha: 1)
    }
}
