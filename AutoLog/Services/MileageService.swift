import Foundation
import UIKit
import UserNotifications

@MainActor
class MileageService: ObservableObject {
    static let shared = MileageService()

    /// Pre-multi-car single cache key; its value belongs to the Elantra.
    private static let legacyCachedMileageKey = "cachedCurrentMileage"
    private static func cachedMileageKey(_ vehicleId: String) -> String { "cachedCurrentMileage.\(vehicleId)" }

    /// How long a 0131 value read this session can still serve as a manual-entry baseline
    /// (the person confirms the car hasn't been driven since).
    private static let liveDistMaxAge: TimeInterval = 30 * 60
    /// How long an identified car is reused across the 10s engine-off retries.
    private static let vinCacheMaxAge: TimeInterval = 60

    @Published var lastSyncDate: Date?
    /// Latest known odometer per vehicle id (also cached in UserDefaults).
    @Published private(set) var currentMileageByVehicle: [String: Double] = [:]
    @Published var isReading = false
    @Published var obdStatus: String = ""
    @Published var needsManualEntry = false
    /// The car the manual-odometer prompt is for — the car that triggered it.
    @Published var manualEntryVehicleId: String?
    @Published var lastCaptureInfo: String = ""
    @Published var isThrottled = false
    /// How the last capture ended, for the UI to react to (switch the viewed
    /// car, offer to reactivate a retired one). Read-only for everyone else.
    @Published private(set) var lastCaptureEnd: CaptureEndEvent?

    struct CaptureEndEvent: Equatable {
        let id = UUID()
        /// Same as the capture_end outcome: saved, updated, skipped_<reason>, failed_<reason>…
        let outcome: String
        let vehicleId: String?
    }

    private var obdService: OBDCommandService?
    private var lastSkipTime: Date?
    private var throttleTask: Task<Void, Never>?
    /// Car identified on the last read; reused only by throttle retries.
    private var cachedVehicle: (vehicle: Vehicle, at: Date)?
    /// Last 0131 value read per car in this app session.
    private var liveDistSinceCleared: [String: (miles: Double, at: Date)] = [:]
    /// Set for the connect in progress once the database is known to be
    /// unreachable (path says offline, or a call failed with a network error).
    /// From then on nothing else waits on the network; the reading is queued.
    private var captureOffline = false

    private static let offlineStatus = "Offline — reading will sync later"

    private init() {
        // Carry the old single cached value over to the Elantra, which owned it.
        let defaults = UserDefaults.standard
        let legacy = defaults.double(forKey: Self.legacyCachedMileageKey)
        if legacy > 0 {
            let key = Self.cachedMileageKey(Vehicle.elantraId)
            if defaults.double(forKey: key) == 0 {
                defaults.set(legacy, forKey: key)
            }
            defaults.removeObject(forKey: Self.legacyCachedMileageKey)
        }
    }

    func currentMileage(for vehicleId: String?) -> Double {
        guard let vehicleId else { return 0 }
        return currentMileageByVehicle[vehicleId]
            ?? UserDefaults.standard.double(forKey: Self.cachedMileageKey(vehicleId))
    }

    func setCurrentMileage(_ miles: Double, for vehicleId: String) {
        guard miles > 0 else { return }
        currentMileageByVehicle[vehicleId] = miles
        UserDefaults.standard.set(miles, forKey: Self.cachedMileageKey(vehicleId))
    }

    /// The latest 0131 read from this car (kept in memory only; a newer read
    /// replaces it) and when it was read — the candidate baseline for a manual
    /// odometer entry. nil once it is 30 minutes old, or if none was read this session.
    func captureBaseline(for vehicleId: String) -> (miles: Double, readAt: Date)? {
        guard let entry = liveDistSinceCleared[vehicleId],
              Date().timeIntervalSince(entry.at) < Self.liveDistMaxAge else { return nil }
        return (entry.miles, entry.at)
    }

    func clearSkipThrottle() {
        lastSkipTime = nil
        throttleTask?.cancel()
        throttleTask = nil
        isThrottled = false
    }

    /// How a capture ended. Exactly one is logged per connect as a `capture_end`
    /// row (outcome in error_message), so no capture can end silently.
    private struct CaptureOutcome {
        let name: String            // saved | updated | skipped_<reason> | failed_<reason>
        let vehicleId: String?
        var odometer: Double? = nil

