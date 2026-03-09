import Foundation

struct MileageRecord: Codable, Identifiable {
    let id: String
    let timestamp: Date
    let odometerMiles: Double
    let source: String
    let distSinceCodesCleared: Double?

    static func manual(odometer: Double, date: Date = Date(), distSinceCodesCleared: Double? = nil) -> MileageRecord {
        MileageRecord(
            id: UUID().uuidString,
            timestamp: date,
            odometerMiles: odometer,
            source: "MANUAL",
            distSinceCodesCleared: distSinceCodesCleared
        )
    }

    static func bleAuto(odometer: Double, distSinceCodesCleared: Double? = nil) -> MileageRecord {
        MileageRecord(
            id: UUID().uuidString,
            timestamp: Date(),
            odometerMiles: odometer,
            source: "BLE_AUTO",
            distSinceCodesCleared: distSinceCodesCleared
        )
    }

    static func imported(odometer: Double, date: Date) -> MileageRecord {
        MileageRecord(
            id: UUID().uuidString,
            timestamp: date,
            odometerMiles: odometer,
            source: "IMPORTED",
            distSinceCodesCleared: nil
        )
    }
}
