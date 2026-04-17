import AppKit
import ApplicationServices
import Combine
import CoreGraphics
import Foundation

@MainActor
final class WindowService: ObservableObject {
    private nonisolated static let refreshInterval: TimeInterval = 0.35
    private nonisolated static let constraintRefreshInterval: TimeInterval = 0.5
    private nonisolated static let interactiveRefreshInterval: TimeInterval = 1.0
    private nonisolated static let deepAXRefreshInterval: TimeInterval = 2.5
    private nonisolated static let minimizedRefreshInterval: TimeInterval = 2.0
    private nonisolated static let minimizedRefreshWhenEmptyInterval: TimeInterval = 6.0
    private nonisolated static let runningAppSnapshotRefreshInterval: TimeInterval = 15.0
    private nonisolated static let axDocumentAttribute = "AXDocument" as CFString
    private nonisolated static let axFocusedWindowAttribute = kAXFocusedWindowAttribute as CFString
    private nonisolated static let axMainWindowAttribute = kAXMainWindowAttribute as CFString
    private nonisolated static let axManualAccessibilityAttribute = "AXManualAccessibility" as CFString
    private nonisolated static let axEnhancedUserInterfaceAttribute = "AXEnhancedUserInterface" as CFString

    @Published private(set) var windows: [WindowInfo] = []
    @Published private(set) var activeAppPID: pid_t?

    /// The bar window — used to compute the clamp line so other apps
    /// don't render under the taskbar.
    weak var barWindow: NSWindow?

    private let windowConstrainer: any WindowConstraining
    private var timer: Timer?
    private var workspaceObservers: [NSObjectProtocol] = []
    private var isRefreshing = false
    private var pendingRefreshReasons: Set<String> = []
    private var lastConstraintRefreshAt: CFAbsoluteTime = 0
    private var lastDeepAXRefreshAt: CFAbsoluteTime = 0
    private var lastMinimizedRefreshAt: CFAbsoluteTime = 0
    private var lastRunningAppSnapshotRefreshAt: CFAbsoluteTime = 0
    private var lastInteractiveTimerRefreshAt: CFAbsoluteTime = 0
    private var cachedWindowPresentation: [CGWindowID: CachedWindowPresentation] = [:]
    private var cachedMinimizedWindows: [WindowInfo] = []
    private var runningAppSnapshots: [RunningAppSnapshot] = []
    private var activeInteractionSources: Set<String> = []