        var isSuccess: Bool { name == "saved" || name == "updated" }

        static func saved(_ vehicleId: String, _ odometer: Double) -> CaptureOutcome {
            CaptureOutcome(name: "saved", vehicleId: vehicleId, odometer: odometer)
        }
        static func updated(_ vehicleId: String, _ odometer: Double) -> CaptureOutcome {
            CaptureOutcome(name: "updated", vehicleId: vehicleId, odometer: odometer)
        }
        static func skipped(_ reason: String, _ vehicleId: String?, odometer: Double? = nil) -> CaptureOutcome {
            CaptureOutcome(name: "skipped_\(reason)", vehicleId: vehicleId, odometer: odometer)
        }
        static func failed(_ reason: String, _ vehicleId: String?, odometer: Double? = nil) -> CaptureOutcome {
            CaptureOutcome(name: "failed_\(reason)", vehicleId: vehicleId, odometer: odometer)
        }
        /// Reading kept in the offline queue; it becomes a row when it syncs.
        static func queued(_ reason: String, _ vehicleId: String?) -> CaptureOutcome {
            CaptureOutcome(name: "queued_\(reason)", vehicleId: vehicleId)
        }
    }

    /// Quick read: connect, identify the car, read PIDs, save, disconnect (~10 seconds)
    func onBLEConnected(bleManager: BLEManager) async {
        let start = Date()

        guard !isReading else {
            await logCaptureEnd(.skipped("already_reading", nil), bleManager: bleManager, start: start)
            return
        }

        // Throttle: if engine-off countdown is active, skip — the countdown task will reconnect
        if isThrottled {
            Log.obd("throttled — countdown active, disconnecting")
            bleManager.disconnectAfterRead()
            await logCaptureEnd(.skipped("throttled", nil), bleManager: bleManager, start: start)
            return
        }

        isReading = true
        obdStatus = "Reading from the car…"
        captureOffline = !NetworkMonitor.shared.isOnline

        // A connect that arrives while the app is in the background (iOS reconnect,
        // state restore) is tagged bg_auto; runCapture then skips it. Throttle
        // retries keep their tag. A briefly inactive app (banner, Control Center)
        // keeps its real trigger.
        if UIApplication.shared.applicationState == .background && bleManager.captureMode != "throttle_retry" {
            bleManager.captureMode = "bg_auto"
        }

        let outcome = await runCapture(bleManager: bleManager, captureMode: bleManager.captureMode)

        isReading = false
        bleManager.disconnectAfterRead()
        lastCaptureEnd = CaptureEndEvent(outcome: outcome.name, vehicleId: outcome.vehicleId)
        await logCaptureEnd(outcome, bleManager: bleManager, start: start)
        captureOffline = false
    }

