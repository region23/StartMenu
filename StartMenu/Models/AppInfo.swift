import AppKit
import Foundation

struct AppInfo: Identifiable, Hashable {
    let bundleID: String
    let name: String
    let url: URL

    var id: String { bundleID }

    static func == (lhs: AppInfo, rhs: AppInfo) -> Bool {
        lhs.bundleID == rhs.bundleID && lhs.url == rhs.url
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(bundleID)
        hasher.combine(url)
    }
}

extension AppInfo {
    static func resolve(bundleID: String) -> AppInfo? {
        let appURL: URL?
        if bundleID == "com.apple.finder" {
            appURL = URL(fileURLWithPath: "/System/Library/CoreServices/Finder.app")
        } else {
            appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
        }

        guard let appURL else { return nil }

        let bundle = Bundle(url: appURL)
        let info = bundle?.infoDictionary
        let name = (info?["CFBundleDisplayName"] as? String)
            ?? (info?["CFBundleName"] as? String)
            ?? appURL.deletingPathExtension().lastPathComponent

        return AppInfo(bundleID: bundleID, name: name, url: appURL)
    }

    static func fallbackName(for bundleID: String) -> String {
        bundleID.split(separator: ".").last.map(String.init) ?? bundleID
    }
}
