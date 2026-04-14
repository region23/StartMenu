import AppKit
import Combine
import Foundation

@MainActor
final class StartMenuService: ObservableObject {
    @Published private(set) var apps: [AppInfo] = []

    private let searchRoots: [URL]

    init() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        self.searchRoots = [
            URL(fileURLWithPath: "/Applications"),
            home.appendingPathComponent("Applications"),
            URL(fileURLWithPath: "/System/Applications"),
            URL(fileURLWithPath: "/System/Library/CoreServices")
        ]
        Task { await rescan() }
    }

    func rescan() async {
        let roots = searchRoots
        let discovered: [AppInfo] = await Task.detached(priority: .userInitiated) {
            Self.scan(roots: roots)
        }.value
        self.apps = discovered.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    func search(_ query: String) -> [AppInfo] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return apps }
        let lower = q.lowercased()
        return apps
            .compactMap { app -> (AppInfo, Int)? in
                let name = app.name.lowercased()
                if name == lower { return (app, 0) }
                if name.hasPrefix(lower) { return (app, 1) }
                if name.contains(lower) { return (app, 2) }
                return nil
            }
            .sorted { lhs, rhs in
                if lhs.1 != rhs.1 { return lhs.1 < rhs.1 }
                return lhs.0.name.localizedCaseInsensitiveCompare(rhs.0.name) == .orderedAscending
            }
            .map { $0.0 }
    }

    // MARK: - Scanning (nonisolated)

    nonisolated private static func scan(roots: [URL]) -> [AppInfo] {
        let fm = FileManager.default
        var seen: Set<String> = []
        var result: [AppInfo] = []

        for root in roots {
            guard let enumerator = fm.enumerator(
                at: root,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            ) else { continue }

            while let url = enumerator.nextObject() as? URL {
                guard url.pathExtension == "app" else { continue }
                enumerator.skipDescendants()

                guard let bundle = Bundle(url: url), let bid = bundle.bundleIdentifier else { continue }
                if seen.contains(bid) { continue }

                let info = bundle.infoDictionary
                // Skip background helpers and menu-bar agents — they should
                // not show up in a launcher.
                if (info?["LSUIElement"] as? Bool) == true { continue }
                if (info?["LSUIElement"] as? String) == "1" { continue }
                if (info?["LSBackgroundOnly"] as? Bool) == true { continue }
                if (info?["LSBackgroundOnly"] as? String) == "1" { continue }

                seen.insert(bid)

                let name = (info?["CFBundleDisplayName"] as? String)
                    ?? (info?["CFBundleName"] as? String)
                    ?? url.deletingPathExtension().lastPathComponent

                result.append(AppInfo(bundleID: bid, name: name, url: url))
            }
        }

        // Seed Finder explicitly — CoreServices enumeration is sometimes
        // restricted and we want Finder to always be searchable from the menu.
        if !seen.contains("com.apple.finder") {
            let finderURL = URL(fileURLWithPath: "/System/Library/CoreServices/Finder.app")
            if fm.fileExists(atPath: finderURL.path) {
                result.append(AppInfo(bundleID: "com.apple.finder", name: "Finder", url: finderURL))
            }
        }

        return result
    }

    static let finderApp: AppInfo = AppInfo(
        bundleID: "com.apple.finder",
        name: "Finder",
        url: URL(fileURLWithPath: "/System/Library/CoreServices/Finder.app")
    )
}
