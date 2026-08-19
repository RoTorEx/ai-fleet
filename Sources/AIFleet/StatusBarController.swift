import AppKit
import Carbon.HIToolbox
import SwiftUI

@MainActor
final class StatusBarController: NSObject, NSPopoverDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: 18)
    private let popover = NSPopover()
    private let openSettings: (NSRect?) -> Void
    private var globalClickMonitor: Any?
    private var localEventMonitor: Any?

    init(service: StatusService, openSettings: @escaping (NSRect?) -> Void) {
        self.openSettings = openSettings
        super.init()

        if let button = statusItem.button {
            button.image = Self.makeStatusImage()
            button.imagePosition = .imageOnly
            button.imageScaling = .scaleNone
            button.toolTip = "AI Fleet (Command-Shift-I)"
            button.target = self
            button.action = #selector(statusItemClicked)
        }

        let content = AIFleetMenuView { [weak self] in
            guard let self else { return }
            self.openSettings(self.popoverScreenFrame)
        }
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

    private func closePopover() {
        popover.close()
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
               !self.isEventInsideSettingsWindow(event) {
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

    private func isEventInsideSettingsWindow(_ event: NSEvent) -> Bool {
        event.window?.identifier?.rawValue == "ai-fleet-settings"
    }

    private var popoverScreenFrame: NSRect? {
        popover.contentViewController?.view.window?.frame
    }

    private static func makeStatusImage() -> NSImage? {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { rect in
            NSColor.black.setFill()
            let scale = min(rect.width, rect.height) / 64
            let scaleTransform = AffineTransform(scaleByX: scale, byY: scale)
            let translateTransform = AffineTransform(
                translationByX: rect.midX - 32 * scale,
                byY: rect.midY - 32 * scale
            )

            for path in makeClipperPaths() {
                path.transform(using: scaleTransform)
                path.transform(using: translateTransform)
                path.fill()
            }
            return true
        }
        image.isTemplate = true
        return image
    }

    private static func makeClipperPaths() -> [NSBezierPath] {
        [
            polygon([
                svgPoint(x: 31, y: 5),
                svgPoint(x: 34, y: 5),
                svgPoint(x: 34, y: 43),
                svgPoint(x: 58, y: 43),
                svgPoint(x: 47, y: 56),
                svgPoint(x: 17, y: 56),
                svgPoint(x: 6, y: 43),
                svgPoint(x: 31, y: 43)
            ]),
            polygon([
                svgPoint(x: 37, y: 14),
                svgPoint(x: 37, y: 27),
                svgPoint(x: 53, y: 27)
            ]),
            polygon([
                svgPoint(x: 37, y: 31),
                svgPoint(x: 37, y: 40),
                svgPoint(x: 55, y: 40),
                svgPoint(x: 48, y: 31)
            ]),
            polygon([
                svgPoint(x: 28, y: 13),
                svgPoint(x: 10, y: 40),
                svgPoint(x: 28, y: 40)
            ]),
            polygon([
                svgPoint(x: 19, y: 47),
                svgPoint(x: 22, y: 51),
                svgPoint(x: 42, y: 51),
                svgPoint(x: 46, y: 47)
            ])
        ]
    }

    private static func svgPoint(x: CGFloat, y: CGFloat) -> NSPoint {
        NSPoint(x: x, y: 64 - y)
    }

    private static func polygon(_ points: [NSPoint]) -> NSBezierPath {
        let path = NSBezierPath()
        guard let first = points.first else { return path }
        path.move(to: first)
        for point in points.dropFirst() {
            path.line(to: point)
        }
        path.close()
        return path
    }
}

private extension NSEvent.EventType {
    var isMouseDown: Bool {
        self == .leftMouseDown || self == .rightMouseDown || self == .otherMouseDown
    }
}
