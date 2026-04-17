import AppKit
import Combine
import Foundation

@MainActor
final class DockAppsService: ObservableObject {
    @Published private(set) var apps: [AppInfo] = []

    init() {
        refresh()
        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(prefsChanged),
            name: NSNotification.Name("com.apple.dock.prefchanged"),
            object: nil
        )
    }

    deinit {
        DistributedNotificationCenter.default().removeObserver(self)
    }

    @objc private func prefsChanged() {
        Task { @MainActor in self.refresh() }
    }

    private static let excludedBundleIDs: Set<String> = [
        "com.apple.finder"
    ]

    func refresh() {
        let span = PerformanceDiagnostics.begin(
            category: "dock",
            name: "refresh_pinned_apps",
            thresholdMs: 8,
            alwaysRecord: true
        )
        let key = "persistent-apps" as CFString
        let appID = "com.apple.dock" as CFString
        let raw = CFPreferencesCopyAppValue(key, appID) as? [[String: Any]] ?? []

        var result: [AppInfo] = []
        var seen: Set<String> = []

        for entry in raw {
            guard
                let tileData = entry["tile-data"] as? [String: Any],
                let fileData = tileData["file-data"] as? [String: Any],
                let urlString = fileData["_CFURLString"] as? String
            else { continue }

            let fileURL: URL
            if let url = URL(string: urlString), url.scheme != nil {
                fileURL = url.scheme == "file" ? url : URL(fileURLWithPath: url.path)
            } else {
                fileURL = URL(fileURLWithPath: urlString)
            }

            guard fileURL.pathExtension == "app" else { continue }
            guard let bundle = Bundle(url: fileURL), let bid = bundle.bundleIdentifier else { continue }
            if Self.excludedBundleIDs.contains(bid) { continue }
            if seen.contains(bid) { continue }
            seen.insert(bid)

            let name = (bundle.infoDictionary?["CFBundleDisplayName"] as? String)
                ?? (bundle.infoDictionary?["CFBundleName"] as? String)
                ?? fileURL.deletingPathExtension().lastPathComponent

            result.append(AppInfo(bundleID: bid, name: name, url: fileURL))
        }

        self.apps = result
        span.end(extraFields: ["apps": String(result.count)])
    }
}
