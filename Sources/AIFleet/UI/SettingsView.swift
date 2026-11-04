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
        VStack(alignment: .leading, spacing: 16) {
            Picker("Settings", selection: $navigation.tab) {
                Text("General").tag("general")
                Text("Accounts").tag("accounts")
            }.pickerStyle(.segmented)
            ScrollView {
                if navigation.tab == "accounts" { AccountsSettingsView() }
                else { generalSettings }
            }
        }
        .padding(20)
        .frame(width: 500, height: 640)
        .onAppear {
            service.refreshNotificationSettings()
            service.refresh()
        }
    }

    private var generalSettings: some View {
        VStack(alignment: .leading, spacing: 16) {
            settingsRow("Menu shortcut") {
                HotkeyRecorder(settings: settings)
            }

            settingsRow("Notifications") {
                VStack(alignment: .leading, spacing: 8) {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(settings.notificationThresholds, id: \.self) { threshold in
                            HStack(spacing: 8) {
                                Text("\(threshold)% remaining")
                                    .font(.system(size: 11.5, weight: .medium))
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
                        .font(.system(size: 10.5))
                        .foregroundColor(.secondary)

                    HStack(spacing: 8) {
                        Text(service.notificationStatusText)
                            .font(.system(size: 10.5, weight: .medium))
                            .foregroundColor(service.notificationsEnabled ? .secondary : .red)
                        Button("Test") {
                            service.refreshNotificationSettings()
                            service.sendTestNotification()
                        }
                        .font(.system(size: 10.5, weight: .semibold))
                        Button("System") {
                            openNotificationSettings()
                        }
                        .font(.system(size: 10.5, weight: .semibold))
                    }
                }
            }

            settingsRow("Statistics") {
                VStack(alignment: .leading, spacing: 7) {
                    Toggle("Refresh daily", isOn: $settings.analyticsAutoRefreshEnabled)
                        .font(.system(size: 11.5, weight: .medium))

                    HStack(spacing: 8) {
                        Text("Local time")
                            .font(.system(size: 10.5))
                            .foregroundColor(.secondary)
                        DatePicker(
                            "",
                            selection: analyticsRefreshTimeBinding,
                            displayedComponents: .hourAndMinute
                        )
                        .labelsHidden()
                        .disabled(!settings.analyticsAutoRefreshEnabled)
                    }

                    Text("Runs quietly in the background and reuses unchanged session files.")
                        .font(.system(size: 10.5))
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func settingsRow<Content: View>(
        _ title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(.secondary)
                .frame(width: 110, alignment: .leading)
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
                        .font(.system(size: 11.5, weight: .medium, design: .monospaced))
                        .textFieldStyle(RoundedBorderTextFieldStyle())
                        .frame(width: 72)
                        .onSubmit(addThresholdFromInput)

                    Text("% remaining")
                        .font(.system(size: 10.5))
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