    /// The capture itself. Every exit returns an outcome, so the compiler
    /// guarantees each connect is accounted for in obd_connection_logs.
    private func runCapture(bleManager: BLEManager, captureMode: String) async -> CaptureOutcome {
        // Captures only happen with the app in use. One that starts in the
        // background is skipped before any command is sent (onBLEConnected then
        // disconnects). Only .background blocks: a banner or Control Center makes
        // the app .inactive and must not stop a capture, and this is checked once,
        // so a capture already running is never cut short.
        if UIApplication.shared.applicationState == .background {
            obdStatus = "Skipped — app in background"
            return .skipped("background", nil)
        }

        // No safe car to save under until the multi-car migration is confirmed.
        // The confirmation is remembered across launches, so this holds offline;
        // if it was never confirmed, try again now rather than waiting for a relaunch.
        let alreadyConfirmed = await NeonRepository.shared.isMultiCarReady
        if !alreadyConfirmed && !captureOffline {
            do {
                try await NeonRepository.shared.ensureMultiCarReady()
            } catch {
                if NetworkMonitor.isOfflineError(error) { captureOffline = true }
            }
        }
        guard await NeonRepository.shared.isMultiCarReady else {
            obdStatus = captureOffline ? Self.offlineStatus : "Database not ready — skipped"
            await logEvent(nil, "schema_not_ready", success: false, error: "multi-car migration not confirmed")
            return .skipped("schema_not_ready", nil)
        }

        let obd = OBDCommandService(bleManager: bleManager)
        self.obdService = obd

        // Init ELM327
        let initStart = Date()
        do {
            try await obd.initialize()
            await logEvent(nil, "init", success: true, duration: Self.ms(since: initStart))
        } catch {
            obdStatus = "Couldn't talk to the adapter"
            await logEvent(nil, "init", success: false, error: error.localizedDescription, duration: Self.ms(since: initStart))
            return .failed("init", nil)
        }

        // Identify the car before anything is read or saved
        var connected: Vehicle?
        var vinFailure: (reason: String, raw: String?)?
        switch await resolveVehicle(obd: obd, captureMode: captureMode) {
        case .vehicle(let v):
            connected = v
        case .retired(let v):
            obdStatus = "\(v.displayName) is retired — not logged"
            await logEvent(v.id, "retired_vehicle_connected", success: false, error: "Captures disabled for retired vehicle")
            return .skipped("retired_vehicle", v.id)
        case .failed(let reason, let raw):
            vinFailure = (reason, raw)
        }
        VehicleStore.shared.connectedVehicle = connected
        let connectedId = connected?.id

        do {
            // Read RPM (one retry on a transient bus error)
            obdStatus = "Checking the engine…"
            var rpm = 0
            var rpmReadSuccess = false
            let rpmAttempts = await obd.sendRetryingTransient("010C")
            if let last = rpmAttempts.last, let raw = last.raw, last.transient == nil {
                rpm = PIDParser.parseRPM(raw)
                rpmReadSuccess = true
            }
            await logAttempts(rpmAttempts, event: "rpm_check", pid: "010C", vehicleId: connectedId,
                              value: Double(rpm), success: rpm > 0, message: rpm == 0 ? "RPM=0 (engine off)" : nil)

            // Only skip if RPM was successfully read as 0 (confirmed engine off)
            // If RPM read failed (timeout/junk/bus error), continue — fix #3 will catch bad data
            if rpmReadSuccess && rpm == 0 {
                obdStatus = "Engine off — retrying in 10s"
                lastSkipTime = Date()
                isThrottled = true
                await logEvent(connectedId, "skipped_engine_off", pid: "010C", value: 0, success: false,
                          error: "RPM=0, engine confirmed off")
                // Start real countdown then reconnect
                startThrottleCountdown(bleManager: bleManager)
                return .skipped("engine_off", connectedId)
            }

            // Read odometer PID (will likely fail on Hyundais of this era)
            var odometer: Double = 0
            var odometerRaw: String?
            let odoStart = Date()
            do {
                let rawResponse = try await obd.sendCommand("01A6")
                odometerRaw = rawResponse
                odometer = PIDParser.parseOdometer(rawResponse)
                await logEvent(connectedId, "odometer_read", pid: "01A6", raw: rawResponse, value: odometer, success: odometer > 0,
                          error: odometer == 0 ? "Parse failed: \(rawResponse)" : nil, duration: Self.ms(since: odoStart))
            } catch {
                await logEvent(connectedId, "odometer_read", pid: "01A6", success: false,
                          error: error.localizedDescription, duration: Self.ms(since: odoStart))
            }
            // What the car itself reported, before any calculation (kept if the reading is queued)
            let reportedOdometer: Double? = odometer > 0 ? odometer : nil

            // Read distance since codes cleared (PID 0131), one retry on a transient bus error
            obdStatus = "Reading distance driven…"
            var distSinceCleared: Double?
            let distAttempts = await obd.sendRetryingTransient("0131")
            let distRaws = distAttempts.compactMap { $0.raw }
            let distRaw: String? = distRaws.isEmpty ? nil : distRaws.joined(separator: " | ")
            var distMiles: Double = 0
            var distNote: String?
            if let last = distAttempts.last, let raw = last.raw, last.transient == nil {
                distMiles = PIDParser.parseDistanceSinceCodesCleared(raw)
                // A genuine 0 (codes just cleared) is still treated as "no reading";
                // the log only says which one it was.
                distSinceCleared = distMiles > 0 ? distMiles : nil
                if distMiles == 0 {
                    distNote = PIDParser.extractBytes(from: raw, expectedPrefix: "41 31").count >= 2
                        ? "Zero (codes just cleared?) — treated as no reading"
                        : "Parse failed: \(raw)"
                }
            }
            await logAttempts(distAttempts, event: "dist_since_clear", pid: "0131", vehicleId: connectedId,
                              value: distMiles, success: distSinceCleared != nil, message: distNote)

            // Car unknown: keep the reading for later assignment, save nothing else
            guard let vehicle = connected, let vehicleId = connectedId else {
                let kept = await saveUnassigned(
                    reason: vinFailure?.reason ?? "vin_error", vinRaw: vinFailure?.raw,
                    peripheralId: bleManager.connectedPeripheralId, captureMode: captureMode,
                    rpm: rpmReadSuccess ? rpm : nil, odometer: odometer, odometerRaw: odometerRaw,
                    dist: distSinceCleared, distRaw: distRaw)
                return .skipped(kept ? "vehicle_unknown" : "vehicle_unknown_no_data", nil)
            }

            if let distSinceCleared {
                liveDistSinceCleared[vehicleId] = (distSinceCleared, Date())
            }

            // Database unreachable: keep the raw reading under this car. Its odometer
            // is worked out when it syncs, from the car's history at that point.
            func queueRaw(_ reason: String) -> CaptureOutcome {
                queueOfflineCapture(vehicle: vehicle, captureMode: captureMode, rpm: rpmReadSuccess ? rpm : nil,
                                    odometer: reportedOdometer, odometerRaw: odometerRaw,
                                    dist: distSinceCleared, distRaw: distRaw, reason: reason)
            }
            if captureOffline {
                return queueRaw("offline")
            }

            do {
                // Calculate mileage
                var promptManualEntry = false
                if odometer == 0 {
                    let (calc, shouldPrompt) = try await calculateMileage(vehicleId: vehicleId, currentDistSinceCleared: distSinceCleared)
                    odometer = calc
                    promptManualEntry = shouldPrompt
                }

                guard odometer > 0 else {
                    obdStatus = "Enter odometer manually"
                    requestManualEntry(for: vehicleId)
                    return .skipped("needs_manual_odometer", vehicleId)
                }

                // Sanity check: reject if odometer drops more than 1.5 miles from this car's last known value
                // CAN filter (ATCRA7E8) should prevent ghost values; this is a safety net.
                if let lastRecord = try await NeonRepository.shared.getLatestMileageRecord(vehicleId: vehicleId),
                   lastRecord.odometerMiles > 0,
                   odometer < lastRecord.odometerMiles - 1.5 {
                    // Retry once after 2s
                    obdStatus = "Double-checking the reading…"
                    try await Task.sleep(nanoseconds: 2_000_000_000)
                    var retryDist: Double?
                    do {
                        let retryRaw = try await obd.sendCommand("0131")
                        let retryMiles = PIDParser.parseDistanceSinceCodesCleared(retryRaw)
                        retryDist = retryMiles > 0 ? retryMiles : nil
                    } catch { /* retry failed, use original */ }

                    var retryOdometer = odometer
                    if retryDist != nil {
                        let (calc, shouldPrompt) = try await calculateMileage(vehicleId: vehicleId, currentDistSinceCleared: retryDist)
                        retryOdometer = calc
                        promptManualEntry = shouldPrompt
                    }

                    if retryOdometer < lastRecord.odometerMiles - 1.5 {
                        obdStatus = "Reading looked wrong — skipped"
                        requestManualEntry(for: vehicleId)
                        await logEvent(vehicleId, "sanity_check_failed", value: retryOdometer, success: false,
                                  error: "Odometer dropped after retry: \(Int(retryOdometer)) < last \(Int(lastRecord.odometerMiles))")
                        return .skipped("sanity_check", vehicleId, odometer: retryOdometer)
                    }
                    // Retry succeeded — use the better value
                    odometer = retryOdometer
                    distSinceCleared = retryDist ?? distSinceCleared
                }

                // Save or update this car's BLE_AUTO record for today (never overwrite MANUAL entries)
                let todayBLERecord = try await NeonRepository.shared.getTodayBLEAutoRecord(vehicleId: vehicleId)
                let record = MileageRecord.bleAuto(vehicleId: vehicleId, odometer: odometer, distSinceCodesCleared: distSinceCleared)
                let outcome: CaptureOutcome

                if let existing = todayBLERecord {
                    // Update today's BLE_AUTO record with latest reading
                    let updated = MileageRecord(
                        id: existing.id,
                        vehicleId: vehicleId,
                        timestamp: Date(),
                        odometerMiles: odometer,
                        source: "BLE_AUTO",
                        // Keep the earlier good 0131 if this capture's read failed
                        distSinceCodesCleared: distSinceCleared ?? existing.distSinceCodesCleared
                    )
                    do {
                        try await NeonRepository.shared.updateMileageRecord(updated)
                        Log.db("updated today's BLE mileage: \(Int(odometer)) miles")
                        outcome = .updated(vehicleId, odometer)
                    } catch {
                        Log.db("failed to update: \(error.localizedDescription)")
                        if NetworkMonitor.isOfflineError(error) {
                            captureOffline = true
                            return queueRaw("offline_update")
                        }
                        outcome = .failed("update", vehicleId, odometer: odometer)
                    }
                } else {
                    do {
                        try await NeonRepository.shared.saveMileageRecord(record)
                        Log.db("mileage record saved: \(Int(odometer)) miles")
                        await logEvent(vehicleId, "mileage_save", value: odometer, success: true)
                        outcome = .saved(vehicleId, odometer)
                    } catch {
                        if NetworkMonitor.isOfflineError(error) {
                            // Queue the raw reading, not a finished row: replay then keeps
                            // one BLE_AUTO row per day even if another capture lands first.
                            captureOffline = true
                            return queueRaw("offline_save")
                        }
                        SyncManager.shared.queueMileageRecord(record)
                        await logEvent(vehicleId, "mileage_save", value: odometer, success: false,
                                  error: "Queued: \(error.localizedDescription)")
                        outcome = .failed("save_queued", vehicleId, odometer: odometer)
                    }
                }

                // Save snapshot for every capture (auto-purges after 7 days)
                await NeonRepository.shared.saveMileageSnapshot(
                    vehicleId: vehicleId, odometer: odometer, distSinceCodesCleared: distSinceCleared, rpm: rpm,
                    captureMode: captureMode)

                setCurrentMileage(odometer, for: vehicleId)
                lastSyncDate = Date()
                if promptManualEntry {
                    requestManualEntry(for: vehicleId)
                } else if manualEntryVehicleId == vehicleId {
                    needsManualEntry = false
                    manualEntryVehicleId = nil
                }
                clearSkipThrottle()
                let timeStr = Date().formatted(date: .omitted, time: .standard)
                obdStatus = "Captured \(Int(odometer)) mi at \(timeStr)"
                lastCaptureInfo = "\(vehicle.displayName): \(Int(odometer)) mi at \(timeStr)"

                // Send silent notification so user knows data was captured
                await sendCaptureNotification(odometer: odometer, vehicle: vehicle)

                await checkStatusNotifications(vehicle: vehicle)
                await ServiceReminderScheduler.reschedule()
                await SyncManager.shared.syncAll()
                return outcome
            } catch where NetworkMonitor.isOfflineError(error) {
                // Every call above is a read made before anything is written, so
                // the capture can be queued whole.
                captureOffline = true
                Log.db("offline mid-capture: \(error.localizedDescription)")
                return queueRaw("offline")
            }

        } catch {
            obdStatus = "Couldn't read the car"
            await logEvent(connectedId, "connection_error", success: false, error: error.localizedDescription)
            return .failed("exception", connectedId)
        }
    }

