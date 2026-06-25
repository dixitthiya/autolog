import Foundation

/// A physical corner of the car. Tracking is per-corner, but a tire's mileage is
/// bound to the tire itself (install odometer), so it survives rotation.
enum TirePosition: String, Codable, CaseIterable, Identifiable {
    case FL, FR, RL, RR

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .FL: return "Front Left"
        case .FR: return "Front Right"
        case .RL: return "Rear Left"
        case .RR: return "Rear Right"
        }
    }
}

/// A single physical tire. Mileage = currentOdometer − installOdometer (or
/// removedOdometer once retired), so it is correct regardless of rotation.
struct Tire: Codable, Identifiable {
    let id: String
    var position: TirePosition?      // current corner; nil once retired
    var makeModel: String?
    var installOdometer: Double
    var installDate: Date
    var removedOdometer: Double?     // set when the tire is replaced
    var removedDate: Date?
    var replacesTireId: String?      // 1:1 lineage to the tire this one replaced
    var notes: String?

    var isActive: Bool { removedOdometer == nil }

    /// Miles this tire has rolled. Bound to the tire, so rotation never resets it.
    func miles(currentOdometer: Double) -> Double {
        max(0, (removedOdometer ?? currentOdometer) - installOdometer)
    }

    func ageDays(asOf date: Date = Date()) -> Int {
        let end = removedDate ?? date
        return Calendar.current.dateComponents([.day], from: installDate, to: end).day ?? 0
    }

    static func new(
        position: TirePosition?,
        makeModel: String? = nil,
        installOdometer: Double,
        installDate: Date = Date(),
        notes: String? = nil,
        replacesTireId: String? = nil
    ) -> Tire {
        Tire(
            id: UUID().uuidString,
            position: position,
            makeModel: makeModel,
            installOdometer: installOdometer,
            installDate: installDate,
            removedOdometer: nil,
            removedDate: nil,
            replacesTireId: replacesTireId,
            notes: notes
        )
    }
}

/// An audit record of a rotation: when, at what odometer, and the corner mapping.
struct TireRotation: Codable, Identifiable {
    let id: String
    let timestamp: Date
    let odometer: Double
    let pattern: String
    var comments: String?

    static func new(odometer: Double, date: Date = Date(), pattern: String, comments: String? = nil) -> TireRotation {
        TireRotation(id: UUID().uuidString, timestamp: date, odometer: odometer, pattern: pattern, comments: comments)
    }
}

/// Standard rotation patterns. `mapping` is old corner → new corner.
enum RotationPattern: String, CaseIterable, Identifiable {
    case rearwardCross = "Rearward cross"
    case forwardCross = "Forward cross"
    case frontBackSameSide = "Front-to-back (same side)"
    case sideToSide = "Side to side"

    var id: String { rawValue }

    var mapping: [TirePosition: TirePosition] {
        switch self {
        case .rearwardCross:
            return [.FL: .RL, .FR: .RR, .RR: .FL, .RL: .FR]
        case .forwardCross:
            return [.RL: .FL, .RR: .FR, .FL: .RR, .FR: .RL]
        case .frontBackSameSide:
            return [.FL: .RL, .RL: .FL, .FR: .RR, .RR: .FR]
        case .sideToSide:
            return [.FL: .FR, .FR: .FL, .RL: .RR, .RR: .RL]
        }
    }

    /// e.g. "FL>RL, FR>RR, RL>FR, RR>FL" — in fixed corner order.
    var patternString: String {
        let m = mapping
        return TirePosition.allCases
            .map { "\($0.rawValue)>\((m[$0] ?? $0).rawValue)" }
            .joined(separator: ", ")
    }
}
