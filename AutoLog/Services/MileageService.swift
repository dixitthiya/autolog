import Foundation
import UIKit
import UserNotifications

@MainActor
class MileageService: ObservableObject {
    static let shared = MileageService()

    /// Pre-multi-car single cache key; its value belongs to the Elantra.
    private static let legacyCachedMileageKey = "cachedCurrentMileage"
    private static func cachedMileageKey(_ vehicleId: String) -> String { "cachedCurrentMileage.\(vehicleId)" }

    /// How long a 0131 value read this session counts as "live" for a manual-entry baseline.
    private static let liveDistMaxAge: TimeInterval = 10 * 60
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

    private var obdService: OBDCommandService?
    private var lastSkipTime: Date?
    private var throttleTask: Task<Void, Never>?
    /// Car identified on the last read; reused only by throttle retries.
    private var cachedVehicle: (vehicle: Vehicle, at: Date)?
    /// Last 0131 value read per car in this app session.
    private var liveDistSinceCleared: [String: (miles: Double, at: Date)] = [:]

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

    /// 0131 read from this car within the last few minutes, if any — the
    /// "live" baseline for a manual odometer entry.
    func recentDistSinceCleared(for vehicleId: String) -> Double? {
        guard let entry = liveDistSinceCleared[vehicleId],
              Date().timeIntervalSince(entry.at) < Self.liveDistMaxAge else { return nil }
        return entry.miles
    }

    func clearSkipThrottle() {
        lastSkipTime = nil
        throttleTask?.cancel()
        throttleTask = nil
        isThrottled = false
    }

