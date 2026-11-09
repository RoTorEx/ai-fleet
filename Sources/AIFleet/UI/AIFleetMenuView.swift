import AppKit
import SwiftUI

struct AIFleetMenuView: View {
    let openSettings: () -> Void
    let openStatistics: () -> Void
    @ObservedObject var screen: FleetMenuScreen
    @ObservedObject var agents: AgentSessionsService

    @EnvironmentObject var service: StatusService
    @EnvironmentObject var settings: AppSettings
    @State private var isLegendShown = false
    // Owned here so the Processes tab shows its count; scans only while the menu is open.
    @StateObject private var processes = CodexProcessesService()
    @ObservedObject private var accounts = AccountStore.shared
    @ObservedObject private var codexProfiles = CodexMonitoringStore.shared
    @ObservedObject private var providerLaunch = ProviderLaunchStore.shared

    private var connections: [MenuAccountConnection] {
        menuProviderRows(accounts: accounts.accounts, enabled: settings.isEnabled,
            global: service.status(for:), statusForConnection: service.status(for:), codex: codexProfiles)
    }

    private var monitoringSummary: MonitoringSummary { MonitoringSummary(rows: connections, monitoring: service.isMonitoring) }

    private var providers: [ProviderStatus] { connections.map(\.status) }

    private var lowestProvider: ProviderStatus? {
        providers
            .filter(\.hasCurrentQuota)
            .filter { ($0.remainingPercent ?? 0) > 0 }
            .min { ($0.remainingPercent ?? 101) < ($1.remainingPercent ?? 101) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

            // Bookmark tabs: the active tab and its page are one shape.
            MenuTabBar(screen: screen, tabs: [
                .init(tab: .providers, title: "Providers",
                      count: "\(monitoringSummary.measured)/\(monitoringSummary.total)", attention: false),
                .init(tab: .agents, title: "Agents", count: "\(agents.sessions.count)",
                      attention: !agents.isStale && agents.sessions.contains(where: \.needsYou)),
                .init(tab: .processes, title: "Processes",
                      count: processes.processes.isEmpty && processes.refreshing ? nil : "\(processes.processes.count)",
                      attention: false),
            ]) {
                // Only the active tab's content scrolls, once the menu reaches 80% of the screen.
                MenuRowsViewport(maxHeight: tabBudget) {
                    switch screen.tab {
                    case .providers:
                        providerRows.padding(.horizontal, 10)
                    case .agents:
                        MenuAgentsSection(service: agents)
                    case .processes:
                        CodexProcessesView(service: processes).padding(.horizontal, 8)
                    }
                }
                .padding(.vertical, 10)
            }
            .padding(.horizontal, 8)
            .padding(.top, 10)
            .padding(.bottom, 8)

            footer
        }
        .padding(.top, 12)
        .padding(.bottom, 10)
        .frame(width: FleetMenuLayout.width)
        .onAppear { processes.start() }
        .onDisappear { processes.stopMonitoring() }
        .overlay(alignment: .topLeading) {
            if isLegendShown {
                VStack(alignment: .leading, spacing: 9) {
                    if !statusNotes.isEmpty {
                        StatusNotesSection(notes: statusNotes)
                        Rectangle().fill(FleetPalette.divider).frame(height: 1)
                    }
                    LegendSection()
                    if !accountSummaries.isEmpty {
                        Rectangle().fill(FleetPalette.divider).frame(height: 1)
                        AccountsLegendSection(accounts: accountSummaries)
                    }
                }
                    .frame(maxWidth: 330, alignment: .leading)
                    .padding(12)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(FleetPalette.border))
                    .shadow(color: .black.opacity(0.18), radius: 8, y: 3)
                    .padding(.horizontal, 10)
                    .padding(.top, 38)
                    .allowsHitTesting(false)
            }
        }
    }

    /// The menu may grow to 80% of the screen's visible height; past that only the
    /// active tab scrolls. Header, tabs and footer always stay whole.
    private var tabBudget: CGFloat {
        let screenHeight = NSScreen.main?.visibleFrame.height ?? 800
        // Header, tab bar, footer, dividers and paddings around the content.
        let chrome: CGFloat = 120
        return max(160, screenHeight * 0.8 - chrome)
    }

    private var providerRows: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(menuRowsAvailableFirst(connections)) { entry in
                ProviderLimitRow(entry: entry, mark: mark(for: entry), openSettings: openSettings)
            }
        }
    }

    /// One leading mark per row: ↓ lowest positive quota anywhere, → the provider's current
    /// account, none for any other working connection, × / ? unavailable.
    private func mark(for entry: MenuAccountConnection) -> String {
        let state = MenuConnectionState(status: entry.status)
        guard state.available else { return state.marker }
        if entry.status.id == lowestProvider?.id { return "↓" }
        if entry.isCurrentCLI ?? entry.isSelected { return "→" }
        return ""
    }

    /// Saved accounts by badge with their email and each provider's plan.
    private var accountSummaries: [AccountsLegendSection.Account] {
        var order: [String] = []
        var byID: [String: AccountsLegendSection.Account] = [:]
        for entry in connections where !entry.isSetup && !entry.account.badge.isEmpty {
            let id = entry.account.id
            if byID[id] == nil {
                order.append(id)
                let email = entry.status.account?.email ?? entry.account.email
                byID[id] = .init(badge: entry.account.badge, email: email, providers: [])
            }
            let plan = entry.status.account?.planLabel
            byID[id]?.providers.append(plan.map { "\(entry.status.name) (\($0))" } ?? entry.status.name)
        }
        // Badges are Greek letters, so code-point order is alphabetical: α, β, γ, δ…
        return order.compactMap { byID[$0] }.sorted { $0.badge < $1.badge }
    }

    /// ⓘ glows red for errors and orange for warnings; info-only notes keep it still.
    private var attentionColor: Color? {
        if statusNotes.contains(where: { $0.severity == .error }) { return FleetPalette.danger }
        if statusNotes.contains(where: { $0.severity == .warning }) { return FleetPalette.warning }
        return nil
    }

    /// Account notes worth reading, shown at the top of the ⓘ card instead of under rows.
    private var statusNotes: [MenuStatusNote] {
        var notes: [MenuStatusNote] = []
        func label(_ entry: MenuAccountConnection) -> String {
            entry.account.badge.isEmpty ? entry.status.name : "\(entry.status.name) (\(entry.account.badge))"
        }
        for entry in connections {
            if let notice = entry.status.quotaNotice {
                notes.append(.init(label: label(entry), text: notice, severity: entry.isSelected ? .warning : .info))
            }
            if providerLaunch.messageIsError, let message = providerLaunch.message,
               providerLaunch.messageAccountID == entry.account.id, providerLaunch.messageProviderID == entry.status.providerID {
                notes.append(.init(label: label(entry), text: message, severity: .error))
            }
            if entry.usesAccountLogin, let error = codexProfiles.error,
               codexProfiles.profiles.first(where: { $0.id == codexProfiles.errorProfileID })?.accountID == entry.account.id {
                let text = codexProfiles.switchBlockedProcessIDs == nil ? error
                    : "Switch blocked while Codex is running. Stop it in Processes, then retry."
                notes.append(.init(label: label(entry), text: text, severity: .error))
            }
        }
        if let error = accounts.launchError {
            let provider = accounts.launchProviderID.flatMap { ProviderCatalog.definition(for: $0)?.name } ?? "Sign-in"
            notes.append(.init(label: provider, text: error, severity: .error))
        }
        if codexProfiles.terminalSetupNotice {
            notes.append(.init(label: "Codex", text: "Terminals opened earlier: run rehash once.", severity: .info))
        }
        return notes
    }

    /// One compact line: monitoring state and measured/saved count, then Refresh and Options.
    private var header: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 7) {
                Circle()
                    .fill(statusDotColor)
                    .frame(width: 7, height: 7)
                Text(operationStatus.title)
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundColor(operationStatus.failed ? FleetPalette.warning : FleetPalette.value)
                    .lineLimit(1)
                InfoIndicator(attention: attentionColor, highlighted: isLegendShown)
                    .frame(width: 18, height: 18)
                    .contentShape(Rectangle())
                    .onHover { isLegendShown = $0 }
                    .accessibilityLabel("Legend")
                Spacer(minLength: 8)
                HeaderIconButton(systemName: "arrow.clockwise", help: "Refresh (⌘R)", spinning: isRefreshing) {
                    refresh()
                }
                optionsMenu
            }
            if let detail = operationStatus.detail {
                HStack(spacing: 8) {
                    Text(detail).font(.system(size: 11))
                        .foregroundColor(operationStatus.failed ? FleetPalette.warning : FleetPalette.muted)
                        .fixedSize(horizontal: false, vertical: true)
                    if codexProfiles.authenticatingID != nil || accounts.codexSigningIn {
                        Button("Cancel") {
                            if codexProfiles.authenticatingID != nil { codexProfiles.cancelAuthentication() }
                            else { accounts.cancelCodexSignIn() }
                        }
                        .buttonStyle(.link).font(.system(size: 11))
                    }
                }
                .padding(.leading, 14)
            }
        }
        .padding(.horizontal, 16)
    }

    private var optionsMenu: some View {
        Menu {
            Button("Statistics") { openStatistics() }.keyboardShortcut("s")
            Button("Settings…") { openSettings() }.keyboardShortcut(",")
            Divider()
            Button("Quit") { NSApplication.shared.terminate(nil) }.keyboardShortcut("q")
        } label: {
            Image(systemName: "ellipsis.circle")
                .font(.system(size: 14, weight: .regular))
                .foregroundColor(FleetPalette.muted)
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Options")
        .accessibilityLabel("Options")
    }

    private var footer: some View {
        HStack {
            Text("Last refresh: \(lastUpdateText)")
            Spacer()
            Text(versionText)
        }
        .font(.system(size: 10.5, weight: .medium).monospacedDigit())
        .foregroundColor(FleetPalette.muted)
        .padding(.horizontal, 16)
    }

    private var isRefreshing: Bool { service.isManualRefresh }

    private func refresh() {
        service.refresh(manual: true); codexProfiles.refresh(force: true)
    }

    private var statusDotColor: Color {
        if operationStatus.failed { return FleetPalette.warning }
        return service.isMonitoring ? FleetPalette.ready : FleetPalette.faint
    }

    private var operationStatus: MenuOperationStatus {
        let active = codexProfiles.profiles.first { $0.id == codexProfiles.authenticatingID }
        let badge = accounts.accounts.first { $0.id == active?.accountID }?.badge
        let signing: String?
        if let badge {
            let verb = codexProfiles.authenticationAction == .logout ? "Signing out" : "Signing in"
            signing = "\(verb) Codex (\(badge))…"
        } else if let provider = service.signingOutProvider {
            signing = "Signing out \(ProviderCatalog.definition(for: provider)?.name ?? provider)…"
        } else if let provider = accounts.signingInProviderID {
            signing = "Signing in \(ProviderCatalog.definition(for: provider)?.name ?? provider)…"
        } else {
            signing = accounts.codexSigningIn ? "Signing in Codex…" : nil
        }
        let status = MenuOperationStatus.resolve(update: .idle, refreshing: false,
                                                 signingIn: signing, monitoring: service.isMonitoring)
        // Sign-in progress belongs on the detail line; the header title stays Active/Paused.
        guard signing != nil else { return status }
        return MenuOperationStatus(title: service.isMonitoring ? "Active" : "Paused", detail: status.title)
    }

    private var lastUpdateText: String {
        guard let updated = providers.compactMap(\.lastUpdated).max() else {
            return "—"
        }
        return updated.formatted(date: .omitted, time: .standard)
    }

    private var versionText: String {
        guard let version = Bundle.main.object(
            forInfoDictionaryKey: "CFBundleShortVersionString"
        ) as? String else {
            return "development build"
        }
        return "v\(version)"
    }
}

