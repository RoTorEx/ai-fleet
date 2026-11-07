import AppKit
import SwiftUI

struct AgentsView: View {
    @ObservedObject var service: AgentSessionsService
    let back: () -> Void
    @State private var filter = "All"
    @State private var collapsed = Set<String>()
    @State private var section: String

    init(service: AgentSessionsService, section: String = "Sessions", back: @escaping () -> Void) {
        self.service = service
        self.back = back
        _section = State(initialValue: section)
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
            HStack(spacing: 9) {
                Image(systemName: "waveform.path.ecg").foregroundStyle(.green)
                Text("Agents").font(.system(size: 15, weight: .semibold))
                Text("\(service.sessions.count)").font(.system(size: 11, weight: .bold, design: .rounded))
                    .padding(.horizontal, 7).padding(.vertical, 3).background(.quaternary, in: Capsule())
                Spacer()
                if section == "Sessions" {
                    if service.isLoading { ProgressView().controlSize(.small) }
                    Button { service.refresh(force: true) } label: { Image(systemName: "arrow.clockwise") }
                        .buttonStyle(.plain).help("Refresh sessions (⌘R)").keyboardShortcut("r")
                }
                Button(action: back) {
                    HStack(spacing: 5) { Image(systemName: "chevron.left"); Text("Back") }
                }.buttonStyle(.plain).help("Return to the main menu")
            }.padding(.horizontal, 16).padding(.top, 15).padding(.bottom, 10)

            Picker("View", selection: $section) {
                Text("Sessions").tag("Sessions")
                Text("Processes").tag("Processes")
            }.pickerStyle(.segmented).padding(.horizontal, 14).padding(.bottom, 10)

            if section == "Processes" {
                MenuRowsViewport(maxHeight: min(550, max(210, (NSScreen.main?.visibleFrame.height ?? 800) - 220))) {
                    CodexProcessesView()
                }
            } else {
                HStack(spacing: 4) {
                    ForEach(filters, id: \.self) { item in
                        Button { filter = item } label: {
                            Text(item).font(.system(size: 10.5, weight: .medium))
                                .padding(.horizontal, 8).padding(.vertical, 5)
                                .foregroundStyle(filter == item ? Color.primary : Color.secondary)
                                .background(filter == item ? Color.primary.opacity(0.09) : Color.clear, in: Capsule())
                        }.buttonStyle(.plain)
                    }
                    Spacer(minLength: 0)
                }.padding(.horizontal, 12).padding(.bottom, 9)
                Divider()

                if let error = service.error {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                        .padding(12).frame(maxWidth: .infinity, alignment: .leading)
                } else if !service.sessions.isEmpty, service.sessions.allSatisfy({ $0.location == nil }) {
                    Text(service.sessions.first?.linkReason ?? "No confirmed iTerm2 links. Check Automation permission in System Settings.")
                        .font(.caption).foregroundStyle(.orange).lineLimit(3)
                        .padding(12).frame(maxWidth: .infinity, alignment: .leading)
                }

                MenuRowsViewport(maxHeight: min(550, max(210, (NSScreen.main?.visibleFrame.height ?? 800) - 220))) {
                    VStack(alignment: .leading, spacing: 3) {
                        if visible.isEmpty {
                            VStack(spacing: 10) {
                                Image(systemName: service.isLoading ? "antenna.radiowaves.left.and.right" : "terminal")
                                    .font(.system(size: 28)).foregroundStyle(.secondary)
                                Text(service.isLoading ? "Finding live sessions…" : emptyTitle).font(.headline)
                                Text(service.sessions.isEmpty ? "Open Codex or Claude in iTerm2.\nYour usual launch commands stay the same." : "Choose another filter to see more sessions.")
                                    .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
                            }.frame(maxWidth: .infinity).padding(.vertical, 55)
                        }
                        ForEach(AgentGroup.make(visible)) { group in
                            Button {
                                withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.18)) {
                                    if !collapsed.insert(group.id).inserted { collapsed.remove(group.id) }
                                }
                            } label: {
                                HStack(spacing: 6) {
                                    Image(systemName: collapsed.contains(group.id) ? "chevron.right" : "chevron.down").font(.system(size: 8, weight: .bold))
                                    Image(systemName: "folder")
                                    Text(group.name).lineLimit(1).truncationMode(.middle)
                                    Text("\(group.sessions.count)").foregroundStyle(.tertiary)
                                    Spacer()
                                }.font(.system(size: 10.5, weight: .medium)).foregroundStyle(.secondary)
                                    .padding(.horizontal, 9).padding(.top, 11).padding(.bottom, 4)
                                    .contentShape(Rectangle())
                            }.buttonStyle(.plain).help(group.id)
                            if !collapsed.contains(group.id) {
                                ForEach(group.sessions) { session in
                                    AgentSessionRow(session: session,
                                        selected: service.selectedID == session.id,
                                        jumping: service.jumpingID == session.id,
                                        stale: service.isStale,
                                        observedAt: service.observedAt,
                                        canJump: service.jumpingID == nil) {
                                        service.jump(to: session)
                                    }
                                }
                            }
                        }
                    }.padding(.horizontal, 9).padding(.bottom, 12)
                }

