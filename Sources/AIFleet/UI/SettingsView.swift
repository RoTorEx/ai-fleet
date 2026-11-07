import AppKit
import Carbon.HIToolbox
import SwiftUI

@MainActor
final class SettingsNavigation: ObservableObject {
    static let shared = SettingsNavigation()
    @Published var tab = "general"
    @Published var addingProviderID: String?

    func addAccount(for providerID: String) {
        addingProviderID = providerID
        tab = "accounts"
    }
}

struct SettingsView: View {
    @ObservedObject var settings = AppSettings.shared
    @ObservedObject var service = StatusService.shared
    @ObservedObject private var navigation = SettingsNavigation.shared
    @State private var newThreshold = 10
    @State private var newThresholdText = "10"
    @State private var isAddingThreshold = false

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
                LabeledContent("Alert at") {
                    HStack(spacing: 6) {
                        ForEach(settings.notificationThresholds, id: \.self) { threshold in
                            HStack(spacing: 3) {
                                Text("\(threshold)%").monospacedDigit()
                                if settings.notificationThresholds.count > 1 {
                                    Button {
                                        settings.removeNotificationThreshold(threshold)
                                        service.resetNotificationThresholdState()
                                    } label: { Image(systemName: "xmark").font(.system(size: 8, weight: .bold)) }
                                    .buttonStyle(.plain).foregroundStyle(.secondary).help("Remove \(threshold)%")
                                }
                            }
                            .font(.system(size: 11.5, weight: .medium))
                            .padding(.horizontal, 7).padding(.vertical, 2)
                            .background(Color.primary.opacity(0.08), in: Capsule())
                        }
                        addThresholdControl
                    }
                }
                LabeledContent("Permission") {
                    HStack(spacing: 8) {
                        Text(service.notificationStatusText)
                            .foregroundStyle(service.notificationsEnabled ? Color.secondary : Color.red)
                        Button("Test") {
                            service.refreshNotificationSettings()
                            service.sendTestNotification()
                        }
                        Button("System Settings…", action: openNotificationSettings)
                    }
                    .controlSize(.small)
                }
            } header: { Text("Notifications") } footer: {
                Text("An alert fires when an account's remaining quota crosses a threshold.")
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
                TextField("%", text: $newThresholdText)
                    .textFieldStyle(.roundedBorder).frame(width: 44)
                    .onSubmit(addThresholdFromInput)
                    .onExitCommand { isAddingThreshold = false }
            }
            Button {
                if isAddingThreshold { addThresholdFromInput() } else {
                    newThresholdText = "\(newThreshold)"
                    isAddingThreshold = true
                }
            } label: { Image(systemName: isAddingThreshold ? "checkmark.circle" : "plus.circle") }
            .buttonStyle(.plain)
            .help(isAddingThreshold ? "Save threshold" : "Add threshold")
            .disabled(isAddingThreshold && parsedNewThreshold == nil)
        }
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
        newThreshold = threshold
        settings.addNotificationThreshold(threshold)
        service.resetNotificationThresholdState()
        newThresholdText = "\(threshold)"
        isAddingThreshold = false
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
    @State private var policy = SwitchPolicy.graceful
    var body: some View {
        Picker(title, selection: $policy) {
            ForEach(SwitchPolicy.allCases) { Text($0.title).tag($0) }
        }
        .onAppear { policy = SwitchCoordinator.policy(provider) }
        .onChange(of: policy) { UserDefaults.standard.set($0.rawValue, forKey: "switch.policy.\(provider)") }
    }
}
