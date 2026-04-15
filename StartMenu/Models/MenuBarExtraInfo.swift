import CoreGraphics
import Foundation

struct MenuBarExtraInfo: Identifiable, Hashable {
    let id: String
    let ownerPID: pid_t
    let ownerBundleID: String?
    let ownerName: String
    let title: String
    let description: String
    let frame: CGRect
    let canPress: Bool
    let canShowMenu: Bool

    var displayTitle: String {
        if !title.isEmpty { return title }
        if !description.isEmpty { return description }
        return ownerName
    }

    var subtitle: String? {
        let normalizedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedDescription = description.trimmingCharacters(in: .whitespacesAndNewlines)

        if !normalizedDescription.isEmpty, normalizedDescription != normalizedTitle {
            return normalizedDescription
        }
        if displayTitle != ownerName {
            return ownerName
        }
        return nil
    }
}
