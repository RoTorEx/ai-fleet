import AppKit
import Carbon.HIToolbox
import SwiftUI

@MainActor
final class SettingsNavigation: ObservableObject {
    static let shared = SettingsNavigation()
    @Published var tab = "general"
    @Published var addingProviderID: String?
    @Published var codingPlanAccountID: String?

    func addAccount(for providerID: String) {
        addingProviderID = providerID
        tab = "accounts"
    }

    func editCodingPlan(for accountID: String) {
        codingPlanAccountID = accountID
        tab = "accounts"
    }
}

struct SettingsView: View {
    @ObservedObject var settings = AppSettings.shared
    @ObservedObject var service = StatusService.shared
    @ObservedObject private var navigation = SettingsNavigation.shared
    @State private var newThresholdText = ""
    @State private var isAddingThreshold = false
    @FocusState private var thresholdInputFocused: Bool
    @State private var sounds: [NotificationSoundChoice] = [.silent, .systemDefault]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Picker("Settings", selection: $navigation.tab) {
                Text("General").tag("general")
                Text("Accounts").tag("accounts")
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 240)
            .frame(maxWidth: .infinity)
            .padding(.top, 14)
            .padding(.bottom, 6)
            if navigation.tab == "accounts" {
                AccountsSettingsView().padding(.horizontal, 20).padding(.vertical, 12)
            } else {
                generalSettings
            }
        }
        .frame(width: 520, height: 620)
        .onAppear {
            sounds = NotificationSounds.choices()
            service.refreshNotificationSettings()
            service.refresh()
        }
    }

    private var generalSettings: some View {
        Form {
            Section {
                LabeledContent("Open menu") { HotkeyRecorder(settings: settings) }
                Toggle(isOn: $settings.menuClosesOnOutsideClick) {
                    Text("Close on outside click")
                    Text("When off, the menu stays open until Esc, the menu bar icon or the shortcut.")
                }
            } header: { Text("Menu") }

            Section {
                Toggle("Hide signed-out accounts", isOn: $settings.hideSignedOutAccounts)
                    .help("Hide rows that need sign-in in the Providers tab")
                ForEach(ProviderCatalog.all.sorted { $0.name < $1.name }) { provider in
                    Toggle(provider.name, isOn: Binding(
                        get: { settings.isEnabled(provider.id) },
                        set: { settings.setEnabled($0, for: provider.id); service.refresh() }
                    ))
                }
            } header: { Text("Providers in menu") }

            Section {
                ForEach(["codex", "claude"], id: \.self) { provider in
                    SwitchPolicyPicker(provider: provider, title: provider.capitalized)
                }
            } header: { Text("Switching") } footer: {
                Text("What happens to running sessions when you switch account.")
            }

            Section {
                Toggle(isOn: $settings.agentNotificationsEnabled) {
                    Text("Agent session alerts")
                    Text("Get notified when a reply is ready or an agent needs your input, even with the menu closed.")
                }
                Toggle(isOn: $settings.agentNotificationsShowText) {
                    Text("Show message text in alerts")
                    Text("Adds your request and the agent's reply to each alert. macOS stores notification text and can show it on the lock screen and while sharing your screen.")
                }
                .disabled(!settings.agentNotificationsEnabled)
                ForEach(NotificationSoundEvent.allCases) { event in
                    notificationSound(event)
                }
                quotaThresholds
                LabeledContent("Permission") {
                    HStack(spacing: 8) {
                        Text(service.notificationStatusText)
                            .foregroundStyle(service.notificationsEnabled ? Color.secondary : FleetPalette.danger)
                        Button("Test") {
                            service.refreshNotificationSettings()
                            service.sendTestNotification()
                        }
                        Button("System Settings…", action: openNotificationSettings)
                    }
                    .controlSize(.small)
                }
            } header: { Text("Notifications") } footer: {
                Text("Sound choices apply to every provider. Fleet detects session alerts in Codex, Claude, Kimi and Antigravity in iTerm2. Session sounds are unavailable for Qwen, Gemini, Grok and GLM. Quota warnings use reported account limits.")
            }

            Section {
                Toggle("Refresh daily", isOn: $settings.analyticsAutoRefreshEnabled)
                DatePicker("At", selection: analyticsRefreshTimeBinding, displayedComponents: .hourAndMinute)
                    .disabled(!settings.analyticsAutoRefreshEnabled)
            } header: { Text("Statistics") } footer: {
                Text("Runs quietly in the background and rereads only changed session files.")
            }
        }
        .formStyle(.grouped)
    }

    private func notificationSound(_ event: NotificationSoundEvent) -> some View {
        let choice = NotificationSounds.choice(for: event, selectedID: settings.notificationSoundIDs[event.rawValue], in: sounds)
        return LabeledContent(event.title) {
            HStack(spacing: 8) {
                NotificationSoundPicker(choices: sounds, selectedID: choice.id, label: "\(event.title) sound") {
                    settings.setNotificationSound($0, for: event)
                }
                .frame(width: 184, height: 22)
                Button {
                    NotificationSounds.playPreview(choice)
                } label: {
                    Image(systemName: "speaker.wave.2")
                }
                .help("Preview \(event.title.lowercased()) sound")
                .accessibilityLabel("Preview \(event.title.lowercased()) sound")
                .disabled(choice.id == NotificationSoundChoice.silent.id)
            }
        }
    }

    private var quotaThresholds: some View {
        HStack(spacing: 16) {
            Text("Quota alert at")
                .fixedSize()
                .frame(minHeight: 19)
            HStack(spacing: 8) {
                QuotaThresholdLayout { thresholdChips }
                    .frame(maxWidth: .infinity, alignment: .trailing)
                addThresholdControl
            }
        }
    }

    private var thresholdChips: some View {
        ForEach(settings.notificationThresholds, id: \.self) { threshold in
            HStack(spacing: 3) {
                Text("\(threshold)%").monospacedDigit()
                if settings.notificationThresholds.count > 1 {
                    Button {
                        settings.removeNotificationThreshold(threshold)
                        service.resetNotificationThresholdState()
                    } label: {
                        Image(systemName: "xmark").font(.system(size: 8, weight: .bold))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help("Remove \(threshold)%")
                }
            }
            .font(.system(size: 11.5, weight: .medium))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .frame(minHeight: 19)
            .background(Color.primary.opacity(0.08), in: Capsule())
            .fixedSize()
        }
    }

    private var analyticsRefreshTimeBinding: Binding<Date> {
        Binding(
            get: { settings.analyticsRefreshTime() },
            set: { settings.setAnalyticsRefreshTime($0) }
        )
    }

    private func openNotificationSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension") else {
            return
        }
        NSWorkspace.shared.open(url)
    }

    private var addThresholdControl: some View {
        HStack(spacing: 4) {
            if isAddingThreshold {
                TextField("Threshold percentage", text: $newThresholdText, prompt: Text("%"))
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 44)
                    .focused($thresholdInputFocused)
                    .onAppear { thresholdInputFocused = true }
                    .onSubmit(addThresholdFromInput)
                    .onExitCommand { isAddingThreshold = false }
                Button(action: addThresholdFromInput) {
                    Image(systemName: "checkmark.circle")
                }
                .buttonStyle(.plain)
                .help("Save threshold")
                .disabled(parsedNewThreshold == nil)
            }
            Button {
                newThresholdText = ""
                isAddingThreshold.toggle()
            } label: {
                Image(systemName: isAddingThreshold ? "xmark.circle" : "plus.circle")
            }
            .buttonStyle(.plain)
            .help(isAddingThreshold ? "Cancel threshold entry" : "Add threshold")
            .keyboardShortcut(isAddingThreshold ? .cancelAction : nil)
        }
        .controlSize(.small)
        .frame(minHeight: 19)
        .fixedSize()
    }

    private var parsedNewThreshold: Int? {
        let trimmed = newThresholdText
            .replacingOccurrences(of: "%", with: "")
            .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
        guard let value = Int(trimmed) else { return nil }
        let clamped = max(0, min(100, value))
        guard !settings.notificationThresholds.contains(clamped) else { return nil }
        return clamped
    }

    private func addThresholdFromInput() {
        guard let threshold = parsedNewThreshold else { return }
        settings.addNotificationThreshold(threshold)
        service.resetNotificationThresholdState()
        newThresholdText = ""
        isAddingThreshold = false
    }
}

