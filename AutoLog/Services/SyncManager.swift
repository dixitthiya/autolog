import Foundation

/// The offline queue (JSON in UserDefaults) and its replay.
///
/// Replay runs in queue order, which is the order things happened. A record
/// keeps the car it was stamped with at capture time; replay never picks a car.
@MainActor
class SyncManager: ObservableObject {
    static let shared = SyncManager()

    /// Readings and records still waiting. Queued log rows are not counted.
    @Published var pendingCount = 0
    @Published var failedCount = 0
    /// What the queue screen lists (everything but log rows), oldest first.
    @Published private(set) var visibleRecords: [PendingRecord] = []
    @Published private(set) var isSyncing = false

    /// Queued `capture_end` rows are kept to this many, oldest dropped first.
    /// Data records are never dropped to make room.
    static let maxQueuedLogs = 25

    private let pendingKey = "pendingRecords"
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    private init() {
        assignMissingQueueIds()
        loadCounts()
    }

    private func loadCounts() {
        let data = getPendingRecords().filter { !$0.isLog }
        pendingCount = data.count
        failedCount = data.filter { $0.retryCount > Config.maxRetryCount }.count
        visibleRecords = data
    }

    /// Records queued before queue ids existed get one (once), so replay can
    /// remove exactly what it synced rather than going by position.
    private func assignMissingQueueIds() {
        var records = getPendingRecords()
        guard records.contains(where: { $0.queueId == nil }) else { return }
        for i in records.indices where records[i].queueId == nil {
            records[i].queueId = UUID().uuidString
        }
        savePendingRecords(records)
    }

    // MARK: - Queueing

    func queueMileageRecord(_ record: MileageRecord) {
        var pending = getPendingRecords()
        pending.append(PendingRecord(type: .mileage, mileageRecord: record, serviceRecord: nil,
                                     queueId: UUID().uuidString, queuedAt: Date()))
        savePendingRecords(pending)
        Log.sync("\(pending.count) pending records (added mileage)")
    }

    func queueServiceRecord(_ record: ServiceRecord) {
        var pending = getPendingRecords()
        pending.append(PendingRecord(type: .service, mileageRecord: nil, serviceRecord: record,
                                     queueId: UUID().uuidString, queuedAt: Date()))
        savePendingRecords(pending)
        Log.sync("\(pending.count) pending records (added service)")
    }

    func queueUnassignedReading(_ reading: UnassignedReading) {
        var pending = getPendingRecords()
        pending.append(PendingRecord(type: .unassigned, mileageRecord: nil, serviceRecord: nil, unassignedReading: reading,
                                     queueId: UUID().uuidString, queuedAt: Date()))
        savePendingRecords(pending)
        Log.sync("\(pending.count) pending records (added unassigned reading)")
    }

    /// One queued capture per car per day, so a long offline stretch stays small
    /// and replay can't create two rows for a day. A newer capture replaces the
    /// older one, unless it has no 0131 or odometer at all and the older one does.
    func queueCapture(_ capture: PendingCapture) {
        var pending = getPendingRecords()
        let sameCarAndDay = pending.firstIndex { record in
            guard record.type == .capture, let old = record.capture else { return false }
            return old.vehicleId == capture.vehicleId
                && Calendar.current.isDate(old.timestamp, inSameDayAs: capture.timestamp)
        }
        if let i = sameCarAndDay {
            let hasData = capture.distSinceCodesCleared != nil || (capture.odometer ?? 0) > 0
            if hasData {
                pending[i].capture = capture
                pending[i].retryCount = 0
                pending[i].lastError = nil
            }
            Log.sync("\(pending.count) pending records (updated capture)")
        } else {
            pending.append(PendingRecord(type: .capture, mileageRecord: nil, serviceRecord: nil,
                                         queueId: UUID().uuidString, capture: capture, queuedAt: Date()))
            Log.sync("\(pending.count) pending records (added capture)")
        }
        savePendingRecords(pending)
    }

    /// A log row that couldn't be written (only `capture_end` is queued).
    func queueLog(_ entry: OBDLogEntry) {
        var pending = getPendingRecords()
        pending.append(PendingRecord(type: .log, mileageRecord: nil, serviceRecord: nil,
                                     queueId: UUID().uuidString, log: entry, queuedAt: Date()))
        var excess = pending.filter { $0.isLog }.count - Self.maxQueuedLogs
        if excess > 0 {
            pending.removeAll { record in
                guard record.isLog, excess > 0 else { return false }
                excess -= 1
                return true
            }
        }
        savePendingRecords(pending)
    }