    /// One `capture_end` row: outcome in error_message, odometer in parsed_value,
    /// whole-capture duration, and what started the connect in raw_response.
    private func logCaptureEnd(_ outcome: CaptureOutcome, bleManager: BLEManager, start: Date) async {
        let appState: String
        switch UIApplication.shared.applicationState {
        case .active: appState = "active"
        case .inactive: appState = "inactive"
        case .background: appState = "background"
        @unknown default: appState = "unknown"
        }
        let context = "mode=\(bleManager.captureMode);app_state=\(appState);trigger=\(bleManager.connectTriggerDescription)"
        let entry = OBDLogEntry(
            id: UUID().uuidString, timestamp: Date(), vehicleId: outcome.vehicleId, eventType: "capture_end",
            rawResponse: context, parsedValue: outcome.odometer, success: outcome.isSuccess,
            errorMessage: outcome.name, durationMs: Self.ms(since: start))

        // The one log row that is kept offline: queued with its own timestamp,
        // written when the network is back.
        if captureOffline || !NetworkMonitor.shared.isOnline {
            SyncManager.shared.queueLog(entry)
            return
        }
        do {
            try await NeonRepository.shared.writeOBDEvent(entry)
        } catch {
            if NetworkMonitor.isOfflineError(error) {
                SyncManager.shared.queueLog(entry)
            } else {
                Log.db("failed to log capture_end: \(error.localizedDescription)")
            }
        }
    }

