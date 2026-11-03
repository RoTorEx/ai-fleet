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
    private let filters = ["All", "Needs you", "Working", "Idle", "Ready", "Question", "Error", "Unknown"]

    private var visible: [AgentSession] {
        service.sessions.filter { session in
            switch filter {
            case "Needs you": return session.needsYou
            case "Working": return session.isWorking
            case "Idle": return ["Untracked", "Opened", "Idle"].contains(session.state)
            case "Ready": return ["New reply", "Ready"].contains(session.state)
            case "Question": return ["Question", "Approval"].contains(session.state)
            case "Error": return ["Blocked", "Error"].contains(session.state)
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
                        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().quietMenuFocus()
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
                                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                                .padding(12).frame(maxWidth: .infinity, alignment: .leading)
                        } else if !service.sessions.isEmpty, service.sessions.allSatisfy({ $0.location == nil }) {
                            Text(service.sessions.first?.linkReason ?? "No confirmed iTerm2 links. Check Automation permission in System Settings.")
                                .font(.caption).foregroundStyle(.secondary).lineLimit(3)
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
                                        workClock: service.workClock(for: session),
                                        canJump: service.jumpingID == nil) {
                                        service.jump(to: session)
                                    }
                                }
                            }
                        }
                        if let error = service.jumpError {
                            Text(error).font(FleetUI.caption).foregroundStyle(.secondary)
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
            FleetMenuIcon(systemName: "line.3.horizontal.decrease.circle")
                .foregroundStyle(filter == "All" ? Color.secondary : Color.accentColor)
        }.menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().quietMenuFocus()
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
            case "New reply": self = Self(title: "Ready", symbol: "checkmark.message", tone: .success)
            case "Approval": self = Self(title: state, symbol: "hand.raised", tone: .attention)
            case "Question": self = Self(title: state, symbol: "questionmark.bubble", tone: .attention)
            case "Blocked", "Error": self = Self(title: "Error", symbol: "exclamationmark.octagon", tone: .blocked)
            case "Untracked", "Opened": self = Self(title: "Idle", symbol: "pause", tone: .quiet)
            default: self = Self(title: state, symbol: state == "Unknown" ? "questionmark.circle" : "pause", tone: .quiet)
            }
        }
    }

    private init(title: String, symbol: String, tone: Tone) {
        self.title = title; self.symbol = symbol; self.tone = tone
    }
    var color: Color { .secondary }
}

struct AgentSessionRow: View {
    let session: AgentSession
    let selected: Bool
    let jumping: Bool
    let stale: Bool
    var workClock: AgentWorkClock? = nil
    let canJump: Bool
    let jump: () -> Void
    @State private var hovering = false
    private var status: AgentSessionStatus {
        AgentSessionStatus(state: session.state, stale: stale, linked: session.location != nil, jumping: jumping)
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
                Text(agentSessionDisplayTitle(session.title, provider: session.provider, project: session.project))
                    .font(FleetUI.menuBody).foregroundStyle(.primary)
                    .lineLimit(1).truncationMode(.tail).frame(maxWidth: .infinity, alignment: .leading)
                HStack(spacing: 5) {
                    Text(session.provider.capitalized).foregroundStyle(.secondary).fixedSize().layoutPriority(1)
                    if let model = session.model { Text("· \(model)").lineLimit(1).truncationMode(.middle) }
                    Spacer(minLength: 4)
                    if session.isWorking, !stale, session.location != nil {
                        TimelineView(.periodic(from: .now, by: 1)) { context in
                            Text("Working (\(workClock?.elapsed(at: context.date) ?? "—"))")
                                .monospacedDigit().lineLimit(1).fixedSize()
                        }
                    } else {
                        Text(status.title).lineLimit(1).fixedSize()
                    }
                }.font(FleetUI.menuSecondary).foregroundStyle(.secondary)
                HStack(spacing: 4) {
                    Text("Last message:")
                    if let time = session.lastMessageAt {
                        Text(Date(timeIntervalSince1970: time).formatted(date: .omitted, time: .standard)).monospacedDigit()
                    } else { Text("—") }
                    Spacer(minLength: 0)
                }.font(.system(size: 9)).foregroundStyle(.tertiary)
                AgentWorkingStrip(active: session.isWorking && !stale && session.location != nil)
                    .frame(height: 2).accessibilityHidden(true)
            }
            .padding(.horizontal, 9).padding(.vertical, 7)
            .background(status.color.opacity(hovering ? 0.12 : (selected ? 0.08 : 0.035)), in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(status.color.opacity(hovering || selected ? 0.4 : 0.1), lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain).quietMenuFocus().disabled(session.location == nil || !canJump)
        .onHover { hovering = $0 }
        .help(helpText)
        .accessibilityLabel("\(session.title), \(status.title), \(session.locationLabel)")
        .accessibilityHint("Open the existing iTerm2 pane; keep Agents visible")
    }
}

