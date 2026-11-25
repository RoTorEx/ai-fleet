import Combine
import CryptoKit
import Foundation

extension ProviderLimitWindow {
    var isWeeklyQuota: Bool {
        durationSeconds == WeeklyQuotaPace.weekSeconds || weeklyModel != nil
    }
}

extension StatisticsProviderReport {
    var weeklyWindows: [ProviderLimitWindow] {
        limits.filter(\.isWeeklyQuota).sorted {
            if ($0.weeklyModel == nil) != ($1.weeklyModel == nil) { return $0.weeklyModel == nil }
            return $0.label.localizedStandardCompare($1.label) == .orderedAscending
        }
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
        let cutoff = now.addingTimeInterval(-WeeklyQuotaPace.weekSeconds)
        for key in Array(records.keys) {
            records[key]?.removeAll { $0.time < cutoff }
            if records[key]?.isEmpty == true { records.removeValue(forKey: key) }
        }
        for report in reports where report.quotaState == .available || report.quotaState == .exhausted {
            for window in report.weeklyWindows {
                guard let sample = WeeklyQuotaObservation(report: report, window: window, now: now),
                      sample.time >= cutoff, now.timeIntervalSince(sample.time) <= WeeklyQuotaPace.maximumObservationAge else { continue }
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
        enum Period: String { case window = "Window average", day = "Trailing 24h" }
        let period: Period
        let atReset: Double
        let exhaustion: Date?
        var id: Period { period }
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
    let latest: WeeklyQuotaObservation?
    var sustainablePerHour: Double? { pace.sustainablePercentPerDay.map { $0 / 24 } }

    init(report: StatisticsProviderReport, window: ProviderLimitWindow, history: WeeklyQuotaHistory,
         now: Date, calendar: Calendar = .autoupdatingCurrent) {
        pace = WeeklyQuotaPace.make(report: report, window: window, now: now)
        var samples = history.records[WeeklyQuotaHistoryKey(report: report, window: window)] ?? []
        if let sample = WeeklyQuotaObservation(report: report, window: window, now: now),
           samples.last.map({ $0.time <= sample.time }) ?? true {
            if samples.last?.time == sample.time { samples.removeLast() }
            samples.append(sample)
        }
        let current = samples.last
        latest = current
        cycleStart = current?.reset.addingTimeInterval(-WeeklyQuotaPace.weekSeconds)
        let currentCycle = current.map { latest in samples.filter { $0.sharesCycle(with: latest) } } ?? []
        segments = Self.segments(from: currentCycle)
        let correction = currentCycle.indices.dropFirst().last { index in
            currentCycle[index].used < currentCycle[index - 1].used
        }
        let forecastSamples = correction.map { Array(currentCycle[$0...]) } ?? currentCycle
        forecasts = pace.state == .current ? Self.forecasts(for: forecastSamples, afterCorrection: correction != nil) : []
        hours = Self.hourlyUsage(samples, now: now, calendar: calendar)
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

    private static func hourlyUsage(_ samples: [WeeklyQuotaObservation], now: Date, calendar: Calendar) -> [Hour] {
        let hours = UsageHours(now: now, calendar: calendar)
        var firstIndex = 0
        return hours.starts.map { start in
            let nominalEnd = min(start.addingTimeInterval(UsageHours.hour), now)
            while firstIndex + 1 < samples.count, samples[firstIndex + 1].time <= start {
                firstIndex += 1
            }
            guard let newest = samples.last else { return Hour(start: start) }
            let end = start == hours.last ? min(nominalEnd, newest.time) : nominalEnd
            guard start < end else { return Hour(start: start) }
            if samples[firstIndex].time > start {
                let observed = samples[firstIndex...].prefix { $0.time <= end }
                return Hour(start: start, partialPercentagePoints: partialChange(in: observed))
            }
            var index = firstIndex
            var used = 0
            while index + 1 < samples.count, samples[index].time < end {
                let left = samples[index]
                let right = samples[index + 1]
                let delta = right.used - left.used
                guard left.sharesCycle(with: right), delta >= 0,
                      right.time.timeIntervalSince(left.time) <= WeeklyQuotaPace.maximumObservationAge,
                      delta == 0 || (left.time >= start && right.time <= end) else {
                    return Hour(start: start)
                }
                used += delta
                index += 1
            }
            return Hour(start: start, percentagePoints: samples[index].time >= end ? used : nil)
        }
    }

    private static func partialChange(in observations: ArraySlice<WeeklyQuotaObservation>) -> Int? {
        guard let first = observations.first, let last = observations.last, last.used > first.used,
              zip(observations, observations.dropFirst()).allSatisfy({ left, right in
                  left.sharesCycle(with: right) && right.used >= left.used
                      && right.time.timeIntervalSince(left.time) <= WeeklyQuotaPace.maximumObservationAge
              }) else { return nil }
        return last.used - first.used
    }
}
