import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let environment = AppEnvironment()
    private var barWindowController: BarWindowController?
    private var startMenuWindowController: StartMenuWindowController?
    private var onboardingWindowController: OnboardingWindowController?
    private let hotkeyService = HotkeyService()
    private var sigtermSource: DispatchSourceSignal?
    private var sigintSource: DispatchSourceSignal?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        // Cocoa doesn't handle SIGTERM/SIGINT by default — the process just
        // dies and applicationWillTerminate never runs, leaving the Dock in
        // our "hidden" state. Install signal sources so `pkill` and Ctrl-C
        // still hit the restore path.
        installSignalHandler(SIGTERM, keeping: &sigtermSource)
        installSignalHandler(SIGINT, keeping: &sigintSource)

        // Always hide the system Dock while Start Menu is running. It is
        // restored on quit via applicationWillTerminate or the signal
        // handlers above.
        environment.dockControlService.hide()

        let startMenu = StartMenuWindowController(
            startMenuService: environment.startMenuService,
            dockAppsService: environment.dockAppsService,
            appUpdateService: environment.appUpdateService,
            settingsStore: environment.settingsStore,
            autostartService: environment.autostartService,
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
            onStartTapped: { [weak self] frame in
                self?.startMenuWindowController?.toggle(anchorFrame: frame)
            }
        )
        bar.show()
        barWindowController = bar
        startMenu.setIgnoreClicksInWindow(bar.window)
        environment.windowService.barWindow = bar.window

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
    }

    func applicationWillTerminate(_ notification: Notification) {
        if environment.dockControlService.isHidden {
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
                if self?.environment.dockControlService.isHidden == true {
                    self?.environment.dockControlService.restore()
                }
            }
            exit(0)
        }
        src.resume()
        holder = src
    }
}