private struct NotificationSoundPicker: NSViewRepresentable {
    let choices: [NotificationSoundChoice]
    let selectedID: String
    let label: String
    let onSelect: (String) -> Void

    final class Coordinator: NSObject {
        var onSelect: ((String) -> Void)?

        @objc func selectSound(_ button: NSPopUpButton) {
            if let id = button.selectedItem?.representedObject as? String {
                onSelect?(id)
            }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSPopUpButton {
        let button = NSPopUpButton(frame: .zero, pullsDown: false)
        button.bezelStyle = .rounded
        button.alignment = .left
        button.cell?.lineBreakMode = .byTruncatingTail
        button.target = context.coordinator
        button.action = #selector(Coordinator.selectSound)
        button.setAccessibilityLabel(label)
        return button
    }

    func updateNSView(_ button: NSPopUpButton, context: Context) {
        context.coordinator.onSelect = onSelect
        if button.itemArray.compactMap({ $0.representedObject as? String }) != choices.map(\.id) {
            button.removeAllItems()
            for choice in choices {
                button.addItem(withTitle: choice.id)
                button.lastItem?.title = choice.title
                button.lastItem?.representedObject = choice.id
            }
        }
        if let index = choices.firstIndex(where: { $0.id == selectedID }) {
            button.selectItem(at: index)
        }
    }
}

private struct QuotaThresholdLayout: Layout {
    private let spacing: CGFloat = 4

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        arrange(subviews, width: proposal.width ?? .infinity).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let frames = arrange(subviews, width: bounds.width).frames
        let rowWidths = Dictionary(frames.map { ($0.minY, $0.maxX) }, uniquingKeysWith: max)
        for (subview, frame) in zip(subviews, frames) {
            let rowWidth = rowWidths[frame.minY, default: frame.maxX]
            subview.place(at: CGPoint(x: bounds.maxX - rowWidth + frame.minX, y: bounds.minY + frame.minY),
                          anchor: .topLeading, proposal: ProposedViewSize(frame.size))
        }
    }

