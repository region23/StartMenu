import AppKit
import ApplicationServices
import Foundation
import os

@MainActor
final class WindowController {
    private let log = Logger(subsystem: AppFlavor.current.logSubsystem, category: "windows")
    private static let axFocusedWindowAttribute = kAXFocusedWindowAttribute as CFString
    private static let axMainWindowAttribute = kAXMainWindowAttribute as CFString
    private static let axManualAccessibilityAttribute = "AXManualAccessibility" as CFString
    private static let axEnhancedUserInterfaceAttribute = "AXEnhancedUserInterface" as CFString

    func activate(_ window: WindowInfo) {
        log.info("activate pid=\(window.ownerPID, privacy: .public) title=\(window.displayTitle, privacy: .public)")
        bringAppToFront(pid: window.ownerPID)

        if let ax = findAXWindow(for: window) {
            AXUIElementPerformAction(ax, kAXRaiseAction as CFString)
            AXUIElementSetAttributeValue(ax, kAXMainAttribute as CFString, kCFBooleanTrue)
            AXUIElementSetAttributeValue(ax, kAXFocusedAttribute as CFString, kCFBooleanTrue)
            if getMinimized(of: ax) == true {
                AXUIElementSetAttributeValue(ax, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
            }
            return
        }

        // No AX window found — happens for apps that disabled the
        // Accessibility API (Chromium/Electron) or for a placeholder
        // chip we synthesized because the app has no visible window.
        // Fall back to LaunchServices openApplication which triggers
        // applicationShouldHandleReopen on the already-running target.
        // Most macOS apps respond by unminimizing their main window or
        // opening a fresh one.
        if let running = NSRunningApplication(processIdentifier: window.ownerPID),
           let url = running.bundleURL {
            let config = NSWorkspace.OpenConfiguration()
            config.activates = true
            NSWorkspace.shared.openApplication(at: url, configuration: config) { _, _ in }
        }
    }

    func close(_ window: WindowInfo) {
        log.info("close pid=\(window.ownerPID, privacy: .public) wid=\(window.id, privacy: .public)")

        guard let ax = findAXWindow(for: window) else {
            log.error("close: findAXWindow returned nil, using app-level fallback")
            bringAppToFront(pid: window.ownerPID)
            runScript("""
            tell application "System Events"
                keystroke "w" using {command down}
            end tell
            """, label: "close-fallback-no-ax")
            return
        }
        log.info("close: found AX window")

        var buttonRef: CFTypeRef?
        let copyErr = AXUIElementCopyAttributeValue(ax, kAXCloseButtonAttribute as CFString, &buttonRef)
        log.info("close: AXCloseButton copy err=\(copyErr.rawValue, privacy: .public)")

        if copyErr == .success, let ref = buttonRef {
            let button = ref as! AXUIElement
            let pressErr = AXUIElementPerformAction(button, kAXPressAction as CFString)
            log.info("close: press err=\(pressErr.rawValue, privacy: .public)")
            if pressErr == .success { return }
        }

        log.info("close: falling back to System Events keystroke")
        runScript("""
        tell application "System Events"
            set frontmost of (first process whose unix id is \(window.ownerPID)) to true
            delay 0.05
            keystroke "w" using {command down}
        end tell
        """, label: "close-fallback")
    }

    func minimize(_ window: WindowInfo) {
        log.info("minimize pid=\(window.ownerPID, privacy: .public) wid=\(window.id, privacy: .public)")

        guard let ax = findAXWindow(for: window) else {
            log.error("minimize: findAXWindow returned nil, using app-level fallback")
            bringAppToFront(pid: window.ownerPID)
            runScript("""
            tell application "System Events"
                keystroke "m" using {command down}
            end tell
            """, label: "minimize-fallback-no-ax")
            return
        }
        log.info("minimize: found AX window")

        let err = AXUIElementSetAttributeValue(ax, kAXMinimizedAttribute as CFString, kCFBooleanTrue)
        log.info("minimize: set err=\(err.rawValue, privacy: .public)")
        if err == .success { return }

        log.info("minimize: falling back to System Events keystroke")
        runScript("""
        tell application "System Events"
            set frontmost of (first process whose unix id is \(window.ownerPID)) to true
            delay 0.05
            keystroke "m" using {command down}
        end tell
        """, label: "minimize-fallback")
    }

    private func bringAppToFront(pid: pid_t) {
        runScript("""
        tell application "System Events"
            set frontmost of (first process whose unix id is \(pid)) to true
        end tell
        """, label: "frontmost")
    }

    private func runScript(_ source: String, label: String) {
        var error: NSDictionary?
        let script = NSAppleScript(source: source)
        _ = script?.executeAndReturnError(&error)
        if let error {
            log.error("\(label, privacy: .public) script failed: \(String(describing: error), privacy: .public)")
        } else {
            log.info("\(label, privacy: .public) script ok")
        }
    }

    private func findAXWindow(for window: WindowInfo) -> AXUIElement? {
        let trusted = AXIsProcessTrusted()
        log.info("findAXWindow: pid=\(window.ownerPID, privacy: .public) AXIsProcessTrusted=\(trusted, privacy: .public)")
        let app = AXUIElementCreateApplication(window.ownerPID)
        let axWindows = copyAXWindows(for: app)
        log.info("findAXWindow: pid=\(window.ownerPID, privacy: .public) count=\(axWindows.count, privacy: .public)")
        if axWindows.isEmpty { return nil }

        for ax in axWindows {
            var wid: CGWindowID = 0
            if _AXUIElementGetWindow(ax, &wid) == .success && wid == window.id {
                log.info("findAXWindow: matched by CGWindowID")
                return ax
            }
        }
        if let byTitle = axWindows.first(where: { matches(window, ax: $0) }) {
            log.info("findAXWindow: matched by title")
            return byTitle
        }
        log.info("findAXWindow: fallback to first window")
        return axWindows.first
    }

    private func copyAXWindows(for app: AXUIElement) -> [AXUIElement] {
        var windowsRef: CFTypeRef?
        var copyErr = AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &windowsRef)
        if copyErr == .apiDisabled || copyErr == .cannotComplete || copyErr == .attributeUnsupported {
            wakeAccessibilityTree(for: app)
            windowsRef = nil
            copyErr = AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &windowsRef)
        }

