import Foundation

@MainActor
final class AppEnvironment: ObservableObject {
    let appFlavor: AppFlavor
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
    let powerUserFeatureFlags: PowerUserFeatureFlags
    let powerUserBridge: any PowerUserBridge
    let powerUserDiagnosticsStore: PowerUserDiagnosticsStore
    let desktopReservationStrategy: any DesktopReservationStrategy

    init() {
        self.appFlavor = .current

        let defaults = AppDefaults.shared
        let featureFlags = PowerUserFeatureFlags(defaults: defaults)
        self.powerUserFeatureFlags = featureFlags
        let dockControlService = DockControlService(defaults: defaults)
        self.dockControlService = dockControlService

        let availability: any PrivateFeatureAvailability = if appFlavor.isPowerUser {
            PowerUserFeatureAvailability(featureFlags: featureFlags)
        } else {
            PublicFeatureAvailability()
        }

        let bridge: any PowerUserBridge = if appFlavor.isPowerUser {
            DockReservationPowerUserBridge(dockControlService: dockControlService)
        } else {
            NoopPowerUserBridge()
        }
        self.powerUserBridge = bridge

        let reservationStrategy: any DesktopReservationStrategy = if appFlavor.isPowerUser {
            DockOwnedReservationStrategy(bridge: bridge, featureFlags: featureFlags)
        } else {
            OverlayReservationStrategy()
        }
        self.desktopReservationStrategy = reservationStrategy

        let fallbackConstrainer = AXWindowConstrainer()
        let windowConstrainer: any WindowConstraining = if appFlavor.isPowerUser {
            DockInjectionWindowConstrainer(
                bridge: bridge,
                fallback: fallbackConstrainer,
                featureFlags: featureFlags
            )
        } else {
            fallbackConstrainer
        }

        let windowService = WindowService(windowConstrainer: windowConstrainer)
        self.windowService = windowService
        self.windowController = WindowController()
        self.menuBarExtrasService = MenuBarExtrasService()
        self.appUpdateService = AppUpdateService(flavor: appFlavor)
        self.startMenuService = StartMenuService()
        self.dockAppsService = DockAppsService()
        self.settingsStore = SettingsStore(defaults: defaults)
        self.permissionsService = PermissionsService()
        self.autostartService = AutostartService()
        self.powerUserDiagnosticsStore = PowerUserDiagnosticsStore(
            bridge: bridge,
            availability: availability,
            reservationStrategy: reservationStrategy,
            windowConstrainer: windowConstrainer,
            featureFlags: featureFlags,
            barWindowProvider: { [weak windowService] in windowService?.barWindow }
        )
    }
}
