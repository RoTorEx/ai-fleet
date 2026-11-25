import CoreText
import SwiftUI

enum QuotaHistoryFigureData {
    case quota(WeeklyQuotaChart)
    case tokens(LocalTokenHistory)
}

struct QuotaHourTick: Equatable {
    let date: Date
    let hour: Int

    var isMajor: Bool { hour == 0 || hour == 12 }

    static func inDomain(_ domain: ClosedRange<Date>, calendar: Calendar = .autoupdatingCurrent) -> [Self] {
        var ticks: [Self] = []
        var day = calendar.startOfDay(for: domain.lowerBound)
        while day <= domain.upperBound {
            for hour in stride(from: 0, through: 20, by: 4) {
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

struct QuotaHistoryFigure: View {
    let data: QuotaHistoryFigureData
    @State private var selectedHour: Date?

    var body: some View {
        let drawing = QuotaHistoryDrawing(data: data)
        Canvas { graphics, size in
            graphics.withCGContext { drawing.draw(in: $0, size: size, selectedHour: selectedHour) }
        }
        .aspectRatio(drawing.size.width / drawing.size.height, contentMode: .fit)
        .overlay {
            GeometryReader { geometry in
                Color.clear.contentShape(Rectangle())
                    .onContinuousHover { phase in
                        switch phase {
                        case .active(let location): selectedHour = drawing.hour(at: location, in: geometry.size)
                        case .ended: selectedHour = nil
                        }
                    }
                    .accessibilityHidden(true)
            }
        }
        .accessibilityLabel(drawing.accessibilityTitle)
        .accessibilityValue(drawing.accessibilityDetails(selectedHour: selectedHour))
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: selectedHour = drawing.adjacentHour(to: selectedHour, offset: 1)
            case .decrement: selectedHour = drawing.adjacentHour(to: selectedHour, offset: -1)
            @unknown default: break
            }
        }
    }
}

/// Coordinates in the 1300 × 910 VPM-40 reference. Typography and the axis gutter
/// also have minimum sizes in screen points.
struct QuotaHistoryDrawing {
    static let referenceSize = CGSize(width: 1300, height: 910)
    static let weekPlot = CGRect(x: 66.5, y: 49.5, width: 1195, height: 440)
    static let hoursPlot = CGRect(x: 66.5, y: 566.5, width: 1195, height: 294)

    private struct Hour {
        let start: Date
        let parts: [Double]?
        var partial = false
    }

    private let data: QuotaHistoryFigureData
    private let hours: [Hour]
    private let drawsWeek: Bool

    init(data: QuotaHistoryFigureData) {
        self.data = data
        switch data {
        case .quota(let quota):
            drawsWeek = true
            hours = quota.hours.map { hour in
                Hour(start: hour.start,
                     parts: (hour.percentagePoints ?? hour.partialPercentagePoints).map { [Double($0)] },
                     partial: hour.partialPercentagePoints != nil)
            }
        case .tokens(let tokens):
            drawsWeek = false
            hours = tokens.hours.map { hour in
                Hour(start: hour.start, parts: hour.tokens.map {
                    [Double($0.billableInputTokens), Double($0.cachedInputTokens) + Double($0.cacheWriteInputTokens),
                     Double($0.outputTokens)]
                })
            }
        }
    }

    var size: CGSize { drawsWeek ? Self.referenceSize : CGSize(width: Self.referenceSize.width, height: 392) }
    private var hoursFrame: CGRect { drawsWeek ? Self.hoursPlot : Self.hoursPlot.offsetBy(dx: 0, dy: -518) }
    private var hoursDomain: ClosedRange<Date> {
        let first = hours.first?.start ?? .now
        let last = hours.last?.start ?? first
        // Half an hour for each end bin plus the reference's 5% margins.
        let padding = (0.5 + Double(UsageHours.count) * 0.05) * UsageHours.hour
        return first.addingTimeInterval(-padding)...last.addingTimeInterval(padding)
    }

    var accessibilityTitle: String {
        drawsWeek ? "Weekly quota and hourly usage" : "Hourly local tokens"
    }

    func accessibilityDetails(selectedHour: Date?) -> String {
        if let selectedHour, let hour = hours.first(where: { $0.start == selectedHour }) {
            return hourDescription(hour)
        }
        if case .quota(let quota) = data {
            let forecasts = quota.forecasts.map { forecastText($0, latest: quota.latest) }
            return ([weekTitle(quota.pace)] + forecasts).joined(separator: ". ")
        }
        return "\(hours.filter { $0.parts?.contains(where: { $0 > 0 }) == true }.count) hours with recorded tokens"
    }

    func hour(at point: CGPoint, in canvas: CGSize) -> Date? {
        guard canvas.width > 0, canvas.height > 0 else { return nil }
        let referencePoint = CGPoint(x: point.x * size.width / canvas.width, y: point.y * size.height / canvas.height)
        let plot = FigureLayout(scale: canvas.width / size.width).frame(hoursFrame)
        guard plot.contains(referencePoint), let first = hours.first else { return nil }
        let axis = PlotAxes(frame: plot, time: hoursDomain, maximum: 1)
        let timestamp = axis.time(at: referencePoint.x)
        let index = Int((timestamp.timeIntervalSince(first.start) / UsageHours.hour).rounded())
        return hours.indices.contains(index) ? hours[index].start : nil
    }

    func adjacentHour(to hour: Date?, offset: Int) -> Date? {
        guard !hours.isEmpty else { return nil }
        let current = hour.flatMap { selected in hours.firstIndex { $0.start == selected } } ?? hours.count - 1
        return hours[min(hours.count - 1, max(0, current + offset))].start
    }

    /// The caller provides an upper-left coordinate system.
    func draw(in context: CGContext, size canvas: CGSize, selectedHour: Date? = nil) {
        guard canvas.width > 0, canvas.height > 0 else { return }
        let layout = FigureLayout(scale: canvas.width / size.width)
        context.saveGState()
        context.scaleBy(x: layout.scale, y: canvas.height / size.height)
        context.setAllowsFontSmoothing(false)
        context.setShouldSmoothFonts(false)
        fill(CGRect(origin: .zero, size: size), Palette.canvas, in: context)
        switch data {
        case .quota(let quota):
            drawWeek(quota, layout: layout, in: context)
            drawHours(guide: quota.sustainablePerHour, firstObservation: quota.firstObservation,
                      selectedHour: selectedHour, layout: layout, in: context)
        case .tokens:
            drawHours(guide: nil, firstObservation: nil, selectedHour: selectedHour, layout: layout, in: context)
        }
        context.restoreGState()
    }

    private func drawWeek(_ quota: WeeklyQuotaChart, layout: FigureLayout, in context: CGContext) {
        let plot = layout.frame(Self.weekPlot)
        Label(weekTitle(quota.pace), size: layout.font(reference: 24, minimum: 12), color: Palette.heading)
            .draw(at: CGPoint(x: plot.midX, y: 38), alignment: 0.5, in: context)
        fill(plot, Palette.plot, in: context)
        guard let start = quota.cycleStart, let latest = quota.latest, start < latest.reset else {
            Label("Waiting for a quota measurement with a reset time.", size: layout.labelSize)
                .draw(at: CGPoint(x: plot.midX, y: plot.midY), alignment: 0.5, in: context)
            frame(plot, in: context)
            return
        }

        let axis = PlotAxes(frame: plot, time: start...latest.reset, maximum: 110)
        let days = (0...7).map { start.addingTimeInterval(Double($0) * WeeklyQuotaPace.daySeconds) }
        let calendar = Calendar.autoupdatingCurrent
        let firstDay = calendar.startOfDay(for: start)
        let dates = (0...7).compactMap { calendar.date(byAdding: .day, value: $0, to: firstDay) }
            .filter { start <= $0 && $0 < latest.reset }
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
        grid(axis, dates: dates, levels: levels.map(\.value), in: context)
        let budget = days.map { axis.point($0, WeeklyQuotaPace.budget(at: $0, cycleStart: start)) }
        stroke(steps(budget), Palette.budget, width: 2.1, in: context)
        let limit = floor(axis.y(100))
        stroke([CGPoint(x: plot.minX, y: limit), CGPoint(x: plot.maxX, y: limit)], Palette.limit, width: 2, in: context)
        for segment in quota.segments {
            let points = segment.map { axis.point($0.time, Double($0.used)) }
            if points.count == 1, let point = points.first {
                context.setFillColor(Palette.actual)
                context.fillEllipse(in: CGRect(x: point.x - 3, y: point.y - 3, width: 6, height: 6))
            } else {
                stroke(steps(points), Palette.actual, width: 3.5, in: context)
            }
        }
        for forecast in quota.forecasts {
            let endpoint = forecast.plotEndpoint(reset: latest.reset)
            guard endpoint.time > latest.time else { continue }
            stroke([axis.point(latest.time, Double(latest.used)), axis.point(endpoint.time, endpoint.used)],
                   forecast.period == .window ? Palette.amber : Palette.coral, width: 2.8, dash: [2.8, 4.6], in: context)
        }
        context.restoreGState()

        axes(axis, dates: dates, levels: levels, showHour: false, layout: layout, in: context)
        var keys = [
            LegendKey("Usage, %", Palette.actual, .line(3.5)),
            LegendKey("Cumulative budget · 14.3%/day", Palette.budget, .line(2.1))
        ]
        if let headroom = quota.pace.headroomPoints {
            let amount = formattedNumber(abs(headroom), fractionDigits: 0)
            keys.append(LegendKey(headroom >= 0 ? "End-of-day headroom: \(amount)% of weekly quota"
                : "Over today's budget: \(amount)% of weekly quota", headroom >= 0 ? Palette.headroom : Palette.overspend, .block))
        }
        for forecast in quota.forecasts {
            keys.append(LegendKey(forecastText(forecast, latest: latest),
                                  forecast.period == .window ? Palette.amber : Palette.coral, .line(2.8, [2.8, 4.6])))
        }
        let legend = Legend(keys, minimumWidth: 661, fontSize: layout.legendSize)
        let left = CGPoint(x: plot.minX + 8, y: plot.minY + 8)
        let earlyLimit = quota.forecasts.contains { forecast in
            forecast.exhaustion.map { axis.x($0) < left.x + legend.size.width } ?? false
        }
        let origin = earlyLimit
            ? CGPoint(x: plot.maxX - 8 - legend.size.width, y: plot.maxY - 8 - legend.size.height) : left
        legend.draw(at: origin, in: context)
    }

    private func drawHours(guide: Double?, firstObservation: Date?, selectedHour: Date?, layout: FigureLayout, in context: CGContext) {
        let plot = layout.frame(hoursFrame)
        let maximum = max(drawsWeek ? 1 : 10, guide ?? 0, hours.compactMap { $0.parts?.reduce(0, +) }.max() ?? 0)
        let axis = PlotAxes(frame: plot, time: hoursDomain, maximum: maximum * 1.05)
        let ticks = hourlyLevels(maximum: maximum)
        let levels = ticks.map { value in
            let label = drawsWeek ? formattedNumber(value, fractionDigits: maximum <= 5 ? 1 : 0)
                : compactCount(Int(min(value, Double(Int.max / 2)))).replacingOccurrences(of: ".00", with: "")
            return (value: value, label: label)
        }
        let colors = drawsWeek ? [Palette.mint] : [Palette.actual, Palette.cache, Palette.mint]
        let clockTicks = QuotaHourTick.inDomain(axis.time)
        let dates = clockTicks.filter(\.isMajor).map(\.date)
        let minorDates = clockTicks.filter { !$0.isMajor }.map(\.date)
        let selected = selectedHour.flatMap { start in hours.first { $0.start == start } }
        let title = drawsWeek ? "Hourly usage, % of weekly quota (last 72h)" : "Tokens per hour (last 72h)"
        Label(title, size: layout.font(reference: 20, minimum: 12), color: Palette.heading)
            .draw(at: CGPoint(x: plot.midX, y: plot.minY - 10), alignment: 0.5, in: context)
        fill(plot, Palette.plot, in: context)

        context.saveGState()
        context.clip(to: plot)
        let halfBar = (axis.x(axis.time.lowerBound.addingTimeInterval(UsageHours.hour)) - plot.minX) * 0.42
        for hour in hours {
            guard let parts = hour.parts else { continue }
            let center = axis.x(hour.start)
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
        if let guide {
            stroke([CGPoint(x: plot.minX, y: axis.y(guide)), CGPoint(x: plot.maxX, y: axis.y(guide))],
                   Palette.amber, width: 1.8, dash: [6, 4], in: context)
        }
        if let selected {
            let x = axis.x(selected.start)
            stroke([CGPoint(x: x, y: plot.minY), CGPoint(x: x, y: plot.maxY)], Palette.budget, width: 1.3, in: context)
        }
        context.restoreGState()

        axes(axis, dates: dates, minorDates: minorDates, levels: levels, showHour: true, layout: layout, in: context)
        let hasSamples = hours.contains { $0.parts != nil }
        var keys: [LegendKey] = []
        if let guide {
            keys.append(LegendKey("Sustainable average: \(formattedNumber(guide, fractionDigits: 2))%/h",
                                  Palette.amber, .line(1.8, [6, 4])))
        }
        if hours.contains(where: \.partial) {
            keys.append(LegendKey("Observed part of hour", Palette.mint.copy(alpha: 0.56) ?? Palette.mint, .block))
        }
        if let firstObservation, let first = hours.first?.start, firstObservation.timeIntervalSince(first) > UsageHours.hour {
            keys.append(LegendKey("Recording since \(hourDescriptionDate(firstObservation))", Palette.labels, .none))
        }
        if !drawsWeek, hasSamples {
            keys = [LegendKey("Uncached input", Palette.actual, .block), LegendKey("Cache", Palette.cache, .block),
                    LegendKey("Output", Palette.mint, .block)]
        }
        let legendOrigin = CGPoint(x: plot.minX + 8, y: plot.minY + 8)
        let legend = keys.isEmpty ? nil : Legend(keys, minimumWidth: drawsWeek ? 357 : 0,
            fontSize: layout.legendSize, horizontal: !drawsWeek)
        legend?.draw(at: legendOrigin, in: context)
        if !hasSamples {
            Label(drawsWeek ? "Collecting hourly quota history" : "No recorded tokens for this period", size: layout.labelSize)
                .draw(at: CGPoint(x: plot.midX, y: plot.midY + 6), alignment: 0.5, in: context)
        }
        if let selected {
            let label = Label(hourDescription(selected), size: layout.labelSize, maximumWidth: plot.width - 26)
            let right = plot.maxX - 12
            let left = right - label.width - 8
            var top = plot.minY + 9
            if let legend, left < legendOrigin.x + legend.size.width {
                top = legendOrigin.y + legend.size.height + 8
            }
            fill(CGRect(x: left, y: top, width: label.width + 16, height: layout.labelSize + 14), Palette.plot, in: context)
            label.draw(at: CGPoint(x: right, y: top + layout.labelSize + 3), alignment: 1, in: context)
        }
    }

    private func hourDescription(_ hour: Hour) -> String {
        let amount: String
        if let parts = hour.parts {
            let total = parts.reduce(0, +)
            amount = drawsWeek
                ? "\(hour.partial ? "≥ " : "")\(formattedNumber(total, fractionDigits: 0))% of weekly quota"
                : "\(groupedInteger(Int(min(total, Double(Int.max / 2))))) tokens"
        } else {
            amount = drawsWeek ? "No sample" : "No recorded data"
        }
        return "\(hourDescriptionDate(hour.start)) · \(amount)"
    }
}

private struct FigureLayout {
    let scale: CGFloat

    var labelSize: CGFloat { font(reference: 18, minimum: 10.5) }
    var legendSize: CGFloat { font(reference: 18.5, minimum: 10.5) }

    func font(reference: CGFloat, minimum: CGFloat) -> CGFloat { max(reference, minimum / scale) }

    func frame(_ reference: CGRect) -> CGRect {
        let left = max(reference.minX, min(reference.width * 0.23, 44 / scale))
        return CGRect(x: left, y: reference.minY, width: reference.maxX - left, height: reference.height)
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
        stroke([CGPoint(x: x, y: axis.frame.minY), CGPoint(x: x, y: axis.frame.maxY)], minorColor, width: 0.7, in: context)
    }
    for date in dates {
        let x = axis.x(date)
        stroke([CGPoint(x: x, y: axis.frame.minY), CGPoint(x: x, y: axis.frame.maxY)], Palette.grid, width: 0.9, in: context)
    }
    for value in levels {
        let y = axis.y(value)
        stroke([CGPoint(x: axis.frame.minX, y: y), CGPoint(x: axis.frame.maxX, y: y)], Palette.grid, width: 0.9, in: context)
    }
}

private func axes(_ axis: PlotAxes, dates: [Date], minorDates: [Date] = [],
                  levels: [(value: Double, label: String)], showHour: Bool, layout: FigureLayout, in context: CGContext) {
    let plot = axis.frame
    frame(plot, in: context)
    for date in minorDates {
        let x = axis.x(date)
        stroke([CGPoint(x: x, y: plot.maxY), CGPoint(x: x, y: plot.maxY + 3)], Palette.budget, width: 1, in: context)
    }
    for date in dates {
        let x = axis.x(date)
        stroke([CGPoint(x: x, y: plot.maxY), CGPoint(x: x, y: plot.maxY + 6)], Palette.labels, width: 1, in: context)
        let label = Label(axisDate(date, withHour: showHour), size: layout.labelSize)
        let halfLabel = label.width / 2 + 4
        let textX = min(max(x, halfLabel), QuotaHistoryDrawing.referenceSize.width - halfLabel)
        label.draw(at: CGPoint(x: textX, y: plot.maxY + max(26, layout.labelSize + 5)), alignment: 0.5, in: context)
    }
    for (value, label) in levels {
        let y = axis.y(value)
        stroke([CGPoint(x: plot.minX - 6, y: y), CGPoint(x: plot.minX, y: y)], Palette.labels, width: 1, in: context)
        Label(label, size: layout.labelSize, maximumWidth: plot.minX - 16)
            .draw(at: CGPoint(x: plot.minX - 12, y: y + layout.labelSize * 0.36), alignment: 1, in: context)
    }
}

private func frame(_ rect: CGRect, in context: CGContext) {
    context.setStrokeColor(Palette.frame)
    context.setLineWidth(1.4)
    context.setLineDash(phase: 0, lengths: [])
    context.stroke(rect)
}

private func stroke(_ points: [CGPoint], _ color: CGColor, width: CGFloat, dash: [CGFloat] = [], in context: CGContext) {
    guard let start = points.first, points.count > 1 else { return }
    context.beginPath()
    context.move(to: start)
    for point in points.dropFirst() { context.addLine(to: point) }
    context.setStrokeColor(color)
    context.setLineWidth(width)
    context.setLineCap(.butt)
    context.setLineJoin(.round)
    context.setLineDash(phase: 0, lengths: dash)
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

private func hourlyLevels(maximum: Double) -> [Double] {
    let interval = maximum / 6
    let magnitude = pow(10, floor(log10(interval)))
    let factor = [1.0, 2, 2.5, 5, 10].first { $0 * magnitude >= interval } ?? 10
    let step = factor * magnitude
    return (0...Int(floor(maximum / step + 1e-9))).map { Double($0) * step }
}

private func weekTitle(_ pace: WeeklyQuotaPace) -> String {
    var title = "Weekly limit"
    if let used = pace.usedPercent { title += ": \(used)%" }
    switch pace.state {
    case .current:
        if let remaining = pace.timeToReset { title += " · \(Int(ceil(remaining / UsageHours.hour)))h to reset" }
    case .stale: title += " · Stale measurement"
    case .resetPending: title += " · Reset due"
    case .partial: title += " · Reset time unavailable"
    case .unavailable: title += " · Unavailable"
    }
    return title
}

private func forecastText(_ forecast: WeeklyQuotaChart.Forecast, latest: WeeklyQuotaObservation?) -> String {
    let rate = forecast.period == .window ? "week average" : "last 24h"
    if let exhaustion = forecast.exhaustion, let latest {
        let untilLimit = exhaustion.timeIntervalSince(latest.time)
        return untilLimit > 0 ? "Forecast: 100% in \(WeeklyQuotaPace.countdownText(untilLimit)) (\(rate))" : "100% reached"
    }
    return "Forecast: \(formattedNumber(forecast.atReset, fractionDigits: 0))% (\(rate))"
}

private func axisDate(_ date: Date, withHour: Bool = false) -> String {
    let fields = Calendar.autoupdatingCurrent.dateComponents([.day, .month, .hour], from: date)
    let day = String(format: "%02d.%02d", fields.day ?? 0, fields.month ?? 0)
    guard withHour else { return day }
    return fields.hour == 12 ? "12:00" : day + " 00:00"
}

private func hourDescriptionDate(_ date: Date) -> String {
    date.formatted(.dateTime.day().month(.abbreviated).hour().minute().timeZone(.specificName(.short)))
}

private struct LegendKey {
    enum Mark {
        case line(CGFloat, [CGFloat] = [])
        case block
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
    private let rows: [(key: LegendKey, label: Label)]
    private let horizontal: Bool
    private let rowHeight: CGFloat
    private let fontSize: CGFloat
    let size: CGSize

    init(_ keys: [LegendKey], minimumWidth: CGFloat, fontSize: CGFloat, horizontal: Bool = false) {
        rows = keys.map { ($0, Label($0.text, size: fontSize)) }
        self.horizontal = horizontal
        self.fontSize = fontSize
        rowHeight = max(27, fontSize + 6)
        let widths = rows.map { $0.label.width + 66 }
        let width = horizontal ? widths.reduce(0, +) : widths.max() ?? 0
        let height = (horizontal ? 1 : CGFloat(keys.count)) * rowHeight + 6.5
        size = CGSize(width: max(minimumWidth, ceil(width)), height: height)
    }

    func draw(at origin: CGPoint, in context: CGContext) {
        let rect = CGRect(origin: origin, size: size)
        let background = CGPath(roundedRect: rect, cornerWidth: 3.7, cornerHeight: 3.7, transform: nil)
        context.addPath(background)
        context.setFillColor(Palette.plot.copy(alpha: 0.8) ?? Palette.plot)
        context.setStrokeColor(Palette.legendBorder)
        context.setLineWidth(1.8)
        context.setLineDash(phase: 0, lengths: [])
        context.drawPath(using: .fillStroke)
        var left = origin.x + 8
        for (index, row) in rows.enumerated() {
            let center = origin.y + 2.5 + (CGFloat(horizontal ? 0 : index) + 0.5) * rowHeight
            switch row.key.mark {
            case .line(let width, let dash):
                stroke([CGPoint(x: left, y: center), CGPoint(x: left + 37, y: center)], row.key.color,
                       width: width, dash: dash, in: context)
            case .block:
                fill(CGRect(x: left, y: center - 6, width: 37, height: 12), row.key.color, in: context)
            case .none: break
            }
            row.label.draw(at: CGPoint(x: left + 50, y: center + fontSize * 0.33), in: context)
            if horizontal { left += row.label.width + 66 }
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

    init(_ text: String, size: CGFloat = 18, color: CGColor = Palette.labels, maximumWidth: CGFloat? = nil) {
        func makeLine(_ size: CGFloat) -> CTLine {
            let font = Self.typeface.map { CTFontCreateWithGraphicsFont($0, size, nil, nil) }
                ?? CTFontCreateWithName("Helvetica" as CFString, size, nil)
            return CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [
                NSAttributedString.Key(kCTFontAttributeName as String): font,
                NSAttributedString.Key(kCTForegroundColorAttributeName as String): color
            ]))
        }
        let preferred = makeLine(size)
        let preferredWidth = CTLineGetTypographicBounds(preferred, nil, nil, nil)
        if let maximumWidth, preferredWidth > maximumWidth {
            line = makeLine(size * maximumWidth / preferredWidth)
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
    static let canvas = rgb(0x15171a)
    static let plot = rgb(0x1b1f25)
    static let grid = rgb(0x2c3036)
    static let frame = rgb(0x3d4147)
    static let legendBorder = rgb(0x30353b)
    static let labels = rgb(0xc7c9d0)
    static let heading = rgb(0xe8e9ed)
    static let actual = rgb(0x7da2fa)
    static let budget = rgb(0x9499a3)
    static let limit = rgb(0xe8565d)
    static let headroom = rgb(0x26403b)
    static let overspend = rgb(0x412b31)
    static let mint = rgb(0x5ed5a0)
    static let amber = rgb(0xf4b558)
    static let coral = rgb(0xe9784c)
    static let cache = rgb(0xa4b9ee)

    private static func rgb(_ value: UInt32) -> CGColor {
        CGColor(srgbRed: Double((value >> 16) & 255) / 255,
                green: Double((value >> 8) & 255) / 255, blue: Double(value & 255) / 255, alpha: 1)
    }
}
