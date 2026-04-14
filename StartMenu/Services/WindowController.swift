import AppKit
import ApplicationServices
import Foundation
import os

@MainActor
final class WindowController {
    private let log = Logger(subsystem: "app.pavlenko.startmenu", category: "windows")

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
        }
    }

    func close(_ window: WindowInfo) {
        log.info("close pid=\(window.ownerPID, privacy: .public) wid=\(window.id, privacy: .public)")

        guard let ax = findAXWindow(for: window) else {
            log.error("close: findAXWindow returned nil")
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
            log.error("minimize: findAXWindow returned nil")
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
        var windowsRef: CFTypeRef?
        let copyErr = AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &windowsRef)
        guard copyErr == .success, let ref = windowsRef else {
            log.error("findAXWindow: pid=\(window.ownerPID, privacy: .public) copyErr=\(copyErr.rawValue, privacy: .public)")
            return nil
        }
        let axWindows = ref as! [AXUIElement]
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