struct MenuRowsViewport<Content: View>: View {
    let maxHeight: CGFloat
    let content: Content
    @State private var contentHeight: CGFloat = 1

    init(maxHeight: CGFloat, @ViewBuilder content: () -> Content) {
        self.maxHeight = maxHeight
        self.content = content()
    }

    var body: some View {
        let scrolls = contentHeight > maxHeight
        ScrollView {
            content
                .fixedSize(horizontal: false, vertical: true)
                .padding(.bottom, scrolls ? 14 : 0)
                .background(GeometryReader { geometry in
                    Color.clear.preference(key: MenuRowsHeightKey.self, value: geometry.size.height)
                })
                .background(OverlayScrollers())
        }
        .mask {
            VStack(spacing: 0) {
                Color.black
                LinearGradient(colors: [.black, .black.opacity(scrolls ? 0 : 1)], startPoint: .top, endPoint: .bottom)
                    .frame(height: 22)
            }
        }
        .frame(height: min(maxHeight, contentHeight))
        .onPreferenceChange(MenuRowsHeightKey.self) { contentHeight = max(1, $0) }
    }
}

/// Terminal-style scrolling: the scroller slides in while scrolling and fades out,
/// even when System Settings asks for always-visible (legacy) scroll bars, whose
/// opaque track would cover the glass.
private struct OverlayScrollers: NSViewRepresentable {
    func makeNSView(context: Context) -> OverlayScrollersView { OverlayScrollersView() }
    func updateNSView(_ view: OverlayScrollersView, context: Context) { view.apply() }
}

