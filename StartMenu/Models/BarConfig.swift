import Foundation

enum UIScale: Double, CaseIterable, Identifiable {
    case small = 0.9
    case medium = 1.0
    case large = 1.2
    case xlarge = 1.4
    case xxlarge = 1.6

    var id: Double { rawValue }

    var label: String {
        switch self {
        case .small: return "Small"
        case .medium: return "Medium"
        case .large: return "Large"
        case .xlarge: return "Extra Large"
        case .xxlarge: return "Huge"
        }
    }

    static func closest(to value: Double) -> UIScale {
        allCases.min(by: { abs($0.rawValue - value) < abs($1.rawValue - value) }) ?? .medium
    }
}