    /// Quick read: connect, identify the car, read PIDs, save, disconnect (~10 seconds)
    func onBLEConnected(bleManager: BLEManager) async {
        guard !isReading else { return }

        // Throttle: if engine-off countdown is active, skip — the countdown task will reconnect
        if isThrottled {
            Log.obd("throttled — countdown active, disconnecting")
            bleManager.disconnectAfterRead()
            return
        }

        isReading = true
        obdStatus = "Reading data..."
        defer {
            isReading = false
            bleManager.disconnectAfterRead()
        }

        // Anything connecting while the app isn't in the foreground (iOS reconnect,
        // state restore, BT power-on) is bg_auto; throttle retries keep their tag.
        if UIApplication.shared.applicationState != .active && bleManager.captureMode != "throttle_retry" {
            bleManager.captureMode = "bg_auto"
        }
        let captureMode = bleManager.captureMode

        // No safe car to save under until the multi-car migration is confirmed.
        guard await NeonRepository.shared.isMultiCarReady else {
            obdStatus = "Database not ready — skipped"
            await logEvent(nil, "schema_not_ready", success: false, error: "multi-car migration not confirmed")
            return
        }

        let obd = OBDCommandService(bleManager: bleManager)
        self.obdService = obd

        // Init ELM327
        let initStart = Date()
        do {
            try await obd.initialize()
            await logEvent(nil, "init", success: true, duration: Self.ms(since: initStart))
        } catch {
            obdStatus = "OBD init failed"
            await logEvent(nil, "init", success: false, error: error.localizedDescription, duration: Self.ms(since: initStart))
            return
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
            return
        case .failed(let reason, let raw):
            vinFailure = (reason, raw)
        }
        VehicleStore.shared.connectedVehicle = connected
        let connectedId = connected?.id

        do {
            // Read RPM
            obdStatus = "Reading RPM..."
            var rpm = 0
            var rpmReadSuccess = false
            let rpmStart = Date()
            do {
                let rpmRaw = try await obd.sendCommand("010C")
                rpm = PIDParser.parseRPM(rpmRaw)
                rpmReadSuccess = true
                await logEvent(connectedId, "rpm_check", pid: "010C", raw: rpmRaw, value: Double(rpm), success: rpm > 0,
                          error: rpm == 0 ? "RPM=0 (engine off)" : nil, duration: Self.ms(since: rpmStart))
            } catch {
                await logEvent(connectedId, "rpm_check", pid: "010C", success: false,
                          error: error.localizedDescription, duration: Self.ms(since: rpmStart))
            }

            // Only skip if RPM was successfully read as 0 (confirmed engine off)
            // If RPM read failed (timeout/junk), continue — fix #3 will catch bad data
            if rpmReadSuccess && rpm == 0 {
                obdStatus = "Engine off — retrying in 10s"
                lastSkipTime = Date()
                isThrottled = true
                await logEvent(connectedId, "skipped_engine_off", pid: "010C", value: 0, success: false,
                          error: "RPM=0, engine confirmed off")
                // Start real countdown then reconnect
                startThrottleCountdown(bleManager: bleManager)
                return
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

            // Read distance since codes cleared (PID 0131)
            obdStatus = "Reading distance..."
            var distSinceCleared: Double?
            var distRaw: String?
            let distStart = Date()
            do {
                let raw = try await obd.sendCommand("0131")
                distRaw = raw
                let distMiles = PIDParser.parseDistanceSinceCodesCleared(raw)
                distSinceCleared = distMiles > 0 ? distMiles : nil
                await logEvent(connectedId, "dist_since_clear", pid: "0131", raw: raw, value: distMiles, success: distMiles > 0,
                          error: distMiles == 0 ? "Parse failed or zero" : nil, duration: Self.ms(since: distStart))
            } catch {
                await logEvent(connectedId, "dist_since_clear", pid: "0131", success: false,
                          error: error.localizedDescription, duration: Self.ms(since: distStart))
            }

            // Car unknown: keep the reading for later assignment, save nothing else
            guard let vehicle = connected, let vehicleId = connectedId else {
                await saveUnassigned(
                    reason: vinFailure?.reason ?? "vin_error", vinRaw: vinFailure?.raw,
                    peripheralId: bleManager.connectedPeripheralId, captureMode: captureMode,
                    rpm: rpmReadSuccess ? rpm : nil, odometer: odometer, odometerRaw: odometerRaw,
                    dist: distSinceCleared, distRaw: distRaw)
                return
            }

            if let distSinceCleared {
                liveDistSinceCleared[vehicleId] = (distSinceCleared, Date())
            }

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
                return
            }

            // Sanity check: reject if odometer drops more than 1.5 miles from this car's last known value
            // CAN filter (ATCRA7E8) should prevent ghost values; this is a safety net.
            if let lastRecord = try await NeonRepository.shared.getLatestMileageRecord(vehicleId: vehicleId),
               lastRecord.odometerMiles > 0,
               odometer < lastRecord.odometerMiles - 1.5 {
                // Retry once after 2s
                obdStatus = "Verifying reading..."
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
                    obdStatus = "Bad reading — skipped"
                    requestManualEntry(for: vehicleId)
                    await logEvent(vehicleId, "sanity_check_failed", value: retryOdometer, success: false,
                              error: "Odometer dropped after retry: \(Int(retryOdometer)) < last \(Int(lastRecord.odometerMiles))")
                    return
                }
                // Retry succeeded — use the better value
                odometer = retryOdometer
                distSinceCleared = retryDist ?? distSinceCleared
            }

            // Save or update this car's BLE_AUTO record for today (never overwrite MANUAL entries)
            let todayBLERecord = try await NeonRepository.shared.getTodayBLEAutoRecord(vehicleId: vehicleId)
            let record = MileageRecord.bleAuto(vehicleId: vehicleId, odometer: odometer, distSinceCodesCleared: distSinceCleared)

            if let existing = todayBLERecord {
                // Update today's BLE_AUTO record with latest reading
                let updated = MileageRecord(
                    id: existing.id,
                    vehicleId: vehicleId,
                    timestamp: Date(),
                    odometerMiles: odometer,
                    source: "BLE_AUTO",
                    distSinceCodesCleared: distSinceCleared
                )
                do {
                    try await NeonRepository.shared.updateMileageRecord(updated)
                    Log.db("updated today's BLE mileage: \(Int(odometer)) miles")
                } catch {
                    Log.db("failed to update: \(error.localizedDescription)")
                }
            } else {
                do {
                    try await NeonRepository.shared.saveMileageRecord(record)
                    Log.db("mileage record saved: \(Int(odometer)) miles")
                    await logEvent(vehicleId, "mileage_save", value: odometer, success: true)
                } catch {
                    SyncManager.shared.queueMileageRecord(record)
                    await logEvent(vehicleId, "mileage_save", value: odometer, success: false,
                              error: "Queued: \(error.localizedDescription)")
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

        } catch {
            obdStatus = "Read failed"
            await logEvent(connectedId, "connection_error", success: false, error: error.localizedDescription)
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

        obdStatus = "Identifying car..."
        let start = Date()
        let result = await obd.readVIN()
        let duration = Self.ms(since: start)

        switch result {
        case .failed(let reason, let raw):
            await logEvent(nil, "vin_read", pid: "0902", raw: raw, success: false, error: reason, duration: duration)
            return .failed(reason: reason, raw: raw)

        case .vin(let vin, let raw):
            do {
                if let known = try await NeonRepository.shared.getVehicle(byVIN: vin) {
                    await logEvent(known.id, "vin_read", pid: "0902", raw: raw, success: true, duration: duration)
                    guard known.isActive else { return .retired(known) }
                    cachedVehicle = (known, Date())
                    return .vehicle(known)
                }
                let created = try await createVehicle(vin: vin)
                await logEvent(created.id, "vin_read", pid: "0902", raw: raw, success: true,
                          error: "new vehicle created", duration: duration)
                cachedVehicle = (created, Date())
                return .vehicle(created)
            } catch {
                await logEvent(nil, "vin_read", pid: "0902", raw: raw, success: false,
                          error: "lookup failed: \(error.localizedDescription)", duration: duration)
                return .failed(reason: "vin_lookup_error", raw: raw)
            }
        }
    }

    /// Unknown VIN: create the car (make/year decoded offline), give it a copy
    /// of the Elantra's thresholds in the same statement, and ask for its odometer.
    private func createVehicle(vin: String) async throws -> Vehicle {
        let new = Vehicle.new(vin: vin, make: VINDecoder.make(fromVIN: vin), year: VINDecoder.modelYear(fromVIN: vin))
        let vehicle = try await NeonRepository.shared.createVehicle(new, copyingThresholdsFrom: Vehicle.elantraId)
        Log.db("new vehicle: \(vehicle.displayName) (\(vin))")
        await VehicleStore.shared.reload()
        requestManualEntry(for: vehicle.id)
        return vehicle
    }

    /// VIN unknown: never guess a car. Keep the reading if there is one.
    private func saveUnassigned(reason: String, vinRaw: String?, peripheralId: String?, captureMode: String,
                                rpm: Int?, odometer: Double, odometerRaw: String?,
                                dist: Double?, distRaw: String?) async {
        guard dist != nil || odometer > 0 else {
            obdStatus = "Couldn't identify car — no reading"
            await logEvent(nil, "unassigned_skipped", success: false, error: "\(reason); no 0131/01A6 data")
            return
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
        do {
            try await NeonRepository.shared.saveUnassignedReading(reading)
        } catch {
            SyncManager.shared.queueUnassignedReading(reading)
        }
        obdStatus = "Couldn't identify car — reading saved for review"
        await logEvent(nil, "unassigned_saved", value: dist, success: false, error: reason)
    }

    // MARK: - Mileage Calculation

    /// Calculate this car's mileage using: manual entry (priority 1) > reference + delta from 0131
    /// Returns (odometer, shouldPromptManualEntry)
    private func calculateMileage(vehicleId: String, currentDistSinceCleared: Double?) async throws -> (Double, Bool) {
        let manualRef = try await NeonRepository.shared.getLatestManualMileageRecord(vehicleId: vehicleId)

        guard let ref = manualRef else {
            obdStatus = "Enter odometer to start tracking"
            let latest = try await NeonRepository.shared.getLatestMileageRecord(vehicleId: vehicleId)
            return (latest?.odometerMiles ?? 0, true)
        }

        guard let currentDist = currentDistSinceCleared else {
            // dist unavailable — never regress below last known mileage
            let latest = try await NeonRepository.shared.getLatestMileageRecord(vehicleId: vehicleId)
            let lastKnown = latest?.odometerMiles ?? 0
            let best = max(ref.odometerMiles, lastKnown)
            obdStatus = "Using last known: \(Int(best)) mi"
            return (best, false)
        }

        guard let refDist = ref.distSinceCodesCleared else {
            obdStatus = "Confirm odometer now to enable auto-tracking"
            return (ref.odometerMiles, true)
        }

        let delta = currentDist - refDist

        if delta < 0 {
            obdStatus = "Codes cleared — enter new odometer"
            await logEvent(vehicleId, "codes_cleared_detected", pid: "0131", value: currentDist, success: false,
                      error: "Negative delta: current=\(Int(currentDist)) ref=\(Int(refDist))")
            return (ref.odometerMiles, true)
        }

        let calculated = ref.odometerMiles + delta
        obdStatus = "Calculated: \(Int(calculated)) mi"
        return (calculated, false)
    }

    // MARK: - Logging

    private static func ms(since start: Date) -> Int {
        Int(Date().timeIntervalSince(start) * 1000)
    }

    private func logEvent(_ vehicleId: String?, _ eventType: String, pid: String? = nil, raw: String? = nil,
                     value: Double? = nil, success: Bool, error: String? = nil, duration: Int? = nil) async {
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
            obdStatus = "Reconnecting..."
            Log.obd("throttle expired — reconnecting")
            bleManager.captureMode = "throttle_retry"
            bleManager.connectOrScan()
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