private final class OverlayScrollersView: NSView {
    private var observer: NSObjectProtocol?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        apply()
        guard observer == nil, window != nil else { return }
        // The scroll view resets its style when the system preference changes.
        observer = NotificationCenter.default.addObserver(forName: NSScroller.preferredScrollerStyleDidChangeNotification,
                                                          object: nil, queue: .main) { [weak self] _ in
            DispatchQueue.main.async { self?.apply() }
        }
    }

    func apply() {
        guard let scrollView = enclosingScrollView else { return }
        if scrollView.scrollerStyle != .overlay { scrollView.scrollerStyle = .overlay }
        scrollView.autohidesScrollers = true
        scrollView.hasHorizontalScroller = false
    }

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }
}

/// The shared block look of menu rows (agents, processes).
private struct FleetCard: ViewModifier {
    let hovering: Bool
    let accent: Color?

    func body(content: Content) -> some View {
        content
            .background(Color.primary.opacity(hovering ? 0.12 : 0.075), in: RoundedRectangle(cornerRadius: 7))
            .overlay(RoundedRectangle(cornerRadius: 7).stroke(accent?.opacity(0.45) ?? Color.primary.opacity(0.08)))
    }
}

/// Shows a popover after the pointer rests on the view and hides it when it leaves.
private struct HoverPopover<Popover: View>: ViewModifier {
    let enabled: Bool
    let popover: () -> Popover
    @State private var hovering = false
    @State private var shown = false

