import AppKit
import SwiftUI

struct CodexProcessesView: View {
    @StateObject private var service = CodexProcessesService()
    @State private var pending: [CodexProcess] = []
    @State private var force = false
    @State private var confirms = false
    @State private var filter = "All"
    @State private var newestFirst = true
    @State private var toast: String?
    @State private var toastID = UUID()

    private var visible: [CodexProcess] {
        let rows = service.processes.filter { filter == "All" || $0.providerID == filter.lowercased() }
        let start = { (process: CodexProcess) in TimeInterval(process.started) ?? 0 }
        return rows.sorted { newestFirst ? start($0) > start($1) : start($0) < start($1) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // The tab title names the list; it rescans every 3 seconds while visible.
            HStack(spacing: 4) {
                ForEach(["All", "Codex", "Claude"], id: \.self) { item in
                    let count = item == "All" ? service.processes.count
                        : service.processes.filter { $0.providerID == item.lowercased() }.count
                    Button { filter = item } label: {
                        Text("\(item) \(count)").font(.system(size: 10.5, weight: .medium).monospacedDigit())
                            .padding(.horizontal, 8).padding(.vertical, 3)
                            .foregroundStyle(filter == item ? Color.primary : Color.secondary)
                            .background(filter == item ? Color.primary.opacity(0.1) : .clear, in: Capsule())
                    }.buttonStyle(.plain)
                }
                Spacer(minLength: 4)
                Button { newestFirst.toggle() } label: {
                    Label(newestFirst ? "Newest" : "Oldest", systemImage: "arrow.up.arrow.down")
                        .font(.system(size: 10.5, weight: .medium))
                }.buttonStyle(.plain).foregroundStyle(.secondary).help("Sort by start time")
                bulkMenu
            }
            if let error = service.error {
                Text(error).font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            }
            if let notice = service.notice {
                Text(notice).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if visible.isEmpty {
                Text(service.refreshing && service.processes.isEmpty ? "Reading processes…" : "No provider processes found.")
                    .font(.system(size: 11)).foregroundStyle(.secondary).padding(.vertical, 16)
            }
            ForEach(visible) { process in
                ProcessRow(process: process, stopping: service.stopping.contains(process.id),
                           stop: { force in request([process], force: force) },
                           copied: { what in showToast("Copied \(what)") })
            }
        }
        .overlay(alignment: .top) {
            if let toast {
                Label(toast, systemImage: "checkmark.circle.fill")
                    .font(.system(size: 11, weight: .medium))
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .background(.regularMaterial, in: Capsule())
                    .overlay(Capsule().stroke(Color.primary.opacity(0.12)))
                    .shadow(color: .black.opacity(0.15), radius: 4, y: 2)
                    .transition(.opacity)
                    .allowsHitTesting(false)
            }
        }
        .disabled(!service.stopping.isEmpty)
        .onAppear { service.start() }
        .onDisappear { service.stopMonitoring() }
        .confirmationDialog(force ? "Force quit selected processes?" : "Stop selected processes?",
                            isPresented: $confirms, titleVisibility: .visible) {
            Button(force ? "Force Quit" : "Stop", role: .destructive) { service.terminate(pending, force: force) }
            Button("Cancel", role: .cancel) { pending = [] }
        } message: {
            Text("PIDs: \(pending.map { String($0.pid) }.joined(separator: ", ")). This can interrupt running conversations and their tools, including other accounts in a provider-wide selection. Saved history and credentials are retained. A native client may restart a background server.")
        }
    }

    /// Provider-wide and background actions live in one menu instead of a stack of buttons.
    private var bulkMenu: some View {
        Menu {
            ForEach(["codex", "claude"], id: \.self) { provider in
                let rows = service.processes.filter { $0.providerID == provider }
                Section(provider.capitalized) {
                    Button("Stop all \(provider.capitalized) (\(rows.count))…") { request(rows, force: false) }
                        .disabled(rows.isEmpty)
                    Button("Force quit all \(provider.capitalized) (\(rows.count))…") { request(rows, force: true) }
                        .disabled(rows.isEmpty)
                }
            }
            let background = service.processes.filter(\.isBackground)
            Divider()
            Button("Stop all background processes (\(background.count))…") { request(background, force: false) }
                .disabled(background.isEmpty)
        } label: {
            Image(systemName: "ellipsis.circle").font(.system(size: 12))
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        .foregroundStyle(.secondary).help("Stop several processes")
    }

    private func showToast(_ text: String) {
        let id = UUID()
        toastID = id
        withAnimation(.easeOut(duration: 0.12)) { toast = text }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) {
            guard toastID == id else { return }
            withAnimation(.easeIn(duration: 0.2)) { toast = nil }
        }
    }

    private func request(_ processes: [CodexProcess], force: Bool) {
        pending = processes; self.force = force; confirms = true
    }
}

/// Two thin lines: kind, PID and path icon (each click-to-copy, path shown on
/// hover) with a ⋯ Stop/Force Quit menu, then account and start time.
private struct ProcessRow: View {
    let process: CodexProcess
    let stopping: Bool
    let stop: (_ force: Bool) -> Void
    let copied: (_ what: String) -> Void
    @State private var hovering = false
    @State private var pidHovered = false
    @State private var moreHovered = false
    @State private var pathHovered = false
    @State private var moreFrame = CGRect.zero

