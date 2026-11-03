import AppKit
import Carbon.HIToolbox
import Combine
import SwiftUI

@main
struct AIFleetApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    init() {
        if CommandLine.arguments.dropFirst().first == "--fleet-provider" {
            let args = Array(CommandLine.arguments.dropFirst(2))
            guard let provider = args.first, ProviderTerminalLaunch.providers.contains(provider) else { exit(1) }
            ProviderTerminalLaunch.run(provider, arguments: Array(args.dropFirst()))
        }
        if CommandLine.arguments.dropFirst().first == "--fleet-codex" {
            CodexTerminalLaunch.run(arguments: Array(CommandLine.arguments.dropFirst(2)))
        }
        if CommandLine.arguments.dropFirst().first == "--fleet-select-codex" {
            let arguments = Array(CommandLine.arguments.dropFirst(2))
            guard arguments.count == 1,
                  let account = AccountStore.shared.accounts.first(where: { $0.id == arguments[0] }) else {
                FileHandle.standardError.write(Data("Choose an existing AI Fleet account UUID.\n".utf8))
                exit(1)
            }
            let store = CodexMonitoringStore.shared
            store.switchAccount(account)
            if let error = store.error {
                FileHandle.standardError.write(Data("AI Fleet: \(error)\n".utf8)); exit(1)
            }
            print("Next Codex launch: \(account.name). Running sessions were not changed.")
            exit(0)
        }
    }

    var body: some Scene {
        Settings {
            SettingsView()
        }.commands {
            CommandGroup(replacing: .appSettings) {
                Button("Settings…") { appDelegate.openSettings() }
                    .keyboardShortcut(",", modifiers: .command)
            }
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusBarController: StatusBarController?
    private var settingsWindowController: SettingsWindowController?
    private var statisticsWindowController: StatisticsWindowController?
    private var settingsShortcutMonitor: Any?
    private var toggleHotKey: GlobalHotKey?
    private var hotkeyObserver: AnyCancellable?
    private var cancellables = Set<AnyCancellable>()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApplication.shared.setActivationPolicy(.accessory)
        ProviderLaunchStore.shared.installCommandIntegration()
        StatusService.shared.start()
        UsageAnalyticsService.shared.startDailyRefreshSchedule()
        CodexMonitoringStore.shared.synchronizeAccounts(AccountStore.shared)
        CodexMonitoringStore.shared.start()

        let statusBarController = StatusBarController(
            service: StatusService.shared,
            openSettings: { [weak self] anchorFrame in
                self?.openSettings(anchorFrame: anchorFrame)
            },
            openStatistics: { [weak self] anchorFrame in
                self?.openStatistics(anchorFrame: anchorFrame)
            }
        )
        self.statusBarController = statusBarController

        hotkeyObserver = AppSettings.shared.$hotkey
            .dropFirst()
            .sink { [weak self] _ in
                if AppSettings.shared.isRecordingHotkey {
                    return
                }
                self?.registerToggleHotKey()
            }
        AppSettings.shared.$isRecordingHotkey
            .dropFirst()
            .sink { [weak self] recording in
                if recording {
                    self?.toggleHotKey?.unregister()
                    self?.toggleHotKey = nil
                } else {
                    self?.registerToggleHotKey()
                }
            }
            .store(in: &cancellables)
        Publishers.CombineLatest(
            AppSettings.shared.$analyticsAutoRefreshEnabled,
            AppSettings.shared.$analyticsRefreshMinutes
        )
        .dropFirst()
        .sink { _ in
            UsageAnalyticsService.shared.rescheduleDailyRefresh()
        }
        .store(in: &cancellables)
        registerToggleHotKey()
        // Consume Cmd-comma before SwiftUI's separate Settings scene handles it.
        settingsShortcutMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == 43,
               event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command {
                self?.openSettings()
                return nil
            }
            return event
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let settingsShortcutMonitor { NSEvent.removeMonitor(settingsShortcutMonitor) }
        AccountStore.shared.cancelCodexSignIn()
        CodexMonitoringStore.shared.stop()
    }

    func openSettings(anchorFrame: NSRect? = nil) {
        statusBarController?.closePopoverIfNeeded()
        NSApplication.shared.activate(ignoringOtherApps: true)
        StatusService.shared.refresh()

        if settingsWindowController == nil {
            settingsWindowController = SettingsWindowController()
        }

        settingsWindowController?.showSettings(relativeTo: anchorFrame)
    }

    func openStatistics(anchorFrame: NSRect? = nil) {
        statusBarController?.closePopoverIfNeeded()
        NSApplication.shared.activate(ignoringOtherApps: true)

        if statisticsWindowController == nil {
            statisticsWindowController = StatisticsWindowController()
        }

        statisticsWindowController?.showStatistics(relativeTo: anchorFrame)
    }

    private func registerToggleHotKey() {
        toggleHotKey?.unregister()
        let hotkey = AppSettings.shared.hotkey
        toggleHotKey = GlobalHotKey(
            keyCode: hotkey.keyCode,
            modifiers: hotkey.carbonModifiers
        ) { [weak self] in
            Task { @MainActor in
                self?.statusBarController?.togglePopover()
            }
        }
    }
}

