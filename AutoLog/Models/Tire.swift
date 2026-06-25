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

/// A tread-depth measurement of one physical tire at a point in time.
/// Depth is in 32nds of an inch (new ~10-11/32, legal limit 2/32). Bound to
/// the tire, so readings form a wear curve across rotations and corners.
struct TireTreadReading: Codable, Identifiable {
    let id: String
    let tireId: String
    let timestamp: Date
    let odometer: Double
    let depth32nds: Double

    static func new(tireId: String, odometer: Double, date: Date = Date(), depth32nds: Double) -> TireTreadReading {
        TireTreadReading(id: UUID().uuidString, tireId: tireId, timestamp: date, odometer: odometer, depth32nds: depth32nds)
    }
}

extension Double {
    /// "8/32" — whole when possible, one decimal otherwise.
    var treadLabel: String {
        self == rounded() ? "\(Int(self))/32" : String(format: "%.1f/32", self)
    }
}

/// Resolves a manual corner change so two active tires never share a corner.
/// Moving a tire onto an occupied corner swaps the occupant into the spot the
/// moved tire just vacated.
enum TireMove {
    struct Update: Equatable {
        let id: String
        let position: TirePosition?
    }

    static func resolve(activeTires: [Tire], moving tireId: String, to newPosition: TirePosition?) -> [Update] {
        guard let mover = activeTires.first(where: { $0.id == tireId }) else { return [] }
        var updates: [Update] = []
        if let newPos = newPosition,
           let occupant = activeTires.first(where: { $0.id != tireId && $0.position == newPos }) {
            updates.append(Update(id: occupant.id, position: mover.position))
        }
        updates.append(Update(id: tireId, position: newPosition))
        return updates
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
