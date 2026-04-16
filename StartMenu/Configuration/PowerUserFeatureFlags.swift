import Combine
import Foundation

enum PowerUserDefaultsKey {
    static let helperEndpoint = "powerUser.helperEndpoint"
}

enum PowerUserFeatureFlag: String, CaseIterable, Identifiable {
    case realDesktopReservation = "powerUser.realDesktopReservation"
    case privateMaximizeHandling = "powerUser.privateMaximizeHandling"
    case multiDisplayDockOwnership = "powerUser.multiDisplayDockOwnership"
    case debugOverlayMetrics = "powerUser.debugOverlayMetrics"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .realDesktopReservation:
            return "Real desktop reservation"
        case .privateMaximizeHandling:
            return "Private maximize handling"
        case .multiDisplayDockOwnership:
            return "Multi-display Dock ownership"
        case .debugOverlayMetrics:
            return "Debug overlay metrics"
        }
    }

    var details: String {
        switch self {
        case .realDesktopReservation:
            return "Use the system Dock as the reserved desktop owner so other apps lay out above Start Menu."
        case .privateMaximizeHandling:
            return "Keep the AX clamp active on top of Dock reservation to catch apps that still try to maximize into the bar."
        case .multiDisplayDockOwnership:
            return "Experiment with assigning Dock ownership per display."
        case .debugOverlayMetrics:
            return "Expose extra geometry and visibility diagnostics in the private panel."
        }
    }

    var defaultValue: Bool {
        false
    }
}

@MainActor
final class PowerUserFeatureFlags: ObservableObject {
    private let defaults: UserDefaults
    let isAvailable: Bool

    init(
        defaults: UserDefaults = AppDefaults.shared,
        isAvailable: Bool = AppFlavor.current.isPowerUser
    ) {
        self.defaults = defaults
        self.isAvailable = isAvailable
        defaults.register(defaults: Self.defaultRegistration)
    }

    func isEnabled(_ flag: PowerUserFeatureFlag) -> Bool {
        isAvailable && defaults.bool(forKey: flag.rawValue)
    }

    func setEnabled(_ enabled: Bool, for flag: PowerUserFeatureFlag) {
        defaults.set(enabled, forKey: flag.rawValue)
        objectWillChange.send()
    }

    private static var defaultRegistration: [String: Any] {
        Dictionary(uniqueKeysWithValues: PowerUserFeatureFlag.allCases.map { ($0.rawValue, $0.defaultValue) })
    }
}
