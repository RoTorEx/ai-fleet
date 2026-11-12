import AppKit
import SwiftUI

/// Live agent sessions on the Agents tab, grouped by location. The tab's
/// viewport bounds the height and scrolls.
struct MenuAgentsSection: View {
    @ObservedObject var service: AgentSessionsService
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let error = service.error ?? service.jumpError {
                Text(error).font(.system(size: 10.5)).foregroundStyle(FleetPalette.warning)
                    .fixedSize(horizontal: false, vertical: true).padding(.horizontal, 4)
            }
            if service.sessions.isEmpty {
                Text(service.isLoading ? "Finding live sessions…" : "No live Codex or Claude sessions in iTerm2.")
                    .font(.system(size: 11)).foregroundStyle(.secondary).padding(.horizontal, 4)
            } else {
                filters
                if visible.isEmpty {
                    Text("No sessions in this filter.").font(.system(size: 11)).foregroundStyle(.secondary)
                        .padding(.horizontal, 4).padding(.vertical, 8)
                }
            }
            ForEach(AgentGroup.make(visible)) { group in
                groupHeader(group)
                if !service.collapsedGroups.contains(group.id) {
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
        }
        .padding(.horizontal, 8)
    }

    private var visible: [AgentSession] { service.sessions.filter(service.filter.matches) }

    private var filters: some View {
        HStack(spacing: 4) {
            ForEach(AgentFilter.allCases, id: \.self) { item in
                let count = service.sessions.filter(item.matches).count
                let active = service.filter == item
                Button { service.filter = item } label: {
                    Text("\(item.rawValue) \(count)").font(.system(size: 10.5, weight: .medium).monospacedDigit())
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .foregroundStyle(active ? Color.primary
                            : (item == .needsYou && count > 0 ? FleetPalette.warning : Color.secondary))
                        .background(active ? Color.primary.opacity(0.1) : .clear, in: Capsule())
                }.buttonStyle(.plain)
            }
            Spacer(minLength: 0)
        }
        .padding(.bottom, 2)
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
}

private struct AgentSessionRow: View {
    let session: AgentSession
    let selected: Bool
    let jumping: Bool
    let stale: Bool
    let observedAt: Date?
    let canJump: Bool
    let jump: () -> Void
    @State private var hovering = false
    private var tint: Color { AgentColors.color(for: session.id) }
    private var contract: AgentSessionContract {
        AgentSessionContract(session: session, observedAt: observedAt, stale: stale)
    }
    private var live: Bool { session.isWorking && !stale }
    private var statusColor: Color {
        if stale || session.location == nil { return .secondary }
        if session.needsYou { return session.state == "Blocked" ? FleetPalette.danger : FleetPalette.warning }
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
         jump: @escaping () -> Void) {
        self.session = session; self.selected = selected; self.jumping = jumping; self.stale = stale
        self.observedAt = observedAt; self.canJump = canJump; self.jump = jump
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button(action: jump) { summary.contentShape(Rectangle()) }
                .buttonStyle(.plain).disabled(session.location == nil || !canJump)
                .accessibilityLabel("\(session.title), \(session.state), \(session.locationLabel)")
                .accessibilityHint("Open the existing iTerm2 pane; keep Agents visible")
            AgentActivityLine(color: tint, active: live)
                .frame(height: 2)
                .padding(.leading, 35).padding(.top, 3)
        }
        .padding(.horizontal, 9).padding(.vertical, 6)
        .fleetCard(hovering: hovering, accent: selected ? tint : nil)
        .onHover { hovering = $0 }
        // Hovering shows the last request and reply without clicking.
        .hoverPopover(enabled: session.request != nil || session.answer != nil) {
            AgentMessages(session: session, contract: contract, tint: tint)
                .frame(width: 300).padding(12)
        }
    }

    private var summary: some View {
        HStack(spacing: 10) {
            ZStack {
                Circle().fill(tint.opacity(0.12))
                if live {
                    AgentOrbit(color: tint)
                } else {
                    Circle().stroke(tint.opacity(0.35), lineWidth: 1)
                }
                Image(systemName: symbol).font(.system(size: 11, weight: .semibold)).foregroundStyle(statusColor)
            }
            .frame(width: 25, height: 25)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 5) {
                    Text(AgentRowText.title(session.title, provider: session.provider))
                        .font(.system(size: 12, weight: .medium)).foregroundStyle(.primary)
                        .lineLimit(1).truncationMode(.tail)
                    Spacer(minLength: 3)
                    if jumping { ProgressView().controlSize(.mini) }
                    else { AgentTimeLabel(contract: contract, fallback: session.updatedAt) }
                }
                HStack(spacing: 5) {
                    Text(session.provider.capitalized).foregroundStyle(tint)
                    if let model = session.model { Text("· \(model)").lineLimit(1) }
                    Spacer(minLength: 4)
                    Text(session.location == nil ? "Unlinked" : (stale ? "Stale" : session.state))
                        .foregroundStyle(statusColor).lineLimit(1)
                }.font(.system(size: 10)).foregroundStyle(.secondary)
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
        .font(.system(size: 10).monospacedDigit()).foregroundStyle(.secondary).lineLimit(1)
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
