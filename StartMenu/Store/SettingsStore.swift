import Combine
import Foundation

@MainActor
final class SettingsStore: ObservableObject {
    static let shared = SettingsStore()

    private enum Keys {
        static let pinnedBundleIDs = "pinnedBundleIDs"
        static let uiScale = "uiScale"
    }

    @Published var pinnedBundleIDs: [String] {
        didSet {
            UserDefaults.standard.set(pinnedBundleIDs, forKey: Keys.pinnedBundleIDs)
        }
    }

    @Published var uiScale: Double {
        didSet {
            UserDefaults.standard.set(uiScale, forKey: Keys.uiScale)
        }
    }

    init() {
        self.pinnedBundleIDs = UserDefaults.standard.stringArray(forKey: Keys.pinnedBundleIDs) ?? []
        let rawScale = UserDefaults.standard.double(forKey: Keys.uiScale)
        self.uiScale = rawScale > 0 ? rawScale : UIScale.medium.rawValue
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
