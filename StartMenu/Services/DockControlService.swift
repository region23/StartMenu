import AppKit
import Combine
import Foundation

/// Hides/restores the system Dock via com.apple.dock preferences.
///
/// The pre-launch Dock state is snapshotted to UserDefaults the first time
/// `hide()` is called so that a crash or external kill (e.g. `pkill`) in
/// the previous run can still be reconciled on the next launch: we never
/// overwrite a persisted snapshot with our own already-applied values.
@MainActor
final class DockControlService: ObservableObject {
    enum Mode: Equatable {
        case hidden
        case reserved(barHeight: CGFloat, inset: CGFloat)
    }

    private let appID: CFString = "com.apple.dock" as CFString
    private let autohideKey: CFString = "autohide" as CFString
    private let autohideDelayKey: CFString = "autohide-delay" as CFString
    private let tileSizeKey: CFString = "tilesize" as CFString
    private let largeSizeKey: CFString = "largesize" as CFString
    private let magnificationKey: CFString = "magnification" as CFString
    private let showRecentsKey: CFString = "show-recents" as CFString
    private let orientationKey: CFString = "orientation" as CFString

    private let defaults: UserDefaults
    private let snapshotKey = "dock.preLaunchSnapshot.v1"
    private let snapshotAutohide = "autohide"
    private let snapshotDelay = "delay"
    private let snapshotTileSize = "tilesize"
    private let snapshotLargeSize = "largesize"
    private let snapshotMagnification = "magnification"
    private let snapshotShowRecents = "showRecents"
    private let snapshotOrientation = "orientation"
    private let reservedTileSizeKey = "dock.reservedTileSize.v1"

    private(set) var isHidden = false
    @Published private(set) var mode: Mode = .hidden
    @Published private(set) var lastReservationError: String?

    init(defaults: UserDefaults = AppDefaults.shared) {
        self.defaults = defaults
    }

    func hide() {
        snapshotIfNeeded()

        CFPreferencesSetAppValue(autohideKey, kCFBooleanTrue, appID)
        CFPreferencesSetAppValue(autohideDelayKey, 1000 as CFNumber, appID)
        CFPreferencesAppSynchronize(appID)
        restartDock()
        isHidden = true
        mode = .hidden
        lastReservationError = nil
    }

    func reserveSpace(forBarHeight barHeight: CGFloat) {
        snapshotIfNeeded()

        let clampedHeight = max(24, min(96, barHeight))
        var tileSize = CGFloat(max(16.0, min(128.0, defaults.double(forKey: reservedTileSizeKey))))
        if tileSize == 0 {
            tileSize = clampedHeight
        }

        var inset = applyReservedDockProfile(tileSize: tileSize)
        if inset > 1 {
            let adjustedTileSize = max(16, min(128, tileSize * clampedHeight / inset))
            if abs(adjustedTileSize - tileSize) >= 1 {
                tileSize = adjustedTileSize
                inset = applyReservedDockProfile(tileSize: tileSize)
            }
        }

        defaults.set(tileSize, forKey: reservedTileSizeKey)
        defaults.synchronize()

        let resolvedInset = inset > 1 ? inset : clampedHeight
        isHidden = false
        mode = .reserved(barHeight: clampedHeight, inset: resolvedInset)
        lastReservationError = inset > 1
            ? nil
            : "Dock inset measurement was unavailable; using requested bar height as a fallback."
    }

    func refreshReservation(forBarHeight barHeight: CGFloat) {
        let clampedHeight = max(24, min(96, barHeight))

        guard isReservingSpace else {
            return
        }

        let measuredInset = NSScreen.main?.visibleFrame.minY ?? 0
        if measuredInset <= 1 {
            reserveSpace(forBarHeight: clampedHeight)
            return
        }

        isHidden = false
        mode = .reserved(barHeight: clampedHeight, inset: max(measuredInset, clampedHeight))
        lastReservationError = nil
    }

