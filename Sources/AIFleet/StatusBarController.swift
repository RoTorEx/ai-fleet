import AppKit
import Carbon.HIToolbox
import SwiftUI
import Combine

@MainActor
final class FleetMenuScreen: ObservableObject {
    @Published var showsAgents = false
    @Published var agentsSection = "Sessions"
}

private struct FleetMenuRoot: View {
    @ObservedObject var screen: FleetMenuScreen
    @ObservedObject var agents: AgentSessionsService
    let service: StatusService
    let openSettings: () -> Void
    let openStatistics: () -> Void
    let toggleAgents: () -> Void
    let openProcesses: () -> Void

    var body: some View {
        Group {
            if screen.showsAgents {
                AgentsView(service: agents, back: toggleAgents, section: $screen.agentsSection)
            } else {
                AIFleetMenuView(openSettings: openSettings, openStatistics: openStatistics, openAgents: toggleAgents, openProcesses: openProcesses, agents: agents)
                    .environmentObject(service)
                    .environmentObject(AppSettings.shared)
            }
        }.fixedSize(horizontal: false, vertical: true)
    }
}

@MainActor
final class StatusBarController: NSObject {
    private let statusItem = NSStatusBar.system.statusItem(withLength: 18)
    private let panel = FleetMenuPanel()
    private var sizeObservation: AnyCancellable?
    private let openSettings: (NSRect?) -> Void
    private let openStatistics: (NSRect?) -> Void
    private var globalClickMonitor: Any?
    private var localEventMonitor: Any?
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
        super.init()

        if let button = statusItem.button {
            button.image = FleetIcon.menuBarImage()
            button.imagePosition = .imageOnly
            button.imageScaling = .scaleNone
            button.toolTip = "AI Fleet (\(AppSettings.shared.hotkey.displayString))"
            button.target = self
            button.action = #selector(statusItemClicked)
        }

