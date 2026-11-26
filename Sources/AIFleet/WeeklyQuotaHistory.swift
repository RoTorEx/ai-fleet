import Combine
import CryptoKit
import Foundation

extension ProviderLimitWindow {
    var isWeeklyQuota: Bool {
        durationSeconds == WeeklyQuotaPace.weekSeconds || weeklyModel != nil
    }

    var quotaDisplayLabel: String { id == "monthly" ? "Monthly" : label }
}

extension StatisticsProviderReport {
    var weeklyWindows: [ProviderLimitWindow] {
        limits.filter(\.isWeeklyQuota).sorted {
            if ($0.weeklyModel == nil) != ($1.weeklyModel == nil) { return $0.weeklyModel == nil }
            return $0.label.localizedStandardCompare($1.label) == .orderedAscending
        }
    }
}

struct QuotaLimitReading {
    let window: ProviderLimitWindow?
    let measuredAt: Date?
    let now: Date
    let markedStale: Bool

    var usedPercent: Int? {
        guard let window, (0...100).contains(window.remainingPercent) else { return nil }
        return 100 - window.remainingPercent
    }

    var isStale: Bool {
        guard !markedStale, let measuredAt else { return true }
        let age = now.timeIntervalSince(measuredAt)
        return age < -WeeklyQuotaPace.clockTolerance || age > WeeklyQuotaPace.maximumObservationAge
    }
}

struct WeeklyQuotaHistoryKey: Hashable, Codable {
    let provider: String
    let accountID: String
    let windowID: String
    private let identity: String