    func restore() {
        let snapshot = defaults.dictionary(forKey: snapshotKey)
        let savedAutohide = snapshot?[snapshotAutohide] as? Bool
        let savedDelay = snapshot?[snapshotDelay] as? Double
        let savedTileSize = snapshot?[snapshotTileSize] as? Double
        let savedLargeSize = snapshot?[snapshotLargeSize] as? Double
        let savedMagnification = snapshot?[snapshotMagnification] as? Bool
        let savedShowRecents = snapshot?[snapshotShowRecents] as? Bool
        let savedOrientation = snapshot?[snapshotOrientation] as? String

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

        if let tileSize = savedTileSize {
            CFPreferencesSetAppValue(tileSizeKey, tileSize as CFNumber, appID)
        } else {
            CFPreferencesSetAppValue(tileSizeKey, nil, appID)
        }

        if let largeSize = savedLargeSize {
            CFPreferencesSetAppValue(largeSizeKey, largeSize as CFNumber, appID)
        } else {
            CFPreferencesSetAppValue(largeSizeKey, nil, appID)
        }

        if let magnification = savedMagnification {
            CFPreferencesSetAppValue(magnificationKey, magnification ? kCFBooleanTrue : kCFBooleanFalse, appID)
        } else {
            CFPreferencesSetAppValue(magnificationKey, nil, appID)
        }

        if let showRecents = savedShowRecents {
            CFPreferencesSetAppValue(showRecentsKey, showRecents ? kCFBooleanTrue : kCFBooleanFalse, appID)
        } else {
            CFPreferencesSetAppValue(showRecentsKey, nil, appID)
        }

        if let savedOrientation {
            CFPreferencesSetAppValue(orientationKey, savedOrientation as CFString, appID)
        } else {
            CFPreferencesSetAppValue(orientationKey, nil, appID)
        }

        CFPreferencesAppSynchronize(appID)
        restartDock()

        defaults.removeObject(forKey: snapshotKey)
        defaults.synchronize()
        isHidden = false
        mode = .hidden
        lastReservationError = nil
    }

    var hasManagedDockState: Bool {
        defaults.dictionary(forKey: snapshotKey) != nil
    }

    var isReservingSpace: Bool {
        if case .reserved = mode {
            return true
        }
        return false
    }

    var currentDesktopInset: CGFloat {
        switch mode {
        case .hidden:
            return 0
        case .reserved(_, let inset):
            return inset
        }
    }

    func barOriginY(for screen: NSScreen, barHeight: CGFloat) -> CGFloat {
        switch mode {
        case .hidden:
            return screen.visibleFrame.minY
        case .reserved:
            let dockInset = max(currentDesktopInset, barHeight)
            return max(screen.frame.minY, dockInset - barHeight)
        }
    }

    private func snapshotIfNeeded() {
        if defaults.dictionary(forKey: snapshotKey) == nil {
            let currentAutohide = CFPreferencesCopyAppValue(autohideKey, appID) as? Bool
            let currentDelay = CFPreferencesCopyAppValue(autohideDelayKey, appID) as? Double
            let currentTileSize = CFPreferencesCopyAppValue(tileSizeKey, appID) as? Double
            let currentLargeSize = CFPreferencesCopyAppValue(largeSizeKey, appID) as? Double
            let currentMagnification = CFPreferencesCopyAppValue(magnificationKey, appID) as? Bool
            let currentShowRecents = CFPreferencesCopyAppValue(showRecentsKey, appID) as? Bool
            let currentOrientation = CFPreferencesCopyAppValue(orientationKey, appID) as? String

            var dict: [String: Any] = [:]
            if let a = currentAutohide { dict[snapshotAutohide] = a }
            if let d = currentDelay { dict[snapshotDelay] = d }
            if let tile = currentTileSize { dict[snapshotTileSize] = tile }
            if let large = currentLargeSize { dict[snapshotLargeSize] = large }
            if let magnification = currentMagnification { dict[snapshotMagnification] = magnification }
            if let showRecents = currentShowRecents { dict[snapshotShowRecents] = showRecents }
            if let orientation = currentOrientation { dict[snapshotOrientation] = orientation }
            defaults.set(dict, forKey: snapshotKey)
            defaults.synchronize()
        }
    }

    private func applyReservedDockProfile(tileSize: CGFloat) -> CGFloat {
        CFPreferencesSetAppValue(autohideKey, kCFBooleanFalse, appID)
        CFPreferencesSetAppValue(autohideDelayKey, 0 as CFNumber, appID)
        CFPreferencesSetAppValue(tileSizeKey, tileSize as CFNumber, appID)
        CFPreferencesSetAppValue(largeSizeKey, tileSize as CFNumber, appID)
        CFPreferencesSetAppValue(magnificationKey, kCFBooleanFalse, appID)
        CFPreferencesSetAppValue(showRecentsKey, kCFBooleanFalse, appID)
        CFPreferencesSetAppValue(orientationKey, "bottom" as CFString, appID)
        CFPreferencesAppSynchronize(appID)
        restartDock()
        RunLoop.current.run(until: Date().addingTimeInterval(0.35))
        return NSScreen.main?.visibleFrame.minY ?? 0
    }

    private func restartDock() {
        let task = Process()
        task.launchPath = "/usr/bin/killall"
        task.arguments = ["Dock"]
        try? task.run()
        task.waitUntilExit()
    }
}