    func body(content: Content) -> some View {
        content
            .onHover { inside in
                hovering = inside
                guard inside else { shown = false; return }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) {
                    if hovering && enabled { shown = true }
                }
            }
            .popover(isPresented: $shown, arrowEdge: .leading) { popover() }
    }
}

extension View {
    func fleetCard(hovering: Bool, accent: Color? = nil) -> some View {
        modifier(FleetCard(hovering: hovering, accent: accent))
    }

    func hoverPopover<Popover: View>(enabled: Bool = true, @ViewBuilder _ popover: @escaping () -> Popover) -> some View {
        modifier(HoverPopover(enabled: enabled, popover: popover))
    }
}

enum FleetMenuLayout {
    static let width: CGFloat = 354
}

/// Tabs look like bookmarks sticking out of one page: the active tab and the
/// content below share a single filled shape; the others stay flat text.
/// Tabs split the full width; an orange dot flags agents waiting for the user.
struct MenuTabBar<Content: View>: View {
    struct Item {
        let tab: MenuTab
        let title: String
        let count: String?
        let attention: Bool
    }
    @ObservedObject var screen: FleetMenuScreen
    let tabs: [Item]
    let content: Content

    init(screen: FleetMenuScreen, tabs: [Item], @ViewBuilder content: () -> Content) {
        self.screen = screen
        self.tabs = tabs
        self.content = content()
    }

    var body: some View {
        let index = tabs.firstIndex { $0.tab == screen.tab } ?? 0
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                ForEach(tabs, id: \.tab) { item in
                    tab(item, active: item.tab == screen.tab)
                }
            }
            .frame(height: BookmarkPage.tabHeight)
            content
        }
        .background(BookmarkPage(index: index, count: tabs.count).fill(FleetPalette.page))
    }

    private func tab(_ item: Item, active: Bool) -> some View {
        Button { screen.tab = item.tab } label: {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(item.title).font(.system(size: 13, weight: active ? .semibold : .medium))
                    .foregroundColor(active ? FleetPalette.value : FleetPalette.muted)
                if let count = item.count {
                    Text(count).font(.system(size: 11, weight: .medium).monospacedDigit())
                        .foregroundColor(FleetPalette.muted.opacity(active ? 1 : 0.75))
                }
            }
            .overlay(alignment: .topTrailing) {
                if item.attention {
                    Circle().fill(FleetPalette.warning).frame(width: 6, height: 6).offset(x: 7, y: -1)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("\(item.title) (← →)")
        .accessibilityAddTraits(active ? .isSelected : [])
    }
}

/// One outline for the active tab and its page, so they read as a single sheet.
struct BookmarkPage: Shape {
    static let tabHeight: CGFloat = 28
    let index: Int
    let count: Int

    func path(in rect: CGRect) -> Path {
        let radius: CGFloat = 9
        let width = rect.width / CGFloat(max(count, 1))
        let tab = CGRect(x: rect.minX + width * CGFloat(index), y: rect.minY, width: width, height: Self.tabHeight + radius)
        let page = CGRect(x: rect.minX, y: rect.minY + Self.tabHeight, width: rect.width, height: rect.height - Self.tabHeight)
        var path = Path(roundedRect: page, cornerRadius: radius, style: .continuous)
        path.addPath(Path(roundedRect: tab, cornerRadius: radius, style: .continuous))
        // Square the page corner the tab grows out of at either edge.
        if index == 0 {
            path.addRect(CGRect(x: page.minX, y: page.minY, width: radius, height: radius))
        }
        if index == count - 1 {
            path.addRect(CGRect(x: page.maxX - radius, y: page.minY, width: radius, height: radius))
        }
        return path
    }
}

private struct MenuRowsHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

/// Leading row mark. Every mark uses one monospaced font sharing the × optical center.
/// The font's → is shorter than its ↓, so → is the same ↓ glyph turned a quarter.
struct RowMark: View {
    let mark: String
    var size: CGFloat = 14

    var body: some View {
        if mark == "→" {
            glyph("↓").rotationEffect(.degrees(-90)).offset(y: size * 0.07)
        } else {
            glyph(mark)
        }
    }

    private func glyph(_ text: String) -> some View {
        Text(text).font(.system(size: size, weight: .medium, design: .monospaced))
    }
}

enum FleetRowMetrics {
    static let markWidth: CGFloat = 14
    static let markSpacing: CGFloat = 5
    /// Wide enough for `↻ 12 Nov 10:58` and the `6d 23h 59m 59s` countdown.
    static let resetWidth: CGFloat = 112
    static let quotaLineSpacing: CGFloat = 3
    /// Quota rows sit a little inside the provider name, like a nested list.
    static let detailIndent: CGFloat = markWidth + markSpacing + 10
}

struct MenuStatusNote: Hashable {
    enum Severity { case info, warning, error }
    let label: String
    let text: String
    let severity: Severity
}

struct InfoIndicator: View {
    let attention: Color?
    let highlighted: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        if let attention, !reduceMotion {
            InfoPulse(color: NSColor(attention)).fixedSize()
        } else {
            Image(systemName: "info.circle")
                .font(.system(size: 12, weight: attention == nil ? .regular : .semibold))
                .foregroundColor(attention ?? (highlighted ? FleetPalette.value : FleetPalette.muted))
        }
    }
}