    private func requestManualEntry(for vehicleId: String) {
        needsManualEntry = true
        manualEntryVehicleId = vehicleId
    }

    // MARK: - Vehicle Identification

    private enum VehicleResolution {
        case vehicle(Vehicle)
        case retired(Vehicle)
        case failed(reason: String, raw: String?)
    }

    /// Which car is the adapter in? Reads the VIN (reusing the last answer only
    /// for a throttle retry within a minute), then finds or creates the car.
    private func resolveVehicle(obd: OBDCommandService, captureMode: String) async -> VehicleResolution {
        if captureMode == "throttle_retry", let cached = cachedVehicle,
           Date().timeIntervalSince(cached.at) < Self.vinCacheMaxAge {
            Log.obd("reusing identified car for retry: \(cached.vehicle.displayName)")
            return .vehicle(cached.vehicle)
        }
        cachedVehicle = nil

        obdStatus = "Identifying the car…"
        let (result, attempts) = await obd.readVIN()

        switch result {
        case .failed(let reason, let raw):
            await logAttempts(attempts, event: "vin_read", pid: "0902", vehicleId: nil,
                              value: nil, success: false, message: reason)
            return .failed(reason: reason, raw: raw)

        case .vin(let vin, let raw):
            if captureOffline {
                return resolveFromCache(vin: vin, raw: raw)
            }
            do {
                if let known = try await NeonRepository.shared.getVehicle(byVIN: vin) {
                    VehicleCache.upsert(known)
                    await logAttempts(attempts, event: "vin_read", pid: "0902", vehicleId: known.id,
                                      value: nil, success: true, message: nil)
                    guard known.isActive else { return .retired(known) }
                    cachedVehicle = (known, Date())
                    return .vehicle(known)
                }
                let created = try await createVehicle(vin: vin)
                await logAttempts(attempts, event: "vin_read", pid: "0902", vehicleId: created.id,
                                  value: nil, success: true, message: "new vehicle created")
                cachedVehicle = (created, Date())
                return .vehicle(created)
            } catch {
                if NetworkMonitor.isOfflineError(error) {
                    return resolveFromCache(vin: vin, raw: raw)
                }
                await logAttempts(attempts, event: "vin_read", pid: "0902", vehicleId: nil,
                                  value: nil, success: false, message: "lookup failed: \(error.localizedDescription)")
                return .failed(reason: "vin_lookup_error", raw: raw)
            }
        }
    }

