import AppKit
import SwiftUI

struct AgentsView: View {
    @ObservedObject var service: AgentSessionsService
    let back: () -> Void
    @State private var filter = "All"
    @State private var collapsed = Set<String>()
    @Binding var section: String
    let embedded: Bool
    let maxListHeight: CGFloat?

    init(service: AgentSessionsService, back: @escaping () -> Void, section: Binding<String> = .constant("Sessions"), embedded: Bool = false, maxListHeight: CGFloat? = nil) {
        self.service = service; self.back = back; self._section = section; self.embedded = embedded; self.maxListHeight = maxListHeight
    }
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private let filters = ["All", "Needs you", "Working", "Idle", "Unknown"]

    private var visible: [AgentSession] {
        service.sessions.filter { session in
            switch filter {
            case "Needs you": return session.needsYou
            case "Working": return session.isWorking
            case "Idle": return ["Untracked", "Opened", "New reply"].contains(session.state)
            case "Unknown": return session.state == "Unknown" || session.location == nil
            default: return true
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            if embedded {
                HStack(spacing: 6) {
                    Text("Agents").font(FleetUI.menuHeading)
                    Text("\(visible.count)").font(FleetUI.menuSecondary).foregroundStyle(.secondary)
                    Spacer()
                    filterMenu
                }.padding(.vertical, 6)
            } else {
                HStack(spacing: 9) {
                    Image(systemName: "waveform.path.ecg").foregroundStyle(.green)
                    Text(section == "Processes" ? "Processes" : "Agents").font(FleetUI.title)
                    if section == "Sessions" {
                        Text("\(service.sessions.count)").font(FleetUI.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if section == "Sessions" {
                        if service.isLoading { ProgressView().controlSize(.small) }
                        Button { service.refresh(force: true) } label: { Image(systemName: "arrow.clockwise") }
                            .buttonStyle(.plain).help("Refresh sessions (⌘R)").keyboardShortcut("r")
                    }
                    Menu {
                        Button("Overview") { back() }
                        Button("Processes") { section = "Processes" }
                    } label: { Image(systemName: "ellipsis").frame(width: 24, height: 24) }
                        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                        .accessibilityLabel("Agent view options")
                    Button(action: back) {
                        HStack(spacing: 5) { Image(systemName: "chevron.left"); Text("Overview"); Text("⌘A").foregroundStyle(.secondary) }
                    }.buttonStyle(.plain).help("Return to the main menu (⌘A)")
                }.padding(.horizontal, 16).padding(.top, 15).padding(.bottom, 10)
            }
            if section == "Processes" {
                MenuRowsViewport(maxHeight: maxListHeight ?? (embedded ? 400 : 550)) {
                    CodexProcessesView()
                }
            } else {
                MenuRowsViewport(maxHeight: maxListHeight ?? (embedded ? 400 : 550)) {
                    VStack(alignment: .leading, spacing: 3) {
                        if let error = service.error {
                            Label(error, systemImage: "exclamationmark.triangle")
                                .font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                                .padding(12).frame(maxWidth: .infinity, alignment: .leading)
                        } else if !service.sessions.isEmpty, service.sessions.allSatisfy({ $0.location == nil }) {
                            Text(service.sessions.first?.linkReason ?? "No confirmed iTerm2 links. Check Automation permission in System Settings.")
                                .font(.caption).foregroundStyle(.orange).lineLimit(3)
                                .padding(12).frame(maxWidth: .infinity, alignment: .leading)
                        }

                        if visible.isEmpty {
                            VStack(spacing: 10) {
                                Image(systemName: service.isLoading ? "antenna.radiowaves.left.and.right" : "terminal")
                                    .font(.system(size: embedded ? 18 : 28)).foregroundStyle(.secondary)
                                Text(service.isLoading ? "Finding live sessions…" : emptyTitle).font(embedded ? FleetUI.menuHeading : .headline)
                                Text(service.sessions.isEmpty ? "Open Codex or Claude in iTerm2.\nYour usual launch commands stay the same." : "Choose another filter to see more sessions.")
                                    .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
                            }.frame(maxWidth: .infinity).padding(.vertical, embedded ? 16 : 55)
                        }
                        ForEach(AgentGroup.make(visible)) { group in
                            Button {
                                withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.18)) {
                                    if !collapsed.insert(group.id).inserted { collapsed.remove(group.id) }
                                }
                            } label: {
                                HStack(spacing: 6) {
                                    Image(systemName: collapsed.contains(group.id) ? "chevron.right" : "chevron.down").font(.system(size: 8, weight: .bold))
                                    Image(systemName: "folder").font(FleetUI.menuIcon).frame(width: 12)
                                    Text(compactAgentLocation(group.id)).lineLimit(1).truncationMode(.middle)
                                    Text("\(group.sessions.count)").foregroundStyle(.tertiary)
                                    Spacer()
                                }.font(FleetUI.menuBody).foregroundStyle(.secondary)
                                    .padding(.horizontal, embedded ? 0 : 9).padding(.top, 6).padding(.bottom, 3)
                                    .contentShape(Rectangle())
                            }.buttonStyle(.plain).help(group.id)
                            if !collapsed.contains(group.id) {
                                ForEach(group.sessions) { session in
                                    AgentSessionRow(session: session,
                                        selected: service.selectedID == session.id,
                                        jumping: service.jumpingID == session.id,
                                        stale: service.isStale,
                                        canJump: service.jumpingID == nil) {
                                        service.jump(to: session)
                                    }
                                }
                            }
                        }
                        if let error = service.jumpError {
                            Text(error).font(FleetUI.caption).foregroundStyle(.orange)
                                .frame(maxWidth: .infinity, alignment: .leading).padding(.top, 6)
                        }
                    }.padding(.horizontal, embedded ? 0 : 9).padding(.bottom, 6)
                }

                if !embedded {
                    Divider()
                    HStack(spacing: 7) {
                        Circle().fill(service.isStale ? Color.orange : Color.green).frame(width: 5, height: 5)
                        Text(service.isStale ? "Stale · refresh to verify" : (service.isLoading ? "Connecting to iTerm2…" : "Live · local iTerm2 sessions"))
                        Spacer()
                        Text("Click to jump · Esc to close")
                    }.font(FleetUI.caption).foregroundStyle(.secondary)
                        .padding(.horizontal, FleetUI.spacing).padding(.vertical, 8)
                }

            }
        }
        .frame(width: embedded ? nil : 520)
        .background(embedded ? Color.clear : Color(nsColor: .windowBackgroundColor))
        .onChange(of: section) { section in
            if section == "Processes" { service.stop() } else { service.start() }
        }
    }

    private var filterMenu: some View {
        Menu {
            ForEach(filters, id: \.self) { item in
                Button { filter = item } label: {
                    if filter == item { Label(item, systemImage: "checkmark") } else { Text(item) }
                }
            }
        } label: {
            Image(systemName: "line.3.horizontal.decrease.circle").font(FleetUI.menuIcon).frame(width: FleetUI.menuControlSize, height: FleetUI.menuControlSize)
                .foregroundStyle(filter == "All" ? Color.secondary : Color.accentColor)
        }.menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            .accessibilityLabel("Filter agents: \(filter)").help("Agent filter: \(filter)")
    }

    private var emptyTitle: String { service.sessions.isEmpty ? "No linked agents yet" : "No sessions in this filter" }
}

struct AgentSessionStatus: Equatable {
    enum Tone: Equatable { case working, success, attention, blocked, quiet }
    let title: String
    let symbol: String
    let tone: Tone

