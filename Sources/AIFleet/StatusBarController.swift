import AppKit
import Carbon.HIToolbox
import SwiftUI

@MainActor
final class FleetMenuScreen: ObservableObject {
    @Published var showsAgents = false
}

struct FleetMenuRoot: View {
    @ObservedObject var screen: FleetMenuScreen
    @ObservedObject var agents: AgentSessionsService
    let service: StatusService
    let openSettings: () -> Void
    let openStatistics: () -> Void
    let toggleAgents: () -> Void

    var body: some View {
        Group {
            if screen.showsAgents {
                AgentsView(service: agents, back: toggleAgents)
            } else {
                AIFleetMenuView(openSettings: openSettings, openStatistics: openStatistics, openAgents: toggleAgents)
                    .environmentObject(service)
                    .environmentObject(AppSettings.shared)
            }
        }.fixedSize(horizontal: false, vertical: true)
    }
}

/// Borderless menu window: no popover arrow and no open/close animation. On
/// macOS 26+ it uses the same glass as native menu-bar menus; older systems get
/// menu blur with a hairline outline.
final class FleetMenuPanel: NSPanel {
    static let cornerRadius: CGFloat = 12
    static let gap: CGFloat = 5
    static let screenMargin: CGFloat = 8

    let hostingView: NSView

    init(content: NSView) {
        hostingView = content
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        level = .popUpMenu
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        animationBehavior = .none
        collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary, .transient, .ignoresCycle]

        content.translatesAutoresizingMaskIntoConstraints = true
        content.autoresizingMask = [.width, .height]
        if #available(macOS 26.0, *) {
            let glass = NSGlassEffectView()
            glass.style = .regular
            glass.cornerRadius = Self.cornerRadius
            glass.contentView = content
            contentView = glass
        } else {
            let effect = NSVisualEffectView()
            effect.material = .menu
            effect.blendingMode = .behindWindow
            effect.state = .active
            effect.maskImage = Self.roundedMask(radius: Self.cornerRadius)
            effect.addSubview(content)
            let outline = MenuPanelOutline()
            outline.autoresizingMask = [.width, .height]
            effect.addSubview(outline)
            contentView = effect
        }
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    func layout(contentSize: NSSize, below anchor: NSRect, in visibleFrame: NSRect) {
        setFrame(Self.frame(contentSize: contentSize, below: anchor, in: visibleFrame), display: true)
        hostingView.frame = hostingView.superview?.bounds ?? hostingView.frame
        invalidateShadow()
    }

    /// Centers the panel under the status item and keeps it inside the visible screen.
    static func frame(contentSize: NSSize, below anchor: NSRect, in visibleFrame: NSRect) -> NSRect {
        let width = min(contentSize.width, visibleFrame.width - 2 * screenMargin)
        let height = min(contentSize.height, anchor.minY - gap - visibleFrame.minY - screenMargin)
        var x = anchor.midX - width / 2
        x = min(max(x, visibleFrame.minX + screenMargin), visibleFrame.maxX - screenMargin - width)
        return NSRect(x: x.rounded(), y: (anchor.minY - gap - height).rounded(), width: width, height: height)
    }

    private static func roundedMask(radius: CGFloat) -> NSImage {
        let side = radius * 2 + 1
        let image = NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            return true
        }
        image.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
        image.resizingMode = .stretch
        return image
    }
}

private final class MenuPanelOutline: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        let radius = FleetMenuPanel.cornerRadius
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: radius - 0.5, yRadius: radius - 0.5)
        path.lineWidth = 1
        let dark = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        NSColor(white: dark ? 1 : 0, alpha: dark ? 0.18 : 0.12).setStroke()
        path.stroke()
    }

    override func viewDidChangeEffectiveAppearance() {
        needsDisplay = true
    }
}

@MainActor
final class StatusBarController: NSObject {
    private let statusItem = NSStatusBar.system.statusItem(withLength: 18)
    private let hostingController: NSHostingController<FleetMenuRoot>
    private let panel: FleetMenuPanel
    private let openSettings: (NSRect?) -> Void
    private let openStatistics: (NSRect?) -> Void
    private var globalClickMonitor: Any?
    private var localEventMonitor: Any?
    private var sizeObservation: NSKeyValueObservation?
    private var lastOutsideDismissal = Date.distantPast
    private let screen = FleetMenuScreen()
    private let agents = AgentSessionsService()
    private var agentsHotKey: GlobalHotKey?

    init(
        service: StatusService,
        openSettings: @escaping (NSRect?) -> Void,
        openStatistics: @escaping (NSRect?) -> Void
    ) {
        self.openSettings = openSettings
        self.openStatistics = openStatistics
        // The root view is built before `self` exists; its actions resolve through this box.
        var actions: (settings: () -> Void, statistics: () -> Void, agents: () -> Void) = ({}, {}, {})
        hostingController = NSHostingController(rootView: FleetMenuRoot(
            screen: screen,
            agents: agents,
            service: service,
            openSettings: { actions.settings() },
            openStatistics: { actions.statistics() },
            toggleAgents: { actions.agents() }
        ))
        hostingController.sizingOptions = [.preferredContentSize]
        panel = FleetMenuPanel(content: hostingController.view)
        super.init()

        actions = (
            settings: { [weak self] in
                guard let self else { return }
                let anchorFrame = self.panel.frame
                self.closePanel()
                DispatchQueue.main.async { [weak self] in
                    self?.openSettings(anchorFrame)
                }
            },
            statistics: { [weak self] in
                guard let self else { return }
                let anchorFrame = self.panel.frame
                self.closePanel()
                DispatchQueue.main.async { [weak self] in
                    self?.openStatistics(anchorFrame)
                }
            },
            agents: { [weak self] in self?.toggleAgents() }
        )

        if let button = statusItem.button {
            button.image = FleetIcon.menuBarImage()
            button.imagePosition = .imageOnly
            button.imageScaling = .scaleNone
            button.toolTip = "AI Fleet (\(AppSettings.shared.hotkey.displayString))"
            button.target = self
            button.action = #selector(statusItemClicked)
        }

        sizeObservation = hostingController.observe(\.preferredContentSize) { [weak self] _, _ in
            Task { @MainActor in self?.layoutPanel() }
        }
    }

