import AppKit
import Combine
import Foundation
import Darwin

struct AgentPane: Decodable, Equatable {
    let id: String
    let window: String
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
    let explanation: String
    let model: String?
    let reasoning: String?
    let request: String?
    let answer: String?
    let updatedAt: Double?
    let requestedAt: Double?
    let workingStartedAt: Double?
    let lastMessageAt: Double?

    var needsYou: Bool { ["Approval", "Question", "Blocked"].contains(state) }
    var isWorking: Bool { state == "Working" }
    var locationLabel: String {
        guard let pane = location else { return linkReason ?? "Unlinked" }
        return "\(pane.window) · tab \(pane.tab_index + 1) · pane \(pane.pane_index + 1)"
    }
}

func compactAgentLocation(_ path: String, home: String = NSHomeDirectory()) -> String {
    let normalized = URL(fileURLWithPath: path).standardizedFileURL.path
    if normalized == URL(fileURLWithPath: home).standardizedFileURL.path { return "~" }
    let url = URL(fileURLWithPath: normalized)
    if url.deletingLastPathComponent().path == home { return "~/" + url.lastPathComponent }
    return url.pathComponents.filter { $0 != "/" }.suffix(2).joined(separator: "/")
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
    private var workObservations = AgentWorkObservations()
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

    init(executableURL: URL? = nil) {
        self.executableURL = executableURL
    }

    var groups: [AgentGroup] { AgentGroup.make(sessions) }
    var isStale: Bool { error != nil || (observedAt.map { Date().timeIntervalSince($0) > 15 } ?? false) }

    func start() {
        guard !isVisible else { return }
        isVisible = true
        refresh(force: true)
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        timer?.tolerance = 0.3
    }

    func stop() {
        isVisible = false
        workObservations.reset()
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
                guard let self, self.generation == token, self.isVisible else { return }
                self.transport = nil
                self.pendingRefresh = nil
                self.pendingJump = nil
                self.isLoading = false
                self.jumpingID = nil
                self.error = "Session engine stopped. Refresh to reconnect."
            }
        })
    }

    func refresh(force: Bool = false) {
        guard isVisible else { return }
        if let started = jumpStarted, pendingJump != nil, Date().timeIntervalSince(started) > 8 {
            pendingJump = nil
            jumpingID = nil
            jumpError = "Terminal did not confirm the jump. Retry."
        }
        if pendingRefresh != nil {
            if let started = refreshStarted, Date().timeIntervalSince(started) > 15 {
                error = "Session scan is taking longer than expected. Last results are stale."
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
            pendingRefresh = nil
            isLoading = false
        }
    }

    func workClock(for session: AgentSession) -> AgentWorkClock? {
        workObservations.clock(for: session)
    }

    func jump(to session: AgentSession) {
        guard session.location != nil, pendingJump == nil, isVisible else { return }
        selectedID = session.id
        jumpError = nil
        do {
            try connect()
            nextID += 1
            pendingJump = nextID
            jumpingID = session.id
            jumpStarted = Date()
            try transport?.send(["requestId": nextID, "command": "jump", "sessionId": session.id])
        } catch {
            jumpError = error.localizedDescription
            pendingJump = nil
            jumpingID = nil
        }
    }

    func receive(_ data: Data) {
        guard let reply = try? JSONDecoder().decode(AgentReply.self, from: data), reply.protocol == 1 else {
            error = "Session engine returned an unsupported response. Reinstall AI Fleet."
            pendingRefresh = nil
            isLoading = false
            return
        }
        if reply.kind == "snapshot", reply.requestID == pendingRefresh {
            pendingRefresh = nil
            isLoading = false
            error = reply.error
            if let sessions = reply.sessions, reply.error == nil {
                workObservations.update(sessions, now: Date())
                if self.sessions != sessions { self.sessions = sessions }
                observedAt = reply.observedAt.map(Date.init(timeIntervalSince1970:))
            }
        } else if reply.kind == "jump", reply.requestID == pendingJump {
            pendingJump = nil
            jumpingID = nil
            jumpError = reply.error
        }
    }
}

struct AgentWorkClock: Equatable {
    let startedAt: Date
    let exact: Bool
    func elapsed(at now: Date) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(startedAt)))
        let parts = [(seconds / 86400, "d"), ((seconds % 86400) / 3600, "h"),
                     ((seconds % 3600) / 60, "m"), (seconds % 60, "s")]
        let duration = parts.filter { $0.0 > 0 }.map { "\($0.0)\($0.1)" }.joined(separator: " ")
        return (exact ? "" : "≥") + (duration.isEmpty ? "0s" : duration)
    }
}

struct AgentWorkObservations {
    private var starts: [String: Date] = [:]
    mutating func reset() { starts.removeAll() }
    mutating func update(_ sessions: [AgentSession], now: Date) {
        let working = Set(sessions.filter(\.isWorking).map(\.id))
        starts = starts.filter { working.contains($0.key) }
        for session in sessions where session.isWorking && starts[session.id] == nil { starts[session.id] = now }
    }
    func clock(for session: AgentSession) -> AgentWorkClock? {
        guard session.isWorking, let observed = starts[session.id] else { return nil }
        if let requestedAt = session.workingStartedAt ?? session.requestedAt, requestedAt <= Date().timeIntervalSince1970 {
            return AgentWorkClock(startedAt: Date(timeIntervalSince1970: requestedAt), exact: true)
        }
        return AgentWorkClock(startedAt: observed, exact: false)
    }
}