/// The glow runs as a Core Animation layer animation: a SwiftUI repeatForever
/// animation re-renders the whole menu every frame (measured ~80% CPU vs ~0.1%).
private struct InfoPulse: NSViewRepresentable {
    let color: NSColor

    func makeNSView(context: Context) -> NSImageView {
        let view = NSImageView()
        view.image = NSImage(systemSymbolName: "info.circle", accessibilityDescription: "Status details")?
            .withSymbolConfiguration(.init(pointSize: 12, weight: .semibold))
        view.wantsLayer = true
        view.layer?.shadowOffset = .zero
        view.layer?.shadowRadius = 3
        let opacity = CABasicAnimation(keyPath: "opacity")
        opacity.fromValue = 0.35
        opacity.toValue = 1
        let glow = CABasicAnimation(keyPath: "shadowOpacity")
        glow.fromValue = 0
        glow.toValue = 0.9
        let pulse = CAAnimationGroup()
        pulse.animations = [opacity, glow]
        pulse.duration = 1.1
        pulse.autoreverses = true
        pulse.repeatCount = .infinity
        pulse.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        view.layer?.add(pulse, forKey: "pulse")
        return view
    }

    func updateNSView(_ view: NSImageView, context: Context) {
        view.contentTintColor = color
        view.layer?.shadowColor = color.cgColor
    }
}

