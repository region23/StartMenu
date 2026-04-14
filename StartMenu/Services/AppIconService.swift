import AppKit
import Foundation

@MainActor
final class AppIconService {
    static let shared = AppIconService()

    private var byPID: [pid_t: NSImage] = [:]
    private var byURL: [URL: NSImage] = [:]

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

    func reset() {
        byPID.removeAll()
        byURL.removeAll()
    }
}
