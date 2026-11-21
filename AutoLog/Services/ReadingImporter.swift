import Foundation

/// Turns a raw reading (car + time + 0131, maybe an odometer) into that car's
/// BLE_AUTO mileage row. Shared by the offline-queue replay and by assigning
/// an unassigned reading to a car, so both follow exactly the same rules:
/// - the odometer comes from MileageMath, using the car's history as it was
///   when the reading was taken;
/// - one BLE_AUTO row per car per day: update that day's row, or insert one;
/// - a newer reading for that day is never overwritten;
/// - a new row uses the reading's own id, so doing it twice changes nothing.
enum ReadingImporter {
    enum ImportResult: Equatable {
        case saved(odometer: Double)
        case updated(odometer: Double)
        /// A newer reading for that day already stands; nothing was changed.
        case superseded(odometer: Double)
        case rejected(reason: String, detail: String)
    }

    enum Evaluation: Equatable {
        case odometer(Double)
        case rejected(reason: String, detail: String)
    }

    /// What saving would do to the car's BLE_AUTO row for the reading's day.
    enum DayRowEffect {
        case insert
        case update(MileageRecord)
        case keepNewer(MileageRecord)
    }

    /// Work out the odometer, or why it can't be. Reads only.
    static func evaluate(_ c: PendingCapture) async throws -> Evaluation {
        let repo = NeonRepository.shared
        let manualRef = try await repo.getLatestManualMileageRecord(vehicleId: c.vehicleId)
        let latest = try await repo.getLatestMileageRecord(vehicleId: c.vehicleId, onOrBefore: c.timestamp)

        let odometer: Double
        if let reported = c.odometer, reported > 0 {
            odometer = reported
        } else {
            let estimate = MileageMath.estimate(manualRef: manualRef, latest: latest, currentDist: c.distSinceCodesCleared)
            guard estimate.basis == .calculated else {
                let reference = manualRef.map { "manual_ref=\(Int($0.odometerMiles))@\($0.distSinceCodesCleared.map { String($0) } ?? "nil")" } ?? "manual_ref=none"
                return .rejected(reason: rejectionReason(estimate.basis), detail: "\(estimate.status); \(reference)")
            }
            odometer = estimate.odometer
        }

        // Same safety net as a live capture (a drop of more than 1.5 mi), judged
        // against the car's last record at the time of the reading.
        if let latest, latest.odometerMiles > 0, odometer < latest.odometerMiles - 1.5 {
            return .rejected(reason: "sanity_check",
                             detail: "computed \(Int(odometer)) < last \(Int(latest.odometerMiles)) at capture time")
        }
        return .odometer(odometer)
    }

    /// Preview of `apply` for the reading's day. Reads only.
    static func dayRowEffect(_ c: PendingCapture) async throws -> DayRowEffect {
        guard let existing = try await NeonRepository.shared.getBLEAutoRecord(vehicleId: c.vehicleId, onDayOf: c.timestamp) else {
            return .insert
        }
        return c.timestamp > existing.timestamp ? .update(existing) : .keepNewer(existing)
    }

    /// Write the row for an odometer that `evaluate` produced.
    static func apply(_ c: PendingCapture, odometer: Double, saveSnapshot: Bool) async throws -> ImportResult {
        let repo = NeonRepository.shared
        let result: ImportResult
        if let existing = try await repo.getBLEAutoRecord(vehicleId: c.vehicleId, onDayOf: c.timestamp) {
            // A newer reading for that day (taken online since) is left alone.
            if c.timestamp > existing.timestamp {
                let updated = MileageRecord(
                    id: existing.id,
                    vehicleId: c.vehicleId,
                    timestamp: c.timestamp,
                    odometerMiles: odometer,
                    source: "BLE_AUTO",
                    distSinceCodesCleared: c.distSinceCodesCleared ?? existing.distSinceCodesCleared
                )
                try await repo.updateMileageRecord(updated)
                result = .updated(odometer: odometer)
            } else {
                result = .superseded(odometer: odometer)
            }
        } else {
            let record = MileageRecord(
                id: c.id,
                vehicleId: c.vehicleId,
                timestamp: c.timestamp,
                odometerMiles: odometer,
                source: "BLE_AUTO",
                distSinceCodesCleared: c.distSinceCodesCleared
            )
            try await repo.saveMileageRecord(record)
            result = .saved(odometer: odometer)
        }

        if saveSnapshot {
            await repo.saveMileageSnapshot(
                vehicleId: c.vehicleId, odometer: odometer, distSinceCodesCleared: c.distSinceCodesCleared,
                rpm: c.rpm, captureMode: c.captureMode, timestamp: c.timestamp)
        }
        return result
    }

    /// Evaluate, then apply if an odometer could be worked out.
    static func importCapture(_ c: PendingCapture, saveSnapshot: Bool) async throws -> ImportResult {
        switch try await evaluate(c) {
        case .rejected(let reason, let detail):
            return .rejected(reason: reason, detail: detail)
        case .odometer(let odometer):
            return try await apply(c, odometer: odometer, saveSnapshot: saveSnapshot)
        }
    }

    static func rejectionReason(_ basis: MileageMath.Basis) -> String {
        switch basis {
        case .noManualReference: return "no_manual_reference"
        case .codesCleared: return "negative_delta"
        case .referenceMissingDist: return "reference_missing_0131"
        case .noCurrentDistance: return "no_0131_reading"
        case .calculated: return "calculated"
        }
    }
}
