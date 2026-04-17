import AppKit
import Combine
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let environment = AppEnvironment()
    private var barWindowController: BarWindowController?
    private var startMenuWindowController: StartMenuWindowController?
    private var onboardingWindowController: OnboardingWindowController?
    private var responsivenessActivity: NSObjectProtocol?
    private let hotkeyService = HotkeyService()
    private let mainThreadStallMonitor = MainThreadStallMonitor()
    private var sigtermSource: DispatchSourceSignal?
    private var sigintSource: DispatchSourceSignal?
    private var cancellables: Set<AnyCancellable> = []
    private var workspaceObservers: [NSObjectProtocol] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        let launchSpan = PerformanceDiagnostics.begin(
            category: "lifecycle",
            name: "application_did_finish_launching",
            thresholdMs: 30,
            alwaysRecord: true
        )
        NSApp.setActivationPolicy(.accessory)
        mainThreadStallMonitor.start()
        beginResponsivenessActivity()

        // Cocoa doesn't handle SIGTERM/SIGINT by default — the process just
        // dies and applicationWillTerminate never runs, leaving the Dock in
        // our "hidden" state. Install signal sources so `pkill` and Ctrl-C
        // still hit the restore path.
        installSignalHandler(SIGTERM, keeping: &sigtermSource)
        installSignalHandler(SIGINT, keeping: &sigintSource)

        configureDockMode()
        installDockModeObservers()
        installWorkspaceObservers()
        environment.powerUserBridge.connectIfNeeded()

        let startMenu = StartMenuWindowController(
            startMenuService: environment.startMenuService,
            dockAppsService: environment.dockAppsService,
            appUpdateService: environment.appUpdateService,
            settingsStore: environment.settingsStore,
            autostartService: environment.autostartService,
            powerUserFeatureFlags: environment.powerUserFeatureFlags,
            powerUserDiagnosticsStore: environment.powerUserDiagnosticsStore,
            onVisibilityChanged: { [weak self] isVisible in
                self?.environment.windowService.setInteractionActive(
                    isVisible,
                    source: "start_menu"
                )
            },
            onLaunch: { [weak self] app in
                self?.launch(app)
            },
            onQuit: {
                NSApp.terminate(nil)
            }
        )
        startMenuWindowController = startMenu

        let bar = BarWindowController(
            windowService: environment.windowService,
            menuBarExtrasService: environment.menuBarExtrasService,
            windowController: environment.windowController,
            settingsStore: environment.settingsStore,
            dockControlService: environment.dockControlService,
            onInteractionChanged: { [weak self] isInteracting in
                self?.environment.windowService.setInteractionActive(
                    isInteracting,
                    source: "bar_hover"
                )
            },
            onLaunchApp: { [weak self] app in
                self?.launch(app)
            },
            onStartTapped: { [weak self] frame in
                self?.startMenuWindowController?.toggle(anchorFrame: frame)
            }
        )
        bar.show()
        barWindowController = bar
        startMenu.setIgnoreClicksInWindow(bar.window)
        environment.windowService.barWindow = bar.window
        environment.powerUserDiagnosticsStore.refresh()

        hotkeyService.registerCtrlSpace { [weak self] in
            guard let self, let bar = self.barWindowController else { return }
            self.startMenuWindowController?.toggle(anchorFrame: bar.currentStartFrame)
        }

        // Screen Recording is reserved for a future feature (window
        // thumbnails on hover) and not surfaced in the onboarding UI.
        // Gate onboarding on Accessibility only — otherwise every launch
        // flashes the Setup window until that unrelated grant is given.
        if !environment.permissionsService.hasAccessibility {
            showOnboarding()
        }

        PerformanceDiagnostics.recordEvent(
            "application_launched",
            category: "lifecycle",
            level: .notice,
            fields: [
                "bundleID": AppFlavor.current.bundleIdentifier,
                "version": Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown",
                "build": Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "unknown",
                "pid": String(ProcessInfo.processInfo.processIdentifier)
            ]
        )
        launchSpan.end()
    }

    private func configureDockMode() {
        let barHeight = BarMetrics.height(for: environment.settingsStore.uiScale)
        if environment.appFlavor.isPowerUser,
           environment.powerUserFeatureFlags.isEnabled(.realDesktopReservation) {
            environment.dockControlService.reserveSpace(forBarHeight: barHeight)
        } else {
            environment.dockControlService.hide()
        }
        environment.powerUserDiagnosticsStore.refresh()
    }

    private func refreshDockGeometryIfNeeded() {
        let barHeight = BarMetrics.height(for: environment.settingsStore.uiScale)

        if environment.appFlavor.isPowerUser,
           environment.powerUserFeatureFlags.isEnabled(.realDesktopReservation) {
            environment.dockControlService.refreshReservation(forBarHeight: barHeight)
            environment.powerUserDiagnosticsStore.refresh()
        }
    }

    private func installDockModeObservers() {
        environment.settingsStore.$uiScale
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] _ in
                self?.configureDockMode()
            }
            .store(in: &cancellables)

        environment.powerUserFeatureFlags.objectWillChange
            .sink { [weak self] _ in
                Task { @MainActor in
                    self?.configureDockMode()
                }
            }
            .store(in: &cancellables)
    }

    private func installWorkspaceObservers() {
        let center = NSWorkspace.shared.notificationCenter

        for name in [
            NSWorkspace.activeSpaceDidChangeNotification,
            NSWorkspace.didWakeNotification
        ] {
            let token = center.addObserver(
                forName: name,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in
                    self?.refreshDockGeometryIfNeeded()
                }
            }
            workspaceObservers.append(token)
        }

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(screenParametersChanged),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )
    }

    func applicationWillTerminate(_ notification: Notification) {
        mainThreadStallMonitor.stop()
        endResponsivenessActivity()
        PerformanceDiagnostics.recordEvent(
            "application_will_terminate",
            category: "lifecycle",
            level: .notice
        )
        if environment.dockControlService.hasManagedDockState {
            environment.dockControlService.restore()
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    /// Bundle IDs whose `File → New Window` binding isn't Cmd+N (usually
    /// because Cmd+N is already claimed by "new file / new tab" inside
    /// the workspace). Add more entries as they come up.
    private static let newWindowOverride: [String: CGEventFlags] = [
        "dev.zed.Zed": [.maskCommand, .maskShift],
        "com.microsoft.VSCode": [.maskCommand, .maskShift],
        "com.microsoft.VSCodeInsiders": [.maskCommand, .maskShift],
        "com.todesktop.230313mzl4w4u92": [.maskCommand, .maskShift] // Cursor
    ]

    private func launch(_ app: AppInfo) {
        if let running = NSRunningApplication.runningApplications(
            withBundleIdentifier: app.bundleID
        ).first, !running.isTerminated {
            running.activate()
            let flags = Self.newWindowOverride[app.bundleID] ?? .maskCommand
            // Give the frontmost switch a beat so the target app actually
            // owns the key event when we post it.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
                Self.sendNewWindowShortcut(flags: flags)
            }
            return
        }

        let config = NSWorkspace.OpenConfiguration()
        NSWorkspace.shared.openApplication(at: app.url, configuration: config) { _, _ in }
    }

    private static func sendNewWindowShortcut(flags: CGEventFlags) {
        let source = CGEventSource(stateID: .combinedSessionState)
        let nKey: CGKeyCode = 0x2D // kVK_ANSI_N
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: nKey, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: nKey, keyDown: false) else { return }
        down.flags = flags
        up.flags = flags
        down.post(tap: .cgSessionEventTap)
        up.post(tap: .cgSessionEventTap)
    }

    private func showOnboarding() {
        let controller = OnboardingWindowController(permissionsService: environment.permissionsService)
        controller.show()
        onboardingWindowController = controller
    }

    private func installSignalHandler(_ sig: Int32, keeping holder: inout DispatchSourceSignal?) {
        signal(sig, SIG_IGN)
        let src = DispatchSource.makeSignalSource(signal: sig, queue: .main)
        src.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                self?.endResponsivenessActivity()
                if self?.environment.dockControlService.hasManagedDockState == true {
                    self?.environment.dockControlService.restore()
                }
            }
            exit(0)
        }
        src.resume()
        holder = src
    }

    private func beginResponsivenessActivity() {
        guard responsivenessActivity == nil else { return }
        responsivenessActivity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated, .latencyCritical],
            reason: "Keep StartMenu responsive while the bar is active"
        )
    }

    private func endResponsivenessActivity() {
        guard let responsivenessActivity else { return }
        ProcessInfo.processInfo.endActivity(responsivenessActivity)
        self.responsivenessActivity = nil
    }

    @objc private func screenParametersChanged() {
        refreshDockGeometryIfNeeded()
    }
}
