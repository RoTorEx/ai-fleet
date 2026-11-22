import AppKit
import Combine
import Foundation
import Darwin

struct AgentPane: Decodable, Equatable {
    let id: String
    let window: String
    let tab: String?
    let tab_index: Int
    let pane_index: Int
}

struct AgentSession: Decodable, Identifiable, Equatable {
    let id: String
    let provider: String
    let project: String
    let title: String
    let location: AgentPane?
    let linkReason: String?
    let state: String
    let activityState: String?
    let explanation: String
    let model: String?
    let reasoning: String?
    let request: String?
    let answer: String?
    let updatedAt: Double?
    let activityObservedAt: Double?
    let dataVersion: Int?
    let pid: UInt32?
    let processStarted: UInt64?
    let cwd: String?
    let requestedAt: Double?
    let lastMessageAt: Double?
    let workingStartedAt: Double?
    let workStartedAt: Double?
    let workTimeSource: String?
    let stateSource: String?

    var needsYou: Bool { ["Approval", "Question", "Blocked"].contains(state) }
    var isWorking: Bool { state == "Working" }
    var locationLabel: String {
        guard let pane = location else { return linkReason ?? "Unlinked" }
        return "\(pane.window) · tab \(pane.tab_index + 1) · pane \(pane.pane_index + 1)"
    }
}

enum AgentNotificationReason: String {
    case replyReady = "New reply"
    case approval = "Approval"
    case question = "Question"
    case blocked = "Blocked"
}

struct AgentNotificationTracker {
    private var previousStates: [String: String] = [:]
    private var lastSample: Date?
    private let startedAt: Date

    init(startedAt: Date) {
        self.startedAt = startedAt
    }

    mutating func observe(_ sessions: [AgentSession], now: Date) -> [(AgentSession, AgentNotificationReason)] {
        let linked = sessions.filter { $0.location != nil }
        let linkedIDs = Set(linked.map(\.id))
        previousStates = previousStates.filter { linkedIDs.contains($0.key) }
        guard let seconds = linked.first(where: { $0.activityState != nil })?.activityObservedAt,
              seconds.isFinite else { return [] }
        let sample = Date(timeIntervalSince1970: seconds)
        guard sample >= startedAt, sample <= now, now.timeIntervalSince(sample) <= 15,
              lastSample.map({ sample > $0 }) ?? true else { return [] }
        if let lastSample, sample.timeIntervalSince(lastSample) > 15 {
            previousStates.removeAll()
        }
        lastSample = sample
        return linked.compactMap { session in
            guard let state = session.activityState else { return nil }
            if state == "Unknown" {
                // Keep a known waiting state across unreadable samples, but break work continuity.
                if previousStates[session.id] == "Working" { previousStates.removeValue(forKey: session.id) }
                return nil
            }
            guard let previous = previousStates.updateValue(state, forKey: session.id),
                  previous != state, let reason = AgentNotificationReason(rawValue: state),
                  reason != .replyReady || previous == "Working" || previous == "Approval" else { return nil }
            return (session, reason)
        }
    }
}

enum AgentFilter: String, CaseIterable {
    case all = "All", needsYou = "Needs you", working = "Working", idle = "Idle", unknown = "Unknown"

    func matches(_ session: AgentSession) -> Bool {
        switch self {
        case .all: return true
        case .needsYou: return session.needsYou
        case .working: return session.isWorking
        case .idle: return ["Idle", "Opened", "Untracked", "New reply"].contains(session.state)
        case .unknown: return !session.isWorking && !session.needsYou && !["Idle", "Opened", "Untracked", "New reply"].contains(session.state)
        }
    }
}

struct AgentGroup: Identifiable {
    let id: String
    let name: String
    let sessions: [AgentSession]

    static func make(_ sessions: [AgentSession]) -> [AgentGroup] {
        let groups = Dictionary(grouping: sessions, by: \.project)
        let names = Dictionary(grouping: groups.keys, by: { URL(fileURLWithPath: $0).lastPathComponent })
        return groups.keys.sorted().map { path in
            let url = URL(fileURLWithPath: path)
            let base = url.lastPathComponent
            let name = (names[base]?.count ?? 0) > 1 ? "\(url.deletingLastPathComponent().lastPathComponent)/\(base)" : base
            // Stable identities/order keep rows under the pointer during refreshes.
            return AgentGroup(id: path, name: name, sessions: groups[path]!.sorted { $0.id < $1.id })
        }
    }
}

struct AgentReply: Decodable {
    let `protocol`: Int
    let requestID: Int
    let kind: String
    let sessions: [AgentSession]?
    let observedAt: Double?
    let sessionID: String?
    let error: String?
}

/// One bundled process, JSON lines over pipes; no shell and no external CLI lookup.
final class AgentTransport {
    private let process = Process()
    private let input = Pipe()
    private let output = Pipe()
    private let queue = DispatchQueue(label: "dev.ai-fleet.agents.output", qos: .utility)
    private var buffer = Data()
    private var stopped = false

