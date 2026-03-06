import SwiftUI

enum ServiceStatus: String, Codable, Comparable {
    case critical
    case serviceSoon
    case allGood
    case noData

    var color: Color {
        switch self {
        case .critical: return Color(red: 1.0, green: 0.231, blue: 0.188)
        case .serviceSoon: return Color(red: 1.0, green: 0.584, blue: 0.0)
        case .allGood: return Color(red: 0.204, green: 0.78, blue: 0.349)
        case .noData: return .gray
        }
    }

    var label: String {
        switch self {
        case .critical: return "Critical - Immediate Service Required"
        case .serviceSoon: return "Service Soon - Inspect Symptoms/Parts"
        case .allGood: return "All Good"
        case .noData: return "No Data"
        }
    }

    var icon: String {
        switch self {
        case .critical: return "exclamationmark.circle.fill"
        case .serviceSoon: return "exclamationmark.triangle.fill"
        case .allGood: return "checkmark.circle.fill"
        case .noData: return "questionmark.circle"
        }
    }

    private var sortOrder: Int {
        switch self {
        case .critical: return 0
        case .serviceSoon: return 1
        case .allGood: return 2
        case .noData: return 3
        }
    }

    static func < (lhs: ServiceStatus, rhs: ServiceStatus) -> Bool {
        lhs.sortOrder < rhs.sortOrder
    }
}
