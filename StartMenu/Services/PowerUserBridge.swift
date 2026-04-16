import Foundation

struct PowerUserPrerequisite: Identifiable, Equatable {
    let id: String
    let title: String
    let isSatisfied: Bool
    let details: String
}

@MainActor
protocol PrivateFeatureAvailability: AnyObject {
    func prerequisites() -> [PowerUserPrerequisite]
}

@MainActor
protocol PowerUserBridge: AnyObject {
    var connectionStatus: String { get }
    var lastErrorDescription: String? { get }
    var isConnected: Bool { get }
    var supportsPrivateDesktopReservation: Bool { get }

    func connectIfNeeded()
}

@MainActor
protocol DesktopReservationStrategy {
    var diagnosticsName: String { get }
    var isTrulyReserved: Bool { get }
}

@MainActor
final class PublicFeatureAvailability: PrivateFeatureAvailability {
    func prerequisites() -> [PowerUserPrerequisite] {
        [
            PowerUserPrerequisite(
                id: "public-build",
                title: "Private build target",
                isSatisfied: false,
                details: "Build the StartMenuPowerUser target to enable private experiments."
            )
        ]
    }
}

@MainActor
final class PowerUserFeatureAvailability: PrivateFeatureAvailability {
    private let featureFlags: PowerUserFeatureFlags

    init(featureFlags: PowerUserFeatureFlags) {
        self.featureFlags = featureFlags
    }

    func prerequisites() -> [PowerUserPrerequisite] {
        return [
            PowerUserPrerequisite(
                id: "private-build",
                title: "Private build target",
                isSatisfied: AppFlavor.current.isPowerUser,
                details: "This target carries the PRIVATE_BUILD compilation condition and isolated bundle id."
            ),
            PowerUserPrerequisite(
                id: "dock-owned-reservation",
                title: "Dock-owned reservation path",
                isSatisfied: featureFlags.isAvailable,
                details: "The private build can use the system Dock itself as the reserved desktop area and place Start Menu over it."
            ),
            PowerUserPrerequisite(
                id: "reservation-flag",
                title: "Real reservation experiment enabled",
                isSatisfied: featureFlags.isEnabled(.realDesktopReservation),
                details: "Toggle “Real desktop reservation” below to reserve the bottom area through the system Dock."
            )
        ]
    }
}

@MainActor
final class NoopPowerUserBridge: PowerUserBridge {
    let connectionStatus = "Public build"
    let lastErrorDescription: String? = nil
    let isConnected = false
    let supportsPrivateDesktopReservation = false

    func connectIfNeeded() {}
}

@MainActor
final class DockReservationPowerUserBridge: PowerUserBridge {
    private let dockControlService: DockControlService

    init(dockControlService: DockControlService) {
        self.dockControlService = dockControlService
    }

    var connectionStatus: String {
        dockControlService.isReservingSpace
            ? "Dock reservation active"
            : "AX fallback"
    }

    var lastErrorDescription: String? {
        dockControlService.lastReservationError
    }

    var isConnected: Bool {
        true
    }

    var supportsPrivateDesktopReservation: Bool {
        dockControlService.isReservingSpace
    }

    func connectIfNeeded() {}
}

struct OverlayReservationStrategy: DesktopReservationStrategy {
    let diagnosticsName = "OverlayReservationStrategy"
    let isTrulyReserved = false
}

@MainActor
final class DockOwnedReservationStrategy: DesktopReservationStrategy {
    private let bridge: any PowerUserBridge
    private let featureFlags: PowerUserFeatureFlags

    init(bridge: any PowerUserBridge, featureFlags: PowerUserFeatureFlags) {
        self.bridge = bridge
        self.featureFlags = featureFlags
    }

    var diagnosticsName: String {
        guard featureFlags.isEnabled(.realDesktopReservation) else {
            return "OverlayReservationStrategy (flag disabled)"
        }
        if bridge.supportsPrivateDesktopReservation {
            return "DockOwnedReservationStrategy"
        }
        if bridge.isConnected {
            return "DockOwnedReservationStrategy (AX fallback)"
        }
        return "OverlayReservationStrategy (Dock reservation unavailable)"
    }

    var isTrulyReserved: Bool {
        featureFlags.isEnabled(.realDesktopReservation) && bridge.supportsPrivateDesktopReservation
    }
}
