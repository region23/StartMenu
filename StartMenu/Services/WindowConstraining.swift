import AppKit
import ApplicationServices
import Foundation
import os.log

struct DisplayMetricsSnapshot: Equatable, Sendable {
    let displayName: String
    let frame: CGRect
    let visibleFrame: CGRect
    let barFrame: CGRect?
}

@MainActor
protocol WindowConstraining {
    var diagnosticsName: String { get }

    func refresh(barWindow: NSWindow?, regularAppPIDs: [pid_t])
    func shouldHideBar(for barWindow: NSWindow) -> Bool
    func metrics(for barWindow: NSWindow?) -> DisplayMetricsSnapshot?
}

@MainActor
final class AXWindowConstrainer: WindowConstraining {
    private let log = OSLog(subsystem: AppFlavor.current.logSubsystem, category: "clamp")

    private static let axFullScreenAttribute = "AXFullScreen" as CFString
    private static let axFocusedWindowAttribute = kAXFocusedWindowAttribute as CFString
    private static let axMainWindowAttribute = kAXMainWindowAttribute as CFString
    private static let axManualAccessibilityAttribute = "AXManualAccessibility" as CFString
    private static let axEnhancedUserInterfaceAttribute = "AXEnhancedUserInterface" as CFString

    var diagnosticsName: String {
        "AXWindowConstrainer"
    }

    func refresh(barWindow: NSWindow?, regularAppPIDs: [pid_t]) {
        let span = PerformanceDiagnostics.begin(
            category: "window_constrainer",
            name: "ax_refresh",
            thresholdMs: 18
        )
        defer { span.end() }

        guard let barWindow,
              barWindow.isVisible,
              let screen = barWindow.screen ?? NSScreen.main else { return }
        guard AXIsProcessTrusted() else { return }

        if isAnyAppInNativeFullscreen(on: screen) { return }

        let screenHeight = screen.frame.height
        let visible = screen.visibleFrame
        let topQuartz = screenHeight - visible.maxY
        let barTopQuartz = screenHeight - barWindow.frame.maxY
        let usableHeight = barTopQuartz - topQuartz
        let ours = ProcessInfo.processInfo.processIdentifier

        for pid in regularAppPIDs {
            if pid == ours { continue }

            let appElement = AXUIElementCreateApplication(pid)
            let axWindows = copyAXWindows(for: appElement)
            if axWindows.isEmpty { continue }

            for ax in axWindows {
                var minRef: CFTypeRef?
                if AXUIElementCopyAttributeValue(ax, kAXMinimizedAttribute as CFString, &minRef) == .success,
                   (minRef as? Bool) == true {
                    continue
                }

                var roleRef: CFTypeRef?
                AXUIElementCopyAttributeValue(ax, kAXRoleAttribute as CFString, &roleRef)
                let role = (roleRef as? String) ?? "?"

                var subroleRef: CFTypeRef?
                AXUIElementCopyAttributeValue(ax, kAXSubroleAttribute as CFString, &subroleRef)
                let subrole = (subroleRef as? String) ?? "?"

                var fsRef: CFTypeRef?
                if AXUIElementCopyAttributeValue(ax, Self.axFullScreenAttribute, &fsRef) == .success,
                   (fsRef as? Bool) == true {
                    continue
                }

                let position = axPoint(ax, attribute: kAXPositionAttribute as CFString) ?? .zero
                let size = axSize(ax, attribute: kAXSizeAttribute as CFString) ?? .zero

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

                os_log(
                    "clamp pid=%{public}d oldY=%{public}.0f oldH=%{public}.0f -> newY=%{public}.0f newH=%{public}.0f ok=%{public}s",
                    log: log,
                    type: clamped ? .info : .error,
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

    func shouldHideBar(for barWindow: NSWindow) -> Bool {
        let span = PerformanceDiagnostics.begin(
            category: "window_constrainer",
            name: "fullscreen_probe",
            thresholdMs: 8
        )
        defer { span.end() }

        guard let screen = barWindow.screen ?? NSScreen.main ?? NSScreen.screens.first else {
            return false
        }
        return isAnyAppInNativeFullscreen(on: screen)
    }

    func metrics(for barWindow: NSWindow?) -> DisplayMetricsSnapshot? {
        guard let screen = barWindow?.screen ?? NSScreen.main ?? NSScreen.screens.first else {
            return nil
        }

        return DisplayMetricsSnapshot(
            displayName: screen.localizedName,
            frame: screen.frame,
            visibleFrame: screen.visibleFrame,
            barFrame: barWindow?.frame
        )
    }

    private func isAnyAppInNativeFullscreen(on screen: NSScreen) -> Bool {
        let ours = ProcessInfo.processInfo.processIdentifier
        let screenSize = screen.frame.size
        guard let raw = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] else {
            return false
        }

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
        var mutableSize = size
        guard let value = AXValueCreate(.cgSize, &mutableSize) else { return .failure }
        return AXUIElementSetAttributeValue(element, kAXSizeAttribute as CFString, value)
    }

    @discardableResult
    private func setAXPosition(_ element: AXUIElement, point: CGPoint) -> AXError {
        var mutablePoint = point
        guard let value = AXValueCreate(.cgPoint, &mutablePoint) else { return .failure }
        return AXUIElementSetAttributeValue(element, kAXPositionAttribute as CFString, value)
    }

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
}

@MainActor
final class DockInjectionWindowConstrainer: WindowConstraining {
    private let bridge: any PowerUserBridge
    private let fallback: any WindowConstraining
    private let featureFlags: PowerUserFeatureFlags

    init(
        bridge: any PowerUserBridge,
        fallback: any WindowConstraining,
        featureFlags: PowerUserFeatureFlags
    ) {
        self.bridge = bridge
        self.fallback = fallback
        self.featureFlags = featureFlags
    }

    var diagnosticsName: String {
        if featureFlags.isEnabled(.realDesktopReservation) {
            if bridge.supportsPrivateDesktopReservation {
                if featureFlags.isEnabled(.privateMaximizeHandling) {
                    return "DockInjectionWindowConstrainer (reserved + AX guard)"
                }
                return "DockInjectionWindowConstrainer"
            }
            if bridge.isConnected {
                return "DockInjectionWindowConstrainer (AX fallback)"
            }
        }
        return fallback.diagnosticsName
    }

    func refresh(barWindow: NSWindow?, regularAppPIDs: [pid_t]) {
        if featureFlags.isEnabled(.realDesktopReservation),
           bridge.supportsPrivateDesktopReservation,
           !featureFlags.isEnabled(.privateMaximizeHandling) {
            return
        }
        fallback.refresh(barWindow: barWindow, regularAppPIDs: regularAppPIDs)
    }

    func shouldHideBar(for barWindow: NSWindow) -> Bool {
        fallback.shouldHideBar(for: barWindow)
    }

    func metrics(for barWindow: NSWindow?) -> DisplayMetricsSnapshot? {
        fallback.metrics(for: barWindow)
    }
}