    func togglePopover() {
        if panel.isVisible {
            closePanel()
        } else {
            showPanel()
        }
    }

    func toggleAgents() {
        screen.showsAgents.toggle()
        if screen.showsAgents { agents.start() } else { agents.stop() }
        // Jump transfers focus to iTerm2. The same shortcut brings the menu back.
        NSApplication.shared.activate(ignoringOtherApps: true)
        panel.makeKey()
    }

    @objc private func statusItemClicked() {
        // A press on the icon can reach the outside-click monitor before the
        // button action; that press already closed the menu, so don't reopen it.
        if !panel.isVisible, Date().timeIntervalSince(lastOutsideDismissal) < 0.5 {
            return
        }
        togglePopover()
    }

    private func showPanel() {
        guard statusItem.button != nil else {
            return
        }
        StatusService.shared.refresh()

        // Activate so the panel becomes key and its buttons receive clicks.
        NSApplication.shared.activate(ignoringOtherApps: true)
        layoutPanel()
        panel.makeKeyAndOrderFront(nil)
        statusItem.button?.highlight(true)
        startClickMonitor()
        agentsHotKey = GlobalHotKey(keyCode: UInt32(kVK_ANSI_A), modifiers: UInt32(cmdKey), id: 2) { [weak self] in
            self?.toggleAgents()
        }
    }

    private func layoutPanel() {
        guard let button = statusItem.button, let buttonWindow = button.window else {
            return
        }
        let anchor = buttonWindow.convertToScreen(button.convert(button.bounds, to: nil))
        let screen = buttonWindow.screen ?? NSScreen.screens.first(where: { $0.frame.intersects(anchor) }) ?? NSScreen.main
        guard let visibleFrame = screen?.visibleFrame else {
            return
        }
        hostingController.view.layoutSubtreeIfNeeded()
        var size = hostingController.preferredContentSize
        if size.width < 1 || size.height < 1 {
            size = hostingController.view.fittingSize
        }
        // The menu bar may be hidden; never anchor above the visible area.
        let top = NSRect(x: anchor.minX, y: min(anchor.minY, visibleFrame.maxY + FleetMenuPanel.gap), width: anchor.width, height: anchor.height)
        panel.layout(contentSize: size, below: top, in: visibleFrame)
    }

    func closePopoverIfNeeded() {
        if panel.isVisible {
            closePanel()
        }
    }

    private func closePanel() {
        guard panel.isVisible else {
            return
        }
        panel.orderOut(nil)
        statusItem.button?.highlight(false)
        stopClickMonitor()
        agents.stop()
        agentsHotKey?.unregister()
        agentsHotKey = nil
        screen.showsAgents = false
    }

    private func startClickMonitor() {
        stopClickMonitor()
        globalClickMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self, AppSettings.shared.menuClosesOnOutsideClick,
                      !self.isMouseOverStatusButton else { return }
                self.dismissOnOutsideClick()
            }
        }

        localEventMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown, .keyDown]
        ) { [weak self] event in
            guard let self else {
                return event
            }

            if event.type == .keyDown, event.keyCode == UInt16(kVK_Escape), NSApplication.shared.modalWindow == nil {
                self.closePanel()
                return nil
            }

            // Carbon can also deliver a local key event. Use one route per press.
            if self.agentsHotKey == nil, event.type == .keyDown, event.keyCode == UInt16(kVK_ANSI_A),
               event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command {
                self.toggleAgents()
                return nil
            }

            if event.type.isMouseDown,
               AppSettings.shared.menuClosesOnOutsideClick,
               NSApplication.shared.modalWindow == nil,
               event.window !== self.panel,
               !self.isMouseOverStatusButton,
               !self.isEventInsideCompanionWindow(event) {
                self.dismissOnOutsideClick()
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

    private func dismissOnOutsideClick() {
        lastOutsideDismissal = Date()
        closePanel()
    }

    /// Screen-space check: status-item clicks may arrive with a window the
    /// monitors cannot match, so compare the pointer with the button frame.
    private var isMouseOverStatusButton: Bool {
        guard let button = statusItem.button, let window = button.window else {
            return false
        }
        let frame = window.convertToScreen(button.convert(button.bounds, to: nil))
        return frame.insetBy(dx: -2, dy: -2).contains(NSEvent.mouseLocation)
    }

    private func isEventInsideCompanionWindow(_ event: NSEvent) -> Bool {
        guard let identifier = event.window?.identifier?.rawValue else {
            return false
        }
        return identifier == "ai-fleet-settings"
    }
}

private extension NSEvent.EventType {
    var isMouseDown: Bool {
        self == .leftMouseDown || self == .rightMouseDown || self == .otherMouseDown
    }
}
