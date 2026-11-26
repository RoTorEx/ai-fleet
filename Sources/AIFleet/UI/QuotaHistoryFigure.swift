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

    var height: CGFloat { self == .overview ? 168 : 122 }
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
    @State private var selection: Date?
    @State private var legendHovered = false
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let tracksHours = panel == .hourly && drawing.hasHourlySamples
        let selectedTime = legendHovered ? nil : selection
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
                    case .increment: selection = drawing.adjacentHour(to: selection, offset: 1)
                    case .decrement: selection = drawing.adjacentHour(to: selection, offset: -1)
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
                                selection = drawing.selection(at: location, in: geometry.size, panel: panel)
                            case .ended:
                                selection = nil
                            }
                        }
                        .accessibilityHidden(true)
                    heading(drawing.heading(for: panel))
                        .frame(width: max(0, layout.plot.width), height: layout.plot.minY)
                        .offset(x: layout.plot.minX)
                }
            }
        }
    }

    private func heading(_ heading: ChartHeading) -> some View {
        ZStack(alignment: .trailing) {
            HStack(spacing: 5) {
                Text("\(Text(heading.name).bold())\(Text(heading.suffix))")
                    .font(.system(size: 13))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
                    .accessibilityHidden(true)
                if let reset = heading.reset {
                    Text("·").accessibilityHidden(true)
                    QuotaResetLabel(resetAt: reset.date, now: reset.now, calendar: reset.calendar,
                                    reservesCountdownWidth: true)
                        .foregroundColor(FleetPalette.muted)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 22)
            Image(systemName: "info.circle")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(legendHovered ? Color.primary : Color.secondary)
                .frame(width: 20, height: 22)
                .contentShape(Rectangle())
                .onHover { legendHovered = $0 }
                .accessibilityHidden(true)
        }
    }
}