    // MARK: - Replay

    func syncAll() async {
        guard !isSyncing else { return }
        let snapshot = getPendingRecords()
        guard !snapshot.isEmpty else { return }
        guard NetworkMonitor.shared.isOnline else {
            Log.sync("offline — \(snapshot.count) pending records kept")
            return
        }

        isSyncing = true
        defer { isSyncing = false }
        Log.sync("\(snapshot.count) pending records found")

        // A capture can't be replayed until the multi-car migration is confirmed.
        if snapshot.contains(where: { $0.type == .capture }) {
            try? await NeonRepository.shared.ensureMultiCarReady()
        }
        let migrationReady = await NeonRepository.shared.isMultiCarReady

        var synced = Set<String>()
        var failures: [String: String] = [:]    // counts as a retry
        var notes: [String: String] = [:]       // not the record's fault: no retry counted

        for record in snapshot {
            guard let queueId = record.queueId, record.retryCount <= Config.maxRetryCount else { continue }
            if record.type == .capture && !migrationReady {
                notes[queueId] = "Waiting for the database migration"
                continue
            }
            do {
                try await replay(record)
                synced.insert(queueId)
                Log.sync("record synced successfully")
            } catch {
                if NetworkMonitor.isOfflineError(error) {
                    // Nothing else will get through either; keep everything, count nothing.
                    notes[queueId] = "Offline"
                    Log.sync("offline during sync — will retry")
                    break
                }
                failures[queueId] = error.localizedDescription
                Log.sync("replay failed: \(error.localizedDescription)")
            }
        }

        // Re-read the queue: anything queued while we were awaiting must survive.
        var current = getPendingRecords()
        current.removeAll { record in record.queueId.map { synced.contains($0) } ?? false }
        for i in current.indices {
            guard let queueId = current[i].queueId else { continue }
            if let message = failures[queueId] {
                current[i].retryCount += 1
                current[i].lastError = message
            } else if let note = notes[queueId] {
                current[i].lastError = note
            }
        }
        savePendingRecords(current)
    }

    private func replay(_ record: PendingRecord) async throws {
        let repo = NeonRepository.shared
        // The car was stamped when the record was queued; only records
        // queued before multi-car have none, and those are the Elantra's.
        switch record.type {
        case .mileage:
            if let mr = record.mileageRecord {
                try await repo.saveMileageRecord(mr.withLegacyVehicleIfMissing())
            }
        case .service:
            if let sr = record.serviceRecord {
                try await repo.saveServiceRecord(sr.withLegacyVehicleIfMissing())
            }
        case .unassigned:
            if let ur = record.unassignedReading {
                try await repo.saveUnassignedReading(ur)
            }
        case .capture:
            if let capture = record.capture {
                try await replayCapture(capture)
            }
        case .log:
            if let entry = record.log {
                try await repo.writeOBDEvent(entry)
            }
        }
    }

