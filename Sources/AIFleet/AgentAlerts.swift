import Foundation

/// One macOS notification: the system draws title and subtitle on one line each
/// and the body below them. Layout follows design/notifications.
struct FleetNotificationText: Equatable {
    let title: String
    var subtitle = ""
    let body: String
}

extension AgentNotificationReason {
    /// Colour emoji is the only colour a system banner allows; shape and colour differ per type.
    var glyph: String {
        switch self {
        case .approval: return "✋"
        case .question: return "💬"
        case .blocked: return "⛔"
        case .replyReady: return "✅"
        }
    }

    var word: String {
        switch self {
        case .approval: return "Approval"
        case .question: return "Question"
        case .blocked: return "Blocked"
        case .replyReady: return "Done"
        }
    }

    /// Body when message text is hidden or the provider has no bound transcript.
    var sentence: String {
        switch self {
        case .approval: return "Waiting for your approval."
        case .question: return "Asked you a question."
        case .blocked: return "Reported a blocker."
        case .replyReady: return "Reply is ready."
        }
    }

    var needsYou: Bool { self != .replyReady }
    /// A question or blocker is what the user acts on, so it precedes the request.
    var leadsWithReply: Bool { self == .question || self == .blocked }
}

/// A fired session alert. The banner and the in-memory History row are both built from it.
struct AgentAlert: Identifiable, Equatable {
    static let requestLimit = 100
    static let replyLimit = 300

    let id: String
    /// The session as it was when the alert fired.
    let session: AgentSession
    let reason: AgentNotificationReason
    /// Sessions spanned several iTerm2 windows, so the meta line names the window.
    let namesWindow: Bool
    let date: Date

    /// States that prove the session moved on: viewed in a frontmost pane, new work, or another request.
    private static let evidence: Set<String> = ["Working", "Opened", "New reply", "Approval", "Question", "Blocked"]

    /// An alert stays until its session ends or leaves the state that fired it. Unreadable samples
    /// (Unknown) and an unknown opening history (Untracked) prove nothing, so they keep it.
    func isCurrent(in sessions: [AgentSession]) -> Bool {
        guard let live = sessions.first(where: { $0.id == session.id }) else { return false }
        return live.state == reason.rawValue || !Self.evidence.contains(live.state)
    }

    /// Terminal session name, then tab title, then project folder.
    var name: String {
        meaningful(session.title) ?? meaningful(session.location?.tab) ?? projectName ?? "Terminal session"
    }

    var heading: String { "\(reason.word) · \(name)" }

    /// Project, location, provider: a truncated line loses the provider first.
    var meta: String {
        var parts: [String] = []
        if let projectName, projectName != name { parts.append(projectName) }
        if let pane = session.location {
            if namesWindow, let window = meaningful(pane.window), window.lowercased() != "iterm2", window != name {
                parts.append(window)
            }
            parts.append("tab \(pane.tab_index + 1)")
            if pane.pane_index > 0 { parts.append("pane \(pane.pane_index + 1)") }
        }
        parts.append(session.provider.capitalized)
        return parts.joined(separator: " · ")
    }

    /// Captured text, most actionable line first. Empty for providers without a transcript.
    var lines: [String] {
        let request = clipped(session.request, limit: Self.requestLimit).map { "› \($0)" }
        let reply = clipped(session.answer, limit: Self.replyLimit)
        return (reason.leadsWithReply ? [reply, request] : [request, reply]).compactMap { $0 }
    }

    func text(showText: Bool) -> FleetNotificationText {
        let lines = showText ? self.lines : []
        return FleetNotificationText(title: "\(reason.glyph) \(heading)", subtitle: meta,
                                     body: lines.isEmpty ? reason.sentence : lines.joined(separator: "\n"))
    }

    private var projectName: String? {
        let name = URL(fileURLWithPath: session.project).lastPathComponent
        return session.project.isEmpty || name == "/" ? nil : name
    }

    /// Titles that only repeat the provider or shell identify nothing.
    private func meaningful(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let generic: Set<String> = [session.provider.lowercased(), "codex", "claude", "claude code", "kimi",
                                    "kimi-code", "qwen", "gemini", "grok", "node", "bash", "zsh", "fish", "sh"]
        let title = AgentRowText.title(raw, provider: session.provider).trimmingCharacters(in: .whitespacesAndNewlines)
        let job = title.trimmingCharacters(in: CharacterSet(charactersIn: "()")).lowercased()
        return title.isEmpty || generic.contains(job) ? nil : title
    }

    private func clipped(_ raw: String?, limit: Int) -> String? {
        guard let raw else { return nil }
        let text = Self.clip(raw, limit: limit)
        return text.isEmpty ? nil : text
    }

    /// One line of plain text: Markdown marks dropped, whitespace collapsed, cut near a word boundary.
    static func clip(_ raw: String, limit: Int) -> String {
        let plain = raw.replacingOccurrences(of: #"(?m)```\w*|`|\*\*|^\s{0,3}#{1,6}\s+"#, with: "",
                                             options: .regularExpression)
        let text = plain.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard text.count > limit else { return text }
        let cut = text.prefix(limit)
        let lastSpace = cut.lastIndex(of: " ").map { cut.distance(from: cut.startIndex, to: $0) } ?? 0
        var kept = String(cut.prefix(max(lastSpace, limit - 20)))
        while let last = kept.last, " ,.;:".contains(last) { kept.removeLast() }
        return kept + "…"
    }
}
