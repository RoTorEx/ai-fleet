import AppKit
import Carbon.HIToolbox
import Combine
import SwiftUI

@main
struct AIFleetApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        Settings {
            SettingsView()
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusBarController: StatusBarController?
    private var settingsWindowController: SettingsWindowController?
    private var statisticsWindowController: StatisticsWindowController?
    private var toggleHotKey: GlobalHotKey?
    private var hotkeyObserver: AnyCancellable?
    private var cancellables = Set<AnyCancellable>()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApplication.shared.setActivationPolicy(.accessory)
        StatusService.shared.start()

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
        registerToggleHotKey()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func openSettings(anchorFrame: NSRect? = nil) {
        NSApplication.shared.activate(ignoringOtherApps: true)

        if settingsWindowController == nil {
            settingsWindowController = SettingsWindowController()
        }

        settingsWindowController?.showSettings(relativeTo: anchorFrame)
    }

    func openStatistics(anchorFrame: NSRect? = nil) {
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
    private var didPlaceWindow = false

    init() {
        let hostingController = NSHostingController(rootView: StatisticsView())
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 340),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "AI Fleet Statistics"
        window.identifier = NSUserInterfaceItemIdentifier("ai-fleet-statistics")
        window.contentViewController = hostingController
        window.isReleasedWhenClosed = false
        super.init(window: window)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    func showStatistics(relativeTo anchorFrame: NSRect?) {
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

@MainActor
private final class SettingsWindowController: NSWindowController {
    private var didPlaceWindow = false

    init() {
        let hostingController = NSHostingController(rootView: SettingsView())
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 380, height: 210),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "AI Fleet Settings"
        window.identifier = NSUserInterfaceItemIdentifier("ai-fleet-settings")
        window.contentViewController = hostingController
        window.isReleasedWhenClosed = false
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
