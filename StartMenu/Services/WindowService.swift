import AppKit
import ApplicationServices
import Combine
import CoreGraphics
import Foundation

@MainActor
final class WindowService: ObservableObject {
    private static let refreshInterval: TimeInterval = 0.2
    private static let axDocumentAttribute = "AXDocument" as CFString

    @Published private(set) var windows: [WindowInfo] = []
    @Published private(set) var activeAppPID: pid_t?

    /// The bar window — used to compute the clamp line so other apps
    /// don't render under the taskbar.
    weak var barWindow: NSWindow?

    private let windowConstrainer: any WindowConstraining
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

    init(windowConstrainer: any WindowConstraining) {
        self.windowConstrainer = windowConstrainer
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
        windowConstrainer.refresh(barWindow: barWindow)
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

    private func updateBarVisibility() {
        guard let bar = barWindow else { return }

        let shouldHide = windowConstrainer.shouldHideBar(for: bar)
        if shouldHide, bar.isVisible {
            bar.orderOut(nil)
        } else if !shouldHide, !bar.isVisible {
            bar.orderFrontRegardless()
        }
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

    private static let axFocusedWindowAttribute = kAXFocusedWindowAttribute as CFString
    private static let axMainWindowAttribute = kAXMainWindowAttribute as CFString
    private static let axManualAccessibilityAttribute = "AXManualAccessibility" as CFString
    private static let axEnhancedUserInterfaceAttribute = "AXEnhancedUserInterface" as CFString

    private func copyAXWindows(for appElement: AXUIElement) -> [AXUIElement] {
        var windowsRef: CFTypeRef?
        var listErr = AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &windowsRef)

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
        return unsafeBitCast(window, to: AXUIElement.self)
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
