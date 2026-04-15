import Foundation

@MainActor
final class AppEnvironment: ObservableObject {
    let windowService: WindowService
    let windowController: WindowController
    let menuBarExtrasService: MenuBarExtrasService
    let appUpdateService: AppUpdateService
    let startMenuService: StartMenuService
    let dockAppsService: DockAppsService
    let settingsStore: SettingsStore
    let permissionsService: PermissionsService
    let dockControlService: DockControlService
    let autostartService: AutostartService

    init() {
        self.windowService = WindowService()
        self.windowController = WindowController()
        self.menuBarExtrasService = MenuBarExtrasService()
        self.appUpdateService = AppUpdateService()
        self.startMenuService = StartMenuService()
        self.dockAppsService = DockAppsService()
        self.settingsStore = .shared
        self.permissionsService = PermissionsService()
        self.dockControlService = DockControlService()
        self.autostartService = AutostartService()
    }
}
