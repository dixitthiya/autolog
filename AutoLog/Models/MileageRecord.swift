import Foundation

struct MileageRecord: Codable, Identifiable {
    let id: String
    let timestamp: Date
    let odometerMiles: Double
    let source: String

    static func manual(odometer: Double, date: Date = Date()) -> MileageRecord {
        MileageRecord(
            id: UUID().uuidString,
            timestamp: date,
            odometerMiles: odometer,
            source: "MANUAL"
        )
    }

    static func bleAuto(odometer: Double) -> MileageRecord {
        MileageRecord(
            id: UUID().uuidString,
            timestamp: Date(),
            odometerMiles: odometer,
            source: "BLE_AUTO"
        )
    }

    static func imported(odometer: Double, date: Date) -> MileageRecord {
        MileageRecord(
            id: UUID().uuidString,
            timestamp: date,
            odometerMiles: odometer,
            source: "IMPORTED"
        )
    }
}