    init(executable: URL, receive: @escaping (Data) -> Void, exited: @escaping () -> Void) throws {
        process.executableURL = executable
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        _ = fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
        process.terminationHandler = { _ in exited() }
        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else { handle.readabilityHandler = nil; return }
            self?.queue.async { [weak self] in
                guard let self else { return }
                self.buffer.append(chunk)
                while let end = self.buffer.firstIndex(of: 10) {
                    let line = self.buffer.prefix(upTo: end)
                    self.buffer.removeSubrange(...end)
                    receive(Data(line))
                }
            }
        }
        do { try process.run() } catch {
            output.fileHandleForReading.readabilityHandler = nil
            throw error
        }
    }

    func send(_ request: [String: Any]) throws {
        var data = try JSONSerialization.data(withJSONObject: request)
        data.append(10)
        try input.fileHandleForWriting.write(contentsOf: data)
    }

    func stop() {
        guard !stopped else { return }
        stopped = true
        // EOF lets the engine drop/reap its helpers, including in-flight work.
        try? input.fileHandleForWriting.close()
    }

    deinit { stop() }
}

@MainActor
final class AgentSessionsService: ObservableObject {
    @Published private(set) var sessions: [AgentSession] = []
    @Published private(set) var error: String?
    @Published private(set) var jumpError: String?
    @Published private(set) var observedAt: Date?
    @Published private(set) var isLoading = false
    @Published private(set) var jumpingID: String?
    @Published private(set) var selectedID: String?
    /// Lives here rather than in the view: menu content is rebuilt on every open.
    @Published var collapsedGroups = Set<String>()
    @Published var filter: AgentFilter = .all
    /// Alerts the user has not dealt with yet, newest first, one per session. Memory only:
    /// session text is never persisted by Fleet.
    @Published private(set) var alerts: [AgentAlert] = []
    @Published var showsHistory = false
    @Published private(set) var highlightedAlertID: String?
    /// Session IDs whose alert is over, so its delivered macOS notification can be withdrawn.
    var onAlertsRetired: (([String]) -> Void)?
    private var transport: AgentTransport?
    private var timer: Timer?
    private var generation = UUID()
    private var nextID = 0
    private var pendingRefresh: Int?
    private var pendingJump: Int?
    private var refreshStarted: Date?
    private var jumpStarted: Date?
    private(set) var isVisible = false
    private let executableURL: URL?
    private var notificationHandler: ((AgentAlert) -> Void)?
    private var notificationTracker: AgentNotificationTracker?
    private var notificationJump: (sessionID: String, completion: (String?) -> Void)?
    private var isObserving: Bool { isVisible || notificationHandler != nil || notificationJump != nil }

    init(executableURL: URL? = nil) {
        self.executableURL = executableURL
    }

    var contracts: [AgentSessionContract] {
        sessions.map { AgentSessionContract(session: $0, observedAt: observedAt, stale: isStale || !isObserving) }
    }

    var groups: [AgentGroup] { AgentGroup.make(sessions) }
    var isStale: Bool { error != nil || (observedAt.map { Date().timeIntervalSince($0) > 15 } ?? false) }

    func start() {
        guard !isVisible else { return }
        isVisible = true
        startObservation()
    }

    func setNotificationsEnabled(
        _ enabled: Bool,
        deliver: @escaping (AgentAlert) -> Void = { _ in }
    ) {
        notificationHandler = enabled ? deliver : nil
        resetNotificationTracking()
        if enabled { startObservation() }
        else if !isObserving { stopObservation() }
    }

    private func resetNotificationTracking() {
        notificationTracker = notificationHandler == nil ? nil : AgentNotificationTracker(startedAt: Date())
    }

    private func startObservation() {
        refresh(force: true)
        guard isObserving, timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        timer?.tolerance = 0.3
    }

    /// The session behind an alert while it still has an exact pane to open.
    func liveSession(for alert: AgentAlert) -> AgentSession? {
        sessions.first { $0.id == alert.session.id && $0.location != nil }
    }

    func showHistory(highlighting alertID: String?) {
        showsHistory = true
        highlightedAlertID = alertID
    }

    func clearAlerts() {
        let retired = alerts.map(\.session.id)
        alerts = []
        highlightedAlertID = nil
        if !retired.isEmpty { onAlertsRetired?(retired) }
    }

    func stop() {
        isVisible = false
        highlightedAlertID = nil
        if !isObserving { stopObservation() }
    }

    private func stopObservation() {
        timer?.invalidate()
        timer = nil
        generation = UUID()
        transport?.stop()
        transport = nil
        pendingRefresh = nil
        pendingJump = nil
        isLoading = false
        jumpingID = nil
    }

    private func connect() throws {
        guard transport == nil else { return }
        guard let executable = executableURL ?? Bundle.main.url(forAuxiliaryExecutable: "fleet-session-engine") else {
            throw NSError(domain: "Agents", code: 1, userInfo: [NSLocalizedDescriptionKey: "Session engine is missing. Reinstall AI Fleet."])
        }
        generation = UUID()
        let token = generation
        transport = try AgentTransport(executable: executable, receive: { [weak self] data in
            Task { @MainActor in
                guard let self, self.generation == token else { return }
                self.receive(data)
            }
        }, exited: { [weak self] in
            Task { @MainActor in
                guard let self, self.generation == token, self.isObserving else { return }
                self.transport = nil
                self.pendingRefresh = nil
                self.isLoading = false
                self.error = "Session engine stopped. Refresh to reconnect."
                self.resetNotificationTracking()
                if self.pendingJump != nil || self.notificationJump != nil {
                    self.finishJump(error: self.error)
                }
            }
        })
    }