struct StatusNotesSection: View {
    let notes: [MenuStatusNote]

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("Status")
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(FleetPalette.label)
            ForEach(notes, id: \.self) { note in
                (Text(note.label + "  ").fontWeight(.semibold) + Text(note.text))
                    .font(.system(size: 10.5))
                    .foregroundColor(note.severity == .error ? FleetPalette.danger
                        : note.severity == .warning ? FleetPalette.warning : FleetPalette.value)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

struct ProviderLimitRow: View {
    let entry: MenuAccountConnection
    let mark: String
    let openSettings: () -> Void
    @ObservedObject private var accounts = AccountStore.shared
    @ObservedObject private var service = StatusService.shared
    @ObservedObject private var codexProfiles = CodexMonitoringStore.shared
    @ObservedObject private var providerLaunch = ProviderLaunchStore.shared
    @State private var isNameHovered = false
    @State private var nameFrame: CGRect = .zero
    private var status: ProviderStatus { entry.status }
    private var presentation: MenuConnectionState { MenuConnectionState(status: status) }
    private var color: Color { presentation.available ? rowColor(for: status) : FleetPalette.muted }
    private var markAccessibility: String {
        switch mark {
        case "↓": return "lowest remaining quota"
        case "→": return "current account"
        case "": return "connected"
        case "×": return "sign in required"
        default: return "unavailable"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: FleetRowMetrics.markSpacing) {
                RowMark(mark: mark)
                    .foregroundColor(color)
                    .frame(width: FleetRowMetrics.markWidth, alignment: .center)
                    .accessibilityLabel(markAccessibility)
                Button(action: showActions) {
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Text(status.name)
                            .font(.system(size: 12, weight: .medium))
                        if !entry.account.badge.isEmpty {
                            Text("(\(entry.account.badge))")
                                .font(.system(size: 10, weight: .medium))
                        }
                    }
                    .foregroundColor(color)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    // Hover highlight shows the name is clickable.
                    .background(
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .fill(Color.primary.opacity(isNameHovered ? 0.1 : 0))
                    )
                    .contentShape(Rectangle())
                    .background(GeometryReader { geometry in
                        Color.clear
                            .onAppear { nameFrame = geometry.frame(in: .global) }
                            .onChange(of: geometry.frame(in: .global)) { nameFrame = $0 }
                    })
                }
                .buttonStyle(PlainButtonStyle())
                .padding(.horizontal, -4)
                .onHover { isNameHovered = $0 }
                .accessibilityLabel("\(status.name) \(entry.account.badge) actions")
                .accessibilityHint(Text(subscription))
                Spacer(minLength: 8)
            }
            if !status.limitWindows.isEmpty {
                VStack(alignment: .leading, spacing: FleetRowMetrics.quotaLineSpacing) {
                    ForEach(status.limitWindows) { window in
                        if status.providerID == "gemini" {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(window.label).font(.system(size: 10, weight: .medium, design: .monospaced))
                                    .foregroundColor(color).lineLimit(1)
                                LimitWindowLine(window: window, status: status, isActive: presentation.available, showsLabel: false)
                            }
                        } else {
                            LimitWindowLine(window: window, status: status, isActive: presentation.available)
                        }
                    }
                }
                .padding(.leading, FleetRowMetrics.detailIndent)
            } else {
                Text(presentation.detail)
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundColor(color).fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, FleetRowMetrics.detailIndent)
            }
        }
    }

    /// Email and plan for this connection, shown at the top of its actions menu.
    private var subscription: String {
        entry.account.tooltip(for: entry.connection, status: status)
            .split(separator: "\n").joined(separator: " · ")
    }

    private var identityLines: [String] {
        let email = status.account?.email ?? entry.account.email
        var lines = email.isEmpty ? [] : [email]
        if let plan = status.account?.planLabel { lines.append("(\(plan))") }
        return lines
    }

    private var actionsBusy: Bool {
        providerLaunch.busy || service.signingOutProvider != nil || accounts.codexSigningIn
            || accounts.signingInProviderID != nil || codexProfiles.authenticatingID != nil
    }

    /// Native menu below the name: email, (plan), separator, Sign in or Sign out, then Switch to.
    private func showActions() {
        let busy = actionsBusy
        var items: [ActionMenu.Item?] = identityLines.map { ActionMenu.Item(title: $0, enabled: false) {} }
        if !items.isEmpty { items.append(nil) }
        if entry.isSetup {
            items.append(.init(title: "Set up connection", enabled: !busy) {
                SettingsNavigation.shared.addAccount(for: status.providerID); openSettings()
            })
        } else if entry.usesAccountLogin {
            let profile = codexProfiles.profile(for: entry.account)
            if let profile, status.authentication == .signedIn {
                items.append(.init(title: "Sign out", enabled: !busy && !codexProfiles.refreshing) {
                    codexProfiles.signOut(profile)
                })
            } else {
                items.append(.init(title: "Sign in", enabled: !busy && !codexProfiles.refreshing) {
                    if entry.account.badge.isEmpty {
                        SettingsNavigation.shared.addAccount(for: "codex"); openSettings()
                    } else { codexProfiles.signIn(codexProfiles.ensureProfile(for: entry.account)) }
                })
            }
            if profile != nil {
                items.append(.init(title: switchActionTitle(provider: status.name, badge: entry.account.badge), enabled: !busy && !codexProfiles.refreshing) {
                    codexProfiles.switchAccount(entry.account)
                })
            }
        } else {
            let signOutFailed = service.signOutFailedProvider == status.providerID
                && service.globalAccountIDs[status.providerID] == entry.account.id
            if entry.isSelected || signOutFailed {
                items.append(.init(title: "Sign out", enabled: !busy) {
                    providerLaunch.signOut(entry.account, providerID: status.providerID)
                })
            } else {
                items.append(.init(title: "Sign in", enabled: !busy) {
                    providerLaunch.signIn(entry.account, providerID: status.providerID)
                })
            }
            if ProviderTerminalLaunch.providers.contains(status.providerID) {
                items.append(.init(title: switchActionTitle(provider: status.name, badge: entry.account.badge), enabled: !busy) {
                    if entry.account.badge.isEmpty {
                        SettingsNavigation.shared.addAccount(for: status.providerID); openSettings()
                    } else {
                        providerLaunch.switchAccount(entry.account, providerID: status.providerID,
                            global: service.status(for: status.providerID))
                    }
                })
            }
        }
        let menu = ActionMenu(items: items)
        withExtendedLifetime(menu) { menu.popUp(below: nameFrame) }
    }
}

/// A small native menu built from closures, opened at the pointer.
@MainActor
final class ActionMenu: NSObject {
    struct Item {
        let title: String
        var enabled = true
        /// A small secondary information line instead of a command.
        var detail = false
        let action: () -> Void

        static func info(_ title: String) -> Item { Item(title: title, enabled: false, detail: true) {} }
    }

    private let items: [Item?]
    private let fontSize: CGFloat?

    init(items: [Item?], fontSize: CGFloat? = nil) {
        self.items = items
        self.fontSize = fontSize
    }

