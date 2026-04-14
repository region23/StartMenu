import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let environment = AppEnvironment()
    private var barWindowController: BarWindowController?
    private var startMenuWindowController: StartMenuWindowController?
    private var onboardingWindowController: OnboardingWindowController?
    private let hotkeyService = HotkeyService()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        // Always hide the system Dock while Start Menu is running. It is
        // restored on quit via applicationWillTerminate.
        environment.dockControlService.hide()

        let startMenu = StartMenuWindowController(
            startMenuService: environment.startMenuService,
            dockAppsService: environment.dockAppsService,
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
            windowController: environment.windowController,
            settingsStore: environment.settingsStore,
            onStartTapped: { [weak self] frame in
                self?.startMenuWindowController?.toggle(anchorFrame: frame)
            }
        )
        bar.show()
        barWindowController = bar
        startMenu.setIgnoreClicksInWindow(bar.window)

        hotkeyService.registerCtrlSpace { [weak self] in
            guard let self, let bar = self.barWindowController else { return }
            self.startMenuWindowController?.toggle(anchorFrame: bar.currentStartFrame)
        }

        if !environment.permissionsService.hasAccessibility || !environment.permissionsService.hasScreenRecording {
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

    private func launch(_ app: AppInfo) {
        let config = NSWorkspace.OpenConfiguration()
        NSWorkspace.shared.openApplication(at: app.url, configuration: config) { _, _ in }
    }

    private func showOnboarding() {
        let controller = OnboardingWindowController(permissionsService: environment.permissionsService)
        controller.show()
        onboardingWindowController = controller
    }
}
