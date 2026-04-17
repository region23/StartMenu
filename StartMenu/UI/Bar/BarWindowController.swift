import AppKit
import Combine
import SwiftUI

@MainActor
final class BarWindowController {
    private let panel: NSPanel
    private let windowService: WindowService
    private let menuBarExtrasService: MenuBarExtrasService
    private let windowController: WindowController
    private let settingsStore: SettingsStore
    private let dockControlService: DockControlService
    private let onInteractionChanged: (Bool) -> Void
    private let onLaunchApp: (AppInfo) -> Void
    private let onStartTapped: (NSRect) -> Void

    private var lastStartFrame: NSRect = .zero
    private var cancellables: Set<AnyCancellable> = []
    private var workspaceObservers: [NSObjectProtocol] = []

    init(
        windowService: WindowService,
        menuBarExtrasService: MenuBarExtrasService,
        windowController: WindowController,
        settingsStore: SettingsStore,
        dockControlService: DockControlService,
        onInteractionChanged: @escaping (Bool) -> Void,
        onLaunchApp: @escaping (AppInfo) -> Void,
        onStartTapped: @escaping (NSRect) -> Void
    ) {
        self.windowService = windowService
        self.menuBarExtrasService = menuBarExtrasService
        self.windowController = windowController
        self.settingsStore = settingsStore
        self.dockControlService = dockControlService
        self.onInteractionChanged = onInteractionChanged
        self.onLaunchApp = onLaunchApp
        self.onStartTapped = onStartTapped

        let screen = NSScreen.main ?? NSScreen.screens.first!
        let frame = Self.barFrame(
            for: screen,
            scale: settingsStore.uiScale,
            dockControlService: dockControlService
        )

        panel = NSPanel(
            contentRect: frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.ignoresMouseEvents = false

        let view = BarView(
            windowService: windowService,
            menuBarExtrasService: menuBarExtrasService,
            settingsStore: settingsStore,
            windowController: windowController,
            onLaunchApp: onLaunchApp,
            onInteractionChanged: onInteractionChanged,
            onStartButtonFrame: { [weak self] in self?.lastStartFrame = $0 },
            onStartButtonTap: { [weak self] in
                guard let self else { return }
                self.onStartTapped(self.lastStartFrame)
            }
        )
        let hosting = CursorHostingView(rootView: view)
        hosting.translatesAutoresizingMaskIntoConstraints = false
        panel.contentView = hosting

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(screenParametersChanged),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )

        let workspaceCenter = NSWorkspace.shared.notificationCenter
        let token = workspaceCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.resize() }
        }
        workspaceObservers.append(token)

        settingsStore.$uiScale
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] _ in self?.resize() }
            .store(in: &cancellables)

        dockControlService.$mode
            .dropFirst()
            .sink { [weak self] _ in self?.resize() }
            .store(in: &cancellables)
    }

    func show() {
        panel.orderFrontRegardless()
    }

    var window: NSWindow { panel }

    var currentStartFrame: NSRect { lastStartFrame }

    @objc private func screenParametersChanged() {
        resize()
    }

    deinit {
        let workspaceCenter = NSWorkspace.shared.notificationCenter
        for observer in workspaceObservers {
            workspaceCenter.removeObserver(observer)
        }
        NotificationCenter.default.removeObserver(self)
    }

    private func resize() {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        panel.setFrame(
            Self.barFrame(
                for: screen,
                scale: settingsStore.uiScale,
                dockControlService: dockControlService
            ),
            display: true
        )
    }

    private static func barFrame(
        for screen: NSScreen,
        scale: Double,
        dockControlService: DockControlService
    ) -> NSRect {
        let visible = screen.visibleFrame
        let height = BarMetrics.height(for: scale)
        return NSRect(
            x: visible.minX,
            y: dockControlService.barOriginY(for: screen, barHeight: height),
            width: visible.width,
            height: height
        )
    }
}
