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
        TabView(selection: $navigation.tab) {
            settingsPage {
                VStack(alignment: .leading, spacing: 18) {
                    generalSettings
                    Divider()
                    providerSettings
                    Divider()
                    statisticsSettings
                    Divider()
                    notificationSettings
                }
            }.tabItem { Text("General") }.tag("general")
            settingsPage { AccountsSettingsView() }.tabItem { Text("Accounts") }.tag("accounts")
        }
        .font(FleetUI.body).padding(12).frame(width: 560, height: 410)
        .onAppear {
            if navigation.tab != "accounts" { navigation.tab = "general" }
            service.refreshNotificationSettings(); service.refresh()
        }
    }

    private func settingsPage<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        ScrollView {
            content().frame(maxWidth: .infinity, alignment: .leading).padding(16)
        }
    }

    private var providerSettings: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Providers").font(FleetUI.title)
            Text("Show providers in the menu. Statistics has its own selection.")
                .font(FleetUI.caption).foregroundStyle(.secondary)
            ForEach(ProviderCatalog.all.sorted { $0.name < $1.name }) { provider in
                settingsRow(provider.name) {
                    Toggle("Show in menu", isOn: Binding(
                        get: { settings.isEnabled(provider.id) },
                        set: { settings.setEnabled($0, for: provider.id); service.refresh() }
                    )).toggleStyle(.checkbox)
                }
            }
        }
    }

    private var generalSettings: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Menu").font(FleetUI.title)
            settingsRow("Outside click") {
                Toggle("Close menu", isOn: $settings.closeMenuOnOutsideClick).toggleStyle(.checkbox)
            }

            settingsRow("Menu shortcut") {
                HotkeyRecorder(settings: settings)
            }

        }
    }

    private var statisticsSettings: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Statistics").font(FleetUI.title)
            settingsRow("Schedule") {
                VStack(alignment: .leading, spacing: 7) {
                    Toggle("Refresh daily", isOn: $settings.analyticsAutoRefreshEnabled)
                        .font(.system(size: 13, weight: .medium))

                    HStack(spacing: 8) {
                        Text("Local time")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                        DatePicker(
                            "",
                            selection: analyticsRefreshTimeBinding,
                            displayedComponents: .hourAndMinute
                        )
                        .labelsHidden().frame(width: 100)
                        .disabled(!settings.analyticsAutoRefreshEnabled)
                    }

                    Text("Runs quietly in the background and reuses unchanged session files.")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private var notificationSettings: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Notifications").font(FleetUI.title)
            settingsRow("Thresholds") {
                VStack(alignment: .leading, spacing: 8) {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(settings.notificationThresholds, id: \.self) { threshold in
                            HStack(spacing: 8) {
                                Text("\(threshold)% remaining")
                                    .font(.system(size: 13, weight: .medium))
                                    .frame(width: 96, alignment: .leading)
                                Button {
                                    settings.removeNotificationThreshold(threshold)
                                    service.resetNotificationThresholdState()
                                } label: {
                                    Image(systemName: "minus.circle")
                                }
                                .buttonStyle(PlainButtonStyle())
                                .help("Remove threshold")
                                .disabled(settings.notificationThresholds.count <= 1)
                            }
                        }
                    }

                    addThresholdControl

                    Text("Alerts fire when remaining quota crosses a threshold.")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)

                    HStack(spacing: 8) {
                        Text(service.notificationStatusText)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(service.notificationsEnabled ? .secondary : .red)
                        Button("Test") {
                            service.refreshNotificationSettings()
                            service.sendTestNotification()
                        }
                        .font(.system(size: 11, weight: .semibold))
                        Button("System") {
                            openNotificationSettings()
                        }
                        .font(.system(size: 11, weight: .semibold))
                    }
                }
            }
        }
    }

    private func settingsRow<Content: View>(
        _ title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text(title)
                .font(FleetUI.body)
                .foregroundColor(.secondary)
                .frame(width: 126, alignment: .leading)
            content()
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
        VStack(alignment: .leading, spacing: 6) {
            Button {
                newThresholdText = "\(newThreshold)"
                isAddingThreshold.toggle()
            } label: {
                Image(systemName: "plus.circle")
                    .font(.system(size: 13, weight: .semibold))
            }
            .buttonStyle(PlainButtonStyle())
            .help("Add threshold")

            if isAddingThreshold {
                HStack(spacing: 8) {
                    TextField("Percent", text: $newThresholdText)
                        .font(.system(size: 13, weight: .medium, design: .monospaced))
                        .textFieldStyle(RoundedBorderTextFieldStyle())
                        .frame(width: 72)
                        .onSubmit(addThresholdFromInput)

                    Text("% remaining")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)

                    Button(action: addThresholdFromInput) {
                        Image(systemName: "checkmark.circle")
                    }
                    .buttonStyle(PlainButtonStyle())
                    .help("Save threshold")
                    .disabled(parsedNewThreshold == nil)

                    Button {
                        isAddingThreshold = false
                    } label: {
                        Image(systemName: "xmark.circle")
                    }
                    .buttonStyle(PlainButtonStyle())
                    .help("Cancel")
                }
            }
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
                .font(.system(size: 13, weight: .medium, design: .monospaced))
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