    /// Opens below `frame` (SwiftUI global coordinates of the menu panel), so another
    /// click on the same name lands outside the menu and simply closes it.
    func popUp(below frame: CGRect) {
        let menu = NSMenu()
        menu.autoenablesItems = false
        if let fontSize { menu.font = .menuFont(ofSize: fontSize) }
        for (index, item) in items.enumerated() {
            guard let item else {
                menu.addItem(.separator())
                continue
            }
            let menuItem = NSMenuItem(title: item.title, action: #selector(run(_:)), keyEquivalent: "")
            menuItem.target = self
            menuItem.tag = index
            menuItem.isEnabled = item.enabled
            if item.detail {
                menuItem.attributedTitle = NSAttributedString(string: item.title, attributes: [
                    .font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor])
            }
            menu.addItem(menuItem)
        }
        // Synchronous: the caller keeps `self` alive until the menu closes.
        if let host = (NSApplication.shared.keyWindow as? FleetMenuPanel)?.hostingView, frame != .zero {
            let flipped = host.isFlipped
            let point = NSPoint(x: frame.minX, y: flipped ? frame.maxY + 3 : host.bounds.height - frame.maxY - 3)
            menu.popUp(positioning: nil, at: point, in: host)
        } else {
            menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
        }
    }

    @objc private func run(_ sender: NSMenuItem) {
        items[sender.tag]?.action()
    }
}

struct LimitWindowLine: View {
    let window: ProviderLimitWindow
    let status: ProviderStatus
    var isActive = true
    var showsLabel = true
    @State private var isResetHovered = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 7) {
            // Fixed columns keep periods, values and reset dates aligned across providers.
            labelText
                .foregroundColor(windowColor)
                .lineLimit(1)
                .frame(width: 66, alignment: .leading)

            Text(windowValueText)
                .font(limitWindowFont)
                .foregroundColor(windowColor)
                .frame(width: 34, alignment: .trailing)

            resetCell
                .padding(.leading, 16)

            Spacer(minLength: 0)
        }
    }

    /// Hovering a date shows the remaining time in the same fixed cell; nothing else moves.
    private var resetCell: some View {
        // The date always sets the cell size; the countdown is only an overlay on top of it.
        Text(resetText)
            .opacity(showsCountdown ? 0 : 1)
            .overlay(alignment: .leading) {
                if showsCountdown {
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        Text("⏱ " + QuotaResetState(resetAt: window.resetAt, now: context.date).text(now: context.date))
                            .fixedSize()
                    }
                }
            }
        .font(limitWindowFont)
        .foregroundColor(resetColor)
        .lineLimit(1)
        .frame(width: FleetRowMetrics.resetWidth, alignment: .leading)
        .contentShape(Rectangle())
        .onHover { isResetHovered = $0 }
        .transaction { $0.animation = nil }
    }

    /// A qualifier such as "(Fable)" stays smaller than the period it narrows.
    private var labelText: Text {
        guard showsLabel else { return Text("") }
        guard let split = window.label.range(of: " (") else { return Text(window.label).font(limitWindowFont) }
        return Text(window.label[..<split.lowerBound]).font(limitWindowFont)
            + Text(window.label[split.lowerBound...]).font(.system(size: 9, weight: .medium, design: .monospaced))
    }

    private var limitWindowFont: Font {
        .system(size: 11, weight: .medium, design: .monospaced)
    }

    private var blockingWindow: ProviderLimitWindow? {
        guard let windowDuration = durationSeconds(for: window.label) else {
            return nil
        }

        return status.limitWindows
            .filter { candidate in
                guard candidate.id != window.id,
                      candidate.remainingPercent <= 0,
                      let candidateDuration = durationSeconds(for: candidate.label) else {
                    return false
                }
                return candidateDuration > windowDuration
            }
            .min {
                let lhs = durationSeconds(for: $0.label) ?? .greatestFiniteMagnitude
                let rhs = durationSeconds(for: $1.label) ?? .greatestFiniteMagnitude
                return lhs < rhs
            }
    }

    private var windowValueText: String {
        if blockingWindow != nil {
            return "-"
        }
        return "\(window.remainingPercent)%"
    }

    private var showsCountdown: Bool {
        guard isResetHovered, blockingWindow == nil,
              case .upcoming = QuotaResetState(resetAt: window.resetAt, now: Date()) else { return false }
        return true
    }

    private var resetText: String {
        if blockingWindow != nil {
            return "-"
        }
        switch QuotaResetState(resetAt: window.resetAt, now: Date()) {
        case .notReported: return "—"
        case .due: return "due"
        case .upcoming(let date): return "↻ \(formatResetTime(date))"
        }
    }

    private var resetColor: Color {
        if !isActive { return FleetPalette.muted }
        return blockingWindow == nil ? FleetPalette.muted : FleetPalette.faint
    }

    private var windowColor: Color {
        if !isActive { return FleetPalette.muted }
        if blockingWindow != nil {
            return FleetPalette.faint
        }
        if window.remainingPercent <= 10 {
            return FleetPalette.danger
        }
        if window.remainingPercent <= 25 {
            return FleetPalette.warning
        }
        return FleetPalette.value
    }
}