        if copyErr == .success, let ref = windowsRef as? [AXUIElement], !ref.isEmpty {
            return ref
        }

        log.error("findAXWindow: fallback copyErr=\(copyErr.rawValue, privacy: .public)")

        var fallback: [AXUIElement] = []
        if let focused = copyWindow(app, attribute: Self.axFocusedWindowAttribute) {
            fallback.append(focused)
        }
        if let main = copyWindow(app, attribute: Self.axMainWindowAttribute),
           !fallback.contains(where: { CFEqual($0, main) }) {
            fallback.append(main)
        }
        return fallback
    }

    private func wakeAccessibilityTree(for app: AXUIElement) {
        AXUIElementSetAttributeValue(app, Self.axManualAccessibilityAttribute, kCFBooleanTrue)
        AXUIElementSetAttributeValue(app, Self.axEnhancedUserInterfaceAttribute, kCFBooleanTrue)
    }

    private func copyWindow(_ app: AXUIElement, attribute: CFString) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, attribute, &value) == .success,
              let value else { return nil }
        return unsafeBitCast(value, to: AXUIElement.self)
    }

    private func matches(_ window: WindowInfo, ax: AXUIElement) -> Bool {
        guard !window.title.isEmpty else { return false }
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(ax, kAXTitleAttribute as CFString, &value) == .success,
              let title = value as? String else { return false }
        return title == window.title
    }

    private func getMinimized(of ax: AXUIElement) -> Bool? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(ax, kAXMinimizedAttribute as CFString, &value) == .success else {
            return nil
        }
        return value as? Bool
    }
}