@MainActor
private final class StatisticsWindowController: NSWindowController {
    private let defaultWindowSize = NSSize(width: 900, height: 650)

    init() {
        let hostingController = NSHostingController(rootView: StatisticsView())
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 650),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "AI Fleet Statistics"
        window.identifier = NSUserInterfaceItemIdentifier("ai-fleet-statistics")
        window.contentViewController = hostingController
        window.minSize = NSSize(width: 820, height: 600)
        window.isReleasedWhenClosed = false
        window.animationBehavior = .none
        super.init(window: window)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    func showStatistics(relativeTo anchorFrame: NSRect?) {
        guard let window else { return }

        placeWindow(window, onScreenContaining: anchorFrame)

        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
    }

    private func sizeWindowToContent(_ window: NSWindow) {
        guard let contentView = window.contentView else { return }
        contentView.layoutSubtreeIfNeeded()
        let fittingSize = contentView.fittingSize
        if fittingSize.width > 0, fittingSize.height > 0 {
            window.setContentSize(fittingSize)
        }
    }

    private func placeWindow(_ window: NSWindow, onScreenContaining anchorFrame: NSRect?) {
        let visibleFrame = anchorFrame.flatMap { anchor in
            NSScreen.screens.first(where: { $0.frame.intersects(anchor) })?.visibleFrame
        }
            ?? window.screen?.visibleFrame
            ?? NSScreen.main?.visibleFrame

        var frame = window.frame
        frame.size = defaultWindowSize
        if let visibleFrame {
            frame = centeredWindowFrame(windowFrame: frame, visibleFrame: visibleFrame)
        }

        window.setFrame(frame, display: true)
    }
}

func centeredWindowFrame(windowFrame: NSRect, visibleFrame: NSRect) -> NSRect {
    var frame = windowFrame
    frame.size.width = min(frame.width, visibleFrame.width)
    frame.size.height = min(frame.height, visibleFrame.height)
    frame.origin.x = visibleFrame.midX - frame.width / 2
    frame.origin.y = visibleFrame.midY - frame.height / 2
    frame.origin.x = max(visibleFrame.minX, min(frame.origin.x, visibleFrame.maxX - frame.width))
    frame.origin.y = max(visibleFrame.minY, min(frame.origin.y, visibleFrame.maxY - frame.height))
    return frame
}

@MainActor
private final class SettingsWindowController: NSWindowController {
    private var didPlaceWindow = false

    init() {
        let hostingController = NSHostingController(rootView: SettingsView())
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 430, height: 300),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "AI Fleet Settings"
        window.identifier = NSUserInterfaceItemIdentifier("ai-fleet-settings")
        window.contentViewController = hostingController
        window.isReleasedWhenClosed = false
        window.animationBehavior = .none
        super.init(window: window)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    func showSettings(relativeTo anchorFrame: NSRect?) {
        guard let window else { return }

        sizeWindowToContent(window)

        if let anchorFrame {
            placeWindow(window, relativeTo: anchorFrame)
        } else if !didPlaceWindow {
            window.center()
            didPlaceWindow = true
        }

        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
    }

    private func sizeWindowToContent(_ window: NSWindow) {
        guard let contentView = window.contentView else { return }
        contentView.layoutSubtreeIfNeeded()
        let fittingSize = contentView.fittingSize
        if fittingSize.width > 0, fittingSize.height > 0 {
            window.setContentSize(fittingSize)
        }
    }

    private func placeWindow(_ window: NSWindow, relativeTo anchorFrame: NSRect) {
        let gap: CGFloat = 36
        let visibleFrame = NSScreen.screens.first(where: { $0.frame.intersects(anchorFrame) })?.visibleFrame
            ?? window.screen?.visibleFrame
            ?? NSScreen.main?.visibleFrame

        var frame = window.frame
        frame.origin.x = anchorFrame.minX - frame.width - gap
        frame.origin.y = anchorFrame.maxY - frame.height

        if let visibleFrame {
            frame.origin.x = max(visibleFrame.minX + gap, min(frame.origin.x, visibleFrame.maxX - frame.width - gap))
            frame.origin.y = max(visibleFrame.minY + gap, min(frame.origin.y, visibleFrame.maxY - frame.height - gap))
        }

        window.setFrame(frame, display: true)
        didPlaceWindow = true
    }
}