                Divider()
                if let error = service.jumpError {
                    Text(error).font(.caption).foregroundStyle(.orange)
                        .padding(.horizontal, 14).padding(.top, 8).frame(maxWidth: .infinity, alignment: .leading)
                }
                HStack(spacing: 7) {
                    Circle().fill(service.isStale ? Color.orange : Color.green).frame(width: 5, height: 5)
                    Text(service.isStale ? "Stale · refresh to verify" : (service.isLoading ? "Connecting to iTerm2…" : "Live · local iTerm2 sessions"))
                    Spacer()
                    Text("Click to jump · Esc to close")
                }.font(.system(size: 10)).foregroundStyle(.secondary).padding(.horizontal, 14).padding(.vertical, 11)
            }
        }
        .frame(width: 520)
        .onAppear { if section == "Processes" { service.stop() } }
        .onChange(of: section) { section in
            if section == "Processes" { service.stop() } else { service.start() }
        }
    }

    private var emptyTitle: String { service.sessions.isEmpty ? "No linked agents yet" : "No sessions in this filter" }
}

/// Live agent sessions in the right column of the main menu, grouped by location.
/// The caller bounds its height; this is the only scrolling block of the menu.
struct MenuAgentsSection: View {
    @ObservedObject var service: AgentSessionsService
    let maxListHeight: CGFloat
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                MenuSectionTitle(title: "Agents", count: "\(service.sessions.count)")
                if service.isLoading { ProgressView().controlSize(.mini) }
                Spacer()
            }
            .padding(.horizontal, 16)

            if let error = service.error ?? service.jumpError {
                Text(error).font(.system(size: 10.5)).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true).padding(.horizontal, 16)
            }

            if service.sessions.isEmpty {
                Text(service.isLoading ? "Finding live sessions…" : "No live Codex or Claude sessions in iTerm2.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    .padding(.horizontal, 16).padding(.bottom, 10)
            } else {
                MenuRowsViewport(maxHeight: maxListHeight) {
                    VStack(alignment: .leading, spacing: 5) {
                        ForEach(AgentGroup.make(service.sessions)) { group in
                            groupHeader(group)
                            if !service.collapsedGroups.contains(group.id) {
                                ForEach(group.sessions) { session in
                                    AgentSessionRow(session: session,
                                        selected: service.selectedID == session.id,
                                        jumping: service.jumpingID == session.id,
                                        stale: service.isStale,
                                        observedAt: service.observedAt,
                                        canJump: service.jumpingID == nil,
                                        expanded: expansion(for: session.id)) {
                                        service.jump(to: session)
                                    }
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.bottom, 10)
                }
            }
        }
    }

    private func groupHeader(_ group: AgentGroup) -> some View {
        Button {
            withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.18)) {
                if !service.collapsedGroups.insert(group.id).inserted { service.collapsedGroups.remove(group.id) }
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 8, weight: .bold))
                    .rotationEffect(.degrees(service.collapsedGroups.contains(group.id) ? 0 : 90))
                Text(group.name).font(.system(size: 11, weight: .semibold)).foregroundStyle(.primary.opacity(0.75))
                    .lineLimit(1).truncationMode(.middle)
                Text("\(group.sessions.count)").font(.system(size: 10, weight: .semibold).monospacedDigit())
                    .padding(.horizontal, 5).padding(.vertical, 1)
                    .background(Color.primary.opacity(0.07), in: Capsule())
                Spacer()
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 4).padding(.top, 5).padding(.bottom, 1)
            .contentShape(Rectangle())
        }.buttonStyle(.plain).help(group.id)
    }

    private func expansion(for id: String) -> Binding<Bool> {
        Binding(get: { service.expandedSessions.contains(id) }, set: { open in
            if open { service.expandedSessions.insert(id) } else { service.expandedSessions.remove(id) }
        })
    }
}