/// Remove explicit UI annotations without deleting provider names from task text.
func agentSessionDisplayTitle(_ title: String, provider: String, project: String? = nil) -> String {
    var result = title
    for label in [provider, provider + " Code"] {
        let suffix = " (" + label + ")"
        if result.lowercased().hasSuffix(suffix.lowercased()) { result = String(result.dropLast(suffix.count)) }
        for separator in [" · ", " | ", ": "] {
            let prefix = label + separator
            if result.lowercased().hasPrefix(prefix.lowercased()) { result = String(result.dropFirst(prefix.count)) }
        }
    }
    // Terminal activity prefixes are decoration, not part of the task name.
    if let scalar = result.unicodeScalars.first,
       ((0x2800...0x28FF).contains(scalar.value) || scalar.value == 0x22EE),
       result.dropFirst().first?.isWhitespace == true {
        result = String(result.dropFirst()).trimmingCharacters(in: .whitespaces)
    }
    if let project, let separator = result.range(of: " | ", options: .backwards) {
        let location = URL(fileURLWithPath: project).standardizedFileURL
        let suffix = String(result[separator.upperBound...]).trimmingCharacters(in: .whitespaces)
        let labels = [location.path, location.lastPathComponent, compactAgentLocation(location.path)]
        if labels.contains(where: { $0.caseInsensitiveCompare(suffix) == .orderedSame }) {
            result = String(result[..<separator.lowerBound]).trimmingCharacters(in: .whitespaces)
        }
    }
    return result.isEmpty ? title : result
}

private struct AgentWorkingStrip: NSViewRepresentable {
    let active: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func makeNSView(context: Context) -> WorkingStripView { WorkingStripView() }
    func updateNSView(_ view: WorkingStripView, context: Context) {
        view.configure(active: active, animated: !reduceMotion)
    }
}

private final class WorkingStripView: NSView {
    private let beam = CALayer()
    private var active = false
    private var animated = false
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        isHidden = true
        layer?.masksToBounds = true
        layer?.cornerRadius = 1
        layer?.addSublayer(beam)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func configure(active: Bool, animated: Bool) {
        isHidden = !active
        guard self.active != active || self.animated != animated else { return }
        self.active = active; self.animated = animated
        isHidden = !active
        needsLayout = true
    }
    override func layout() {
        super.layout()
        layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.08).cgColor
        beam.backgroundColor = NSColor.labelColor.withAlphaComponent(0.4).cgColor
        beam.removeAllAnimations()
        beam.frame = CGRect(x: bounds.width * 0.35, y: 0, width: bounds.width * 0.3, height: bounds.height)
        if active && animated && bounds.width > 0 {
            let animation = CABasicAnimation(keyPath: "position.x")
            animation.fromValue = -bounds.width * 0.15
            animation.toValue = bounds.width * 1.15
            animation.duration = 1.8
            animation.repeatCount = .infinity
            beam.add(animation, forKey: "working")
        }
    }
}
