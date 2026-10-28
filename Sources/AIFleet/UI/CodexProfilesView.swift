import SwiftUI

struct CodexProfilesView: View {
    @ObservedObject var store = CodexMonitoringStore.shared
    var managesProfiles = false
    var nativeStatus: ProviderStatus?
    var start: Date?
    var end: Date?
    var refreshNative: () -> Void = {}
    @ObservedObject var accounts = AccountStore.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Codex accounts").font(.headline)
                Spacer()
                if store.refreshing { ProgressView().controlSize(.small) }
                Button("Refresh") { store.refresh(force: true); refreshNative() }
                    .disabled(store.refreshing || store.authenticatingID != nil)
            }
            Text("Each letter identifies an account. Sign in once per account to keep its limits available.")
                .font(.caption).foregroundColor(.secondary)
            let global = nativeStatus ?? StatusService.shared.codex
            let linked = accounts.visibleAccounts.filter { $0.connection(for: "codex") != nil }
            if linked.isEmpty {
                Text("Connect Codex to an account in Settings → Accounts.")
                    .font(.caption).foregroundColor(.secondary)
            }
            ForEach(linked) { account in
                let status = store.status(for: account, global: global, accounts: accounts.visibleAccounts)
                let usage = store.usage(for: account, global: global, accounts: accounts.visibleAccounts)
                row(label: "Codex (\(account.badge)) · \(account.name)", status: status, usage: usage,
                    error: store.profile(for: account).flatMap { store.results[$0.id]?.usageError })
                if store.profile(for: account) == nil {
                    Text("Sign in once in Settings → Accounts to save this account's connection.")
                        .font(.caption).foregroundColor(.secondary)
                }
                if managesProfiles {
                    HStack {
                        Button("Sign in…") { store.signIn(store.ensureProfile(for: account)) }
                        if let profile = store.profile(for: account), status.authentication == .signedIn {
                            Button("Sign out") { store.signOut(profile) }
                        }
                    }
                    .disabled(store.refreshing || store.authenticatingID != nil)
                }
                Divider()
            }
            CodexAccountAuthenticationStatus(store: store, accounts: accounts)
            Text(start == nil && end == nil
                 ? "Tokens: account-reported all-time usage. Local model details and cost estimates are not assigned across accounts."
                 : "Tokens: provider-reported dates for this period. Their day boundary may differ from this Mac's local session history.")
                .font(.caption).foregroundColor(.secondary)
        }
        .onAppear { store.synchronizeAccounts(accounts); store.refresh() }
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

private func codexProfileDateTime(_ date: Date) -> String {
    date.formatted(date: .abbreviated, time: .shortened)
}