    func refresh(force: Bool = false) {
        guard isObserving else { return }
        if let started = jumpStarted, pendingJump != nil, Date().timeIntervalSince(started) > 8 {
            finishJump(error: "Terminal did not confirm the jump. Retry.")
            guard isObserving else { return }
        }
        if pendingRefresh != nil {
            if let started = refreshStarted, Date().timeIntervalSince(started) > 15 {
                error = "Session scan is taking longer than expected. Last results are stale."
                if notificationJump != nil, pendingJump == nil { finishJump(error: error) }
            }
            return
        }
        do {
            try connect()
            nextID += 1
            pendingRefresh = nextID
            refreshStarted = Date()
            isLoading = sessions.isEmpty
            try transport?.send(["requestId": nextID, "command": "refresh", "force": force])
        } catch {
            self.error = error.localizedDescription
            resetNotificationTracking()
            pendingRefresh = nil
            isLoading = false
            if notificationJump != nil, pendingJump == nil { finishJump(error: self.error) }
        }
    }

    func jump(to session: AgentSession) {
        guard session.location != nil, pendingJump == nil, notificationJump == nil, isVisible else { return }
        sendJump(to: session.id)
    }

    func jumpFromNotification(_ sessionID: String, completion: @escaping (String?) -> Void) {
        guard pendingJump == nil, notificationJump == nil else { return }
        notificationJump = (sessionID, completion)
        jumpError = nil
        if transport != nil, !isStale, sessions.contains(where: { $0.id == sessionID && $0.location != nil }) {
            sendJump(to: sessionID)
        } else {
            startObservation()
        }
    }

    private func sendJump(to sessionID: String) {
        selectedID = sessionID
        jumpError = nil
        do {
            try connect()
            nextID += 1
            pendingJump = nextID
            jumpingID = sessionID
            jumpStarted = Date()
            try transport?.send(["requestId": nextID, "command": "jump", "sessionId": sessionID])
        } catch {
            finishJump(error: error.localizedDescription)
        }
    }

    private func finishJump(error: String?) {
        pendingJump = nil
        jumpingID = nil
        jumpError = error
        let completion = notificationJump?.completion
        notificationJump = nil
        if !isObserving { stopObservation() }
        completion?(error)
    }

    func receive(_ data: Data) {
        guard let reply = try? JSONDecoder().decode(AgentReply.self, from: data), reply.protocol == 1 else {
            error = "Session engine returned an unsupported response. Reinstall AI Fleet."
            resetNotificationTracking()
            pendingRefresh = nil
            isLoading = false
            if notificationJump != nil { finishJump(error: error) }
            return
        }
        if reply.kind == "snapshot", reply.requestID == pendingRefresh {
            pendingRefresh = nil
            isLoading = false
            let late = refreshStarted.map { Date().timeIntervalSince($0) > 15 } ?? false
            if late { resetNotificationTracking() }
            error = reply.error
            if let sessions = reply.sessions, reply.error == nil {
                if self.sessions != sessions { self.sessions = sessions }
                observedAt = reply.observedAt.map(Date.init(timeIntervalSince1970:))
                let fired = late ? [] : notificationTracker?.observe(sessions, now: Date()) ?? []
                let namesWindow = Set(sessions.compactMap { $0.location?.window }).count > 1
                // Alerts fired by this snapshot are judged from the next one, so a reply that lands in
                // the pane being watched still sounds before it leaves.
                let firing = Set(fired.map(\.0.id))
                let over = alerts.filter { !$0.isCurrent(in: sessions) }.map(\.session.id)
                if !over.isEmpty || !firing.isEmpty {
                    alerts.removeAll { over.contains($0.session.id) || firing.contains($0.session.id) }
                }
                // A session firing again reuses its notification; withdrawing it here could race the new one.
                let retired = over.filter { !firing.contains($0) }
                if !retired.isEmpty { onAlertsRetired?(retired) }
                for (session, reason) in fired {
                    let alert = AgentAlert(id: UUID().uuidString, session: session, reason: reason,
                                           namesWindow: namesWindow, date: Date())
                    alerts.insert(alert, at: 0)
                    notificationHandler?(alert)
                }
            } else {
                resetNotificationTracking()
            }
            if let target = notificationJump?.sessionID, pendingJump == nil {
                if late || reply.error != nil {
                    finishJump(error: reply.error ?? "Session scan took too long. Try opening the notification again.")
                } else if reply.sessions?.contains(where: { $0.id == target && $0.location != nil }) == true {
                    sendJump(to: target)
                } else {
                    finishJump(error: "This session has ended or its iTerm2 pane could not be found.")
                }
            }
        } else if reply.kind == "jump", reply.requestID == pendingJump {
            finishJump(error: reply.error)
        }
    }
}