private struct AgentSessionRow: View {
    let session: AgentSession
    let selected: Bool
    let jumping: Bool
    let stale: Bool
    let observedAt: Date?
    let canJump: Bool
    var expanded: Binding<Bool>? = nil
    let jump: () -> Void
    @State private var hovering = false
    private var tint: Color { AgentColors.color(for: session.id) }
    private var contract: AgentSessionContract {
        AgentSessionContract(session: session, observedAt: observedAt, stale: stale)
    }
    private var live: Bool { session.isWorking && !stale }
    private var statusColor: Color {
        if stale || session.location == nil { return .secondary }
        if session.needsYou { return session.state == "Blocked" ? .red : .orange }
        if session.state == "New reply" { return .cyan }
        return session.isWorking ? tint : .secondary
    }
    private var symbol: String {
        switch session.state {
        case "Working": return "waveform"
        case "Approval": return "hand.raised.fill"
        case "Question": return "questionmark"
        case "Blocked": return "exclamationmark"
        case "New reply": return "sparkle"
        case "Opened": return "checkmark"
        case "Untracked", "Idle": return "pause.fill"
        default: return "circle.dotted"
        }
    }

    init(session: AgentSession, selected: Bool, jumping: Bool, stale: Bool, observedAt: Date?, canJump: Bool,
         expanded: Binding<Bool>? = nil, jump: @escaping () -> Void) {
        self.session = session; self.selected = selected; self.jumping = jumping; self.stale = stale
        self.observedAt = observedAt; self.canJump = canJump; self.expanded = expanded; self.jump = jump
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 4) {
                Button(action: jump) { summary.contentShape(Rectangle()) }
                    .buttonStyle(.plain).disabled(session.location == nil || !canJump)
                    .help("\(session.explanation)\n\(session.locationLabel)")
                    .accessibilityLabel("\(session.title), \(session.state), \(session.locationLabel)")
                    .accessibilityHint("Open the existing iTerm2 pane; keep Agents visible")
                if let expanded {
                    Button { expanded.wrappedValue.toggle() } label: {
                        Image(systemName: "chevron.down")
                            .font(.system(size: 9, weight: .bold))
                            .rotationEffect(.degrees(expanded.wrappedValue ? 180 : 0))
                            .foregroundStyle(hovering || expanded.wrappedValue ? tint : Color.secondary.opacity(0.6))
                            .frame(width: 18, height: 30)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(expanded.wrappedValue ? "Hide last messages" : "Show last request and reply")
                    .accessibilityLabel("Last messages")
                }
            }
            if expanded?.wrappedValue == true {
                AgentMessages(session: session, contract: contract, tint: tint)
                    .padding(.leading, 40).padding(.top, 7).padding(.trailing, 6)
            }
            AgentActivityLine(color: tint, active: live)
                .frame(height: 2)
                .padding(.leading, 40).padding(.top, 5)
                .opacity(live ? 1 : 0)
        }
        .padding(.leading, 9).padding(.trailing, 4).padding(.top, 7).padding(.bottom, 5)
        .background(
            LinearGradient(colors: [tint.opacity(hovering ? 0.22 : (selected ? 0.17 : 0.13)),
                                    tint.opacity(hovering ? 0.08 : 0.035)],
                           startPoint: .leading, endPoint: .trailing),
            in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous)
            .strokeBorder(tint.opacity(hovering || selected ? 0.5 : 0.16), lineWidth: 1))
        .onHover { hovering = $0 }
    }

    private var summary: some View {
        HStack(spacing: 10) {
            ZStack {
                Circle().fill(LinearGradient(colors: [tint.opacity(0.42), tint.opacity(0.16)],
                                             startPoint: .topLeading, endPoint: .bottomTrailing))
                if live {
                    AgentOrbit(color: tint)
                } else {
                    Circle().strokeBorder(tint.opacity(0.45), lineWidth: 1)
                }
                Image(systemName: symbol).font(.system(size: 10.5, weight: .bold))
                    .foregroundStyle(session.needsYou ? statusColor : tint)
            }
            .frame(width: 28, height: 28)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 5) {
                    Text(AgentRowText.title(session.title, provider: session.provider))
                        .font(.system(size: 12, weight: .semibold)).foregroundStyle(.primary)
                        .lineLimit(1).truncationMode(.tail)
                    Spacer(minLength: 3)
                    if jumping { ProgressView().controlSize(.mini) }
                    else { AgentTimeLabel(contract: contract, fallback: session.updatedAt) }
                }
                HStack(spacing: 5) {
                    Text(session.provider.capitalized).fontWeight(.medium).foregroundStyle(tint)
                    if let model = session.model { Text("· \(model)").lineLimit(1) }
                    Spacer(minLength: 4)
                    Text(session.location == nil ? "Unlinked" : (stale ? "Stale" : session.state))
                        .fontWeight(live || session.needsYou ? .semibold : .regular)
                        .foregroundStyle(statusColor).lineLimit(1)
                }.font(.system(size: 10.5)).foregroundStyle(.secondary)
            }
        }
    }
}