/// Grouped legend: one titled row per topic, aligned in a shared column.
struct LegendSection: View {
    var body: some View {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 10, verticalSpacing: 6) {
            GridRow {
                title("Monitoring")
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 9) {
                        dot(FleetPalette.ready, "Active")
                        dot(FleetPalette.faint, "Paused")
                        dot(FleetPalette.warning, "Error")
                    }
                    Text("1/6 — current limits / saved accounts")
                        .foregroundColor(FleetPalette.muted)
                }
            }
            GridRow {
                title("Quota")
                HStack(spacing: 4) {
                    Text("≥26%").foregroundColor(FleetPalette.value)
                    Text("·").foregroundColor(FleetPalette.muted)
                    Text("11–25% low").foregroundColor(FleetPalette.warning)
                    Text("·").foregroundColor(FleetPalette.muted)
                    Text("≤10% critical").foregroundColor(FleetPalette.danger)
                }
            }
            GridRow {
                title("Marks")
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 9) {
                        legendMark("→", "current account")
                        legendMark("↓", "lowest")
                    }
                    HStack(spacing: 9) {
                        legendMark("×", "sign in")
                        legendMark("?", "unavailable")
                    }
                }
            }
            GridRow {
                title("Reset")
                VStack(alignment: .leading, spacing: 3) {
                    Text("↻ next reset · hover for the time left")
                    HStack(spacing: 9) {
                        legendKey("—", "not reported")
                        legendKey("due", "updates on next check")
                    }
                }
                .foregroundColor(FleetPalette.value)
            }
            GridRow {
                title("Keys")
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 9) { legendKey("⌘R", "refresh"); legendKey("⌘S", "statistics"); legendKey("⌘,", "settings") }
                    HStack(spacing: 9) { legendKey("← →", "tabs"); legendKey("Click", "jump to agent"); legendKey("Esc", "close") }
                }
            }
        }
        .font(.system(size: 10.5, weight: .medium))
        .lineLimit(1)
        .fixedSize()
    }

    private func legendMark(_ mark: String, _ label: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            RowMark(mark: mark, size: 11).frame(width: 10)
            Text(label)
        }
        .foregroundColor(FleetPalette.value)
    }

    private func legendKey(_ key: String, _ label: String) -> some View {
        HStack(spacing: 4) {
            Text(key).foregroundColor(FleetPalette.value)
            Text(label).foregroundColor(FleetPalette.muted)
        }
    }

    private func title(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .semibold))
            .foregroundColor(FleetPalette.label)
            .gridColumnAlignment(.leading)
    }

    private func dot(_ color: Color, _ label: String) -> some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(label).foregroundColor(FleetPalette.value)
        }
    }
}

struct AccountsLegendSection: View {
    struct Account: Hashable {
        let badge: String
        let email: String
        var providers: [String]
    }
    let accounts: [Account]

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("Accounts")
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(FleetPalette.label)
            ForEach(accounts, id: \.self) { account in
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(account.badge).fontWeight(.semibold)
                        Text(account.email.isEmpty ? "email unknown" : account.email)
                            .foregroundColor(account.email.isEmpty ? FleetPalette.muted : FleetPalette.value)
                            .lineLimit(1).truncationMode(.middle)
                    }
                    ForEach(account.providers, id: \.self) { provider in
                        Text("• " + provider).foregroundColor(FleetPalette.muted).padding(.leading, 14)
                    }
                }
            }
        }
        .font(.system(size: 10.5, weight: .medium))
    }
}

struct HeaderIconButton: View {
    let systemName: String
    let help: String
    var spinning = false
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            icon
                .frame(width: 22, height: 22)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color.primary.opacity(isHovered ? 0.10 : 0))
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(PlainButtonStyle())
        .help(help)
        .accessibilityLabel(help)
        .onHover { isHovered = $0 }
    }

    @ViewBuilder private var icon: some View {
        let image = Image(systemName: systemName)
            .font(.system(size: 12.5, weight: .medium))
            .foregroundColor(FleetPalette.muted)
        if #available(macOS 15.0, *) {
            image.symbolEffect(.rotate.byLayer, options: .repeat(.continuous), isActive: spinning)
        } else if spinning {
            ProgressView().controlSize(.mini)
        } else {
            image
        }
    }
}

struct FleetDivider: View {
    var body: some View {
        Rectangle()
            .fill(FleetPalette.divider)
            .frame(height: 1)
            .padding(.horizontal, 16)
    }
}

private enum FleetPalette {
    static let background = Color(nsColor: .windowBackgroundColor)
    static let border = Color(nsColor: .separatorColor)
    static let divider = Color(nsColor: .separatorColor)
    static let label = Color.secondary
    static let value = Color.primary
    static let command = Color.primary
    static let hoverCommand = Color.primary
    static let muted = Color.secondary
    static let faint = Color(nsColor: .tertiaryLabelColor)
    static let ready = Color(nsColor: .systemGreen)
    static let warning = Color(nsColor: .systemOrange)
    static let danger = Color(nsColor: .systemRed)
    static let page = Color.primary.opacity(0.07)
}

private func rowColor(for status: ProviderStatus) -> Color {
    if status.authentication.needsAccess || status.authentication == .notInstalled { return FleetPalette.faint }
    if status.authentication == .unknown { return FleetPalette.muted }
    if let remaining = status.remainingPercent {
        if remaining <= 10 { return FleetPalette.danger }
        if remaining <= 25 { return FleetPalette.warning }
    }
    return FleetPalette.value
}

/// Today's resets show only the time; other days add the date: `10:58`, `9 Nov 10:58`.
func formatResetTime(_ date: Date, now: Date = Date(), calendar: Calendar = .autoupdatingCurrent) -> String {
    let time = date.formatted(.dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits))
    if calendar.isDate(date, inSameDayAs: now) { return time }
    return date.formatted(.dateTime.day().month(.abbreviated)) + " " + time
}