    init(state: String, stale: Bool, linked: Bool, jumping: Bool = false) {
        if !linked { self = Self(title: "Unlinked", symbol: "link", tone: .quiet) }
        else if stale { self = Self(title: "Stale", symbol: "clock", tone: .quiet) }
        else if jumping { self = Self(title: "Opening…", symbol: "arrow.up.forward", tone: .working) }
        else {
            switch state {
            case "Working": self = Self(title: state, symbol: "bolt.fill", tone: .working)
            case "New reply": self = Self(title: state, symbol: "checkmark.message", tone: .success)
            case "Approval": self = Self(title: state, symbol: "hand.raised", tone: .attention)
            case "Question": self = Self(title: state, symbol: "questionmark.bubble", tone: .attention)
            case "Blocked": self = Self(title: state, symbol: "exclamationmark.octagon", tone: .blocked)
            default: self = Self(title: state, symbol: state == "Unknown" ? "questionmark.circle" : "pause", tone: .quiet)
            }
        }
    }

    private init(title: String, symbol: String, tone: Tone) {
        self.title = title; self.symbol = symbol; self.tone = tone
    }
    var color: Color {
        switch tone {
        case .working: return .blue
        case .success: return .green
        case .attention: return .orange
        case .blocked: return .red
        case .quiet: return .secondary
        }
    }
}

struct AgentSessionRow: View {
    let session: AgentSession
    let selected: Bool
    let jumping: Bool
    let stale: Bool
    let canJump: Bool
    let jump: () -> Void
    @State private var hovering = false
    private var status: AgentSessionStatus {
        AgentSessionStatus(state: session.state, stale: stale, linked: session.location != nil, jumping: jumping)
    }
    private var providerTint: Color {
        switch session.provider.lowercased() {
        case "claude": return .orange
        case "kimi": return .teal
        case "qwen": return .purple
        case "gemini": return .indigo
        default: return .blue
        }
    }