    /// No database: identify the car from the saved car list. A known, active
    /// car is captured under its own id; a retired one is skipped as usual. An
    /// unknown VIN is never turned into a car offline — its reading is kept as
    /// an unassigned reading (the raw VIN reply travels with it).
    private func resolveFromCache(vin: String, raw: String?) -> VehicleResolution {
        captureOffline = true
        guard let known = VehicleCache.vehicle(vin: vin) else {
            Log.obd("offline: VIN not in the saved car list")
            return .failed(reason: "vin_unknown_offline", raw: raw)
        }
        Log.obd("offline: identified \(known.displayName) from the saved car list")
        guard known.isActive else { return .retired(known) }
        cachedVehicle = (known, Date())
        return .vehicle(known)
    }

    /// Unknown VIN: create the car (make/year decoded offline), give it a copy
    /// of the Elantra's thresholds in the same statement, and ask for its odometer.
    private func createVehicle(vin: String) async throws -> Vehicle {
        let new = Vehicle.new(vin: vin, make: VINDecoder.make(fromVIN: vin), year: VINDecoder.modelYear(fromVIN: vin))
        let vehicle = try await NeonRepository.shared.createVehicle(new, copyingThresholdsFrom: Vehicle.elantraId)
        Log.db("new vehicle: \(vehicle.displayName) (\(vin))")
        await VehicleStore.shared.reload()
        // Model etc. from NHTSA, in the background; this capture never waits for it.
        VehicleLookup.fillMissingDetailsInBackground(vehicleId: vehicle.id)
        requestManualEntry(for: vehicle.id)
        return vehicle
    }