    init(report: StatisticsProviderReport, window: ProviderLimitWindow) {
        provider = report.provider
        accountID = report.accountID
        windowID = window.id
        let scope = [report.identity.email, report.identity.organizationID ?? ""].joined(separator: "\u{0}")
        identity = SHA256.hash(data: Data(scope.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

struct WeeklyQuotaObservation: Codable, Equatable {
    let time: Date
    let reset: Date
    let used: Int

    func sharesCycle(with other: Self) -> Bool {
        abs(reset.timeIntervalSince(other.reset)) <= WeeklyQuotaPace.clockTolerance
    }

    init(time: Date, reset: Date, used: Int) {
        self.time = time
        self.reset = reset
        self.used = used
    }

    init?(report: StatisticsProviderReport, window: ProviderLimitWindow, now: Date) {
        guard window.isWeeklyQuota, report.quotaAuthentication == .signedIn,
              [.available, .exhausted, .stale].contains(report.quotaState),
              (0...100).contains(window.remainingPercent),
              let time = report.fetchedAt, let reset = window.resetAt,
              time.timeIntervalSince1970.isFinite, reset.timeIntervalSince1970.isFinite,
              time <= now.addingTimeInterval(WeeklyQuotaPace.clockTolerance),
              time < reset, reset.timeIntervalSince(time) <= WeeklyQuotaPace.weekSeconds + WeeklyQuotaPace.clockTolerance else { return nil }
        self.init(time: time, reset: reset, used: 100 - window.remainingPercent)
    }
}

struct WeeklyQuotaHistory: Codable, Equatable {
    private(set) var records: [WeeklyQuotaHistoryKey: [WeeklyQuotaObservation]] = [:]

    mutating func observe(_ reports: [StatisticsProviderReport], now: Date) {
        for report in reports where report.quotaState == .available || report.quotaState == .exhausted {
            for window in report.weeklyWindows {
                guard let sample = WeeklyQuotaObservation(report: report, window: window, now: now),
                      now.timeIntervalSince(sample.time) <= WeeklyQuotaPace.maximumObservationAge else { continue }
                let key = WeeklyQuotaHistoryKey(report: report, window: window)
                if let last = records[key]?.last {
                    guard last != sample, last.time <= sample.time else { continue }
                    if last.time == sample.time { records[key]?.removeLast() }
                }
                records[key, default: []].append(sample)
            }
        }
    }
}

@MainActor
final class WeeklyQuotaHistoryStore: ObservableObject {
    static let shared = WeeklyQuotaHistoryStore()
    @Published private(set) var history = WeeklyQuotaHistory()
    @Published private(set) var issue: String?
    private let file: URL
    private let writer = DispatchQueue(label: "dev.ai-fleet.quota-history")

    init(file: URL? = nil) {
        self.file = file ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("AI Fleet", isDirectory: true).appendingPathComponent("weekly-quota-history.json")
        do {
            history = try JSONDecoder().decode(WeeklyQuotaHistory.self, from: Data(contentsOf: self.file))
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            // A new installation starts collecting at its first measurement.
        } catch {
            issue = "Could not read the saved weekly quota history."
        }
    }

    func observe(_ reports: [StatisticsProviderReport], now: Date = Date()) {
        var updated = history
        updated.observe(reports, now: now)
        guard updated != history else { return }
        history = updated
        let file = file
        let snapshot = updated
        writer.async { [weak self] in
            let error = Self.save(snapshot, to: file)
            DispatchQueue.main.async { [weak self] in self?.issue = error }
        }
    }

    nonisolated private static func save(_ history: WeeklyQuotaHistory, to file: URL) -> String? {
        do {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            try JSONEncoder().encode(history).write(to: file, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
            return nil
        } catch {
            return "Could not save weekly quota history. Recent measurements are available in memory."
        }
    }
}

struct WeeklyQuotaChart {
    struct Forecast: Identifiable {
        enum Period: String, CaseIterable {
            case window = "Window average"
            case day = "Trailing 24h"
        }
        let period: Period
        let atReset: Double
        let exhaustion: Date?
        var id: Period { period }

        func plotEndpoint(reset: Date) -> (time: Date, used: Double) {
            (min(exhaustion ?? reset, reset), min(atReset, 100))
        }
    }

    struct Hour: Identifiable {
        let start: Date
        var percentagePoints: Int? = nil
        var partialPercentagePoints: Int? = nil
        var id: Date { start }
    }

    let pace: WeeklyQuotaPace
    let cycleStart: Date?
    let segments: [[WeeklyQuotaObservation]]
    let forecasts: [Forecast]
    let hours: [Hour]
    let cycleResets: [Date]
    let cycleIndex: Int
    let earlyResetAt: Date?
    let now: Date
    let latest: WeeklyQuotaObservation?
    let planCrossings: [Date]
    private let crossingTimes: [Date]
    private let anchorTimes: [Date]
    var sustainablePerHour: Double? { pace.sustainablePercentPerDay.map { $0 / 24 } }
    var isHistorical: Bool { cycleIndex > 0 }

    var cycleRange: ClosedRange<Date>? {
        guard let cycleStart, let latest, cycleStart < latest.reset else { return nil }
        return cycleStart...latest.reset
    }

    func cycleReset(offset: Int) -> Date? {
        let next = cycleIndex + offset
        return cycleResets.indices.contains(next) ? cycleResets[next] : nil
    }

    func cycleLabel(calendar: Calendar) -> String? {
        guard let cycle = cycleRange else { return nil }
        let overlaps = [cycleReset(offset: 1), cycleReset(offset: -1)].compactMap { $0 }.contains {
            abs($0.timeIntervalSince(cycle.upperBound)) < WeeklyQuotaPace.weekSeconds - WeeklyQuotaPace.clockTolerance
        }
        let thisYear = calendar.component(.year, from: now)
        var format = Date.FormatStyle.dateTime.day().month(.abbreviated)
        if [cycle.lowerBound, cycle.upperBound].contains(where: { calendar.component(.year, from: $0) != thisYear }) {
            format = format.year()
        }
        if overlaps {
            format = format.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits)
        }
        format.calendar = calendar
        format.timeZone = calendar.timeZone
        return "\(cycle.lowerBound.formatted(format)) – \(cycle.upperBound.formatted(format))"
    }

    func measuredUse(at date: Date) -> Int? {
        let segment = segments.first { points in
            guard let first = points.first, let last = points.last else { return false }
            return first.time <= date && date <= last.time
        }
        return segment?.last { $0.time <= date }?.used
    }

    private static func crossings(in segments: [[WeeklyQuotaObservation]], cycleStart: Date?) -> [Date] {
        guard let cycleStart else { return [] }
        return segments.flatMap { segment in
            zip(segment, segment.dropFirst()).compactMap { previous, reading in
                let plan = WeeklyQuotaPace.budget(at: reading.time, cycleStart: cycleStart)
                return Double(previous.used) <= plan && Double(reading.used) > plan ? reading.time : nil
            }
        }
    }

    func hoverTime(near date: Date) -> Date {
        var crossings = crossingTimes
            .filter { abs($0.timeIntervalSince(date)) <= UsageHours.hour }
        if let earlyResetAt, abs(earlyResetAt.timeIntervalSince(date)) <= UsageHours.hour / 2 {
            crossings.append(earlyResetAt)
        }
        if let nearest = crossings.min(by: { abs($0.timeIntervalSince(date)) < abs($1.timeIntervalSince(date)) }) {
            return nearest
        }

        let nearest = anchorTimes.min { abs($0.timeIntervalSince(date)) < abs($1.timeIntervalSince(date)) }
        guard let nearest, abs(nearest.timeIntervalSince(date)) <= UsageHours.hour / 2 else { return date }
        return nearest
    }

    func projections(at date: Date) -> [(period: Forecast.Period, used: Double)] {
        guard let latest, date > latest.time else { return [] }
        let used = Double(latest.used)
        return forecasts.compactMap { forecast in
            let end = forecast.plotEndpoint(reset: latest.reset)
            guard date <= end.time else { return nil }
            let progress = date.timeIntervalSince(latest.time) / end.time.timeIntervalSince(latest.time)
            return (forecast.period, used + (end.used - used) * progress)
        }
    }

    init(report: StatisticsProviderReport, window: ProviderLimitWindow, history: WeeklyQuotaHistory,
         now: Date, calendar: Calendar = .autoupdatingCurrent, range: QuotaHistoryRange = .threeDays,
         displayedReset: Date? = nil) {
        self.now = now
        pace = WeeklyQuotaPace.make(report: report, window: window, now: now)
        var samples = history.records[WeeklyQuotaHistoryKey(report: report, window: window)] ?? []
        if let sample = WeeklyQuotaObservation(report: report, window: window, now: now),
           samples.last.map({ $0.time <= sample.time }) ?? true {
            if samples.last?.time == sample.time { samples.removeLast() }
            samples.append(sample)
        }
        let cycles = Self.cycles(in: samples)
        let resets = cycles.compactMap { $0.last?.reset }
        cycleResets = resets
        let index = displayedReset.flatMap { reset in
            resets.firstIndex { abs($0.timeIntervalSince(reset)) <= WeeklyQuotaPace.clockTolerance }
        } ?? 0
        cycleIndex = index
        let displayed = cycles.isEmpty ? [] : Array(cycles[index])
        let latest = displayed.last
        self.latest = latest
        cycleStart = latest?.reset.addingTimeInterval(-WeeklyQuotaPace.weekSeconds)
        if index > 0, let latest, let next = cycles[index - 1].first {
            earlyResetAt = Self.earlyReset(previous: latest, next: next)
        } else {
            earlyResetAt = nil
        }
        segments = Self.segments(from: displayed)
        let correction = displayed.indices.dropFirst().last { index in
            displayed[index].used < displayed[index - 1].used
        }
        let forecastSamples = correction.map { Array(displayed[$0...]) } ?? displayed
        forecasts = index == 0 && pace.state == .current
            ? Self.forecasts(for: forecastSamples, afterCorrection: correction != nil) : []
        planCrossings = Self.crossings(in: segments, cycleStart: cycleStart)
        let limits = segments.compactMap { segment -> Date? in
            guard let first = segment.first, first.used < 100 else { return nil }
            return segment.first { $0.used == 100 }?.time
        }
        crossingTimes = planCrossings + limits + forecasts.compactMap(\.exhaustion)
        anchorTimes = segments.compactMap { $0.count == 1 ? $0.first?.time : nil } + [latest?.time].compactMap { $0 }
        hours = Self.hourlyUsage(samples, window: UsageHours(now: now, calendar: calendar, range: range), now: now)
    }

    private static func earlyReset(previous: WeeklyQuotaObservation, next: WeeklyQuotaObservation) -> Date? {
        let start = next.reset.addingTimeInterval(-WeeklyQuotaPace.weekSeconds)
        let tolerance = WeeklyQuotaPace.clockTolerance
        // A lower reading and a new window start together establish the early reset.
        guard next.used < previous.used,
              next.reset.timeIntervalSince(previous.reset) > tolerance,
              previous.reset.timeIntervalSince(start) > tolerance,
              previous.time.timeIntervalSince(start) <= tolerance,
              start.timeIntervalSince(next.time) <= tolerance else { return nil }
        return start
    }

    private static func cycles(in samples: [WeeklyQuotaObservation]) -> [ArraySlice<WeeklyQuotaObservation>] {
        var cycles: [ArraySlice<WeeklyQuotaObservation>] = []
        var end = samples.endIndex
        while end > samples.startIndex {
            let newest = samples[end - 1]
            let start = samples[..<end].lastIndex { !$0.sharesCycle(with: newest) }.map { $0 + 1 } ?? samples.startIndex
            cycles.append(samples[start..<end])
            end = start
        }
        return cycles
    }

    private static func segments(from samples: [WeeklyQuotaObservation]) -> [[WeeklyQuotaObservation]] {
        var result: [[WeeklyQuotaObservation]] = []
        for sample in samples {
            if let previous = result.last?.last,
               sample.time.timeIntervalSince(previous.time) <= WeeklyQuotaPace.maximumObservationAge,
               sample.used >= previous.used {
                result[result.count - 1].append(sample)
            } else {
                result.append([sample])
            }
        }
        return result.map { segment in
            segment.indices.compactMap { index in
                index == 0 || index == segment.count - 1 || segment[index].used != segment[index - 1].used
                    ? segment[index] : nil
            }
        }
    }

    private static func forecasts(for samples: [WeeklyQuotaObservation], afterCorrection: Bool) -> [Forecast] {
        guard let first = samples.first, let last = samples.last else { return [] }
        if afterCorrection, last.time.timeIntervalSince(first.time) < UsageHours.hour { return [] }
        let cycleStart = last.reset.addingTimeInterval(-WeeklyQuotaPace.weekSeconds)
        let elapsed = last.time.timeIntervalSince(cycleStart)
        guard elapsed >= UsageHours.hour else { return [] }
        let remainingTime = last.reset.timeIntervalSince(last.time)
        let used = Double(last.used)
        func forecast(_ period: Forecast.Period, rate: Double) -> Forecast {
            let estimate = used + rate * remainingTime
            let exhaustion = rate > 0 && estimate >= 100 ? last.time.addingTimeInterval((100 - used) / rate) : nil
            return Forecast(period: period, atReset: estimate, exhaustion: exhaustion)
        }
        var projections = [forecast(.window, rate: used / elapsed)]
        let target = last.time.addingTimeInterval(-24 * UsageHours.hour)
        if let sample = samples.last(where: { $0.time <= target }),
           target.timeIntervalSince(sample.time) <= WeeklyQuotaPace.maximumObservationAge {
            projections.append(forecast(.day, rate: Double(last.used - sample.used) / last.time.timeIntervalSince(sample.time)))
        }
        return projections
    }

    private static func hourlyUsage(_ samples: [WeeklyQuotaObservation], window hours: UsageHours, now: Date) -> [Hour] {
        // Start from the observation just before the selected range.
        var lower = 0
        var upper = samples.count
        while lower < upper {
            let middle = lower + (upper - lower) / 2
            if samples[middle].time <= hours.start { lower = middle + 1 } else { upper = middle }
        }
        var firstIndex = max(0, lower - 1)
        return hours.starts.map { start in
            let hourEnd = start.addingTimeInterval(UsageHours.hour)
            let nominalEnd = min(hourEnd, now)
            while firstIndex + 1 < samples.count, samples[firstIndex + 1].time <= start {
                firstIndex += 1
            }
            guard let newest = samples.last else { return Hour(start: start) }
            let end = start == hours.last ? min(nominalEnd, newest.time) : nominalEnd
            guard start < end else { return Hour(start: start) }
            var index = firstIndex
            var complete = samples[index].time <= start && end == hourEnd
            var observed: Int?
            while index + 1 < samples.count, samples[index].time < end {
                let left = samples[index]
                let right = samples[index + 1]
                let delta = right.used - left.used
                if !left.sharesCycle(with: right) || delta < 0 {
                    complete = false
                    // Start a new subtotal when the quota baseline changes inside the hour.
                    if right.time < end { observed = nil }
                } else if right.time.timeIntervalSince(left.time) > WeeklyQuotaPace.maximumObservationAge
                            || (delta > 0 && (left.time < start || right.time > end)) {
                    complete = false
                } else {
                    observed = (observed ?? 0) + delta
                }
                index += 1
            }
            if complete && samples[index].time >= end {
                return Hour(start: start, percentagePoints: observed)
            }
            return Hour(start: start, partialPercentagePoints: observed)
        }
    }
}
