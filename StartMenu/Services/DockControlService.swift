import Foundation

/// Hides/restores the system Dock via com.apple.dock preferences.
/// Sets autohide=true + autohide-delay=1000 so the Dock never appears on hover,
/// and remembers the previous values so we can restore them on quit.
@MainActor
final class DockControlService {
    private let appID: CFString = "com.apple.dock" as CFString
    private let autohideKey: CFString = "autohide" as CFString
    private let autohideDelayKey: CFString = "autohide-delay" as CFString

    private var savedAutohide: Bool?
    private var savedAutohideDelay: Double?
    private var didSnapshot = false
    private(set) var isHidden = false

    func hide() {
        if !didSnapshot {
            savedAutohide = CFPreferencesCopyAppValue(autohideKey, appID) as? Bool
            savedAutohideDelay = CFPreferencesCopyAppValue(autohideDelayKey, appID) as? Double
            didSnapshot = true
        }

        CFPreferencesSetAppValue(autohideKey, kCFBooleanTrue, appID)
        CFPreferencesSetAppValue(autohideDelayKey, 1000 as CFNumber, appID)
        CFPreferencesAppSynchronize(appID)
        restartDock()
        isHidden = true
    }

    func restore() {
        guard didSnapshot else {
            // No saved snapshot — best-effort restore to sane defaults.
            CFPreferencesSetAppValue(autohideKey, kCFBooleanFalse, appID)
            CFPreferencesSetAppValue(autohideDelayKey, nil, appID)
            CFPreferencesAppSynchronize(appID)
            restartDock()
            isHidden = false
            return
        }

        if let auto = savedAutohide {
            CFPreferencesSetAppValue(autohideKey, auto ? kCFBooleanTrue : kCFBooleanFalse, appID)
        } else {
            CFPreferencesSetAppValue(autohideKey, nil, appID)
        }

        if let delay = savedAutohideDelay {
            CFPreferencesSetAppValue(autohideDelayKey, delay as CFNumber, appID)
        } else {
            CFPreferencesSetAppValue(autohideDelayKey, nil, appID)
        }

        CFPreferencesAppSynchronize(appID)
        restartDock()
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