    private nonisolated static let excludedOwnerNames: Set<String> = [
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
        runningAppSnapshots = Self.captureRunningAppSnapshots()
        lastRunningAppSnapshotRefreshAt = CFAbsoluteTimeGetCurrent()
        refresh(reason: "startup")
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
        let didActivate = center.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            Task { @MainActor in
                self?.activeAppPID = app?.processIdentifier
                self?.refresh(reason: "workspace.didActivate")
            }
        }
        workspaceObservers.append(didActivate)

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
                Task { @MainActor in
                    self?.refresh(reason: "workspace.\(name.rawValue)")
                }
            }
            workspaceObservers.append(token)
        }
    }

    func start() {
        timer?.invalidate()
        let t = Timer(timeInterval: Self.refreshInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.refresh(reason: "timer")
            }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    func setInteractionActive(_ isActive: Bool, source: String) {
        let didChange: Bool
        if isActive {
            didChange = activeInteractionSources.insert(source).inserted
        } else {
            didChange = activeInteractionSources.remove(source) != nil
        }

        guard didChange else { return }

        PerformanceDiagnostics.recordEvent(
            isActive ? "interactive_surface_activated" : "interactive_surface_deactivated",
            category: "window_service",
            fields: [
                "source": source,
                "activeSources": activeInteractionSources.sorted().joined(separator: ",")
            ]
        )

        if activeInteractionSources.isEmpty {
            lastInteractiveTimerRefreshAt = 0
            refresh(reason: "interactive_surface.released[\(source)]")
        }
    }

    func refresh(reason: String = "manual") {
        guard !isRefreshing else {
            pendingRefreshReasons.insert(reason)
            return
        }

        let now = CFAbsoluteTimeGetCurrent()
        if shouldSkipTimerRefresh(reason: reason, now: now) {
            return
        }
        let refreshedRunningApps = shouldRefreshRunningAppSnapshots(reason: reason, now: now)
        if refreshedRunningApps {
            runningAppSnapshots = Self.captureRunningAppSnapshots()
            lastRunningAppSnapshotRefreshAt = now
        }
        let runningApps = runningAppSnapshots
        let regularAppPIDs = runningApps.filter(\.isRegular).map(\.pid)
        let activePID = activeAppPID ?? NSWorkspace.shared.frontmostApplication?.processIdentifier
        let performDeepAXRefresh = shouldPerformDeepAXRefresh(reason: reason, now: now)
        let cachedPresentation = cachedWindowPresentation
        let cachedMinimized = cachedMinimizedWindows
        let performMinimizedRefresh = shouldPerformMinimizedRefresh(
            reason: reason,
            now: now,
            hasCachedMinimizedWindows: !cachedMinimized.isEmpty
        )

        let cycleSpan = PerformanceDiagnostics.begin(
            category: "window_service",
            name: "refresh_cycle",
            thresholdMs: 24,
            fields: [
                "reason": reason,
                "runningApps": String(runningApps.count),
                "runningAppsSource": refreshedRunningApps ? "live" : "cache",
                "deepAX": String(performDeepAXRefresh),
                "minimizedScan": String(performMinimizedRefresh)
            ]
        )

        let snapshotSpan = PerformanceDiagnostics.begin(
            category: "window_service",
            name: "refresh_snapshot_build",
            thresholdMs: 16,
            fields: [
                "reason": reason,
                "runningApps": String(runningApps.count),
                "runningAppsSource": refreshedRunningApps ? "live" : "cache",
                "deepAX": String(performDeepAXRefresh),
                "minimizedScan": String(performMinimizedRefresh)
            ]
        )

        isRefreshing = true
        var followUpReason: String?
        defer {
            isRefreshing = false
            if let followUpReason {
                refresh(reason: followUpReason)
            }
        }

        let snapshot = Self.buildRefreshSnapshot(
            runningApps: runningApps,
            activeAppPID: activePID,
            cachedWindowPresentation: cachedPresentation,
            cachedMinimizedWindows: cachedMinimized,
            performDeepAXRefresh: performDeepAXRefresh,
            performMinimizedRefresh: performMinimizedRefresh
        )

        snapshotSpan.end(extraFields: snapshot.metrics.fields)

        let didWindowsChange = snapshot.windows != windows

        if snapshot.activeAppPID != activeAppPID {
            activeAppPID = snapshot.activeAppPID
        }

        cachedWindowPresentation = snapshot.windowPresentationCache
        cachedMinimizedWindows = snapshot.minimizedWindows
        if performDeepAXRefresh {
            lastDeepAXRefreshAt = now
        }
        if performMinimizedRefresh {
            lastMinimizedRefreshAt = now
        }

        if didWindowsChange {
            windows = snapshot.windows
            PerformanceDiagnostics.recordEvent(
                "window_snapshot_changed",
                category: "window_service",
                fields: snapshot.metrics.fields.merging(
                    [
                        "reason": reason,
                        "windows": String(snapshot.windows.count)
                    ]
                ) { _, new in new }
            )
        }

        updateBarVisibility()
        refreshWindowConstraintsIfNeeded(
            reason: reason,
            force: didWindowsChange || reason != "timer",
            regularAppPIDs: regularAppPIDs
        )

        cycleSpan.end(
            extraFields: snapshot.metrics.fields.merging(
                [
                    "reason": reason,
                    "changed": String(didWindowsChange),
                    "windows": String(snapshot.windows.count)
                ]
            ) { _, new in new }
        )

        if !pendingRefreshReasons.isEmpty {
            followUpReason = coalescedReasonSummary()
            pendingRefreshReasons.removeAll()
        }
    }

    private func shouldPerformDeepAXRefresh(reason: String, now: CFAbsoluteTime) -> Bool {
        if !isTimerOnlyReason(reason) {
            return true
        }
        return now - lastDeepAXRefreshAt >= Self.deepAXRefreshInterval
    }

    private func shouldPerformMinimizedRefresh(
        reason: String,
        now: CFAbsoluteTime,
        hasCachedMinimizedWindows: Bool
    ) -> Bool {
        if !isTimerOnlyReason(reason) {
            return true
        }
        let interval = hasCachedMinimizedWindows
            ? Self.minimizedRefreshInterval
            : Self.minimizedRefreshWhenEmptyInterval
        return now - lastMinimizedRefreshAt >= interval
    }

    private func shouldRefreshRunningAppSnapshots(reason: String, now: CFAbsoluteTime) -> Bool {
        if runningAppSnapshots.isEmpty { return true }
        if reason == "startup" { return true }
        if reason.contains("DidLaunchApplication") || reason.contains("DidTerminateApplication") {
            return true
        }
        return now - lastRunningAppSnapshotRefreshAt >= Self.runningAppSnapshotRefreshInterval
    }

    private func shouldSkipTimerRefresh(reason: String, now: CFAbsoluteTime) -> Bool {
        guard !activeInteractionSources.isEmpty, isTimerOnlyReason(reason) else {
            return false
        }
        guard now - lastInteractiveTimerRefreshAt >= Self.interactiveRefreshInterval else {
            return true
        }
        lastInteractiveTimerRefreshAt = now
        return false
    }

    private func isTimerOnlyReason(_ reason: String) -> Bool {
        if reason == "timer" { return true }
        if reason == "coalesced[timer]" { return true }
        return reason.hasPrefix("coalesced[timer,")
    }

    private func coalescedReasonSummary() -> String {
        let reasons = pendingRefreshReasons.sorted()
        guard !reasons.isEmpty else { return "coalesced" }
        let prefix = reasons.prefix(3).joined(separator: ",")
        let suffix = reasons.count > 3 ? ",…" : ""
        return "coalesced[\(prefix)\(suffix)]"
    }

    private func refreshWindowConstraintsIfNeeded(
        reason: String,
        force: Bool,
        regularAppPIDs: [pid_t]
    ) {
        let now = CFAbsoluteTimeGetCurrent()
        guard force || now - lastConstraintRefreshAt >= Self.constraintRefreshInterval else {
            return
        }
        lastConstraintRefreshAt = now

        let span = PerformanceDiagnostics.begin(
            category: "window_constrainer",
            name: "refresh",
            thresholdMs: 18,
            fields: ["reason": reason]
        )
        windowConstrainer.refresh(barWindow: barWindow, regularAppPIDs: regularAppPIDs)
        span.end()
    }

    private struct RunningAppSnapshot: Sendable {
        let pid: pid_t
        let bundleID: String?
        let localizedName: String
        let isRegular: Bool
    }

    private struct RefreshMetrics: Sendable {
        let runningRegularAppCount: Int
        let onscreenCount: Int
        let minimizedCount: Int
        let placeholderCount: Int
        let axLookupPIDCount: Int
        let onscreenDurationMs: Double
        let minimizedDurationMs: Double
        let placeholderDurationMs: Double
        let sortDurationMs: Double

        var fields: [String: String] {
            [
                "runningRegularApps": String(runningRegularAppCount),
                "onscreen": String(onscreenCount),
                "minimized": String(minimizedCount),
                "placeholders": String(placeholderCount),
                "axLookupPIDs": String(axLookupPIDCount),
                "onscreenMs": Self.format(durationMs: onscreenDurationMs),
                "minimizedMs": Self.format(durationMs: minimizedDurationMs),
                "placeholdersMs": Self.format(durationMs: placeholderDurationMs),
                "sortMs": Self.format(durationMs: sortDurationMs)
            ]
        }

        private static func format(durationMs: Double) -> String {
            String(format: "%.1f", durationMs)
        }
    }

    private struct RefreshSnapshot: Sendable {
        let activeAppPID: pid_t?
        let windows: [WindowInfo]
        let metrics: RefreshMetrics
        let minimizedWindows: [WindowInfo]
        let windowPresentationCache: [CGWindowID: CachedWindowPresentation]
    }

    private struct CachedWindowPresentation: Sendable {
        let title: String
        let label: String
        let subtitle: String?
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

    private static func captureRunningAppSnapshots() -> [RunningAppSnapshot] {
        NSWorkspace.shared.runningApplications.map { app in
            RunningAppSnapshot(
                pid: app.processIdentifier,
                bundleID: app.bundleIdentifier,
                localizedName: app.localizedName ?? "",
                isRegular: app.activationPolicy == .regular
            )
        }
    }

    private nonisolated static func buildRefreshSnapshot(
        runningApps: [RunningAppSnapshot],
        activeAppPID: pid_t?,
        cachedWindowPresentation: [CGWindowID: CachedWindowPresentation],
        cachedMinimizedWindows: [WindowInfo],
        performDeepAXRefresh: Bool,
        performMinimizedRefresh: Bool
    ) -> RefreshSnapshot {
        let onscreenStartedAt = CFAbsoluteTimeGetCurrent()
        let onscreenResult = collectOnscreenWindows(
            runningApps: runningApps,
            cachedWindowPresentation: cachedWindowPresentation,
            performDeepAXRefresh: performDeepAXRefresh
        )
        let onscreenDurationMs = (CFAbsoluteTimeGetCurrent() - onscreenStartedAt) * 1_000
        let onscreen = onscreenResult.windows

        let minimized: [WindowInfo]
        let minimizedStartedAt = CFAbsoluteTimeGetCurrent()
        if performMinimizedRefresh {
            minimized = collectMinimizedWindows(
                runningApps: runningApps,
                excludingIDs: Set(onscreen.map(\.id))
            )
        } else {
            let excludedIDs = Set(onscreen.map(\.id))
            minimized = cachedMinimizedWindows.filter { !excludedIDs.contains($0.id) }
        }
        let minimizedDurationMs = (CFAbsoluteTimeGetCurrent() - minimizedStartedAt) * 1_000

        let placeholdersStartedAt = CFAbsoluteTimeGetCurrent()
        let placeholders = placeholdersForInvisibleApps(
            runningApps: runningApps,
            existingPIDs: Set((onscreen + minimized).map(\.ownerPID))
        )
        let placeholderDurationMs = (CFAbsoluteTimeGetCurrent() - placeholdersStartedAt) * 1_000
        let combined = onscreen + minimized + placeholders

        let sortStartedAt = CFAbsoluteTimeGetCurrent()
        let sorted = combined.sorted {
            if $0.ownerName == $1.ownerName { return $0.id < $1.id }
            return $0.ownerName.localizedCaseInsensitiveCompare($1.ownerName) == .orderedAscending
        }
        let sortDurationMs = (CFAbsoluteTimeGetCurrent() - sortStartedAt) * 1_000

        return RefreshSnapshot(
            activeAppPID: activeAppPID,
            windows: sorted,
            metrics: RefreshMetrics(
                runningRegularAppCount: runningApps.filter(\.isRegular).count,
                onscreenCount: onscreen.count,
                minimizedCount: minimized.count,
                placeholderCount: placeholders.count,
                axLookupPIDCount: onscreenResult.axLookupPIDCount,
                onscreenDurationMs: onscreenDurationMs,
                minimizedDurationMs: minimizedDurationMs,
                placeholderDurationMs: placeholderDurationMs,
                sortDurationMs: sortDurationMs
            ),
            minimizedWindows: minimized,
            windowPresentationCache: makeWindowPresentationCache(from: sorted)
        )
    }

    private nonisolated static func makeWindowPresentationCache(
        from windows: [WindowInfo]
    ) -> [CGWindowID: CachedWindowPresentation] {
        Dictionary(uniqueKeysWithValues: windows.map { window in
            (
                window.id,
                CachedWindowPresentation(
                    title: window.title,
                    label: window.label,
                    subtitle: window.subtitle
                )
            )
        })
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
    private nonisolated static func placeholdersForInvisibleApps(
        runningApps: [RunningAppSnapshot],
        existingPIDs: Set<pid_t>
    ) -> [WindowInfo] {
        let ours = ProcessInfo.processInfo.processIdentifier
        var result: [WindowInfo] = []

        for app in runningApps {
            guard app.isRegular else { continue }
            let pid = app.pid
            if pid == ours { continue }
            if existingPIDs.contains(pid) { continue }

            let name = app.localizedName
            if Self.excludedOwnerNames.contains(name) { continue }
            if name.isEmpty { continue }

            let synthID = CGWindowID(0xE000_0000 | (UInt32(bitPattern: pid) & 0x1FFF_FFFF))

            result.append(WindowInfo(
                id: synthID,
                ownerPID: pid,
                ownerBundleID: app.bundleID,
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

    private func updateBarVisibility() {
        guard let bar = barWindow else { return }

        let shouldHide = windowConstrainer.shouldHideBar(for: bar)
        if shouldHide, bar.isVisible {
            bar.orderOut(nil)
        } else if !shouldHide, !bar.isVisible {
            bar.orderFrontRegardless()
        }
    }

    private nonisolated static func copyAXString(_ element: AXUIElement, attribute: CFString) -> String {
        var valueRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &valueRef) == .success,
              let raw = valueRef as? String else { return "" }
        return raw.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private nonisolated static func parseDocumentPath(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if let url = URL(string: trimmed), url.isFileURL {
            return url.path
        }
        return trimmed
    }

    private nonisolated static func stripAppNameSuffix(from title: String, ownerName: String) -> String {
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

    private nonisolated static func resolveWindowLabel(
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

    private nonisolated static func copyAXWindows(for appElement: AXUIElement) -> [AXUIElement] {
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

    private nonisolated static func wakeAccessibilityTree(for appElement: AXUIElement) {
        AXUIElementSetAttributeValue(appElement, Self.axManualAccessibilityAttribute, kCFBooleanTrue)
        AXUIElementSetAttributeValue(appElement, Self.axEnhancedUserInterfaceAttribute, kCFBooleanTrue)
    }

    private nonisolated static func copyAXWindow(_ appElement: AXUIElement, attribute: CFString) -> AXUIElement? {
        var valueRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appElement, attribute, &valueRef) == .success,
              let window = valueRef else { return nil }
        return unsafeBitCast(window, to: AXUIElement.self)
    }

    private nonisolated static func copyAXWindowDetailsByID(for pid: pid_t) -> [CGWindowID: AXWindowDetails] {
        let appElement = AXUIElementCreateApplication(pid)
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

    private nonisolated static func collectOnscreenWindows(
        runningApps: [RunningAppSnapshot],
        cachedWindowPresentation: [CGWindowID: CachedWindowPresentation],
        performDeepAXRefresh: Bool
    ) -> (windows: [WindowInfo], axLookupPIDCount: Int) {
        let ours = ProcessInfo.processInfo.processIdentifier
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let raw = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            return ([], 0)
        }

        let bundleByPID = Dictionary(
            uniqueKeysWithValues: runningApps.compactMap { app -> (pid_t, String)? in
                guard let bid = app.bundleID else { return nil }
                return (app.pid, bid)
            }
        )

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

        var pidsNeedingAXTitles = Set<pid_t>()
        if performDeepAXRefresh {
            pidsNeedingAXTitles = Set(
                snapshots
                    .filter {
                        let cgTitle = $0.cgTitle.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard cgTitle.isEmpty || cgTitle == $0.ownerName else { return false }
                        return cachedWindowPresentation[$0.id] == nil
                    }
                    .map(\.ownerPID)
            )
        }

        var axDetailsByWindowID: [CGWindowID: AXWindowDetails] = [:]
        for pid in pidsNeedingAXTitles {
            axDetailsByWindowID.merge(copyAXWindowDetailsByID(for: pid)) { current, _ in current }
        }

        let windows = snapshots.map { snapshot in
            let cachedPresentation = cachedWindowPresentation[snapshot.id]
            let axDetails = axDetailsByWindowID[snapshot.id]
            let axTitle = axDetails?.title ?? ""
            let rawTitle: String
            let resolved: ResolvedWindowLabel
            if let axDetails {
                rawTitle = axTitle.isEmpty
                    ? snapshot.cgTitle.trimmingCharacters(in: .whitespacesAndNewlines)
                    : axTitle
                resolved = resolveWindowLabel(
                    ownerName: snapshot.ownerName,
                    cgTitle: snapshot.cgTitle,
                    axTitle: axTitle,
                    documentPath: axDetails.documentPath
                )
            } else if let cachedPresentation,
                      (
                        snapshot.cgTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        || snapshot.cgTitle.trimmingCharacters(in: .whitespacesAndNewlines) == snapshot.ownerName
                      ) {
                rawTitle = cachedPresentation.title
                resolved = ResolvedWindowLabel(
                    title: cachedPresentation.label,
                    subtitle: cachedPresentation.subtitle
                )
            } else {
                rawTitle = snapshot.cgTitle.trimmingCharacters(in: .whitespacesAndNewlines)
                resolved = resolveWindowLabel(
                    ownerName: snapshot.ownerName,
                    cgTitle: snapshot.cgTitle,
                    axTitle: "",
                    documentPath: nil
                )
            }

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

        return (windows, pidsNeedingAXTitles.count)
    }

    // MARK: - Minimized (AX scan)

    private nonisolated static func collectMinimizedWindows(
        runningApps: [RunningAppSnapshot],
        excludingIDs: Set<CGWindowID>
    ) -> [WindowInfo] {
        let ours = ProcessInfo.processInfo.processIdentifier
        var result: [WindowInfo] = []

        for app in runningApps {
            guard app.isRegular else { continue }
            let pid = app.pid
            if pid == ours { continue }

            let ownerName = app.localizedName
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
                    resolvedID = CGWindowID(
                        0xC000_0000 | UInt32(truncatingIfNeeded: hasher.finalize() & 0x3FFF_FFFF)
                    )
                }

                if excludingIDs.contains(resolvedID) { continue }

                result.append(WindowInfo(
                    id: resolvedID,
                    ownerPID: pid,
                    ownerBundleID: app.bundleID,
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
