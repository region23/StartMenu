import AppKit
import ApplicationServices
import Combine
import CoreGraphics
import Foundation
import os.log

@MainActor
final class WindowService: ObservableObject {
    @Published private(set) var windows: [WindowInfo] = []
    @Published private(set) var activeAppPID: pid_t?

    /// The bar window — used to compute the clamp line so other apps
    /// don't render under the taskbar.
    weak var barWindow: NSWindow?

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
        let placeholders = placeholdersForInvisibleApps(existingPIDs: Set((onscreen + minimized).map(\.ownerPID)))
        let combined = onscreen + minimized + placeholders

        let sorted = combined.sorted {
            if $0.ownerName == $1.ownerName { return $0.id < $1.id }
            return $0.ownerName.localizedCaseInsensitiveCompare($1.ownerName) == .orderedAscending
        }

        if sorted != windows { windows = sorted }

        clampWindowsAboveBar()
    }

    /// For every running `.regular` application that wasn't picked up
    /// via CGWindowList or the AX minimized scan, synthesize a single
    /// placeholder window so the bar still shows a chip. This catches
    /// three cases in one net:
    ///
    /// 1. Chromium/Electron apps (Claude, VSCode, Cursor, ...) that
    ///    return `kAXErrorAPIDisabled` from the AX API. Once their
    ///    window gets minimized it vanishes from CGWindowList too, and
    ///    without a placeholder the chip would disappear.
    /// 2. Apps where the user closed the last window with the red
    ///    traffic light but the process is still alive and can accept
    ///    a reopen event.
    /// 3. Apps whose visible windows live on a different Space.
    private func placeholdersForInvisibleApps(existingPIDs: Set<pid_t>) -> [WindowInfo] {
        let ours = ProcessInfo.processInfo.processIdentifier
        var result: [WindowInfo] = []

        for app in NSWorkspace.shared.runningApplications {
            guard app.activationPolicy == .regular else { continue }
            let pid = app.processIdentifier
            if pid == ours { continue }
            if existingPIDs.contains(pid) { continue }
            let name = app.localizedName ?? ""
            if Self.excludedOwnerNames.contains(name) { continue }
            if name.isEmpty { continue }

            // Stable per-PID synthetic id, parked in the high 0xE-range
            // so it never collides with real CGWindowIDs (small) or the
            // synthetic ids collectMinimizedWindows hands out (0xC-range).
            let synthID = CGWindowID(0xE000_0000 | (UInt32(bitPattern: pid) & 0x1FFF_FFFF))

            result.append(WindowInfo(
                id: synthID,
                ownerPID: pid,
                ownerBundleID: app.bundleIdentifier,
                ownerName: name,
                title: "",
                bounds: .zero,
                layer: 0,
                isOnScreen: false,
                isMinimized: true
            ))
        }

        return result
    }

    // MARK: - Clamp windows to stay above the bar

    private static let axFullScreenAttribute = "AXFullScreen" as CFString
    private static let axManualAccessibilityAttribute = "AXManualAccessibility" as CFString
    private static let axEnhancedUserInterfaceAttribute = "AXEnhancedUserInterface" as CFString
    private static let log = OSLog(subsystem: "app.pavlenko.startmenu", category: "clamp")

    /// PIDs we've recently kicked out of fullscreen via keystroke — used to
    /// avoid spamming the shortcut every half-second.
    private var lastFullscreenKick: [pid_t: Date] = [:]

    private func clampWindowsAboveBar() {
        guard let bar = barWindow,
              let screen = bar.screen ?? NSScreen.main else { return }

        let screenHeight = screen.frame.height
        let visible = screen.visibleFrame
        // Top of usable area (Quartz). Menu bar lives above this.
        let topQuartz = screenHeight - visible.maxY
        // Bar's top edge in Quartz.
        let barTopQuartz = screenHeight - bar.frame.maxY
        let usableHeight = barTopQuartz - topQuartz
        let ours = ProcessInfo.processInfo.processIdentifier

        for app in NSWorkspace.shared.runningApplications {
            guard app.activationPolicy == .regular else { continue }
            let pid = app.processIdentifier
            if pid == ours { continue }
            let name = app.localizedName ?? "?"

            let appElement = AXUIElementCreateApplication(pid)

            var windowsRef: CFTypeRef?
            var listErr = AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &windowsRef)

            // Chromium/Electron apps keep their AX tree dormant. Flip
            // both known "wake up" attributes and retry once.
            if listErr == .apiDisabled || listErr == .cannotComplete {
                AXUIElementSetAttributeValue(appElement, Self.axManualAccessibilityAttribute, kCFBooleanTrue)
                AXUIElementSetAttributeValue(appElement, Self.axEnhancedUserInterfaceAttribute, kCFBooleanTrue)
                listErr = AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &windowsRef)
            }

            guard listErr == .success, let ref = windowsRef else {
                // AX refused us. Fall back to CGWindowList + keystroke
                // injection if the app has a window under our bar.
                forceExitFullscreenIfNeeded(pid: pid, name: name, barTopQuartz: barTopQuartz)
                continue
            }
            let axWindows = ref as! [AXUIElement]
            if axWindows.isEmpty { continue }

            for ax in axWindows {
                var minRef: CFTypeRef?
                if AXUIElementCopyAttributeValue(ax, kAXMinimizedAttribute as CFString, &minRef) == .success,
                   (minRef as? Bool) == true { continue }

                var roleRef: CFTypeRef?
                AXUIElementCopyAttributeValue(ax, kAXRoleAttribute as CFString, &roleRef)
                let role = (roleRef as? String) ?? "?"
                var subroleRef: CFTypeRef?
                AXUIElementCopyAttributeValue(ax, kAXSubroleAttribute as CFString, &subroleRef)
                let subrole = (subroleRef as? String) ?? "?"

                var fsRef: CFTypeRef?
                let fsReadErr = AXUIElementCopyAttributeValue(ax, Self.axFullScreenAttribute, &fsRef)
                let isFullscreen = (fsReadErr == .success) && ((fsRef as? Bool) == true)

                let position = axPoint(ax, attribute: kAXPositionAttribute as CFString) ?? .zero
                let size = axSize(ax, attribute: kAXSizeAttribute as CFString) ?? .zero

                // Only touch real application windows. This drops Finder's
                // Desktop (role=AXScrollArea), palettes, tooltips, etc.
                if role != kAXWindowRole as String { continue }
                if subrole != kAXStandardWindowSubrole as String { continue }

                if isFullscreen {
                    let setErr = AXUIElementSetAttributeValue(ax, Self.axFullScreenAttribute, kCFBooleanFalse)
                    os_log("exit-fullscreen pid=%{public}d name=%{public}@ setErr=%{public}d",
                           log: Self.log, type: .info, pid, name, setErr.rawValue)
                    continue
                }

                let windowBottom = position.y + size.height
                let extendsPastBar = windowBottom > barTopQuartz + 0.5
                let startsAboveTop = position.y < topQuartz - 0.5
                guard extendsPastBar || startsAboveTop else { continue }

                let newY = max(position.y, topQuartz)
                let maxHeight = barTopQuartz - newY
                let newHeight = min(size.height, maxHeight)
                if newHeight < 80 || usableHeight < 80 { continue }

                if abs(newY - position.y) > 0.5 {
                    setAXPosition(ax, point: CGPoint(x: position.x, y: newY))
                }
                if abs(newHeight - size.height) > 0.5 {
                    setAXSize(ax, size: CGSize(width: size.width, height: newHeight))
                }
                os_log("clamp pid=%{public}d name=%{public}@ oldY=%{public}.0f oldH=%{public}.0f -> newY=%{public}.0f newH=%{public}.0f",
                       log: Self.log, type: .info, pid, name, position.y, size.height, newY, newHeight)
            }
        }
    }

    private func axPoint(_ element: AXUIElement, attribute: CFString) -> CGPoint? {
        var valueRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &valueRef) == .success,
              let value = valueRef else { return nil }
        var point = CGPoint.zero
        AXValueGetValue(value as! AXValue, .cgPoint, &point)
        return point
    }

    private func axSize(_ element: AXUIElement, attribute: CFString) -> CGSize? {
        var valueRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &valueRef) == .success,
              let value = valueRef else { return nil }
        var size = CGSize.zero
        AXValueGetValue(value as! AXValue, .cgSize, &size)
        return size
    }

    private func setAXSize(_ element: AXUIElement, size: CGSize) {
        var s = size
        guard let value = AXValueCreate(.cgSize, &s) else { return }
        AXUIElementSetAttributeValue(element, kAXSizeAttribute as CFString, value)
    }

    private func setAXPosition(_ element: AXUIElement, point: CGPoint) {
        var p = point
        guard let value = AXValueCreate(.cgPoint, &p) else { return }
        AXUIElementSetAttributeValue(element, kAXPositionAttribute as CFString, value)
    }

    // MARK: - Keystroke fallback (for apps that refuse AX, e.g. Claude)

    private func forceExitFullscreenIfNeeded(pid: pid_t, name: String, barTopQuartz: CGFloat) {
        guard let raw = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] else { return }

        var hasOverlap = false
        for entry in raw {
            guard let wpid = entry[kCGWindowOwnerPID as String] as? pid_t, wpid == pid else { continue }
            guard let layer = entry[kCGWindowLayer as String] as? Int, layer == 0 else { continue }
            guard let dict = entry[kCGWindowBounds as String] as? NSDictionary else { continue }
            var bounds = CGRect.zero
            CGRectMakeWithDictionaryRepresentation(dict as CFDictionary, &bounds)
            if bounds.width < 60 || bounds.height < 40 { continue }
            // CGWindowBounds are already in Quartz (top-left origin).
            if bounds.maxY > barTopQuartz + 0.5 {
                hasOverlap = true
                break
            }
        }

        guard hasOverlap else { return }

        // Only kick the frontmost app — otherwise we'd steal the
        // keystroke from whatever the user is actually typing into.
        let frontPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        guard frontPID == pid else {
            os_log("skip-kick pid=%{public}d name=%{public}@ reason=not-frontmost front=%{public}d",
                   log: Self.log, type: .info, pid, name, frontPID ?? -1)
            return
        }

        if let last = lastFullscreenKick[pid], Date().timeIntervalSince(last) < 3.0 { return }
        lastFullscreenKick[pid] = Date()

        sendCtrlCmdF()
        os_log("force-exit-fullscreen via Ctrl+Cmd+F pid=%{public}d name=%{public}@",
               log: Self.log, type: .info, pid, name)
    }

    private func sendCtrlCmdF() {
        let source = CGEventSource(stateID: .combinedSessionState)
        let fKey: CGKeyCode = 0x03 // kVK_ANSI_F
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: fKey, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: fKey, keyDown: false) else { return }
        let flags: CGEventFlags = [.maskCommand, .maskControl]
        down.flags = flags
        up.flags = flags
        down.post(tap: .cgSessionEventTap)
        up.post(tap: .cgSessionEventTap)
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

            for (index, ax) in axWindows.enumerated() {
                var minRef: CFTypeRef?
                guard AXUIElementCopyAttributeValue(ax, kAXMinimizedAttribute as CFString, &minRef) == .success,
                      let minBool = minRef as? Bool, minBool else { continue }

                var wid: CGWindowID = 0
                let widErr = _AXUIElementGetWindow(ax, &wid)

                var titleRef: CFTypeRef?
                AXUIElementCopyAttributeValue(ax, kAXTitleAttribute as CFString, &titleRef)
                let title = (titleRef as? String) ?? ""

                // If the private _AXUIElementGetWindow API couldn't map
                // this element to a CGWindowID (common for minimized
                // windows), synthesize a stable-ish id from pid + title
                // so the chip stays on the bar instead of vanishing.
                var resolvedID = wid
                if widErr != .success || wid == 0 {
                    var hasher = Hasher()
                    hasher.combine(pid)
                    hasher.combine(title)
                    hasher.combine(index)
                    // Put synthetic ids in the high 1G range to avoid
                    // colliding with real CGWindowIDs (small integers).
                    resolvedID = CGWindowID(0xC000_0000 | UInt32(truncatingIfNeeded: hasher.finalize() & 0x3FFF_FFFF))
                }

                if excludingIDs.contains(resolvedID) { continue }

                result.append(WindowInfo(
                    id: resolvedID,
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
