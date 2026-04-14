import AppKit
import ApplicationServices
import Combine
import CoreGraphics
import Foundation

@MainActor
final class WindowService: ObservableObject {
    @Published private(set) var windows: [WindowInfo] = []
    @Published private(set) var activeAppPID: pid_t?

    private var timer: Timer?
    private var workspaceObservers: [NSObjectProtocol] = []

    private static let excludedOwnerNames: Set<String> = [
        "Dock",
        "Window Server",
        "SystemUIServer",
        "Control Center",
        "Notification Center",
        "Spotlight",
        "loginwindow",
        "WallpaperAgent",
        "Wallpaper",
        "TextInputMenuAgent",
        "Screenshot",
        "Universal Control",
        "StartMenu"
    ]

    init() {
        activeAppPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        refresh()
        start()
        observeFrontmost()
    }

    deinit {
        timer?.invalidate()
        let center = NSWorkspace.shared.notificationCenter
        for obs in workspaceObservers {
            center.removeObserver(obs)
        }
    }

    private func observeFrontmost() {
        let center = NSWorkspace.shared.notificationCenter
        let token = center.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            Task { @MainActor in
                self?.activeAppPID = app?.processIdentifier
            }
        }
        workspaceObservers.append(token)
    }

    func start() {
        timer?.invalidate()
        let t = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    func refresh() {
        let onscreen = collectOnscreenWindows()
        let minimized = collectMinimizedWindows(excludingIDs: Set(onscreen.map(\.id)))
        let combined = (onscreen + minimized)

        let sorted = combined.sorted {
            if $0.ownerName == $1.ownerName { return $0.id < $1.id }
            return $0.ownerName.localizedCaseInsensitiveCompare($1.ownerName) == .orderedAscending
        }

        if sorted != windows { windows = sorted }
    }

    // MARK: - Onscreen

    private func collectOnscreenWindows() -> [WindowInfo] {
        let ours = ProcessInfo.processInfo.processIdentifier
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let raw = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            return []
        }

        let running = NSWorkspace.shared.runningApplications
        let bundleByPID = Dictionary(uniqueKeysWithValues: running.compactMap { app -> (pid_t, String)? in
            guard let bid = app.bundleIdentifier else { return nil }
            return (app.processIdentifier, bid)
        })

        return raw.compactMap { entry in
            guard
                let wid = entry[kCGWindowNumber as String] as? CGWindowID,
                let pid = entry[kCGWindowOwnerPID as String] as? pid_t,
                let layer = entry[kCGWindowLayer as String] as? Int
            else { return nil }

            if layer != 0 { return nil }
            if pid == ours { return nil }

            let alpha = (entry[kCGWindowAlpha as String] as? Double) ?? 1.0
            if alpha <= 0.01 { return nil }

            let ownerName = (entry[kCGWindowOwnerName as String] as? String) ?? ""
            if Self.excludedOwnerNames.contains(ownerName) { return nil }

            let title = (entry[kCGWindowName as String] as? String) ?? ""

            var bounds = CGRect.zero
            if let dict = entry[kCGWindowBounds as String] as? NSDictionary {
                CGRectMakeWithDictionaryRepresentation(dict as CFDictionary, &bounds)
            }
            if bounds.width < 60 || bounds.height < 40 { return nil }

            let bundleID = bundleByPID[pid]
            if title.isEmpty && bundleID == nil { return nil }

            return WindowInfo(
                id: wid,
                ownerPID: pid,
                ownerBundleID: bundleID,
                ownerName: ownerName,
                title: title,
                bounds: bounds,
                layer: layer,
                isOnScreen: true,
                isMinimized: false
            )
        }
    }

    // MARK: - Minimized (AX scan)

    private func collectMinimizedWindows(excludingIDs: Set<CGWindowID>) -> [WindowInfo] {
        let ours = ProcessInfo.processInfo.processIdentifier
        var result: [WindowInfo] = []

        for app in NSWorkspace.shared.runningApplications {
            guard app.activationPolicy == .regular else { continue }
            let pid = app.processIdentifier
            if pid == ours { continue }

            let ownerName = app.localizedName ?? ""
            if Self.excludedOwnerNames.contains(ownerName) { continue }

            let appElement = AXUIElementCreateApplication(pid)
            var windowsRef: CFTypeRef?
            guard AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &windowsRef) == .success,
                  let ref = windowsRef else { continue }
            let axWindows = ref as! [AXUIElement]

            for ax in axWindows {
                var minRef: CFTypeRef?
                guard AXUIElementCopyAttributeValue(ax, kAXMinimizedAttribute as CFString, &minRef) == .success,
                      let minBool = minRef as? Bool, minBool else { continue }

                var wid: CGWindowID = 0
                guard _AXUIElementGetWindow(ax, &wid) == .success else { continue }
                if excludingIDs.contains(wid) { continue }

                var titleRef: CFTypeRef?
                AXUIElementCopyAttributeValue(ax, kAXTitleAttribute as CFString, &titleRef)
                let title = (titleRef as? String) ?? ""

                result.append(WindowInfo(
                    id: wid,
                    ownerPID: pid,
                    ownerBundleID: app.bundleIdentifier,
                    ownerName: ownerName,
                    title: title,
                    bounds: .zero,
                    layer: 0,
                    isOnScreen: false,
                    isMinimized: true
                ))
            }
        }

        return result
    }
}