    /// Turn a raw offline reading into a mileage row, using the same math as a
    /// live capture but the car's history as it was when the reading was taken.
    /// Returns normally when the capture is done with (saved, superseded, or
    /// rejected and logged); throws if it should be retried.
    private func replayCapture(_ c: PendingCapture) async throws {
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
                try await reject(c, reason: Self.rejectionReason(estimate.basis), detail: "\(estimate.status); \(reference)")
                return
            }
            odometer = estimate.odometer
        }

        // Same safety net as a live capture (a drop of more than 1.5 mi), judged
        // against the car's last record at the time of the reading.
        if let latest, latest.odometerMiles > 0, odometer < latest.odometerMiles - 1.5 {
            try await reject(c, reason: "sanity_check",
                             detail: "computed \(Int(odometer)) < last \(Int(latest.odometerMiles)) at capture time")
            return
        }

        // One BLE_AUTO row per car per day: update that day's row, else insert.
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
        }

        await repo.saveMileageSnapshot(
            vehicleId: c.vehicleId, odometer: odometer, distSinceCodesCleared: c.distSinceCodesCleared,
            rpm: c.rpm, captureMode: c.captureMode, timestamp: c.timestamp)

        if odometer > MileageService.shared.currentMileage(for: c.vehicleId) {
            MileageService.shared.setCurrentMileage(odometer, for: c.vehicleId)
        }
    }

    private static func rejectionReason(_ basis: MileageMath.Basis) -> String {
        switch basis {
        case .noManualReference: return "no_manual_reference"
        case .codesCleared: return "negative_delta"
        case .referenceMissingDist: return "reference_missing_0131"
        case .noCurrentDistance: return "no_0131_reading"
        case .calculated: return "calculated"
        }
    }

    /// A capture that can't become a row is dropped, but only after a log row
    /// says why. The row carries the car, when the reading was taken, the raw
    /// 0131 value, rpm and the reason — enough to recover it by hand. If the log
    /// can't be written this throws and the capture stays queued.
    private func reject(_ c: PendingCapture, reason: String, detail: String) async throws {
        let stamp = ISO8601DateFormatter().string(from: c.timestamp)
        let raw = [
            "capture_ts=\(stamp)",
            "mode=\(c.captureMode)",
            "rpm=\(c.rpm.map { String($0) } ?? "nil")",
            "dist=\(c.distSinceCodesCleared.map { String($0) } ?? "nil")",
            "dist_raw=\(c.distRawResponse ?? "nil")",
            "odometer_raw=\(c.odometerRawResponse ?? "nil")",
        ].joined(separator: " ")
        let entry = OBDLogEntry(
            id: "replay-rejected-\(c.id)", timestamp: Date(), vehicleId: c.vehicleId,
            eventType: "replay_rejected", pid: "0131", rawResponse: raw,
            parsedValue: c.distSinceCodesCleared, success: false,
            errorMessage: "\(reason): \(detail)", durationMs: nil)
        try await NeonRepository.shared.writeOBDEvent(entry)
        Log.sync("dropped queued capture (\(reason))")
    }

    // MARK: - Storage

    /// Element by element, so one record this build can't read (a newer build's
    /// type, say) is skipped instead of making the whole queue unreadable.
    private func getPendingRecords() -> [PendingRecord] {
        guard let data = UserDefaults.standard.data(forKey: pendingKey) else { return [] }
        let lossy = (try? decoder.decode([LossyPendingRecord].self, from: data)) ?? []
        return lossy.compactMap { $0.record }
    }

    private func savePendingRecords(_ records: [PendingRecord]) {
        if let data = try? encoder.encode(records) {
            UserDefaults.standard.set(data, forKey: pendingKey)
        }
        loadCounts()
    }
}

private struct LossyPendingRecord: Decodable {
    let record: PendingRecord?
    init(from decoder: Decoder) throws {
        record = try? PendingRecord(from: decoder)
    }
}

/// Stored as JSON in UserDefaults. New fields must stay optional so queues
/// written by older builds still decode.
struct PendingRecord: Codable, Identifiable {
    enum RecordType: String, Codable { case mileage, service, unassigned, capture, log }
    let type: RecordType
    let mileageRecord: MileageRecord?
    let serviceRecord: ServiceRecord?
    var unassignedReading: UnassignedReading? = nil
    var retryCount: Int = 0
    var queueId: String? = nil
    var capture: PendingCapture? = nil
    var log: OBDLogEntry? = nil
    var lastError: String? = nil
    var queuedAt: Date? = nil

    var id: String { queueId ?? "\(type.rawValue)-\(eventTime?.timeIntervalSince1970 ?? 0)" }

    var isLog: Bool { type == .log }

    /// When the thing happened (not when it was queued).
    var eventTime: Date? {
        switch type {
        case .mileage: return mileageRecord?.timestamp
        case .service: return serviceRecord?.timestamp
        case .unassigned: return unassignedReading?.timestamp
        case .capture: return capture?.timestamp
        case .log: return log?.timestamp
        }
    }

    /// The car it belongs to, if known. Records queued before multi-car were the Elantra's.
    var vehicleId: String? {
        switch type {
        case .mileage: return mileageRecord.map { $0.vehicleId ?? Vehicle.elantraId }
        case .service: return serviceRecord.map { $0.vehicleId ?? Vehicle.elantraId }
        case .unassigned: return nil
        case .capture: return capture?.vehicleId
        case .log: return log?.vehicleId
        }
    }

    var kindLabel: String {
        switch type {
        case .mileage: return "Mileage record"
        case .service: return "Service record"
        case .unassigned: return "Unidentified-car reading"
        case .capture: return "OBD capture"
        case .log: return "Log"
        }
    }
}
