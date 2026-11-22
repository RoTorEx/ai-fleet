import Foundation

/// One macOS notification. The system draws title and subtitle bold on one line each (about 40
/// characters) and the body below: 3 lines closed, 10 open. Layout follows design/notifications.
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

    var needsYou: Bool { self != .replyReady }
}

/// A fired session alert and the text of its banner.
struct AgentAlert: Identifiable, Equatable {
    /// Reply, request and place together fit the ten body lines of an open banner.
    static let replyLimit = 250
    static let requestLimit = 70

    let id: String
    /// The session as it was when the alert fired.
    let session: AgentSession
    let reason: AgentNotificationReason
    /// Sessions spanned several iTerm2 windows, so the place line names the window.
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

    /// Terminal session name, then tab title. Nil when neither says more than the project.
    var name: String? {
        let name = meaningful(session.title) ?? meaningful(session.location?.tab)
        return name == projectName ? nil : name
    }

    /// Glyph, provider, project. The glyph alone is the type.
    var title: String {
        ["\(reason.glyph) \(session.provider.capitalized)", projectName].compactMap { $0 }.joined(separator: " · ")
    }

    /// Tab, pane for a split, and the window while sessions span several. A click already opens
    /// the exact pane, so this is a reference kept out of the header.
    var place: String? {
        guard let pane = session.location else { return nil }
        var parts = ["tab \(pane.tab_index + 1)"]
        if pane.pane_index > 0 { parts.append("pane \(pane.pane_index + 1)") }
        if namesWindow, let window = meaningful(pane.window), window.lowercased() != "iterm2", window != name {
            parts.append(window)
        }
        return parts.joined(separator: " · ")
    }

    /// Captured text: the agent's reply leads because the closed banner shows three lines and
    /// they must carry the news. Empty for providers without a transcript.
    var lines: [String] {
        [clipped(session.answer, limit: Self.replyLimit),
         clipped(session.request, limit: Self.requestLimit).map { "› \($0)" }].compactMap { $0 }
    }

    /// Title: glyph, provider, project. Subtitle: the session name on its own bold line.
    /// Body: reply, request, then the place as the last line.
    func text(showText: Bool) -> FleetNotificationText {
        let body = (showText ? lines : []) + [place].compactMap { $0 }
        return FleetNotificationText(title: title, subtitle: name ?? "", body: body.joined(separator: "\n"))
    }

    /// The home folder is where sessions start by default, so it identifies nothing.
    private var projectName: String? {
        let name = URL(fileURLWithPath: session.project).lastPathComponent
        return session.project.isEmpty || name == "/" || session.project == NSHomeDirectory() ? nil : name
    }

    /// Titles that only repeat the provider or shell identify nothing. Codex titles read
    /// "[ ! ] Action Required | task | folder": the status repeats the glyph and the folder the title.
    private func meaningful(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let generic: Set<String> = [session.provider.lowercased(), "codex", "claude", "claude code", "kimi",
                                    "kimi-code", "qwen", "gemini", "grok", "node", "bash", "zsh", "fish", "sh"]
        var parts = AgentRowText.title(raw, provider: session.provider).components(separatedBy: " | ")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        if parts.count > 1, parts[0].range(of: #"^\[\s*\S?\s*\]"#, options: .regularExpression) != nil {
            parts.removeFirst()
        }
        let folders = [session.project, session.cwd ?? ""].map { URL(fileURLWithPath: $0).lastPathComponent }
        if parts.count > 1, let last = parts.last, folders.contains(last) { parts.removeLast() }
        let title = parts.joined(separator: " | ")
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
