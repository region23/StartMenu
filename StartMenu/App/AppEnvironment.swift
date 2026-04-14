import Foundation

@MainActor
final class AppEnvironment: ObservableObject {
    let windowService: WindowService
    let windowController: WindowController
    let startMenuService: StartMenuService
    let dockAppsService: DockAppsService
    let settingsStore: SettingsStore
    let permissionsService: PermissionsService
    let dockControlService: DockControlService
    let autostartService: AutostartService

    init() {
        self.windowService = WindowService()
        self.windowController = WindowController()
        self.startMenuService = StartMenuService()
        self.dockAppsService = DockAppsService()
        self.settingsStore = .shared
        self.permissionsService = PermissionsService()
        self.dockControlService = DockControlService()
        self.autostartService = AutostartService()
    }
}
