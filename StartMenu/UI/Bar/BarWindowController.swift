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
    private let onStartTapped: (NSRect) -> Void

    private var lastStartFrame: NSRect = .zero
    private var cancellables: Set<AnyCancellable> = []

    private static let baseBarHeight: CGFloat = 44

    init(
        windowService: WindowService,
        menuBarExtrasService: MenuBarExtrasService,
        windowController: WindowController,
        settingsStore: SettingsStore,
        onStartTapped: @escaping (NSRect) -> Void
    ) {
        self.windowService = windowService
        self.menuBarExtrasService = menuBarExtrasService
        self.windowController = windowController
        self.settingsStore = settingsStore
        self.onStartTapped = onStartTapped

        let screen = NSScreen.main ?? NSScreen.screens.first!
        let frame = Self.barFrame(for: screen, scale: settingsStore.uiScale)

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
            onStartButtonFrame: { [weak self] in self?.lastStartFrame = $0 },
            onStartButtonTap: { [weak self] in
                guard let self else { return }
                self.onStartTapped(self.lastStartFrame)
            }
        )
        let hosting = NSHostingView(rootView: view)
        hosting.translatesAutoresizingMaskIntoConstraints = false
        panel.contentView = hosting

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(screenParametersChanged),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )

        settingsStore.$uiScale
            .removeDuplicates()
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

    private func resize() {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        panel.setFrame(Self.barFrame(for: screen, scale: settingsStore.uiScale), display: true)
    }

    private static func barFrame(for screen: NSScreen, scale: Double) -> NSRect {
        let visible = screen.visibleFrame
        let height = baseBarHeight * scale
        return NSRect(
            x: visible.minX,
            y: visible.minY,
            width: visible.width,
            height: height
        )
    }
}
