import AppKit
import ApplicationServices
import Foundation
import os

@MainActor
final class MenuBarExtrasService: ObservableObject {
    @Published private(set) var items: [MenuBarExtraInfo] = []
    @Published private(set) var hasAccessibilityAccess = AXIsProcessTrusted()

    private var timer: Timer?
    private var elementsByID: [String: AXUIElement] = [:]
    private let log = Logger(subsystem: "app.pavlenko.startmenu", category: "menuextras")

    private static let refreshInterval: TimeInterval = 3.0

    init() {
        refresh()
        start()
    }

    deinit {
        timer?.invalidate()
    }

    func start() {
        timer?.invalidate()
        let timer = Timer(timeInterval: Self.refreshInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.refresh()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func refresh() {
        hasAccessibilityAccess = AXIsProcessTrusted()
        guard hasAccessibilityAccess else {
            items = []
            elementsByID = [:]
            return
        }

        let ourPID = ProcessInfo.processInfo.processIdentifier
        var resolved: [MenuBarExtraInfo] = []
        var elements: [String: AXUIElement] = [:]

        for app in NSWorkspace.shared.runningApplications where !app.isTerminated {
            let pid = app.processIdentifier
            if pid == ourPID { continue }

            let appElement = AXUIElementCreateApplication(pid)
            guard let extrasBar = copyElement(appElement, attribute: kAXExtrasMenuBarAttribute as CFString) else {
                continue
            }

            let children = copyElements(extrasBar, attribute: kAXChildrenAttribute as CFString)
            guard !children.isEmpty else { continue }

            let ownerName = app.localizedName ?? app.bundleIdentifier ?? "Menu Bar Item"
            let ownerBundleID = app.bundleIdentifier

            for (index, child) in children.enumerated() {
                let title = copyString(child, attribute: kAXTitleAttribute as CFString) ?? ""
                let description = copyString(child, attribute: kAXDescriptionAttribute as CFString) ?? ""
                let help = copyString(child, attribute: kAXHelpAttribute as CFString) ?? ""
                let label = [title, description, help, ownerName]
                    .first(where: { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) ?? ownerName

                let position = copyPoint(child, attribute: kAXPositionAttribute as CFString) ?? .zero
                let size = copySize(child, attribute: kAXSizeAttribute as CFString) ?? .zero
                let frame = CGRect(origin: position, size: size)

                let actions = copyActions(child)
                let item = MenuBarExtraInfo(
                    id: makeID(pid: pid, index: index, label: label, frame: frame),
                    ownerPID: pid,
                    ownerBundleID: ownerBundleID,
                    ownerName: ownerName,
                    title: title,
                    description: description.isEmpty ? help : description,
                    frame: frame,
                    canPress: actions.contains(kAXPressAction as String),
                    canShowMenu: actions.contains(kAXShowMenuAction as String)
                )
                resolved.append(item)
                elements[item.id] = child
            }
        }

        resolved.sort { lhs, rhs in
            if abs(lhs.frame.minX - rhs.frame.minX) > 0.5 {
                return lhs.frame.minX < rhs.frame.minX
            }
            return lhs.displayTitle.localizedCaseInsensitiveCompare(rhs.displayTitle) == .orderedAscending
        }

        items = resolved
        elementsByID = elements
    }

    func activate(_ item: MenuBarExtraInfo) {
        guard let element = elementsByID[item.id] else {
            refresh()
            guard let element = elementsByID[item.id] else { return }
            performAction(on: element, item: item, primary: true)
            return
        }
        performAction(on: element, item: item, primary: true)
    }

    func showMenu(for item: MenuBarExtraInfo) {
        guard let element = elementsByID[item.id] else {
            refresh()
            guard let element = elementsByID[item.id] else { return }
            performAction(on: element, item: item, primary: false)
            return
        }
        performAction(on: element, item: item, primary: false)
    }

    private func performAction(on element: AXUIElement, item: MenuBarExtraInfo, primary: Bool) {
        let action = primary ? kAXPressAction as CFString : kAXShowMenuAction as CFString
        let fallback = primary ? kAXShowMenuAction as CFString : kAXPressAction as CFString

        let err = AXUIElementPerformAction(element, action)
        if err == .success { return }

        let fallbackErr = AXUIElementPerformAction(element, fallback)
        if fallbackErr != .success {
            log.error(
                "menu extra action failed pid=\(item.ownerPID, privacy: .public) title=\(item.displayTitle, privacy: .public) err=\(err.rawValue, privacy: .public) fallback=\(fallbackErr.rawValue, privacy: .public)"
            )
        }
    }

    private func copyActions(_ element: AXUIElement) -> Set<String> {
        var value: CFArray?
        guard AXUIElementCopyActionNames(element, &value) == .success,
              let value = value as? [String] else { return [] }
        return Set(value)
    }

    private func copyString(_ element: AXUIElement, attribute: CFString) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success else { return nil }
        return value as? String
    }

    private func copyElement(_ element: AXUIElement, attribute: CFString) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success,
              let value else { return nil }
        return unsafeBitCast(value, to: AXUIElement.self)
    }

    private func copyElements(_ element: AXUIElement, attribute: CFString) -> [AXUIElement] {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success,
              let value = value as? [AXUIElement] else { return [] }
        return value
    }

    private func copyPoint(_ element: AXUIElement, attribute: CFString) -> CGPoint? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success,
              let value else { return nil }
        var point = CGPoint.zero
        guard AXValueGetValue(value as! AXValue, .cgPoint, &point) else { return nil }
        return point
    }

    private func copySize(_ element: AXUIElement, attribute: CFString) -> CGSize? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success,
              let value else { return nil }
        var size = CGSize.zero
        guard AXValueGetValue(value as! AXValue, .cgSize, &size) else { return nil }
        return size
    }

    private func makeID(pid: pid_t, index: Int, label: String, frame: CGRect) -> String {
        "\(pid):\(index):\(label):\(Int(frame.minX.rounded())):\(Int(frame.width.rounded()))"
    }
}