    /// VIN unknown: never guess a car. Keep the reading if there is one.
    /// Returns whether a reading was kept (saved or queued).
    private func saveUnassigned(reason: String, vinRaw: String?, peripheralId: String?, captureMode: String,
                                rpm: Int?, odometer: Double, odometerRaw: String?,
                                dist: Double?, distRaw: String?) async -> Bool {
        guard dist != nil || odometer > 0 else {
            obdStatus = "Couldn't identify car — no reading"
            await logEvent(nil, "unassigned_skipped", success: false, error: "\(reason); no 0131/01A6 data")
            return false
        }
        let reading = UnassignedReading(
            id: UUID().uuidString,
            timestamp: Date(),
            failureReason: reason,
            vinRawResponse: vinRaw,
            peripheralId: peripheralId,
            captureMode: captureMode,
            rpm: rpm,
            odometerRawResponse: odometerRaw,
            distSinceCodesCleared: dist,
            distRawResponse: distRaw
        )
        if captureOffline {
            SyncManager.shared.queueUnassignedReading(reading)
        } else {
            do {
                try await NeonRepository.shared.saveUnassignedReading(reading)
            } catch {
                if NetworkMonitor.isOfflineError(error) { captureOffline = true }
                SyncManager.shared.queueUnassignedReading(reading)
            }
        }
        obdStatus = captureOffline ? Self.offlineStatus : "Couldn't identify car — reading saved for review"
        await logEvent(nil, "unassigned_saved", value: dist, success: false, error: reason)
        return true
    }

    /// The database can't be reached: keep the raw reading in the offline queue
    /// under the car identified by VIN. Nothing is calculated or saved here.
    private func queueOfflineCapture(vehicle: Vehicle, captureMode: String, rpm: Int?,
                                     odometer: Double?, odometerRaw: String?,
                                     dist: Double?, distRaw: String?, reason: String) -> CaptureOutcome {
        clearSkipThrottle()
        // A capture with neither a 0131 nor an odometer carries nothing to compute from.
        guard dist != nil || (odometer ?? 0) > 0 else {
            obdStatus = "Offline — no reading to save"
            return .skipped("offline_no_reading", vehicle.id)
        }
        SyncManager.shared.queueCapture(PendingCapture(
            id: UUID().uuidString,
            vehicleId: vehicle.id,
            timestamp: Date(),
            captureMode: captureMode,
            rpm: rpm,
            odometer: odometer,
            odometerRawResponse: odometerRaw,
            distSinceCodesCleared: dist,
            distRawResponse: distRaw,
            reason: reason
        ))
        obdStatus = Self.offlineStatus
        return .queued(reason, vehicle.id)
    }

    // MARK: - Mileage Calculation

    /// Calculate this car's mileage using: manual entry (priority 1) > reference + delta from 0131
    /// Returns (odometer, shouldPromptManualEntry)
    private func calculateMileage(vehicleId: String, currentDistSinceCleared: Double?) async throws -> (Double, Bool) {
        let manualRef = try await NeonRepository.shared.getLatestManualMileageRecord(vehicleId: vehicleId)
        let latest = try await NeonRepository.shared.getLatestMileageRecord(vehicleId: vehicleId)

        // The rules live in MileageMath so an offline replay uses exactly the same ones.
        let estimate = MileageMath.estimate(manualRef: manualRef, latest: latest, currentDist: currentDistSinceCleared)
        obdStatus = estimate.status

        if estimate.basis == .codesCleared, let currentDist = currentDistSinceCleared, let refDist = manualRef?.distSinceCodesCleared {
            await logEvent(vehicleId, "codes_cleared_detected", pid: "0131", value: currentDist, success: false,
                      error: "Negative delta: current=\(Int(currentDist)) ref=\(Int(refDist))")
        }
        return (estimate.odometer, estimate.shouldPromptManualEntry)
    }

    // MARK: - Logging

    private static func ms(since start: Date) -> Int {
        Int(Date().timeIntervalSince(start) * 1000)
    }

