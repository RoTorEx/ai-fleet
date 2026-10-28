import SwiftUI

struct CodexProfilesView: View {
    @ObservedObject var store = CodexMonitoringStore.shared
    var managesProfiles = false
    var nativeStatus: ProviderStatus?
    var nativeUsage: CodexAccountUsage?
    var start: Date?
    var end: Date?
    var refreshNative: () -> Void = {}
    @State private var label = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Codex accounts").font(.headline)
                Spacer()
                if store.refreshing { ProgressView().controlSize(.small) }
                Button("Refresh") { store.refresh(force: true); refreshNative() }
                    .disabled(store.refreshing || store.authenticatingID != nil)
            }
            Text("Monitoring profiles keep independent logins. Native CLI sessions keep their current account.")
                .font(.caption).foregroundColor(.secondary)
            if managesProfiles {
                HStack {
                    TextField("Account label", text: $label)
                        .textFieldStyle(.roundedBorder)
                        .accessibilityLabel("Codex monitoring account label")
                    Button("Add & sign in…") {
                        let profile = store.add(label: label)
                        label = ""
                        store.signIn(profile)
                    }
                    .disabled(store.refreshing || store.authenticatingID != nil)
                }
            }
            if let nativeStatus {
                row(label: "Native CLI", status: nativeStatus, usage: nativeUsage, error: nil)
                Divider()
            }
            if store.profiles.isEmpty {
                Text("No monitoring profiles. Add accounts in Settings → Accounts → Codex accounts.")
                    .font(.caption).foregroundColor(.secondary)
            }
            ForEach(store.profiles) { profile in
                VStack(alignment: .leading, spacing: 6) {
                    let result = store.results[profile.id]
                    row(label: profile.label, status: result?.status, usage: result?.usage, error: result?.usageError)
                    if managesProfiles {
                        HStack {
                            Button("Sign in…") { store.signIn(profile) }
                            Button("Sign out") { store.signOut(profile) }
                            Spacer()
                            Button("Forget profile") { store.remove(profile) }
                                .help("Remove this profile from monitoring; preserve its login directory and history.")
                        }
                        .font(.caption)
                        .disabled(store.refreshing || store.authenticatingID != nil)
                    }
                }
                Divider()
            }
            if store.authenticatingID != nil {
                HStack {
                    ProgressView().controlSize(.small)
                    Text("Complete native authentication in your browser…").font(.caption)
                    Button("Cancel") { store.cancelAuthentication() }.font(.caption)
                }
            }
            if let error = store.error {
                Text(error).font(.caption).foregroundColor(.red)
            }
            Text(start == nil && end == nil
                 ? "Tokens: account-reported all-time usage. No local model mix or cost is attributed to monitoring profiles."
                 : "Tokens: provider-reported dates for this period. Their day boundary may differ from this Mac's local session history.")
                .font(.caption).foregroundColor(.secondary)
        }
        .onAppear { store.refresh() }
    }

    private func row(label: String, status: ProviderStatus?, usage: CodexAccountUsage?, error: String?) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(label).font(.subheadline).bold()
                Spacer(minLength: 5)
                Text(status?.account?.planLabel ?? "—").font(.caption).foregroundColor(.secondary)
            }
            Text(status?.account?.email ?? (store.refreshing ? "Checking profile…" : "Not connected"))
                .font(.caption).foregroundColor(.secondary).textSelection(.enabled)
            HStack(spacing: 16) {
                Text("5h: \(remaining(status, label: "5h"))")
                Text("7d: \(remaining(status, label: "7d"))")
                Spacer(minLength: 0)
                Text("Tokens: \(codexMonitoringTokens(usage, start: start, end: end).map(groupedInteger) ?? "—")")
            }
            .font(.system(size: 11, design: .monospaced))
            if let status {
                Text(status.detail).font(.caption).foregroundColor(.secondary)
                ForEach(status.limitWindows) { window in
                    if let reset = window.resetAt {
                        Text("\(window.label) resets \(codexProfileDateTime(reset))")
                            .font(.caption2).foregroundColor(.secondary)
                    }
                }
            }
            if let usage {
                Text("Tokens updated \(codexProfileDateTime(usage.fetchedAt))")
                    .font(.caption2).foregroundColor(.secondary)
            }
            if let error { Text(error).font(.caption).foregroundColor(.secondary) }
        }
    }

    private func remaining(_ status: ProviderStatus?, label: String) -> String {
        guard let status, status.hasCurrentQuota,
              let window = status.limitWindows.first(where: { $0.label == label }) else { return "—" }
        return "\(window.remainingPercent)% left"
    }
}

struct CodexMonitoringMenuRows: View {
    @ObservedObject var store = CodexMonitoringStore.shared
    let manage: () -> Void

    var body: some View {
        if !store.profiles.isEmpty {
            Divider()
            HStack {
                Text("Codex profiles").font(.caption).foregroundColor(.secondary)
                Spacer()
                Button("Manage…", action: manage).font(.caption).buttonStyle(.plain)
            }
            ForEach(store.profiles) { profile in
                VStack(alignment: .leading, spacing: 3) {
                    let result = store.results[profile.id]
                    Text("Codex · \(profile.label)").font(.system(size: 12, weight: .semibold))
                        .help([result?.status.account?.email, result?.status.account?.planLabel].compactMap { $0 }.joined(separator: "\n"))
                    if let status = result?.status, status.hasCurrentQuota {
                        HStack(spacing: 12) {
                            ForEach(status.limitWindows) { window in
                                Text("\(window.label): \(window.remainingPercent)% left")
                                    .foregroundColor(window.remainingPercent <= 10 ? .red : window.remainingPercent <= 25 ? .orange : .primary)
                            }
                        }
                        .font(.system(size: 10, design: .monospaced))
                    } else {
                        Text(result?.status.detail ?? (store.refreshing ? "Checking profile…" : "Sign in in Settings → Accounts"))
                            .font(.caption).foregroundColor(.secondary)
                    }
                }
            }
        }
    }
}

private func codexProfileDateTime(_ date: Date) -> String {
    date.formatted(date: .abbreviated, time: .shortened)
}
