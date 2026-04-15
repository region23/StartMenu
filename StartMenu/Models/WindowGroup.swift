import CoreGraphics
import Foundation

/// One chip on the taskbar represents a single running application and
/// owns every window that belongs to its PID. The representative is the
/// window we activate on a plain click — prefer a non-minimized window,
/// fall back to the first one if every window is minimized.
struct WindowGroup: Identifiable, Hashable {
    let id: pid_t
    let ownerName: String
    let ownerBundleID: String?
    let windows: [WindowInfo]
    let representative: WindowInfo

    var count: Int { windows.count }
    var isAllMinimized: Bool { windows.allSatisfy(\.isMinimized) }

    static func group(_ windows: [WindowInfo]) -> [WindowGroup] {
        var byPID: [pid_t: [WindowInfo]] = [:]
        for w in windows { byPID[w.ownerPID, default: []].append(w) }

        return byPID.compactMap { pid, list -> WindowGroup? in
            guard !list.isEmpty else { return nil }
            let sorted = list.sorted { a, b in
                if a.isMinimized != b.isMinimized { return !a.isMinimized }
                return a.id < b.id
            }
            let first = sorted[0]
            return WindowGroup(
                id: pid,
                ownerName: first.ownerName,
                ownerBundleID: first.ownerBundleID,
                windows: sorted,
                representative: first
            )
        }
        .sorted { a, b in
            a.ownerName.localizedCaseInsensitiveCompare(b.ownerName) == .orderedAscending
        }
    }
}
