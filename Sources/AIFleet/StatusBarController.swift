import AppKit
import Carbon.HIToolbox
import SwiftUI

@MainActor
final class StatusBarController: NSObject, NSPopoverDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: 18)
    private let popover = NSPopover()
    private let openSettings: (NSRect?) -> Void
    private let openStatistics: (NSRect?) -> Void
    private var globalClickMonitor: Any?
    private var localEventMonitor: Any?

    init(
        service: StatusService,
        openSettings: @escaping (NSRect?) -> Void,
        openStatistics: @escaping (NSRect?) -> Void
    ) {
        self.openSettings = openSettings
        self.openStatistics = openStatistics
        super.init()

        if let button = statusItem.button {
            button.image = FleetIcon.menuBarImage()
            button.imagePosition = .imageOnly
            button.imageScaling = .scaleNone
            button.toolTip = "AI Fleet (Command-Shift-I)"
            button.target = self
            button.action = #selector(statusItemClicked)
        }

        let content = AIFleetMenuView(
            openSettings: { [weak self] in
                guard let self else { return }
                let anchorFrame = self.popoverScreenFrame
                self.closePopover(immediately: true)
                DispatchQueue.main.async { [weak self] in
                    self?.openSettings(anchorFrame)
                }
            },
            openStatistics: { [weak self] in
                guard let self else { return }
                let anchorFrame = self.popoverScreenFrame
                self.closePopover(immediately: true)
                DispatchQueue.main.async { [weak self] in
                    self?.openStatistics(anchorFrame)
                }
            }
        )
            .environmentObject(service)
            .environmentObject(AppSettings.shared)
            .fixedSize(horizontal: false, vertical: true)
        let hostingController = NSHostingController(rootView: content)
        hostingController.sizingOptions = [.preferredContentSize]

        popover.animates = true
        // .applicationDefined: we control closing (toggle, outside click, Escape).
        // .transient closes on focus stealing, which kills the popover while
        // the user keeps working in another app.
        popover.behavior = .applicationDefined
        popover.contentViewController = hostingController
        popover.delegate = self
    }

    func togglePopover() {
        if popover.isShown {
            closePopover()
        } else {
            showPopover()
        }
    }

    func popoverDidClose(_ notification: Notification) {
        statusItem.button?.highlight(false)
        stopClickMonitor()
    }

    @objc private func statusItemClicked() {
        togglePopover()
    }

    private func showPopover() {
        guard let button = statusItem.button else {
            return
        }
        StatusService.shared.refresh()

        // Activate so the popover becomes key and its buttons receive clicks.
        NSApplication.shared.activate(ignoringOtherApps: true)
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        button.highlight(true)
        startClickMonitor()
    }

    func closePopoverIfNeeded() {
        if popover.isShown {
            closePopover()
        }
    }

    private func closePopover(immediately: Bool = false) {
        let wasAnimated = popover.animates
        if immediately { popover.animates = false }
        popover.performClose(nil)
        if immediately { popover.animates = wasAnimated }
        statusItem.button?.highlight(false)
        stopClickMonitor()
    }

    private func startClickMonitor() {
        stopClickMonitor()
        globalClickMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        ) { [weak self] _ in
            Task { @MainActor in
                self?.closePopover()
            }
        }

        localEventMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown, .keyDown]
        ) { [weak self] event in
            guard let self else {
                return event
            }

            if event.type == .keyDown, event.keyCode == UInt16(kVK_Escape) {
                self.closePopover()
                return nil
            }

            if event.type.isMouseDown,
               !self.isEventInsidePopover(event),
               !self.isEventInsideStatusButton(event),
               !self.isEventInsideCompanionWindow(event) {
                self.closePopover()
            }

            return event
        }
    }

    private func stopClickMonitor() {
        if let globalClickMonitor {
            NSEvent.removeMonitor(globalClickMonitor)
            self.globalClickMonitor = nil
        }

        if let localEventMonitor {
            NSEvent.removeMonitor(localEventMonitor)
            self.localEventMonitor = nil
        }
    }

    private func isEventInsidePopover(_ event: NSEvent) -> Bool {
        guard let popoverWindow = popover.contentViewController?.view.window else {
            return false
        }
        return event.window === popoverWindow
    }

    private func isEventInsideStatusButton(_ event: NSEvent) -> Bool {
        guard let button = statusItem.button,
              event.window === button.window else {
            return false
        }

        let location = button.convert(event.locationInWindow, from: nil)
        return button.bounds.contains(location)
    }

    private func isEventInsideCompanionWindow(_ event: NSEvent) -> Bool {
        guard let identifier = event.window?.identifier?.rawValue else {
            return false
        }
        return identifier == "ai-fleet-settings"
    }

    private var popoverScreenFrame: NSRect? {
        popover.contentViewController?.view.window?.frame
    }

}

private extension NSEvent.EventType {
    var isMouseDown: Bool {
        self == .leftMouseDown || self == .rightMouseDown || self == .otherMouseDown
    }
}
