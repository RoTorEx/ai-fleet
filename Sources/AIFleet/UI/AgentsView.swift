import AppKit
import SwiftUI

struct AgentsView: View {
    @ObservedObject var service: AgentSessionsService
    let back: () -> Void
    @State private var filter = "All"
    @State private var collapsed = Set<String>()
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
                if service.isLoading { ProgressView().controlSize(.small) }
                Button { service.refresh(force: true) } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.plain).help("Refresh sessions (⌘R)").keyboardShortcut("r")
                Button(action: back) {
                    HStack(spacing: 5) { Image(systemName: "chevron.left"); Text("Usage"); Text("⌘A").foregroundStyle(.secondary) }
                }.buttonStyle(.plain).help("Return to the main menu (⌘A)")
            }.padding(.horizontal, 16).padding(.top, 15).padding(.bottom, 10)

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
        .frame(width: 520)
        .background(Color(nsColor: .windowBackgroundColor).opacity(0.97))
        .clipShape(RoundedRectangle(cornerRadius: 15))
    }

    private var emptyTitle: String { service.sessions.isEmpty ? "No linked agents yet" : "No sessions in this filter" }
}

private struct AgentSessionRow: View {
    let session: AgentSession
    let selected: Bool
    let jumping: Bool
    let stale: Bool
    let canJump: Bool
    let jump: () -> Void
    @State private var hovering = false
    private var tint: Color { AgentColors.color(for: session.id) }
    private var statusColor: Color {
        if stale || session.location == nil { return .secondary }
        if session.needsYou { return session.state == "Blocked" ? .red : .orange }
        if session.state == "New reply" { return .cyan }
        return session.isWorking ? tint : .secondary
    }
    private var symbol: String {
        switch session.state {
        case "Working": return "waveform.path"
        case "Approval": return "hand.raised"
        case "Question": return "questionmark"
        case "Blocked": return "exclamationmark"
        case "New reply": return "sparkle"
        case "Opened": return "checkmark"
        default: return "ellipsis"
        }
    }

    var body: some View {
        Button(action: jump) {
            HStack(spacing: 10) {
                ZStack {
                    Circle().fill(tint.opacity(0.12)).frame(width: 25, height: 25)
                    if session.isWorking && !stale {
                        AgentOrbit(color: tint).frame(width: 25, height: 25)
                    } else {
                        Circle().stroke(tint.opacity(0.35), lineWidth: 1).frame(width: 25, height: 25)
                    }
                    Image(systemName: symbol).font(.system(size: 11, weight: .semibold)).foregroundStyle(statusColor)
                }
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 5) {
                        Text(session.title).font(.system(size: 12, weight: .medium)).foregroundStyle(.primary)
                            .lineLimit(1).truncationMode(.tail)
                        Spacer(minLength: 3)
                        if jumping { ProgressView().controlSize(.mini) }
                        else if let updated = session.updatedAt {
                            Text(Date(timeIntervalSince1970: updated), style: .relative)
                                .font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                    HStack(spacing: 5) {
                        Text(session.provider.capitalized).foregroundStyle(tint)
                        if let model = session.model { Text("· \(model)").lineLimit(1) }
                        Spacer(minLength: 4)
                        Text(session.location == nil ? "Unlinked" : (stale ? "Stale" : session.state))
                            .foregroundStyle(statusColor).lineLimit(1)
                    }.font(.system(size: 10)).foregroundStyle(.secondary)
                    AgentActivityLine(color: tint, active: session.isWorking && !stale)
                        .frame(height: 2)
                }
            }
            .padding(.horizontal, 9).padding(.vertical, 6)
            .background(tint.opacity(hovering ? 0.14 : (selected ? 0.09 : 0.035)), in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(tint.opacity(hovering || selected ? 0.45 : 0.08), lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain).disabled(session.location == nil || !canJump)
        .onHover { hovering = $0 }
        .help("\(session.explanation)\n\(session.locationLabel)\n\(String((session.request ?? "").prefix(600)))")
        .accessibilityLabel("\(session.title), \(session.state), \(session.locationLabel)")
        .accessibilityHint("Open the existing iTerm2 pane; keep Agents visible")
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
