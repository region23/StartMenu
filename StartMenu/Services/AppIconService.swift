import AppKit
import Foundation
import UniformTypeIdentifiers

@MainActor
final class AppIconService {
    static let shared = AppIconService()

    private var byPID: [pid_t: NSImage] = [:]
    private var byBundleID: [String: NSImage] = [:]
    private var byURL: [URL: NSImage] = [:]
    private lazy var genericAppIcon: NSImage = {
        let icon = NSWorkspace.shared.icon(for: .application)
        icon.size = NSSize(width: 64, height: 64)
        return icon
    }()

    func icon(forPID pid: pid_t) -> NSImage? {
        if let cached = byPID[pid] { return cached }
        guard let app = NSRunningApplication(processIdentifier: pid) else { return nil }
        if let icon = app.icon {
            byPID[pid] = icon
            return icon
        }
        return nil
    }

    func icon(for url: URL) -> NSImage {
        if let cached = byURL[url] { return cached }
        let icon = NSWorkspace.shared.icon(forFile: url.path)
        icon.size = NSSize(width: 64, height: 64)
        byURL[url] = icon
        return icon
    }

    func icon(forBundleID bundleID: String) -> NSImage? {
        if let cached = byBundleID[bundleID] { return cached }
        guard let app = AppInfo.resolve(bundleID: bundleID) else { return nil }
        let icon = icon(for: app.url)
        byBundleID[bundleID] = icon
        return icon
    }

    func placeholderIcon() -> NSImage {
        genericAppIcon
    }

    func reset() {
        byPID.removeAll()
        byBundleID.removeAll()
        byURL.removeAll()
    }
}
