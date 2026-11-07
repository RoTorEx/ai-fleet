import AppKit
import SwiftUI

struct CodexProcessesView: View {
    @StateObject private var service = CodexProcessesService()
    @State private var pending: [CodexProcess] = []
    @State private var force = false
    @State private var confirms = false
    @State private var filter = "All"
    @State private var newestFirst = true

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
                ProcessRow(process: process, stopping: service.stopping.contains(process.id)) { force in
                    request([process], force: force)
                }
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

    private func request(_ processes: [CodexProcess], force: Bool) {
        pending = processes; self.force = force; confirms = true
    }
}

/// Three thin lines: kind and PID with actions, the executable (click to copy),
/// then account and start time.
private struct ProcessRow: View {
    let process: CodexProcess
    let stopping: Bool
    let stop: (_ force: Bool) -> Void
    @State private var hovering = false
    @State private var copied = false

    private var account: String {
        let roots = SwitchCoordinator.sessionRoots(home: FileManager.default.homeDirectoryForCurrentUser)
        guard let binding = SwitchRecovery.owner(of: process, roots: roots),
              let account = AccountStore.shared.accounts.first(where: { $0.id == binding.accountID }) else {
            return "Account unknown"
        }
        return "\(account.badge) · \(account.name)"
    }

    private var started: String {
        TimeInterval(process.started).map { formatResetTime(Date(timeIntervalSince1970: $0)) } ?? process.started
    }

    var body: some View {
        let account = account
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Image(systemName: process.isBackground ? "gearshape.2" : "terminal")
                    .font(.system(size: 10)).foregroundStyle(.secondary).frame(width: 14)
                Text(process.kind).font(.system(size: 11.5, weight: .medium)).lineLimit(1)
                Spacer(minLength: 4)
                if stopping { ProgressView().controlSize(.mini) }
                Text("PID \(String(process.pid))").font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
                Menu {
                    Button("Stop") { stop(false) }
                    Button("Force Quit") { stop(true) }
                    Divider()
                    Button("Copy Path") { copy(process.executable) }
                    Button("Copy PID") { copy(String(process.pid)) }
                    Divider()
                    Text(account == "Account unknown" ? "Account unknown · manual selection required" : "Account \(account)")
                    Text("Started \(process.startedLabel)")
                } label: {
                    Image(systemName: "ellipsis").font(.system(size: 11, weight: .semibold)).frame(width: 18, height: 14)
                }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .opacity(hovering ? 1 : 0.35)
                .help("Stop, force quit or copy")
            }
            Button { copy(process.executable) } label: {
                Text(copied ? "Copied path" : process.executable)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(copied ? Color.accentColor : Color.secondary)
                    .lineLimit(1).truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain).padding(.leading, 20)
            .help("\(process.executable)\nClick to copy")
            Text("\(account) · started \(started)")
                .font(.system(size: 10)).foregroundStyle(.tertiary).lineLimit(1)
                .padding(.leading, 20)
        }
        .padding(.horizontal, 8).padding(.vertical, 6)
        .background(Color.primary.opacity(hovering ? 0.12 : 0.075), in: RoundedRectangle(cornerRadius: 7))
        .overlay(RoundedRectangle(cornerRadius: 7).stroke(Color.primary.opacity(0.08)))
        .onHover { hovering = $0 }
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        guard text == process.executable else { return }
        copied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { copied = false }
    }
}