fileprivate struct ChartHeading {
    let name: String
    var details: [String] = []
    var reset: (date: Date, now: Date, calendar: Calendar)? = nil

    var suffix: String { details.map { " · " + $0 }.joined() }

    var summary: String {
        guard let reset else { return name + suffix }
        return name + suffix + " · " + QuotaResetState(resetAt: reset.date, now: reset.now)
            .dateLabel(now: reset.now, calendar: reset.calendar)
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

    private let data: QuotaHistoryFigureData
    private let hours: [Hour]
    private let drawsQuota: Bool
    private let calendar: Calendar
    private let tokenSeries: [LocalTokenSeries]
    private let range: QuotaHistoryRange

    init(data: QuotaHistoryFigureData, calendar: Calendar = .current, range: QuotaHistoryRange = .threeDays) {
        self.data = data
        self.calendar = calendar
        switch data {
        case .quota(let quota):
            self.range = quota.range
            drawsQuota = true
            tokenSeries = []
            hours = quota.hours.map { hour in
                Hour(start: hour.start,
                     parts: (hour.percentagePoints ?? hour.partialPercentagePoints).map { [Double($0)] },
                     partial: hour.partialPercentagePoints != nil)
            }
        case .currentQuota(let reading):
            self.range = range
            drawsQuota = true
            tokenSeries = []
            hours = UsageHours(now: reading.now, calendar: calendar, range: range).starts.map { Hour(start: $0, parts: nil) }
        case .unsupportedQuota:
            self.range = range
            drawsQuota = true
            tokenSeries = []
            hours = []
        case .tokens(let tokens, let series):
            self.range = tokens.range
            drawsQuota = false
            let visible = series.map { [$0] } ?? LocalTokenSeries.allCases
            tokenSeries = visible
            hours = tokens.hours.map { hour in
                guard let totals = hour.tokens else { return Hour(start: hour.start, parts: nil) }
                let counts = visible.compactMap { $0.count(in: totals) }
                guard counts.count == visible.count else { return Hour(start: hour.start, parts: nil) }
                return Hour(start: hour.start, parts: counts.map(Double.init), tokenTotals: totals)
            }
        }
    }

    var hasHourlySamples: Bool { hours.contains { $0.parts != nil } }

    private var hourlyScale: HourlyChartScale {
        let maximum = hours.compactMap { $0.parts?.reduce(0, +) }.max() ?? 0
        return HourlyChartScale(measuredMaximum: maximum, minimum: drawsQuota ? 1 : 10)
    }

    private var hoursDomain: ClosedRange<Date> {
        let first = hours.first?.start ?? .now
        let last = hours.last?.start ?? first
        return first...last.addingTimeInterval(UsageHours.hour)
    }

    func accessibilityTitle(for panel: QuotaHistoryPanel) -> String {
        if panel == .overview { return "Provider quota" }
        return drawsQuota ? "Hourly provider quota" : "Hourly local tokens"
    }

    fileprivate func heading(for panel: QuotaHistoryPanel) -> ChartHeading {
        switch (panel, data) {
        case (.overview, .quota(let quota)):
            if quota.isHistorical, let latest = quota.latest {
                return ChartHeading(name: "Weekly quota", details: ["\(quotaPercent(Double(latest.used))) recorded"])
            }
            var heading = ChartHeading(name: "Weekly quota")
            if let used = quota.pace.usedPercent { heading.details.append("\(quotaPercent(Double(used))) used") }
            if quota.pace.state == .stale { heading.details.append("Stale") }
            if let reset = quota.reportedReset {
                heading.reset = (reset, quota.now, calendar)
            } else if quota.pace.state == .partial {
                heading.details.append("Reset time unavailable")
            }
            return heading
        case (.overview, .currentQuota(let reading)):
            guard let used = reading.usedPercent, let window = reading.window else {
                return ChartHeading(name: "Provider quota")
            }
            var heading = ChartHeading(name: "\(window.quotaDisplayLabel) quota", details: ["\(quotaPercent(Double(used))) used"])
            if reading.isStale { heading.details.append("Stale") }
            if let reset = window.resetAt {
                heading.reset = (reset, reading.now, calendar)
            } else {
                heading.details.append("Reset time unavailable")
            }
            return heading
        case (.overview, .unsupportedQuota): return ChartHeading(name: "Provider quota")
        case (_, .tokens(_, let series)):
            return ChartHeading(name: "\(series?.rawValue ?? "Local tokens") per hour", details: ["last \(range.rawValue) days"])
        case (.hourly, _):
            return ChartHeading(name: "Quota used per hour", details: ["%", "last \(range.rawValue) days"])
        }
    }

    fileprivate func legendDescription(for panel: QuotaHistoryPanel) -> String {
        legendKeys(for: panel).map(\.text).joined(separator: ". ")
    }

    func accessibilityDetails(for panel: QuotaHistoryPanel, selectedTime: Date?) -> String {
        if panel == .hourly {
            guard hasHourlySamples else { return emptyHoursText }
            if let selectedTime, let hour = hours.first(where: { $0.start == selectedTime }) {
                return hourReadout(hour).map(\.text).joined(separator: ". ")
            }
            let observed = hours.filter { $0.parts != nil }.count
            return "\(observed) hours with \(drawsQuota ? "quota observations" : "recorded tokens")"
        }
        if let selectedTime, case .quota(let quota) = data, let cycle = quota.cycleRange {
            return weekReadout(quota, at: selectedTime, cycleStart: cycle.lowerBound, calendar: calendar)
                .map(\.text).joined(separator: ". ")
        }
        if case .unsupportedQuota = data { return unsupportedQuotaText }
        return heading(for: panel).summary
    }

    func selection(at point: CGPoint, in canvas: CGSize, panel: QuotaHistoryPanel) -> Date? {
        if panel == .hourly { return hour(at: point, in: canvas) }
        let plot = FigureLayout(canvas: canvas, panel: panel).plot
        guard plot.contains(point) else { return nil }
        switch data {
        case .quota(let quota):
            guard let time = quota.cycleRange else { return nil }
            let axis = PlotAxes(frame: plot, time: time, maximum: 100)
            let date = axis.time(at: point.x)
            if quota.measuredUse(at: date) != nil { return date }
            let nearest = quota.segments.lazy.flatMap { $0 }.min {
                abs($0.time.timeIntervalSince(date)) < abs($1.time.timeIntervalSince(date))
            }
            if let nearest, abs(axis.x(nearest.time) - point.x) <= 4 { return nearest.time }
            return date
        case .currentQuota(let reading):
            return reading.usedPercent == nil ? nil : reading.measuredAt ?? reading.now
        case .unsupportedQuota, .tokens:
            return nil
        }
    }

    func hour(at point: CGPoint, in canvas: CGSize) -> Date? {
        guard hasHourlySamples else { return nil }
        let plot = FigureLayout(canvas: canvas, panel: .hourly).plot
        guard plot.contains(point), let first = hours.first else { return nil }
        let axis = PlotAxes(frame: plot, time: hoursDomain, maximum: 1)
        let timestamp = axis.time(at: point.x)
        let index = Int(floor(timestamp.timeIntervalSince(first.start) / UsageHours.hour))
        return hours.indices.contains(index) ? hours[index].start : nil
    }

    func adjacentHour(to hour: Date?, offset: Int) -> Date? {
        guard !hours.isEmpty else { return nil }
        let current = hour.flatMap { selected in hours.firstIndex { $0.start == selected } } ?? hours.count - 1
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
        let selection = showsLegend ? nil : selectedTime
        context.saveGState()
        context.setAllowsFontSmoothing(false)
        context.setShouldSmoothFonts(false)
        fill(CGRect(origin: .zero, size: canvas), Palette.canvas, in: context)
        switch (panel, data) {
        case (.overview, .quota(let quota)):
            drawWeek(quota, selectedTime: selection, layout: layout, in: context)
        case (.overview, .currentQuota(let reading)):
            drawReading(reading, selectedTime: selection, layout: layout, in: context)
        case (_, .unsupportedQuota):
            let plot = layout.plot
            fill(plot, Palette.plot, in: context)
            frame(plot, in: context)
            Label(panel == .overview ? unsupportedQuotaText : emptyHoursText,
                  size: layout.labelSize, maximumWidth: plot.width - 12)
                .draw(at: CGPoint(x: plot.midX, y: plot.midY + 4), alignment: 0.5, in: context)
        case (.hourly, .quota(let quota)):
            drawHours(guide: quota.sustainablePerHour, selectedHour: selection, layout: layout, in: context)
        case (.hourly, _):
            drawHours(guide: nil, selectedHour: selection, layout: layout, in: context)
        case (.overview, .tokens):
            break
        }
        if showsLegend {
            let keys = legendKeys(for: panel)
            let plot = layout.plot.insetBy(dx: 5, dy: 2)
            let legend = Legend(keys, fontSize: layout.labelSize, maximumWidth: plot.width,
                                preferHorizontal: !drawsQuota)
            let x = plot.maxX - legend.size.width
            context.saveGState()
            context.clip(to: layout.plot)
            legend.draw(at: CGPoint(x: x, y: plot.minY), in: context)
            context.restoreGState()
        }
        context.restoreGState()
    }

    private func drawWeek(_ quota: WeeklyQuotaChart, selectedTime: Date?, layout: FigureLayout, in context: CGContext) {
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
        let days = (0...7).map { start.addingTimeInterval(Double($0) * WeeklyQuotaPace.daySeconds) }
        let levels = stride(from: 0.0, through: 100, by: 20).map { (value: $0, label: String(Int($0))) }

        context.saveGState()
        context.clip(to: plot)
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
        let budget = days.map { axis.point($0, WeeklyQuotaPace.budget(at: $0, cycleStart: start)) }
        stroke(steps(budget), Palette.budget, width: 1, in: context)
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
        let current = axis.point(latest.time, Double(latest.used))
        context.setFillColor(Palette.actual)
        context.fillEllipse(in: CGRect(x: current.x - 3, y: current.y - 3, width: 6, height: 6))
        context.restoreGState()

        axes(axis, levels: levels, layout: layout, in: context)
        drawDateAxis(axis, dates: days, layout: layout, calendar: calendar, in: context)
        drawLimit(plot, in: context)
        if let selectedTime, time.contains(selectedTime) {
            let x = axis.x(selectedTime)
            drawCursor(at: x, in: plot, context: context)
            drawReadout(weekReadout(quota, at: selectedTime, cycleStart: start, calendar: calendar),
                        layout: layout, alignLeft: x > plot.midX, in: context)
        }
    }

    private func legendKeys(for panel: QuotaHistoryPanel) -> [LegendKey] {
        let limit = LegendKey("100% limit", Palette.limit, .line(1))
        let measured = LegendKey("Measured quota use", Palette.mint, .block)
        switch (panel, data) {
        case (.overview, .quota(let quota)):
            return weeklyLegend(quota) + [limit]
        case (.overview, .currentQuota(let reading)):
            guard reading.usedPercent != nil else { return [limit] }
            let marker = reading.isStale ? LegendKey("Stale reading", Palette.budget, .point)
                : LegendKey("Latest reading", Palette.actual, .point)
            return [marker, limit]
        case (.hourly, .quota(let quota)):
            var keys = [measured]
            if let guide = quota.sustainablePerHour {
                let note = guide > hourlyScale.maximum ? " · above scale" : ""
                keys.append(LegendKey("Sustainable average: \(quotaPercent(guide))/h\(note)", Palette.amber, .line(1, [3, 2])))
            }
            if hours.contains(where: \.partial) {
                keys.append(LegendKey("Observed part of hour", Palette.mint.copy(alpha: 0.56) ?? Palette.mint, .block))
            }
            if let first = hours.first?.start, let observation = quota.firstObservation,
               observation.timeIntervalSince(first) > UsageHours.hour {
                keys.append(LegendKey("Recording since \(chartTimestamp(observation, calendar: calendar))", Palette.labels, .none))
            }
            return keys
        case (.hourly, .currentQuota):
            return [measured]
        case (_, .unsupportedQuota):
            return [LegendKey(unsupportedQuotaText, Palette.labels, .none)]
        case (_, .tokens):
            return tokenSeries.map { LegendKey($0.rawValue, $0.color, .block) }
        }
    }

    private func weeklyLegend(_ quota: WeeklyQuotaChart) -> [LegendKey] {
        var keys = [
            LegendKey("Usage, %", Palette.actual, .line(1.5)),
            LegendKey("Plan through completed days · 14.3%/day", Palette.budget, .line(1))
        ]
        if !quota.isHistorical, let headroom = quota.pace.headroomPoints {
            let amount = formattedNumber(abs(headroom), fractionDigits: 0)
            keys.append(LegendKey(headroom >= 0 ? "\(amount) pp below the plan"
                : "\(amount) pp ahead of the plan", headroom >= 0 ? Palette.headroom : Palette.overspend, .block))
        }
        if !quota.isHistorical, quota.pace.state == .current {
            for period in WeeklyQuotaChart.Forecast.Period.allCases {
                let style = period.strokeStyle
                let text: String
                if let forecast = quota.forecasts.first(where: { $0.period == period }) {
                    text = forecastText(forecast, latest: quota.latest)
                } else {
                    text = period == .day ? "Trailing 24h forecast · needs a reading from 24h ago"
                        : "Window average forecast · collecting quota history"
                }
                keys.append(LegendKey(text, style.color, .line(1.2, style.dash)))
            }
        }
        return keys
    }

    private func drawReading(_ reading: QuotaLimitReading, selectedTime: Date?, layout: FigureLayout, in context: CGContext) {
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
        let timestamp = reading.measuredAt.map { "Read \(chartTimestamp($0, calendar: calendar))" } ?? "Latest reading"
        Label(timestamp, size: layout.labelSize, maximumWidth: plot.width - 12)
            .draw(at: CGPoint(x: plot.midX, y: plot.maxY + 16), alignment: 0.5, in: context)
        if selectedTime != nil {
            drawReadout("\(timestamp) · \(quotaPercent(Double(used))) used", layout: layout, in: context)
        }
    }

    private func drawHours(guide: Double?, selectedHour: Date?, layout: FigureLayout, in context: CGContext) {
        let plot = layout.plot
        let scale = hourlyScale
        let axis = PlotAxes(frame: plot, time: hoursDomain, maximum: scale.maximum)
        let ticks = scale.levels
        let levels = ticks.map { value in
            let label = drawsQuota ? formattedNumber(value, fractionDigits: 1)
                : compactCount(Int(min(value, Double(Int.max / 2))), trimsTrailingZeros: true)
            return (value: value, label: label)
        }
        let colors = drawsQuota ? [Palette.mint] : tokenSeries.map(\.color)
        let clockTicks = QuotaHourTick.inDomain(axis.time, calendar: calendar)
        let dates = clockTicks.filter(\.isMajor).map(\.date)
        let minorDates = clockTicks.filter { !$0.isMajor }.map(\.date)
        let selected = hasHourlySamples ? selectedHour.flatMap { start in hours.first { $0.start == start } } : nil
        fill(plot, Palette.plot, in: context)

        context.saveGState()
        context.clip(to: plot)
        let halfBar = (axis.x(axis.time.lowerBound.addingTimeInterval(UsageHours.hour)) - plot.minX) * 0.42
        for hour in hours {
            guard let parts = hour.parts else { continue }
            let center = axis.x(hour.start.addingTimeInterval(UsageHours.hour / 2))
            var low = 0.0
            for (index, value) in parts.enumerated() {
                let bottom = axis.y(low)
                let top = axis.y(low + value)
                let color = hour.partial ? colors[index].copy(alpha: 0.56) ?? colors[index] : colors[index]
                if value > 0 {
                    fill(CGRect(x: center - halfBar, y: top, width: 2 * halfBar, height: bottom - top), color, in: context)
                }
                low += value
            }
        }
        grid(axis, dates: dates, minorDates: minorDates, levels: ticks, in: context)
        if let guide, guide <= scale.maximum {
            stroke([CGPoint(x: plot.minX, y: axis.y(guide)), CGPoint(x: plot.maxX, y: axis.y(guide))],
                   Palette.amber, width: 1, dash: [3, 2], in: context)
        }
        context.restoreGState()

        axes(axis, levels: levels, layout: layout, in: context)
        drawHourAxis(axis, ticks: clockTicks, layout: layout, calendar: calendar, in: context)
        if !hasHourlySamples {
            Label(emptyHoursText, size: layout.labelSize, maximumWidth: plot.width - 12)
                .draw(at: CGPoint(x: plot.midX, y: plot.midY + 4), alignment: 0.5, in: context)
        }
        if let selected {
            let x = axis.x(selected.start.addingTimeInterval(UsageHours.hour / 2))
            drawCursor(at: x, in: plot, context: context)
            drawReadout(hourReadout(selected), layout: layout, alignLeft: x > plot.midX, in: context)
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

    private func hourReadout(_ hour: Hour) -> [ReadoutLine] {
        let timestamp = chartTimestamp(hour.start, calendar: calendar)
        if let totals = hour.tokenTotals {
            let total = totals.totalTokens
            let rows = tokenSeries.compactMap { series in
                series.count(in: totals).map { count in
                    let share = total > 0 ? Double(count) * 100 / Double(total) : 0
                    let percent = share > 0 && share < 0.1 ? "<" + quotaPercent(0.1) : quotaPercent(share)
                    return ReadoutLine("\(series.rawValue) · \(groupedInteger(count)) tokens · \(percent)", color: series.color)
                }
            }
            return [ReadoutLine(timestamp), ReadoutLine("Total · \(groupedInteger(total)) tokens")] + rows
        }
        let amount: String
        if let value = hour.parts?.first {
            amount = "\(hour.partial ? "≥ " : "")\(quotaPercent(value)) of weekly quota"
        } else {
            amount = drawsQuota ? "No sample" : "No recorded data"
        }
        return [ReadoutLine("\(timestamp) · \(amount)")]
    }
}

private struct FigureLayout {
    let canvas: CGSize
    let plot: CGRect
    let labelSize: CGFloat = 11

    init(canvas: CGSize, panel: QuotaHistoryPanel) {
        self.canvas = canvas
        let left = min(44, canvas.width * 0.23)
        let right = min(20, canvas.width * 0.1)
        let top: CGFloat = 24
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

private struct ReadoutLine {
    let text: String
    let color: CGColor

    init(_ text: String, color: CGColor = Palette.labels) {
        self.text = text
        self.color = color
    }
}

private func drawReadout(_ text: String, layout: FigureLayout, in context: CGContext) {
    drawReadout([ReadoutLine(text)], layout: layout, alignLeft: false, in: context)
}

private func drawReadout(_ lines: [ReadoutLine], layout: FigureLayout, alignLeft: Bool, in context: CGContext) {
    let plot = layout.plot
    let labels = lines.map { Label($0.text, size: layout.labelSize, color: $0.color, maximumWidth: plot.width - 22) }
    let width = (labels.map(\.width).max() ?? 0) + 8
    let left = alignLeft ? plot.minX + 7 : plot.maxX - 7 - width
    let rowHeight = layout.labelSize + (labels.count > 4 ? 1 : 2)
    let height = CGFloat(labels.count) * rowHeight + 3
    let top = max(plot.minY, min(plot.minY + 5, plot.maxY - height))
    fill(CGRect(x: left, y: top, width: width, height: height), Palette.canvas, in: context)
    for (index, label) in labels.enumerated() {
        let baseline = top + layout.labelSize + 1 + CGFloat(index) * rowHeight
        label.draw(at: CGPoint(x: left + 4, y: baseline), in: context)
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

func quotaPercent(_ value: Double) -> String {
    "\(formattedNumber(value, fractionDigits: 1))%"
}

private func weekReadout(_ quota: WeeklyQuotaChart, at date: Date, cycleStart: Date, calendar: Calendar) -> [ReadoutLine] {
    let timestamp = chartTimestamp(date, calendar: calendar)
    let budget = "Budget \(quotaPercent(WeeklyQuotaPace.budget(at: date, cycleStart: cycleStart)))"
    if let used = quota.measuredUse(at: date) {
        return [ReadoutLine("\(timestamp) · \(quotaPercent(Double(used))) used · \(budget)")]
    }
    let projections = quota.projections(at: date)
    guard !projections.isEmpty else { return [ReadoutLine("\(timestamp) · No sample · \(budget)")] }
    return [ReadoutLine("\(timestamp) · \(budget)")] + projections.map { period, used in
        ReadoutLine("\(period.rawValue) · \(quotaPercent(used)) projected", color: period.strokeStyle.color)
    }
}

private func forecastText(_ forecast: WeeklyQuotaChart.Forecast, latest: WeeklyQuotaObservation?) -> String {
    let rate = forecast.period.rawValue
    if let exhaustion = forecast.exhaustion, let latest {
        let untilLimit = exhaustion.timeIntervalSince(latest.time)
        return untilLimit > 0 ? "\(rate) · 100% in \(WeeklyQuotaPace.countdownText(untilLimit))" : "\(rate) · 100% reached"
    }
    return "\(rate) · \(quotaPercent(forecast.atReset)) at reset"
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
    return "\(style.format(date)) (\(calendar.timeZone.identifier))"
}

private struct LegendKey {
    enum Mark {
        case line(CGFloat, [CGFloat] = [])
        case block
        case point
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
    private let rows: [(key: LegendKey, label: Label)]
    private let horizontal: Bool
    private let rowHeight: CGFloat
    private let fontSize: CGFloat
    let size: CGSize

    init(_ keys: [LegendKey], fontSize: CGFloat, maximumWidth: CGFloat, preferHorizontal: Bool = false) {
        let entryOverhead = Self.labelOffset + Self.entryPadding
        rows = keys.map { ($0, Label($0.text, size: fontSize, maximumWidth: maximumWidth - entryOverhead)) }
        self.fontSize = fontSize
        rowHeight = fontSize + 3
        let widths = rows.map { $0.label.width + entryOverhead }
        let combinedWidth = widths.reduce(0, +)
        horizontal = preferHorizontal && combinedWidth <= maximumWidth
        let width = horizontal ? combinedWidth : widths.max() ?? 0
        let height = (horizontal ? 1 : CGFloat(keys.count)) * rowHeight + 5
        size = CGSize(width: ceil(width), height: height)
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
        var left = origin.x + 5
        for (index, row) in rows.enumerated() {
            let center = origin.y + 2.5 + (CGFloat(horizontal ? 0 : index) + 0.5) * rowHeight
            switch row.key.mark {
            case .line(let width, let dash):
                stroke([CGPoint(x: left, y: center), CGPoint(x: left + Self.swatchWidth, y: center)], row.key.color,
                       width: width, dash: dash, in: context)
            case .block:
                fill(CGRect(x: left, y: center - 3, width: Self.swatchWidth, height: 6), row.key.color, in: context)
            case .point:
                context.setFillColor(row.key.color)
                context.fillEllipse(in: CGRect(x: left + Self.swatchWidth / 2 - 2.5, y: center - 2.5, width: 5, height: 5))
            case .none: break
            }
            row.label.draw(at: CGPoint(x: left + Self.labelOffset, y: center + fontSize * 0.33), in: context)
            if horizontal { left += row.label.width + Self.labelOffset + Self.entryPadding }
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

    static var canvas: CGColor { color(0x15171a, 0xf6f7f9) }
    static var plot: CGColor { color(0x1b1f25, 0xffffff) }
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

    private static func color(_ dark: UInt32, _ light: UInt32) -> CGColor {
        let appearance = NSAppearance.currentDrawing().bestMatch(from: [.darkAqua, .aqua])
        let value = appearance == .darkAqua ? dark : light
        return CGColor(srgbRed: Double((value >> 16) & 255) / 255,
                       green: Double((value >> 8) & 255) / 255, blue: Double(value & 255) / 255, alpha: 1)
    }
}
