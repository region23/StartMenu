import CoreGraphics

enum BarMetrics {
    static let baseHeight: CGFloat = 44

    static func height(for scale: Double) -> CGFloat {
        baseHeight * scale
    }
}
