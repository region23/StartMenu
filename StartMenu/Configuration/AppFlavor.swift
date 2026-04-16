import Foundation

enum AppFlavor: String {
    case publicApp = "public"
    case powerUser = "power-user"

    static let current: AppFlavor = {
#if PRIVATE_BUILD
        .powerUser
#else
        .publicApp
#endif
    }()

    var isPowerUser: Bool {
        self == .powerUser
    }

    var bundleIdentifier: String {
        switch self {
        case .publicApp:
            return "app.pavlenko.startmenu"
        case .powerUser:
            return "app.pavlenko.startmenu.poweruser"
        }
    }

    var defaultsSuiteName: String? {
        switch self {
        case .publicApp:
            return nil
        case .powerUser:
            return "app.pavlenko.startmenu.poweruser.defaults"
        }
    }

    var logSubsystem: String {
        bundleIdentifier
    }

    var productName: String {
        switch self {
        case .publicApp:
            return "StartMenu"
        case .powerUser:
            return "StartMenuPowerUser"
        }
    }

    var displayName: String {
        switch self {
        case .publicApp:
            return "Start Menu"
        case .powerUser:
            return "Start Menu Power User"
        }
    }

    var usesPublicReleaseChannel: Bool {
        !isPowerUser
    }

    var userDefaults: UserDefaults {
        if let defaultsSuiteName,
           let defaults = UserDefaults(suiteName: defaultsSuiteName) {
            return defaults
        }
        return .standard
    }
}

enum AppDefaults {
    static var shared: UserDefaults {
        AppFlavor.current.userDefaults
    }
}