    /// One log row per attempt of a command. Transient bus errors read
    /// "transient: CAN ERROR"; retried attempts end "— retrying"; with a retry,
    /// each row carries "(attempt n/m)". The caller's value/success/message
    /// apply to the final attempt only, and only if it got a usable reply.
    private func logAttempts(_ attempts: [CommandAttempt], event: String, pid: String, vehicleId: String?,
                             value: Double?, success: Bool, message: String?) async {
        for (i, attempt) in attempts.enumerated() {
            let isLast = i == attempts.count - 1
            let usable = isLast && attempt.transient == nil && attempt.errorDescription == nil
            var text: String?
            if let marker = attempt.transient {
                text = "transient: \(marker)"
            } else if let error = attempt.errorDescription {
                text = error
            } else if isLast {
                text = message
            }
            if !isLast { text = (text ?? "") + " — retrying" }
            if attempts.count > 1 { text = (text ?? "ok") + " (attempt \(i + 1)/\(attempts.count))" }
            await logEvent(vehicleId, event, pid: pid, raw: attempt.raw,
                           value: usable ? value : nil, success: usable ? success : false,
                           error: text, duration: attempt.durationMs)
        }
    }

    private func logEvent(_ vehicleId: String?, _ eventType: String, pid: String? = nil, raw: String? = nil,
                     value: Double? = nil, success: Bool, error: String? = nil, duration: Int? = nil) async {
        // Once the capture is known to be offline these can't be written (and would
        // only wait on timeouts); capture_end alone is queued, by logCaptureEnd.
        guard !captureOffline else { return }
        await NeonRepository.shared.logOBDEvent(
            vehicleId: vehicleId, eventType: eventType, pid: pid, rawResponse: raw,
            parsedValue: value, success: success, errorMessage: error, durationMs: duration)
    }

    // MARK: - Throttle Countdown

    /// Live countdown that updates the status label every second, then reconnects
    private func startThrottleCountdown(bleManager: BLEManager) {
        throttleTask?.cancel()
        throttleTask = Task { @MainActor in
            for remaining in stride(from: 10, through: 1, by: -1) {
                guard !Task.isCancelled else { return }
                obdStatus = "Engine off — retrying in \(remaining)s"
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
            guard !Task.isCancelled else { return }
            isThrottled = false
            lastSkipTime = nil
            obdStatus = "Reconnecting…"
            Log.obd("throttle expired — reconnecting")
            bleManager.captureMode = "throttle_retry"
            bleManager.connectOrScan(trigger: "throttle")
        }
    }

    // MARK: - Notifications

    /// Notify user that mileage data was captured
    private func sendCaptureNotification(odometer: Double, vehicle: Vehicle) async {
        let content = UNMutableNotificationContent()
        content.title = "AutoLog"
        content.body = "\(vehicle.displayName): mileage captured \(Int(odometer).formatted()) mi"
        content.sound = nil
        content.interruptionLevel = .passive

        let request = UNNotificationRequest(
            identifier: "mileage-capture-\(vehicle.id)",
            content: content,
            trigger: nil
        )

        do {
            try await UNUserNotificationCenter.current().add(request)
        } catch {
            Log.notify("capture notification failed: \(error.localizedDescription)")
        }
    }

    /// Status alerts for the car just captured (always an active car).
    private func checkStatusNotifications(vehicle: Vehicle) async {
        guard vehicle.isActive else { return }
        do {
            let dashboard = try await NeonRepository.shared.getDashboardData(vehicleId: vehicle.id)
            for row in dashboard {
                switch row.status {
                case .critical:
                    await sendNotification(
                        title: "Critical Service Alert",
                        body: "\(vehicle.displayName) · \(row.serviceType): Immediate Service Required"
                    )
                case .serviceSoon:
                    if let toCritical = row.milesToCritical, toCritical > 0 {
                        await sendNotification(
                            title: "Service Reminder",
                            body: "\(vehicle.displayName) · \(row.serviceType): Critical in \(Int(toCritical).formatted()) miles"
                        )
                    } else {
                        await sendNotification(
                            title: "Service Reminder",
                            body: "\(vehicle.displayName) · \(row.serviceType): Service due"
                        )
                    }
                default:
                    break
                }
            }
        } catch {
            Log.notify("failed to check statuses: \(error.localizedDescription)")
        }
    }

    private func sendNotification(title: String, body: String) async {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil
        )

        do {
            try await UNUserNotificationCenter.current().add(request)
        } catch {
            Log.notify("failed to send: \(error.localizedDescription)")
        }
    }
}