        let content = FleetMenuRoot(
            screen: screen,
            agents: agents,
            service: service,
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
            },
            toggleAgents: { [weak self] in self?.toggleAgents() },
            openProcesses: { [weak self] in
                self?.screen.agentsSection = "Processes"
                self?.screen.showsAgents = true
                self?.agents.stop()
            }
        )
        let hostingController = NSHostingController(rootView: content)
        hostingController.sizingOptions = [.preferredContentSize]

        let backdrop = NSVisualEffectView()
        backdrop.material = .popover
        backdrop.blendingMode = .behindWindow
        backdrop.state = .active
        backdrop.wantsLayer = true
        backdrop.layer?.cornerRadius = 12
        backdrop.layer?.masksToBounds = true
        panel.contentView = backdrop
        let hosted = hostingController.view
        hosted.translatesAutoresizingMaskIntoConstraints = false
        backdrop.addSubview(hosted)
        NSLayoutConstraint.activate([
            hosted.leadingAnchor.constraint(equalTo: backdrop.leadingAnchor),
            hosted.trailingAnchor.constraint(equalTo: backdrop.trailingAnchor),
            hosted.topAnchor.constraint(equalTo: backdrop.topAnchor),
            hosted.bottomAnchor.constraint(equalTo: backdrop.bottomAnchor)
        ])
        sizeObservation = hostingController.publisher(for: \.preferredContentSize)
            .sink { [weak self] size in
                DispatchQueue.main.async { self?.resizePanel(to: size) }
            }
        // Retain the controller for SwiftUI's content-size observation.
        panel.hostingController = hostingController

    }

    func togglePopover() {
        if panel.isVisible {
            closePopover()
        } else {
            showPopover()
        }
    }

    private func didCloseMenu() {
        statusItem.button?.highlight(false)
        stopClickMonitor()
        agents.stop()
        agentsHotKey?.unregister()
        agentsHotKey = nil
        screen.showsAgents = false
    }

    func toggleAgents() {
        screen.showsAgents = false
        screen.agentsSection = "Sessions"
        agents.start()
        // Jump transfers focus to iTerm2. The same shortcut brings the menu back.
        NSApplication.shared.activate(ignoringOtherApps: true)
        panel.makeKey()
    }

    @objc private func statusItemClicked() {
        togglePopover()
    }

    private func showPopover() {
        guard let button = statusItem.button else {
            return
        }
        // Activate so the panel becomes key and its buttons receive clicks.
        NSApplication.shared.activate(ignoringOtherApps: true)
        resizePanel(to: panel.hostingController?.preferredContentSize ?? NSSize(width: 320, height: 400))
        panel.makeKeyAndOrderFront(nil)
        button.highlight(true)
        StatusService.shared.refresh()
        if !screen.showsAgents { agents.start() }
        startClickMonitor()
        agentsHotKey = GlobalHotKey(keyCode: UInt32(kVK_ANSI_A), modifiers: UInt32(cmdKey), id: 2) { [weak self] in
            self?.toggleAgents()
        }
    }

    func closePopoverIfNeeded() {
        if panel.isVisible {
            closePopover()
        }
    }

    private func closePopover(immediately: Bool = false) {
        panel.orderOut(nil)
        didCloseMenu()
    }

    private func startClickMonitor() {
        stopClickMonitor()
        globalClickMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        ) { [weak self] _ in
            Task { @MainActor in
                if AppSettings.shared.closeMenuOnOutsideClick { self?.closePopover() }
            }
        }

        localEventMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown, .keyDown]
        ) { [weak self] event in
            guard let self else {
                return event
            }

            if event.type == .keyDown, event.keyCode == UInt16(kVK_Escape) {
                if event.window?.identifier?.rawValue == "ai-fleet-child-popover" { return event }
                self.closePopover()
                return nil
            }

            if !self.screen.showsAgents, event.type == .keyDown,
               event.keyCode == UInt16(kVK_ANSI_R),
               event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command {
                StatusService.shared.refresh(); CodexMonitoringStore.shared.refresh(force: true); self.agents.refresh(force: true)
                return nil
            }

            // Carbon can also deliver a local key event. Use one route per press.
            if self.agentsHotKey == nil, event.type == .keyDown, event.keyCode == UInt16(kVK_ANSI_A),
               event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command {
                self.toggleAgents()
                return nil
            }

            if AppSettings.shared.closeMenuOnOutsideClick, event.type.isMouseDown,
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
        let popoverWindow = panel
        return event.window === popoverWindow || event.window?.identifier?.rawValue == "ai-fleet-child-popover"
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

    private func resizePanel(to contentSize: NSSize) {
        guard contentSize.width > 0, contentSize.height > 0,
              let button = statusItem.button, let window = button.window else { return }
        let anchor = window.convertToScreen(button.convert(button.bounds, to: nil))
        let visible = window.screen?.visibleFrame ?? NSScreen.main!.visibleFrame
        let size = NSSize(width: min(contentSize.width, visible.width), height: min(contentSize.height, visible.height - 8))
        let x = min(max(visible.minX + 4, anchor.midX - size.width / 2), visible.maxX - size.width - 4)
        panel.setFrame(NSRect(x: x, y: anchor.minY - size.height - 5, width: size.width, height: size.height), display: true, animate: false)
    }

    private var popoverScreenFrame: NSRect? {
        panel.frame
    }

}

private extension NSEvent.EventType {
    var isMouseDown: Bool {
        self == .leftMouseDown || self == .rightMouseDown || self == .otherMouseDown
    }
}

/// An arrow-free, instantly presented menu using the system's adaptive material.
final class FleetMenuPanel: NSPanel {
    var hostingController: NSViewController?
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    init() {
        super.init(contentRect: .zero, styleMask: [.borderless], backing: .buffered, defer: false)
        identifier = NSUserInterfaceItemIdentifier("ai-fleet-menu")
        title = "AI Fleet"
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        level = .popUpMenu
        animationBehavior = .none
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
    }
}
