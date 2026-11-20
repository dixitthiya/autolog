import Foundation

struct MileageRecord: Codable, Identifiable {
    let id: String
    /// Optional only so records queued offline before multi-car still decode;
    /// every new record is created with a car.
    let vehicleId: String?
    let timestamp: Date
    let odometerMiles: Double
    let source: String
    let distSinceCodesCleared: Double?

    static func manual(vehicleId: String, odometer: Double, date: Date = Date(), distSinceCodesCleared: Double? = nil) -> MileageRecord {
        MileageRecord(
            id: UUID().uuidString,
            vehicleId: vehicleId,
            timestamp: date,
            odometerMiles: odometer,
            source: "MANUAL",
            distSinceCodesCleared: distSinceCodesCleared
        )
    }

    static func bleAuto(vehicleId: String, odometer: Double, distSinceCodesCleared: Double? = nil) -> MileageRecord {
        MileageRecord(
            id: UUID().uuidString,
            vehicleId: vehicleId,
            timestamp: Date(),
            odometerMiles: odometer,
            source: "BLE_AUTO",
            distSinceCodesCleared: distSinceCodesCleared
        )
    }

    static func imported(vehicleId: String, odometer: Double, date: Date) -> MileageRecord {
        MileageRecord(
            id: UUID().uuidString,
            vehicleId: vehicleId,
            timestamp: date,
            odometerMiles: odometer,
            source: "IMPORTED",
            distSinceCodesCleared: nil
        )
    }

    /// Records queued before multi-car support have no car; they were all the
    /// Elantra's. Used only when replaying the offline queue.
    func withLegacyVehicleIfMissing() -> MileageRecord {
        guard vehicleId == nil else { return self }
        return MileageRecord(
            id: id,
            vehicleId: Vehicle.elantraId,
            timestamp: timestamp,
            odometerMiles: odometerMiles,
            source: source,
            distSinceCodesCleared: distSinceCodesCleared
        )
    }
}
