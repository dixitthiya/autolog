import Foundation

/// A reading taken while the database was unreachable. The odometer is NOT
/// worked out at capture time (the reference it needs lives in the database);
/// it is computed when the capture is replayed. `vehicleId` is the car
/// identified by VIN at capture time and is never replaced at replay.
struct PendingCapture: Codable, Identifiable {
    /// Becomes the mileage_records id if the capture inserts a new row.
    let id: String
    let vehicleId: String
    let timestamp: Date
    var captureMode: String
    var rpm: Int?
    /// 01A6 value, only if the car reported one.
    var odometer: Double?
    var odometerRawResponse: String?
    var distSinceCodesCleared: Double?
    var distRawResponse: String?
    /// Why it was queued (offline | offline_update | offline_save).
    var reason: String
}

/// One obd_connection_logs row, written now or queued for later. `id` makes a
/// replay idempotent.
struct OBDLogEntry: Codable, Identifiable {
    let id: String
    let timestamp: Date
    let vehicleId: String?
    let eventType: String
    var pid: String?
    var rawResponse: String?
    var parsedValue: Double?
    var success: Bool
    var errorMessage: String?
    var durationMs: Int?
}