    private var account: String? {
        let roots = SwitchCoordinator.sessionRoots(home: FileManager.default.homeDirectoryForCurrentUser)
        guard let binding = SwitchRecovery.owner(of: process, roots: roots),
              let account = AccountStore.shared.accounts.first(where: { $0.id == binding.accountID }) else { return nil }
        return "\(account.badge) · \(account.name)"
    }

    /// `14:03:14` today, `7 Nov 14:03:14` earlier.
    private var started: String {
        guard let seconds = TimeInterval(process.started) else { return process.started }
        let date = Date(timeIntervalSince1970: seconds)
        return (Calendar.current.isDateInToday(date) ? Self.today : Self.earlier).string(from: date)
    }

    private static let today = formatter("HH:mm:ss")
    private static let earlier = formatter("d MMM HH:mm:ss")
    private static func formatter(_ format: String) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.dateFormat = format
        return formatter
    }

    var body: some View {
        let account = account
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Image(systemName: process.isBackground ? "gearshape.2" : "terminal")
                    .font(.system(size: 10)).foregroundStyle(.secondary).frame(width: 14)
                Text(process.kind).font(.system(size: 11.5, weight: .medium)).lineLimit(1).layoutPriority(-1)
                Button { copy(String(process.pid), label: "PID \(process.pid)") } label: {
                    Text("(\(String(process.pid)))").font(.system(size: 10.5).monospacedDigit())
                        .foregroundStyle(pidHovered ? Color.accentColor : Color.secondary)
                        .padding(.horizontal, 3).padding(.vertical, 1)
                        .background(Color.accentColor.opacity(pidHovered ? 0.14 : 0), in: RoundedRectangle(cornerRadius: 4))
                }
                .buttonStyle(.plain).onHover { pidHovered = $0 }.help("Copy PID")
                Button { copy(process.executable, label: "path") } label: {
                    Image(systemName: "folder").font(.system(size: 9.5, weight: .medium))
                        .foregroundStyle(pathHovered ? Color.accentColor : Color.secondary)
                        .frame(width: 18, height: 16)
                        .background(Color.accentColor.opacity(pathHovered ? 0.14 : 0), in: RoundedRectangle(cornerRadius: 4))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain).onHover { pathHovered = $0 }
                .hoverPopover {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(process.executable).font(.system(size: 10.5, design: .monospaced))
                            .fixedSize(horizontal: false, vertical: true)
                        Text("Click to copy").font(.system(size: 9.5)).foregroundStyle(.secondary)
                    }
                    .frame(width: 280, alignment: .leading).padding(10)
                }
                .accessibilityLabel("Copy path")
                Spacer(minLength: 4)
                if stopping { ProgressView().controlSize(.mini) }
                Button(action: showActions) {
                    Image(systemName: "ellipsis").font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(moreHovered ? Color.primary : Color.secondary)
                        .frame(width: 22, height: 16)
                        .background(Color.primary.opacity(moreHovered ? 0.12 : 0), in: RoundedRectangle(cornerRadius: 5))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain).onHover { moreHovered = $0 }
                .opacity(hovering ? 1 : 0.45)
                .background(GeometryReader { geometry in
                    Color.clear.onAppear { moreFrame = geometry.frame(in: .global) }
                        .onChange(of: geometry.frame(in: .global)) { moreFrame = $0 }
                })
                .help("Stop or force quit")
            }
            HStack(spacing: 6) {
                Text(account ?? "Account unknown").lineLimit(1)
                Spacer(minLength: 6)
                Text(started).monospacedDigit()
            }
            .font(.system(size: 10)).foregroundStyle(.secondary)
            .padding(.leading, 20).padding(.trailing, 4)
        }
        .padding(.horizontal, 8).padding(.vertical, 6)
        .fleetCard(hovering: hovering)
        .onHover { hovering = $0 }
    }

    private func showActions() {
        ActionMenu(items: [
            .init(title: "Stop") { stop(false) },
            .init(title: "Force Quit") { stop(true) },
        ], fontSize: 12).popUp(below: moreFrame)
    }

    private func copy(_ text: String, label: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        copied(label)
    }
}
