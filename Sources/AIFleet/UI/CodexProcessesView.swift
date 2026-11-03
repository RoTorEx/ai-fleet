import SwiftUI

struct CodexProcessesView: View {
    @StateObject private var service = CodexProcessesService()
    @State private var pending: [CodexProcess] = []
    @State private var force = false
    @State private var confirms = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Codex processes").font(.headline)
                Spacer()
                if service.refreshing { ProgressView().controlSize(.small) }
                Button("Refresh") { service.refresh() }.keyboardShortcut("r")
            }
            Text("Includes background servers and helpers left after terminal windows close. Switching the default account for new launches does not require stopping them.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if let error = service.error {
                Text(error).font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            }
            if let notice = service.notice {
                Text(notice).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if service.processes.isEmpty {
                Text(service.refreshing ? "Reading processes…" : "No Codex processes found.")
                    .foregroundStyle(.secondary).padding(.vertical, 24)
            }
            ForEach(service.processes) { process in
                VStack(alignment: .leading, spacing: 5) {
                    HStack {
                        Image(systemName: process.isBackground ? "gearshape.2" : "terminal")
                        Text(process.kind).font(.system(size: 12, weight: .medium))
                        Spacer()
                        Text("PID \(String(process.pid))").font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
                    }
                    Text(process.executable).font(.caption2).foregroundStyle(.secondary)
                        .lineLimit(2).truncationMode(.middle).help(process.executable)
                    HStack {
                        Text("Started \(process.startedLabel)").font(.caption2).foregroundStyle(.secondary)
                        Spacer()
                        Button("Stop") { request([process], force: false) }
                        Button("Force Quit", role: .destructive) { request([process], force: true) }
                    }.buttonStyle(.bordered).controlSize(.small)
                }
                .padding(9).background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
            }
            let background = service.processes.filter(\.isBackground)
            if !background.isEmpty {
                Button("Stop all background processes…") { request(background, force: false) }
                    .font(.caption).padding(.top, 4)
            }
        }
        .padding(14)
        .disabled(!service.stopping.isEmpty)
        .onAppear { service.start() }
        .onDisappear { service.stopMonitoring() }
        .confirmationDialog(force ? "Force quit selected Codex processes?" : "Stop selected Codex processes?",
                            isPresented: $confirms, titleVisibility: .visible) {
            Button(force ? "Force Quit" : "Stop", role: .destructive) { service.terminate(pending, force: force) }
            Button("Cancel", role: .cancel) { pending = [] }
        } message: {
            Text("PIDs: \(pending.map { String($0.pid) }.joined(separator: ", ")). This can interrupt running conversations and their tools. Saved history and credentials are retained. A native client may restart a background server.")
        }
    }

    private func request(_ processes: [CodexProcess], force: Bool) {
        pending = processes; self.force = force; confirms = true
    }
}
