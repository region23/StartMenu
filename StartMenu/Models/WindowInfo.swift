import CoreGraphics
import Foundation

struct WindowInfo: Identifiable, Hashable {
    let id: CGWindowID
    let ownerPID: pid_t
    let ownerBundleID: String?
    let ownerName: String
    let title: String
    let bounds: CGRect
    let layer: Int
    let isOnScreen: Bool
    let isMinimized: Bool

    var displayTitle: String {
        title.isEmpty ? ownerName : title
    }
}
