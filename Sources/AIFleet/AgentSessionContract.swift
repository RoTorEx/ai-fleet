import Foundation

/// Presentation-independent data; no colors, layout, icon or animation decisions.
struct AgentSessionContract: Equatable, Identifiable {
    enum State: String { case working, idle, ready, question, approval, error, unknown, stale, unlinked }
    enum WorkTimeSource: String { case terminalTimer, providerRequest, observed }
    let id: String
    let provider: String
    let project: String
    let workingDirectory: String?
    let originalTitle: String
    let state: State
    let stateSource: String
    let pid: UInt32?
    let processStarted: UInt64?
    let pane: AgentPane?
    let linkReason: String?
    let model: String?
    let reasoning: String?
    let activityObservedAt: Date?
    let observedAt: Date?
    let lastMessageAt: Date?
    let requestStartedAt: Date?
    let workStartedAt: Date?
    let workTimeSource: WorkTimeSource?

    init(session: AgentSession, observedAt: Date?, stale: Bool) {
        id = session.id; provider = session.provider; project = session.project
        workingDirectory = session.cwd; originalTitle = session.title
        pid = session.pid; processStarted = session.processStarted
        pane = session.location; linkReason = session.linkReason
        model = session.model; reasoning = session.reasoning
        self.observedAt = observedAt
        activityObservedAt = session.activityObservedAt.flatMap { $0.isFinite && $0 >= 0 ? Date(timeIntervalSince1970: $0) : nil }
        stateSource = session.stateSource ?? "unspecified"
        if stale { state = .stale }
        else if session.location == nil { state = .unlinked }
        else {
            switch session.state {
            case "Working": state = .working
            case "Idle", "Opened", "Untracked": state = .idle
            case "Ready", "New reply": state = .ready
            case "Question": state = .question
            case "Approval": state = .approval
            case "Blocked", "Error": state = .error
            default: state = .unknown
            }
        }
        func validDate(_ seconds: Double?) -> Date? {
            guard let seconds, seconds.isFinite, seconds >= 0,
                  let observedAt, seconds <= observedAt.timeIntervalSince1970 else { return nil }
            return Date(timeIntervalSince1970: seconds)
        }
        // Legacy updatedAt is a change observation and must never become message time.
        lastMessageAt = validDate(session.lastMessageAt)
        requestStartedAt = validDate(session.requestedAt)
        let source = session.workTimeSource.flatMap(WorkTimeSource.init(rawValue:))
        workTimeSource = state == .working ? source : nil
        workStartedAt = state == .working && source != nil ? validDate(session.workStartedAt) : nil
    }

    func workingDuration(at date: Date) -> TimeInterval? {
        guard state == .working, let workStartedAt, date >= workStartedAt else { return nil }
        return date.timeIntervalSince(workStartedAt)
    }
}