/// The latest request and reply bound to this process, for orienting across sessions.
private struct AgentMessages: View {
    let session: AgentSession
    let contract: AgentSessionContract
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            if session.request == nil && session.answer == nil {
                Text("No messages captured for this session yet.")
                    .font(.system(size: 10.5)).foregroundStyle(.secondary)
            }
            if let request = session.request {
                message("You", time: contract.requestStartedAt, text: request, lines: 3)
            }
            if let answer = session.answer {
                message(session.provider.capitalized, time: contract.lastMessageAt, text: answer, lines: 5)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func message(_ who: String, time: Date?, text: String, lines: Int) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 5) {
                Text(who.uppercased()).font(.system(size: 9, weight: .bold)).kerning(0.4)
                    .foregroundStyle(who == "You" ? Color.secondary : tint)
                if let time {
                    Text(formatResetTime(time)).font(.system(size: 9.5).monospacedDigit()).foregroundStyle(.tertiary)
                }
            }
            Text(text.trimmingCharacters(in: .whitespacesAndNewlines))
                .font(.system(size: 11)).foregroundStyle(.primary.opacity(0.85))
                .lineLimit(lines).truncationMode(.tail)
                .fixedSize(horizontal: false, vertical: true)
                .help(String(text.prefix(1200)))
        }
    }
}

/// Working sessions tick an exact stopwatch; anything else shows a rough age so idle
/// rows stay quiet and cheap to redraw.
private struct AgentTimeLabel: View {
    let contract: AgentSessionContract
    let fallback: Double?

    var body: some View {
        // Both forms share one Text style so working and idle rows match.
        Group {
            if let start = contract.workStartedAt {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    Text(AgentRowText.stopwatch(context.date.timeIntervalSince(start)))
                }
            } else if let since = contract.lastMessageAt ?? fallback.map(Date.init(timeIntervalSince1970:)) {
                TimelineView(.periodic(from: .now, by: 10)) { context in
                    Text(AgentRowText.roughAge(context.date.timeIntervalSince(since)))
                }
            }
        }
        .font(.system(size: 10.5).monospacedDigit()).foregroundStyle(.secondary).lineLimit(1)
    }
}

enum AgentRowText {
    /// Terminal titles carry spinner glyphs and the iTerm job suffix, e.g. "⠂ Thira (codex)".
    /// The provider already has its own line, so show only the session's own name.
    static func title(_ raw: String, provider: String) -> String {
        var text = raw.trimmingCharacters(in: .whitespaces)
        while let first = text.unicodeScalars.first, isDecoration(first) {
            text = String(text.unicodeScalars.dropFirst()).trimmingCharacters(in: .whitespaces)
        }
        let jobs: Set<String> = [provider.lowercased(), "codex", "claude", "node"]
        if text.hasSuffix(")"), let open = text.lastIndex(of: "(") {
            let job = text[text.index(after: open)..<text.index(before: text.endIndex)].lowercased()
            let name = text[..<open].trimmingCharacters(in: .whitespaces)
            if jobs.contains(job), !name.isEmpty { text = name }
        }
        return text.isEmpty ? raw : text
    }

    /// Exact running time: 0:52, 4:51, 1:02:03.
    static func stopwatch(_ seconds: TimeInterval) -> String {
        let value = max(0, Int(seconds))
        let (h, m, s) = (value / 3600, value / 60 % 60, value % 60)
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }

    /// One coarse unit with a tilde: ~40s, ~5m, ~16h, ~3d.
    static func roughAge(_ seconds: TimeInterval) -> String {
        let value = max(0, Int(seconds))
        switch value {
        case ..<60: return "~\(value)s"
        case ..<3600: return "~\(value / 60)m"
        case ..<86_400: return "~\(value / 3600)h"
        default: return "~\(value / 86_400)d"
        }
    }

    private static func isDecoration(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x2800...0x28FF, 0x2700...0x27BF, 0x25A0...0x25FF: return true // braille spinners, dingbats ✳✻, shapes
        case 0x00B7, 0x2022, 0x2025, 0x2026, 0x205D, 0x22EE: return true // · • ‥ … ⁝ ⋮
        default: return false
        }
    }
}

private struct AgentOrbit: View {
    let color: Color
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        AgentMotion(color: NSColor(color), orbit: true, animated: !reduceMotion)
            .allowsHitTesting(false).accessibilityHidden(true)
    }
}

private struct AgentActivityLine: View {
    let color: Color
    let active: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        Capsule().fill(color.opacity(active ? 0.16 : 0.08)).overlay {
            if active {
                AgentMotion(color: NSColor(color), orbit: false, animated: !reduceMotion)
            }
        }.allowsHitTesting(false).accessibilityHidden(true)
    }
}

/// Core Animation drives decoration without invalidating SwiftUI rows every frame.
private struct AgentMotion: NSViewRepresentable {
    let color: NSColor
    let orbit: Bool
    let animated: Bool
    func makeNSView(context: Context) -> AgentMotionView { AgentMotionView() }
    func updateNSView(_ view: AgentMotionView, context: Context) {
        view.configure(color: color, orbit: orbit, animated: animated)
    }
}

private final class AgentMotionView: NSView {
    private let ring = CAShapeLayer()
    private let beam = CAGradientLayer()
    private var orbit = false
    private var animated = false
    private var previousSize = CGSize.zero

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = true
        layer?.addSublayer(ring)
        layer?.addSublayer(beam)
        ring.fillColor = nil
        ring.lineWidth = 1.6
        ring.lineCap = .round
        ring.strokeStart = 0.1
        ring.strokeEnd = 0.85
        beam.startPoint = CGPoint(x: 0, y: 0.5)
        beam.endPoint = CGPoint(x: 1, y: 0.5)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(color: NSColor, orbit: Bool, animated: Bool) {
        let changed = self.orbit != orbit || self.animated != animated
        self.orbit = orbit
        self.animated = animated
        ring.strokeColor = color.cgColor
        beam.colors = [color.withAlphaComponent(0).cgColor, color.withAlphaComponent(0.8).cgColor, color.withAlphaComponent(0).cgColor]
        ring.isHidden = !orbit
        beam.isHidden = orbit
        if changed { previousSize = .zero }
        needsLayout = true
    }

    override func layout() {
        super.layout()
        guard bounds.size != previousSize, bounds.width > 0 else { return }
        previousSize = bounds.size
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        ring.frame = bounds
        ring.path = CGPath(ellipseIn: CGRect(origin: .zero, size: bounds.size).insetBy(dx: 1, dy: 1), transform: nil)
        beam.frame = CGRect(x: bounds.width * 0.25, y: 0, width: bounds.width * 0.45, height: bounds.height)
        ring.removeAllAnimations()
        beam.removeAllAnimations()
        if animated {
            let animation = CABasicAnimation(keyPath: orbit ? "transform.rotation.z" : "position.x")
            animation.fromValue = orbit ? 0 : -bounds.width * 0.25
            animation.toValue = orbit ? Double.pi * 2 : bounds.width * 1.25
            animation.duration = orbit ? 2.4 : 2.2
            animation.repeatCount = .infinity
            (orbit ? ring : beam).add(animation, forKey: "activity")
        }
        CATransaction.commit()
    }
}

private enum AgentColors {
    static func color(for id: String) -> Color {
        let colors: [Color] = [.teal, .purple, .green, .pink, .blue, .orange, .indigo, .cyan]
        let hash = id.utf8.reduce(UInt64(5381)) { ($0 &* 33) &+ UInt64($1) }
        return colors[Int(hash % UInt64(colors.count))]
    }
}