    private var helpText: String {
        let lastActivity = session.updatedAt.map {
            "Last activity · " + Date(timeIntervalSince1970: $0).formatted(date: .abbreviated, time: .standard)
        } ?? ""
        return [session.explanation, session.locationLabel, lastActivity, String((session.request ?? "").prefix(600))]
            .filter { !$0.isEmpty }.joined(separator: "\n")
    }

    var body: some View {
        Button(action: jump) {
            VStack(alignment: .leading, spacing: 4) {
                Text(agentSessionDisplayTitle(session.title, provider: session.provider))
                    .font(FleetUI.menuBody).foregroundStyle(.primary)
                    .lineLimit(1).truncationMode(.tail).frame(maxWidth: .infinity, alignment: .leading)
                HStack(spacing: 5) {
                    Text(session.provider.capitalized).foregroundStyle(providerTint).fixedSize().layoutPriority(1)
                    if let model = session.model { Text("· \(model)").lineLimit(1).truncationMode(.middle) }
                    Spacer(minLength: 4)
                    Label(status.title, systemImage: status.symbol)
                        .foregroundStyle(status.color).lineLimit(1).fixedSize()
                }.font(FleetUI.menuSecondary).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 9).padding(.vertical, 7)
            .background(status.color.opacity(hovering ? 0.12 : (selected ? 0.08 : 0.035)), in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(status.color.opacity(hovering || selected ? 0.4 : 0.1), lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain).disabled(session.location == nil || !canJump)
        .onHover { hovering = $0 }
        .help(helpText)
        .accessibilityLabel("\(session.title), \(status.title), \(session.locationLabel)")
        .accessibilityHint("Open the existing iTerm2 pane; keep Agents visible")
    }
}

/// Remove explicit UI annotations without deleting provider names from task text.
func agentSessionDisplayTitle(_ title: String, provider: String) -> String {
    var result = title
    for label in [provider, provider + " Code"] {
        let suffix = " (" + label + ")"
        if result.lowercased().hasSuffix(suffix.lowercased()) { result = String(result.dropLast(suffix.count)) }
        for separator in [" · ", " | ", ": "] {
            let prefix = label + separator
            if result.lowercased().hasPrefix(prefix.lowercased()) { result = String(result.dropFirst(prefix.count)) }
        }
    }
    return result.isEmpty ? title : result
}
