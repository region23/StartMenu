import Foundation

/// Hides/restores the system Dock via com.apple.dock preferences.
///
/// The pre-launch Dock state is snapshotted to UserDefaults the first time
/// `hide()` is called so that a crash or external kill (e.g. `pkill`) in
/// the previous run can still be reconciled on the next launch: we never
/// overwrite a persisted snapshot with our own already-applied values.
@MainActor
final class DockControlService {
    private let appID: CFString = "com.apple.dock" as CFString
    private let autohideKey: CFString = "autohide" as CFString
    private let autohideDelayKey: CFString = "autohide-delay" as CFString

    private let defaults = UserDefaults.standard
    private let snapshotKey = "dock.preLaunchSnapshot.v1"
    private let snapshotAutohide = "autohide"
    private let snapshotDelay = "delay"

    private(set) var isHidden = false

    func hide() {
        // Snapshot the ORIGINAL Dock state exactly once and persist it to
        // disk. If a snapshot already exists (previous run didn't restore)
        // we keep it — that's the real pre-StartMenu state.
        if defaults.dictionary(forKey: snapshotKey) == nil {
            let currentAutohide = CFPreferencesCopyAppValue(autohideKey, appID) as? Bool
            let currentDelay = CFPreferencesCopyAppValue(autohideDelayKey, appID) as? Double
            var dict: [String: Any] = [:]
            if let a = currentAutohide { dict[snapshotAutohide] = a }
            if let d = currentDelay { dict[snapshotDelay] = d }
            defaults.set(dict, forKey: snapshotKey)
            defaults.synchronize()
        }

        CFPreferencesSetAppValue(autohideKey, kCFBooleanTrue, appID)
        CFPreferencesSetAppValue(autohideDelayKey, 1000 as CFNumber, appID)
        CFPreferencesAppSynchronize(appID)
        restartDock()
        isHidden = true
    }

    func restore() {
        let snapshot = defaults.dictionary(forKey: snapshotKey)
        let savedAutohide = snapshot?[snapshotAutohide] as? Bool
        let savedDelay = snapshot?[snapshotDelay] as? Double

        if let auto = savedAutohide {
            CFPreferencesSetAppValue(autohideKey, auto ? kCFBooleanTrue : kCFBooleanFalse, appID)
        } else {
            CFPreferencesSetAppValue(autohideKey, nil, appID)
        }

        if let delay = savedDelay {
            CFPreferencesSetAppValue(autohideDelayKey, delay as CFNumber, appID)
        } else {
            CFPreferencesSetAppValue(autohideDelayKey, nil, appID)
        }

        CFPreferencesAppSynchronize(appID)
        restartDock()

        defaults.removeObject(forKey: snapshotKey)
        defaults.synchronize()
        isHidden = false
    }

    private func restartDock() {
        let task = Process()
        task.launchPath = "/usr/bin/killall"
        task.arguments = ["Dock"]
        try? task.run()
        task.waitUntilExit()
    }
}
