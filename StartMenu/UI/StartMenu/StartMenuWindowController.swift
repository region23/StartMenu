import AppKit
import Combine
import SwiftUI

@MainActor
final class StartMenuWindowController {
    private let panel: KeyablePanel
    private let hosting: NSHostingView<StartMenuView>
    private let settingsStore: SettingsStore
    private var globalClickMonitor: Any?
    private var localClickMonitor: Any?
    private var cancellables: Set<AnyCancellable> = []
    private var lastAnchorFrame: NSRect = .zero
    private weak var ignoreClicksInWindow: NSWindow?
    private var pendingHoverDismiss: DispatchWorkItem?
    private let makeRootView: (UUID) -> StartMenuView
    private var presentationID = UUID()
    private var hasMouseEnteredPanel = false

    private static let hoverDismissDelay: TimeInterval = 0.18

    /// Tells the dismiss-on-outside-click logic to leave clicks in this window alone
    /// (used for the bar: the Start button there handles toggling on its own).
    func setIgnoreClicksInWindow(_ window: NSWindow?) {
        ignoreClicksInWindow = window
    }

    private static let baseSize = NSSize(width: 360, height: 520)

    init(
        startMenuService: StartMenuService,
        dockAppsService: DockAppsService,
        appUpdateService: AppUpdateService,
        settingsStore: SettingsStore,
        autostartService: AutostartService,
        onLaunch: @escaping (AppInfo) -> Void,
        onQuit: @escaping () -> Void
    ) {
        self.settingsStore = settingsStore

        panel = KeyablePanel(
            contentRect: NSRect(origin: .zero, size: Self.scaledSize(settingsStore.uiScale)),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .transient, .fullScreenAuxiliary]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = false
        panel.worksWhenModal = true

        let controllerRef = ControllerRef()
        makeRootView = { presentationID in
            StartMenuView(
                startMenuService: startMenuService,
                dockAppsService: dockAppsService,
                appUpdateService: appUpdateService,
                settingsStore: settingsStore,
                autostartService: autostartService,
                presentationID: presentationID,
                onHoverChange: { inside in
                    controllerRef.value?.handleHoverChange(inside)
                },
                onLaunch: { app in
                    onLaunch(app)
                    controllerRef.value?.hide()
                },
                onDismiss: { controllerRef.value?.hide() },
                onQuit: onQuit
            )
        }
        hosting = NSHostingView(rootView: makeRootView(presentationID))
        hosting.translatesAutoresizingMaskIntoConstraints = false
        panel.contentView = hosting
        controllerRef.value = self

        settingsStore.$uiScale
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] _ in self?.relayout() }
            .store(in: &cancellables)
    }

    var isVisible: Bool { panel.isVisible }

    func toggle(anchorFrame: NSRect) {
        if panel.isVisible { hide() } else { show(anchorFrame: anchorFrame) }
    }

    func show(anchorFrame: NSRect) {
        lastAnchorFrame = anchorFrame
        hasMouseEnteredPanel = false
        pendingHoverDismiss?.cancel()
        pendingHoverDismiss = nil
        presentationID = UUID()
        hosting.rootView = makeRootView(presentationID)
        panel.setFrame(layoutFrame(for: anchorFrame), display: true)
        panel.makeKeyAndOrderFront(nil)
        installClickOutsideMonitors()
    }

    func hide() {
        pendingHoverDismiss?.cancel()
        pendingHoverDismiss = nil
        hasMouseEnteredPanel = false
        removeClickOutsideMonitors()
        panel.orderOut(nil)
    }

    private func relayout() {
        guard panel.isVisible else {
            panel.setContentSize(Self.scaledSize(settingsStore.uiScale))
            return
        }
        panel.setFrame(layoutFrame(for: lastAnchorFrame), display: true)
    }

    /// Positions the panel so it sits flush against the top of the bar and the left edge
    /// of the screen, visually continuing the taskbar. Height is clamped so it never runs
    /// off the top of the visible area.
    private func layoutFrame(for anchorFrame: NSRect) -> NSRect {
        let screen = panel.screen ?? NSScreen.main ?? NSScreen.screens.first!
        let visible = screen.visibleFrame
        let scaled = Self.scaledSize(settingsStore.uiScale)

        // Snap to the top of the bar window, with a tiny nudge up to avoid a
        // hairline overlap caused by subpixel rounding between the two panels.
        let barTop = ignoreClicksInWindow?.frame.maxY ?? anchorFrame.maxY
        let panelBottom = barTop + 2
        let topMargin: CGFloat = 8
        let maxHeight = max(200, visible.maxY - panelBottom - topMargin)
        let height = min(scaled.height, maxHeight)

        let maxWidth = max(260, visible.width)
        let width = min(scaled.width, maxWidth)

        let x = visible.minX

        return NSRect(x: x, y: panelBottom, width: width, height: height)
    }

    private static func scaledSize(_ scale: Double) -> NSSize {
        NSSize(width: baseSize.width * scale, height: baseSize.height * scale)
    }

    private func installClickOutsideMonitors() {
        removeClickOutsideMonitors()
        globalClickMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] _ in
            Task { @MainActor in self?.hide() }
        }
        localClickMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] event in
            guard let self else { return event }
            if event.window === self.panel { return event }
            if event.window === self.ignoreClicksInWindow { return event }
            Task { @MainActor in self.hide() }
            return event
        }
    }

    private func removeClickOutsideMonitors() {
        if let m = globalClickMonitor { NSEvent.removeMonitor(m) }
        if let m = localClickMonitor { NSEvent.removeMonitor(m) }
        globalClickMonitor = nil
        localClickMonitor = nil
    }

    private func handleHoverChange(_ inside: Bool) {
        pendingHoverDismiss?.cancel()
        pendingHoverDismiss = nil

        if inside {
            hasMouseEnteredPanel = true
            return
        }

        guard hasMouseEnteredPanel else { return }

        let work = DispatchWorkItem { [weak self] in
            self?.hide()
        }
        pendingHoverDismiss = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.hoverDismissDelay, execute: work)
    }

    private final class ControllerRef {
        weak var value: StartMenuWindowController?
    }
}
