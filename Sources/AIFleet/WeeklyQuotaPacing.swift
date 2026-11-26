import Foundation

/// Weekly quota pacing for one identity-verified account report.
/// Every value stays in provider percentage units; local token counts never enter it.
/// Only the provider-reported window and reset timestamp are used: no hourly history, forecast or assumed lifetime.
struct WeeklyQuotaPace: Equatable {
    enum State: Equatable {
        /// Fresh observation inside its provider window; pacing values are present.
        case current
        /// Last observation is too old or the provider marked it stale; only the observed percentage is shown.
        case stale
        /// The reported reset has passed (or preceded the observation); the old percentage no longer describes the window.
        case resetPending
        /// Weekly percentage is fresh but the reset timestamp is missing or inconsistent with the window.
        case partial
        /// No trustworthy weekly percentage for this account.
        case unavailable
    }

    /// Observations older than this are not current enough for pacing (see business/provider-statistics.md).
    static let maximumObservationAge: TimeInterval = 15 * 60
    /// Provider windows whose reported duration is exactly one week.
    static let weekSeconds: TimeInterval = 7 * 24 * 60 * 60
    static let daySeconds: TimeInterval = 24 * 60 * 60
    /// Reset timestamps may round against the observation clock by this much.
    static let clockTolerance: TimeInterval = 60

    var state: State = .unavailable
    var usedPercent: Int?
    /// Seconds from `now` to the observed provider reset.
    var timeToReset: TimeInterval?
    /// Pace target at the most recent completed provider day.
    var dailyBudgetPercent: Double?
    /// Daily budget minus used, in percentage points; positive means under budget.
    var headroomPoints: Double?
    /// Remaining percentage per day that lasts exactly until the reset.
    var sustainablePercentPerDay: Double?

    static func make(report: StatisticsProviderReport, window selected: ProviderLimitWindow? = nil, now: Date,
                     maximumAge: TimeInterval = WeeklyQuotaPace.maximumObservationAge) -> WeeklyQuotaPace {
        var pace = WeeklyQuotaPace()
        let measuredStates: [ProviderStatus.QuotaState] = [.available, .exhausted, .stale]
        let trusted = report.quotaAuthentication == .signedIn && measuredStates.contains(report.quotaState)
        guard trusted, let window = selected ?? report.weeklyWindows.first(where: { $0.weeklyModel == nil }),
              window.isWeeklyQuota,
              (0...100).contains(window.remainingPercent) else { return pace }
        pace.usedPercent = 100 - window.remainingPercent
        guard report.quotaState != .stale, let observed = report.fetchedAt,
              observed <= now.addingTimeInterval(clockTolerance),
              now.timeIntervalSince(observed) <= maximumAge else { pace.state = .stale; return pace }
        guard let reset = window.resetAt, reset.timeIntervalSince1970.isFinite else { pace.state = .partial; return pace }
        guard reset > now, reset > observed else { pace.state = .resetPending; return pace }
        let windowStart = reset.addingTimeInterval(-weekSeconds)
        // A reset further away than one window cannot place the observation inside it.
        guard observed >= windowStart.addingTimeInterval(-clockTolerance) else { pace.state = .partial; return pace }
        let budget = budget(at: observed, cycleStart: windowStart)
        let left = reset.timeIntervalSince(now)
        pace.state = .current
        pace.timeToReset = left
        pace.dailyBudgetPercent = budget
        pace.headroomPoints = budget - Double(100 - window.remainingPercent)
        pace.sustainablePercentPerDay = Double(window.remainingPercent) / (left / daySeconds)
        return pace
    }

    static func budget(at date: Date, cycleStart: Date) -> Double {
        let completedDays = floor(max(0, date.timeIntervalSince(cycleStart)) / daySeconds)
        return min(7, completedDays) * 100 / 7
    }
}

extension WeeklyQuotaPace {
    /// Up to two leading units, with seconds rounded up to the next minute.
    static func countdownText(_ seconds: TimeInterval) -> String {
        let minutes = Int(max(0, ceil(seconds / 60)))
        let (days, hours, rest) = (minutes / 1440, minutes % 1440 / 60, minutes % 60)
        if days > 0 { return "\(days)d \(hours)h" }
        return hours > 0 ? "\(hours)h \(rest)m" : "\(rest)m"
    }
}
