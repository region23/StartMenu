import AppKit
import ApplicationServices
import Combine
import CoreGraphics
import Foundation
import os.log

@MainActor
final class WindowService: ObservableObject {
    private static let refreshInterval: TimeInterval = 0.2
    private static let axDocumentAttribute = "AXDocument" as CFString

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
                self?.refresh()
            }
        }
        workspaceObservers.append(token)

        for name in [
            NSWorkspace.activeSpaceDidChangeNotification,
            NSWorkspace.didLaunchApplicationNotification,
            NSWorkspace.didTerminateApplicationNotification,
            NSWorkspace.didHideApplicationNotification,
            NSWorkspace.didUnhideApplicationNotification
        ] {
            let token = center.addObserver(
                forName: name,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in self?.refresh() }
            }
            workspaceObservers.append(token)
        }
    }

    func start() {
        timer?.invalidate()
        let t = Timer(timeInterval: Self.refreshInterval, repeats: true) { [weak self] _ in
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

        updateBarVisibility()
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
                label: name,
                subtitle: nil,
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
    private static let axFocusedWindowAttribute = kAXFocusedWindowAttribute as CFString
    private static let axMainWindowAttribute = kAXMainWindowAttribute as CFString
    private static let axManualAccessibilityAttribute = "AXManualAccessibility" as CFString
    private static let axEnhancedUserInterfaceAttribute = "AXEnhancedUserInterface" as CFString
    private static let log = OSLog(subsystem: "app.pavlenko.startmenu", category: "clamp")

    private struct AXWindowDetails {
        let title: String
        let documentPath: String?
    }

    private struct ResolvedWindowLabel {
        let title: String
        let subtitle: String?
    }

    private struct OnscreenWindowSnapshot {
        let id: CGWindowID
        let ownerPID: pid_t
        let ownerBundleID: String?
        let ownerName: String
        let cgTitle: String
        let bounds: CGRect
        let layer: Int
    }

    private func clampWindowsAboveBar() {
        guard let bar = barWindow,
              let screen = bar.screen ?? NSScreen.main else { return }

        // If any app is in native fullscreen on this screen, updateBarVisibility
        // has already ordered the bar out of the way. Nothing to clamp.
        if isAnyAppInNativeFullscreen(on: screen) { return }

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

            let appElement = AXUIElementCreateApplication(pid)
            let axWindows = copyAXWindows(for: appElement)
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

                // Native fullscreen windows live in their own Space and
                // aren't ours to resize — the bar auto-hides while a
                // fullscreen app is frontmost, so skip silently.
                var fsRef: CFTypeRef?
                if AXUIElementCopyAttributeValue(ax, Self.axFullScreenAttribute, &fsRef) == .success,
                   (fsRef as? Bool) == true { continue }

                let position = axPoint(ax, attribute: kAXPositionAttribute as CFString) ?? .zero
                let size = axSize(ax, attribute: kAXSizeAttribute as CFString) ?? .zero

                // Only touch real application windows. This drops Finder's
                // Desktop (role=AXScrollArea), palettes, tooltips, etc.
                if role != kAXWindowRole as String { continue }
                if subrole != kAXStandardWindowSubrole as String { continue }

                let windowBottom = position.y + size.height
                let extendsPastBar = windowBottom > barTopQuartz + 0.5
                let startsAboveTop = position.y < topQuartz - 0.5
                guard extendsPastBar || startsAboveTop else { continue }

                let newY = max(position.y, topQuartz)
                let maxHeight = barTopQuartz - newY
                let newHeight = min(size.height, maxHeight)
                if newHeight < 80 || usableHeight < 80 { continue }

                let clamped = applyClamp(
                    ax,
                    from: position,
                    size: size,
                    targetY: newY,
                    targetHeight: newHeight
                )
                let logType: OSLogType = clamped ? .info : .error
                os_log(
                    "clamp pid=%{public}d oldY=%{public}.0f oldH=%{public}.0f -> newY=%{public}.0f newH=%{public}.0f ok=%{public}s",
                    log: Self.log,
                    type: logType,
                    pid,
                    position.y,
                    size.height,
                    newY,
                    newHeight,
                    clamped ? "yes" : "no"
                )
            }
        }
    }

    // MARK: - Native fullscreen detection

    /// Returns true iff CGWindowList shows any non-StartMenu window on
    /// the given screen whose layer is 0 and whose bounds exactly cover
    /// the full screen frame (origin 0,0 + size = screen.frame.size).
    /// That's the native fullscreen signature — zoomed/maximised
    /// windows still leave the menu bar visible and therefore have a
    /// positive top-Y offset.
    private func isAnyAppInNativeFullscreen(on screen: NSScreen) -> Bool {
        let ours = ProcessInfo.processInfo.processIdentifier
        let screenSize = screen.frame.size
        guard let raw = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] else { return false }

        for entry in raw {
            guard let pid = entry[kCGWindowOwnerPID as String] as? pid_t, pid != ours else { continue }
            guard let layer = entry[kCGWindowLayer as String] as? Int, layer == 0 else { continue }
            guard let dict = entry[kCGWindowBounds as String] as? NSDictionary else { continue }
            var bounds = CGRect.zero
            CGRectMakeWithDictionaryRepresentation(dict as CFDictionary, &bounds)
            if abs(bounds.origin.x) < 0.5,
               abs(bounds.origin.y) < 0.5,
               abs(bounds.size.width - screenSize.width) < 0.5,
               abs(bounds.size.height - screenSize.height) < 0.5 {
                return true
            }
        }
        return false
    }

    private func updateBarVisibility() {
        guard let bar = barWindow else { return }
        let screen = bar.screen ?? NSScreen.main ?? NSScreen.screens.first
        guard let screen else { return }

        let shouldHide = isAnyAppInNativeFullscreen(on: screen)
        if shouldHide, bar.isVisible {
            bar.orderOut(nil)
        } else if !shouldHide, !bar.isVisible {
            bar.orderFrontRegardless()
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

    @discardableResult
    private func setAXSize(_ element: AXUIElement, size: CGSize) -> AXError {
        var s = size
        guard let value = AXValueCreate(.cgSize, &s) else { return .failure }
        return AXUIElementSetAttributeValue(element, kAXSizeAttribute as CFString, value)
    }

    @discardableResult
    private func setAXPosition(_ element: AXUIElement, point: CGPoint) -> AXError {
        var p = point
        guard let value = AXValueCreate(.cgPoint, &p) else { return .failure }
        return AXUIElementSetAttributeValue(element, kAXPositionAttribute as CFString, value)
    }

    private func copyAXWindows(for appElement: AXUIElement) -> [AXUIElement] {
        var windowsRef: CFTypeRef?
        var listErr = AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &windowsRef)

        // Chromium/Electron apps often keep their AX tree asleep until
        // another client explicitly opts them into manual AX access.
        if listErr == .apiDisabled || listErr == .cannotComplete || listErr == .attributeUnsupported {
            wakeAccessibilityTree(for: appElement)
            windowsRef = nil
            listErr = AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &windowsRef)
        }

        if listErr == .success, let ref = windowsRef as? [AXUIElement], !ref.isEmpty {
            return ref
        }

        var fallback: [AXUIElement] = []
        if let focused = copyAXWindow(appElement, attribute: Self.axFocusedWindowAttribute) {
            fallback.append(focused)
        }
        if let main = copyAXWindow(appElement, attribute: Self.axMainWindowAttribute),
           !fallback.contains(where: { CFEqual($0, main) }) {
            fallback.append(main)
        }
        return fallback
    }

    private func wakeAccessibilityTree(for appElement: AXUIElement) {
        AXUIElementSetAttributeValue(appElement, Self.axManualAccessibilityAttribute, kCFBooleanTrue)
        AXUIElementSetAttributeValue(appElement, Self.axEnhancedUserInterfaceAttribute, kCFBooleanTrue)
    }

    private func copyAXWindow(_ appElement: AXUIElement, attribute: CFString) -> AXUIElement? {
        var valueRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appElement, attribute, &valueRef) == .success,
              let window = valueRef else { return nil }
        return (window as! AXUIElement)
    }

    private func copyAXString(_ element: AXUIElement, attribute: CFString) -> String {
        var valueRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &valueRef) == .success,
              let raw = valueRef as? String else { return "" }
        return raw.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func parseDocumentPath(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if let url = URL(string: trimmed), url.isFileURL {
            return url.path
        }
        return trimmed
    }

    private func stripAppNameSuffix(from title: String, ownerName: String) -> String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }

        for separator in [" — ", " – ", " - ", " —", " –", " -"] {
            let suffix = separator + ownerName
            if trimmed.hasSuffix(suffix) {
                return String(trimmed.dropLast(suffix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        return trimmed
    }

    private func resolveWindowLabel(
        ownerName: String,
        cgTitle: String,
        axTitle: String,
        documentPath: String?
    ) -> ResolvedWindowLabel {
        let cleanedCGTitle = stripAppNameSuffix(from: cgTitle, ownerName: ownerName)
        let cleanedAXTitle = stripAppNameSuffix(from: axTitle, ownerName: ownerName)
        let resolvedDocumentPath = parseDocumentPath(documentPath)

        let documentURL = resolvedDocumentPath.map { URL(fileURLWithPath: $0) }
        let documentName = documentURL?.lastPathComponent.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let documentParent = documentURL?
            .deletingLastPathComponent()
            .lastPathComponent
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        let label = [cleanedCGTitle, cleanedAXTitle, documentName]
            .first(where: { !$0.isEmpty && $0 != ownerName }) ?? ownerName

        var subtitleCandidates: [String] = []
        if !cleanedAXTitle.isEmpty && cleanedAXTitle != label {
            subtitleCandidates.append(cleanedAXTitle)
        }
        if !documentParent.isEmpty && documentParent != label {
            subtitleCandidates.append(documentParent)
        }
        if let resolvedDocumentPath,
           !resolvedDocumentPath.isEmpty,
           resolvedDocumentPath != label {
            subtitleCandidates.append(resolvedDocumentPath)
        }
        if !cleanedCGTitle.isEmpty && cleanedCGTitle != label {
            subtitleCandidates.append(cleanedCGTitle)
        }

        return ResolvedWindowLabel(
            title: label,
            subtitle: subtitleCandidates.first(where: { !$0.isEmpty })
        )
    }

    private func copyAXWindowDetailsByID(for app: NSRunningApplication) -> [CGWindowID: AXWindowDetails] {
        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        let axWindows = copyAXWindows(for: appElement)
        guard !axWindows.isEmpty else { return [:] }

        var result: [CGWindowID: AXWindowDetails] = [:]
        for ax in axWindows {
            var wid: CGWindowID = 0
            guard _AXUIElementGetWindow(ax, &wid) == .success, wid != 0 else { continue }
            result[wid] = AXWindowDetails(
                title: copyAXString(ax, attribute: kAXTitleAttribute as CFString),
                documentPath: parseDocumentPath(copyAXString(ax, attribute: Self.axDocumentAttribute))
            )
        }
        return result
    }

    private func applyClamp(
        _ ax: AXUIElement,
        from position: CGPoint,
        size: CGSize,
        targetY: CGFloat,
        targetHeight: CGFloat
    ) -> Bool {
        let targetPoint = CGPoint(x: position.x, y: targetY)
        let targetSize = CGSize(width: size.width, height: targetHeight)
        let needsMove = abs(targetY - position.y) > 0.5
        let needsResize = abs(targetHeight - size.height) > 0.5

        let attempts: [[(AXUIElement) -> AXError]] = {
            switch (needsMove, needsResize) {
            case (true, true):
                return [
                    [{ self.setAXSize($0, size: targetSize) }, { self.setAXPosition($0, point: targetPoint) }],
                    [{ self.setAXPosition($0, point: targetPoint) }, { self.setAXSize($0, size: targetSize) }]
                ]
            case (true, false):
                return [[{ self.setAXPosition($0, point: targetPoint) }]]
            case (false, true):
                return [[{ self.setAXSize($0, size: targetSize) }]]
            case (false, false):
                return []
            }
        }()

        for operations in attempts {
            var operationFailed = false
            for operation in operations {
                let err = operation(ax)
                if err != .success { operationFailed = true }
            }

            guard !operationFailed else { continue }

            let currentY = axPoint(ax, attribute: kAXPositionAttribute as CFString)?.y ?? position.y
            let currentHeight = axSize(ax, attribute: kAXSizeAttribute as CFString)?.height ?? size.height
            if abs(currentY - targetY) <= 1.0, abs(currentHeight - targetHeight) <= 1.0 {
                return true
            }
        }

        return attempts.isEmpty
    }

    // MARK: - Onscreen

    private func collectOnscreenWindows() -> [WindowInfo] {
        let ours = ProcessInfo.processInfo.processIdentifier
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let raw = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            return []
        }

        let running = NSWorkspace.shared.runningApplications
        let appsByPID = Dictionary(uniqueKeysWithValues: running.map { ($0.processIdentifier, $0) })
        let bundleByPID = Dictionary(uniqueKeysWithValues: running.compactMap { app -> (pid_t, String)? in
            guard let bid = app.bundleIdentifier else { return nil }
            return (app.processIdentifier, bid)
        })

        let snapshots = raw.compactMap { entry -> OnscreenWindowSnapshot? in
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

            return OnscreenWindowSnapshot(
                id: wid,
                ownerPID: pid,
                ownerBundleID: bundleID,
                ownerName: ownerName,
                cgTitle: title,
                bounds: bounds,
                layer: layer
            )
        }

        let pidsNeedingAXTitles = Set(
            snapshots
                .filter {
                    let cgTitle = $0.cgTitle.trimmingCharacters(in: .whitespacesAndNewlines)
                    return cgTitle.isEmpty || cgTitle == $0.ownerName
                }
                .map(\.ownerPID)
        )

        var axDetailsByWindowID: [CGWindowID: AXWindowDetails] = [:]
        for pid in pidsNeedingAXTitles {
            guard let app = appsByPID[pid] else { continue }
            axDetailsByWindowID.merge(copyAXWindowDetailsByID(for: app)) { current, _ in current }
        }

        return snapshots.map { snapshot in
            let axDetails = axDetailsByWindowID[snapshot.id]
            let axTitle = axDetails?.title ?? ""
            let rawTitle = axTitle.isEmpty
                ? snapshot.cgTitle.trimmingCharacters(in: .whitespacesAndNewlines)
                : axTitle
            let resolved = resolveWindowLabel(
                ownerName: snapshot.ownerName,
                cgTitle: snapshot.cgTitle,
                axTitle: axTitle,
                documentPath: axDetails?.documentPath
            )

            return WindowInfo(
                id: snapshot.id,
                ownerPID: snapshot.ownerPID,
                ownerBundleID: snapshot.ownerBundleID,
                ownerName: snapshot.ownerName,
                title: rawTitle,
                label: resolved.title,
                subtitle: resolved.subtitle,
                bounds: snapshot.bounds,
                layer: snapshot.layer,
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

                let title = copyAXString(ax, attribute: kAXTitleAttribute as CFString)
                let resolved = resolveWindowLabel(
                    ownerName: ownerName,
                    cgTitle: "",
                    axTitle: title,
                    documentPath: copyAXString(ax, attribute: Self.axDocumentAttribute)
                )

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
                    label: resolved.title,
                    subtitle: resolved.subtitle,
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