    private func arrange(_ subviews: Subviews, width: CGFloat) -> (size: CGSize, frames: [CGRect]) {
        var frames: [CGRect] = []
        var origin = CGPoint.zero
        var rowHeight: CGFloat = 0
        var usedWidth: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if origin.x > 0, origin.x + size.width > width {
                origin = CGPoint(x: 0, y: origin.y + rowHeight + spacing)
                rowHeight = 0
            }
            let frame = CGRect(origin: origin, size: size)
            frames.append(frame)
            origin.x = frame.maxX + spacing
            usedWidth = max(usedWidth, frame.maxX)
            rowHeight = max(rowHeight, size.height)
        }
        return (CGSize(width: usedWidth.rounded(.up), height: origin.y + rowHeight), frames)
    }
}

struct HotkeyRecorder: View {
    @ObservedObject var settings: AppSettings
    @State private var recording = false
    @State private var monitor: Any?

    var body: some View {
        Button(action: toggleRecording) {
            Text(recording ? "Type shortcut…" : settings.hotkey.displayString)
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color.primary.opacity(recording ? 0.16 : 0.08))
                )
        }
        .buttonStyle(PlainButtonStyle())
        .onDisappear(perform: stopRecording)
    }

    private func toggleRecording() {
        recording ? stopRecording() : startRecording()
    }

    private func startRecording() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
        recording = true
        settings.isRecordingHotkey = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            // Escape cancels recording.
            if event.keyCode == UInt16(kVK_Escape) {
                stopRecording()
                return nil
            }

            let carbon = carbonModifiers(from: event.modifierFlags)
            // Require a non-shift modifier so plain typing can't become a hotkey.
            guard carbon & ~(UInt32(shiftKey)) != 0 else {
                return nil
            }

            let key = event.charactersIgnoringModifiers?.uppercased() ?? "?"
            settings.hotkey = HotkeyCombo(
                keyCode: UInt32(event.keyCode),
                carbonModifiers: carbon,
                keyDisplay: key
            )
            stopRecording()
            return nil
        }
    }

    private func stopRecording() {
        recording = false
        if let monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
        settings.isRecordingHotkey = false
    }
}

struct SwitchPolicyPicker: View {
    let provider: String
    let title: String
    @State private var policy = SwitchPolicy.nextLaunch
    var body: some View {
        Picker(title, selection: $policy) {
            ForEach(SwitchPolicy.allCases) { Text($0.title).tag($0) }
        }
        .onAppear { policy = SwitchCoordinator.policy(provider) }
        .onChange(of: policy) { UserDefaults.standard.set($0.rawValue, forKey: "switch.policy.\(provider)") }
    }
}
