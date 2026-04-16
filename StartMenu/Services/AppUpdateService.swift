import AppKit
import Foundation

@MainActor
final class AppUpdateService: ObservableObject {
    struct ReleaseInfo: Equatable {
        let version: String
        let url: URL
        let sourceLabel: String
    }

    enum Status: Equatable {
        case idle
        case checking
        case upToDate(ReleaseInfo)
        case updateAvailable(currentVersion: String, latest: ReleaseInfo)
        case disabled(message: String)
        case failed
    }

    static let upgradeCommand = "brew upgrade --cask region23/tap/startmenu"

    @Published private(set) var status: Status = .idle

    private let currentVersion: String
    private let flavor: AppFlavor
    private let session: URLSession
    private var lastCheckedAt: Date?
    private var refreshTask: Task<Void, Never>?

    private static let tapCaskURL = URL(string: "https://raw.githubusercontent.com/region23/homebrew-tap/main/Casks/startmenu.rb")!
    private static let latestReleaseAPIURL = URL(string: "https://api.github.com/repos/region23/StartMenu/releases/latest")!
    private static let minimumRefreshInterval: TimeInterval = 60 * 60 * 6

    init(
        session: URLSession = .shared,
        flavor: AppFlavor = .current
    ) {
        self.flavor = flavor
        self.session = session
        self.currentVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"
        if !flavor.usesPublicReleaseChannel {
            status = .disabled(message: "Private builds stay off the public Homebrew/release flow.")
            return
        }
        refreshIfNeeded()
    }

    deinit {
        refreshTask?.cancel()
    }

    var upgradeCommand: String { Self.upgradeCommand }

    func refreshIfNeeded(force: Bool = false) {
        guard flavor.usesPublicReleaseChannel else { return }
        guard force || shouldRefresh else { return }

        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            await self?.refresh(force: force)
        }
    }

    func copyUpgradeCommand() {
        guard flavor.usesPublicReleaseChannel else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(Self.upgradeCommand, forType: .string)
    }

    func openReleasePage(for release: ReleaseInfo) {
        NSWorkspace.shared.open(release.url)
    }

    private var shouldRefresh: Bool {
        guard let lastCheckedAt else { return true }
        return Date().timeIntervalSince(lastCheckedAt) >= Self.minimumRefreshInterval
    }

    private func refresh(force: Bool) async {
        if !force, !shouldRefresh { return }

        status = .checking

        let release = await fetchLatestRelease()
        lastCheckedAt = Date()

        guard let release else {
            status = .failed
            return
        }

        if isVersion(release.version, newerThan: currentVersion) {
            status = .updateAvailable(currentVersion: currentVersion, latest: release)
        } else {
            status = .upToDate(release)
        }
    }

    private func fetchLatestRelease() async -> ReleaseInfo? {
        if let release = await fetchFromTap() {
            return release
        }
        return await fetchFromGitHubReleaseAPI()
    }

    private func fetchFromTap() async -> ReleaseInfo? {
        do {
            let (data, _) = try await session.data(from: Self.tapCaskURL)
            guard let body = String(data: data, encoding: .utf8) else { return nil }

            let pattern = #"version\s+"([^"]+)""#
            let regex = try NSRegularExpression(pattern: pattern)
            let range = NSRange(body.startIndex..<body.endIndex, in: body)
            guard
                let match = regex.firstMatch(in: body, range: range),
                let versionRange = Range(match.range(at: 1), in: body)
            else {
                return nil
            }

            let version = String(body[versionRange])
            guard let url = URL(string: "https://github.com/region23/StartMenu/releases/tag/v\(version)") else {
                return nil
            }
            return ReleaseInfo(version: version, url: url, sourceLabel: "Homebrew")
        } catch {
            return nil
        }
    }

    private func fetchFromGitHubReleaseAPI() async -> ReleaseInfo? {
        do {
            var request = URLRequest(url: Self.latestReleaseAPIURL)
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            request.setValue("StartMenu", forHTTPHeaderField: "User-Agent")

            let (data, _) = try await session.data(for: request)
            let payload = try JSONDecoder().decode(LatestReleasePayload.self, from: data)
            let version = payload.tagName.hasPrefix("v") ? String(payload.tagName.dropFirst()) : payload.tagName
            return ReleaseInfo(version: version, url: payload.htmlURL, sourceLabel: "GitHub")
        } catch {
            return nil
        }
    }

    private func isVersion(_ lhs: String, newerThan rhs: String) -> Bool {
        lhs.compare(rhs, options: [.numeric, .caseInsensitive]) == .orderedDescending
    }
}

private struct LatestReleasePayload: Decodable {
    let tagName: String
    let htmlURL: URL

    private enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case htmlURL = "html_url"
    }
}
