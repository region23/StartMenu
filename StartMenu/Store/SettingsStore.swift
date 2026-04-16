import Combine
import Foundation

@MainActor
final class SettingsStore: ObservableObject {
    static let shared = SettingsStore(defaults: AppDefaults.shared)

    private enum Keys {
        static let pinnedBundleIDs = "pinnedBundleIDs"
        static let uiScale = "uiScale"
        static let compactChips = "compactChips"
    }

    private let defaults: UserDefaults

    @Published var pinnedBundleIDs: [String] {
        didSet {
            defaults.set(pinnedBundleIDs, forKey: Keys.pinnedBundleIDs)
        }
    }

    @Published var uiScale: Double {
        didSet {
            defaults.set(uiScale, forKey: Keys.uiScale)
        }
    }

    /// When true, taskbar chips shrink to just the app icon and expand
    /// back to icon+title on hover. Saves horizontal space when many
    /// apps are running.
    @Published var compactChips: Bool {
        didSet {
            defaults.set(compactChips, forKey: Keys.compactChips)
        }
    }

    init(defaults: UserDefaults = AppDefaults.shared) {
        self.defaults = defaults
        self.pinnedBundleIDs = defaults.stringArray(forKey: Keys.pinnedBundleIDs) ?? []
        let rawScale = defaults.double(forKey: Keys.uiScale)
        self.uiScale = rawScale > 0 ? rawScale : UIScale.medium.rawValue
        self.compactChips = defaults.bool(forKey: Keys.compactChips)
    }

    func isPinned(_ bundleID: String) -> Bool {
        pinnedBundleIDs.contains(bundleID)
    }

    func togglePin(_ bundleID: String) {
        if let idx = pinnedBundleIDs.firstIndex(of: bundleID) {
            pinnedBundleIDs.remove(at: idx)
        } else {
            pinnedBundleIDs.append(bundleID)
        }
    }
}
