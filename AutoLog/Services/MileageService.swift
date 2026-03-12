import Foundation
import UserNotifications

@MainActor
class MileageService: ObservableObject {
    static let shared = MileageService()

    @Published var lastSyncDate: Date?
    @Published var currentMileage: Double = 0
    @Published var isReading = false
    @Published var obdStatus: String = ""
    @Published var needsManualEntry = false
    @Published var lastCaptureInfo: String = ""
    @Published var isThrottled = false

    private var obdService: OBDCommandService?
    private var lastSkipTime: Date?
    private var throttleTask: Task<Void, Never>?

    private init() {}

    func clearSkipThrottle() {
        lastSkipTime = nil
        throttleTask?.cancel()
        throttleTask = nil
        isThrottled = false
    }

    /// Quick read: connect, read PIDs, save, disconnect (~10 seconds)
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

        let obd = OBDCommandService(bleManager: bleManager)
        self.obdService = obd

        // Init ELM327
        do {
            try await obd.initialize()
            await NeonRepository.shared.logOBDEvent(
                eventType: "init", pid: nil, rawResponse: nil,
                parsedValue: nil, success: true, errorMessage: nil)
        } catch {
            obdStatus = "OBD init failed"
            await NeonRepository.shared.logOBDEvent(
                eventType: "init", pid: nil, rawResponse: nil,
                parsedValue: nil, success: false,
                errorMessage: error.localizedDescription)
            return
        }

        do {
            // Read RPM
            obdStatus = "Reading RPM..."
            var rpm = 0
            var rpmReadSuccess = false
            do {
                let rpmRaw = try await obd.sendCommand("010C")
                rpm = PIDParser.parseRPM(rpmRaw)
                rpmReadSuccess = true
                await NeonRepository.shared.logOBDEvent(
                    eventType: "rpm_check", pid: "010C", rawResponse: rpmRaw,
                    parsedValue: Double(rpm), success: rpm > 0,
                    errorMessage: rpm == 0 ? "RPM=0 (engine off)" : nil)
            } catch {
                await NeonRepository.shared.logOBDEvent(
                    eventType: "rpm_check", pid: "010C", rawResponse: nil,
                    parsedValue: nil, success: false,
                    errorMessage: error.localizedDescription)
            }

            // Only skip if RPM was successfully read as 0 (confirmed engine off)
            // If RPM read failed (timeout/junk), continue — fix #3 will catch bad data
            if rpmReadSuccess && rpm == 0 {
                obdStatus = "Engine off — retrying in 10s"
                lastSkipTime = Date()
                isThrottled = true
                await NeonRepository.shared.logOBDEvent(
                    eventType: "skipped_engine_off", pid: "010C", rawResponse: nil,
                    parsedValue: 0, success: false,
                    errorMessage: "RPM=0, engine confirmed off")
                // Start real countdown then reconnect
                startThrottleCountdown(bleManager: bleManager)
                return
            }

            // Read odometer PID (will likely fail on 2013 Elantra)
            var odometer: Double = 0
            do {
                let rawResponse = try await obd.sendCommand("01A6")
                odometer = PIDParser.parseOdometer(rawResponse)
                await NeonRepository.shared.logOBDEvent(
                    eventType: "odometer_read", pid: "01A6", rawResponse: rawResponse,
                    parsedValue: odometer, success: odometer > 0,
                    errorMessage: odometer == 0 ? "Parse failed: \(rawResponse)" : nil)
            } catch {
                await NeonRepository.shared.logOBDEvent(
                    eventType: "odometer_read", pid: "01A6", rawResponse: nil,
                    parsedValue: nil, success: false,
                    errorMessage: error.localizedDescription)
            }

            // Read distance since codes cleared (PID 0131)
            obdStatus = "Reading distance..."
            var distSinceCleared: Double?
            do {
                let distRaw = try await obd.sendCommand("0131")
                let distMiles = PIDParser.parseDistanceSinceCodesCleared(distRaw)
                distSinceCleared = distMiles > 0 ? distMiles : nil
                await NeonRepository.shared.logOBDEvent(
                    eventType: "dist_since_clear", pid: "0131", rawResponse: distRaw,
                    parsedValue: distMiles, success: distMiles > 0,
                    errorMessage: distMiles == 0 ? "Parse failed or zero" : nil)
            } catch {
                await NeonRepository.shared.logOBDEvent(
                    eventType: "dist_since_clear", pid: "0131", rawResponse: nil,
                    parsedValue: nil, success: false,
                    errorMessage: error.localizedDescription)
            }

            // Calculate mileage
            if odometer == 0 {
                odometer = try await calculateMileage(currentDistSinceCleared: distSinceCleared)
            }

            guard odometer > 0 else {
                obdStatus = "Enter odometer manually"
                needsManualEntry = true
                return
            }

            // Sanity check: reject if odometer drops more than 1 mile from last known value
            if let lastRecord = try await NeonRepository.shared.getLatestMileageRecord(),
               lastRecord.odometerMiles > 0,
               odometer < lastRecord.odometerMiles - 1 {
                obdStatus = "Bad reading — skipped"
                await NeonRepository.shared.logOBDEvent(
                    eventType: "sanity_check_failed", pid: nil, rawResponse: nil,
                    parsedValue: odometer, success: false,
                    errorMessage: "Odometer dropped: \(Int(odometer)) < last \(Int(lastRecord.odometerMiles))")
                return
            }

            // Save or update today's BLE_AUTO record (never overwrite MANUAL entries)
            let todayBLERecord = try await NeonRepository.shared.getTodayBLEAutoRecord()
            let record = MileageRecord.bleAuto(odometer: odometer, distSinceCodesCleared: distSinceCleared)

            if let existing = todayBLERecord {
                // Update today's BLE_AUTO record with latest reading
                let updated = MileageRecord(
                    id: existing.id,
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
                    await NeonRepository.shared.logOBDEvent(
                        eventType: "mileage_save", pid: nil, rawResponse: nil,
                        parsedValue: odometer, success: true, errorMessage: nil)
                } catch {
                    SyncManager.shared.queueMileageRecord(record)
                    await NeonRepository.shared.logOBDEvent(
                        eventType: "mileage_save", pid: nil, rawResponse: nil,
                        parsedValue: odometer, success: false,
                        errorMessage: "Queued: \(error.localizedDescription)")
                }
            }

            // Save snapshot for every capture (auto-purges after 7 days)
            await NeonRepository.shared.saveMileageSnapshot(
                odometer: odometer, distSinceCodesCleared: distSinceCleared, rpm: rpm,
                captureMode: bleManager.captureMode)

            currentMileage = odometer
            lastSyncDate = Date()
            clearSkipThrottle()
            let timeStr = Date().formatted(date: .omitted, time: .standard)
            obdStatus = "Captured \(Int(odometer)) mi at \(timeStr)"
            lastCaptureInfo = "Mileage: \(Int(odometer)) mi at \(timeStr)"

            // Send silent notification so user knows data was captured
            await sendCaptureNotification(odometer: odometer, captureMode: bleManager.captureMode)

            await checkStatusNotifications()
            await SyncManager.shared.syncAll()

        } catch {
            obdStatus = "Read failed"
            await NeonRepository.shared.logOBDEvent(
                eventType: "connection_error", pid: nil, rawResponse: nil,
                parsedValue: nil, success: false,
                errorMessage: error.localizedDescription)
        }
    }

    /// Calculate current mileage using: manual entry (priority 1) > reference + delta from 0131
    private func calculateMileage(currentDistSinceCleared: Double?) async throws -> Double {
        let manualRef = try await NeonRepository.shared.getLatestManualMileageRecord()

        guard let ref = manualRef else {
            needsManualEntry = true
            obdStatus = "Enter odometer to start tracking"
            let latest = try await NeonRepository.shared.getLatestMileageRecord()
            return latest?.odometerMiles ?? 0
        }

        guard let currentDist = currentDistSinceCleared else {
            // dist unavailable — never regress below last known mileage
            let latest = try await NeonRepository.shared.getLatestMileageRecord()
            let lastKnown = latest?.odometerMiles ?? 0
            let best = max(ref.odometerMiles, lastKnown)
            obdStatus = "Using last known: \(Int(best)) mi"
            return best
        }

        guard let refDist = ref.distSinceCodesCleared else {
            needsManualEntry = true
            obdStatus = "Confirm odometer now to enable auto-tracking"
            return ref.odometerMiles
        }

        let delta = currentDist - refDist

        if delta < 0 {
            needsManualEntry = true
            obdStatus = "Codes cleared — enter new odometer"
            await NeonRepository.shared.logOBDEvent(
                eventType: "codes_cleared_detected", pid: "0131", rawResponse: nil,
                parsedValue: currentDist, success: false,
                errorMessage: "Negative delta: current=\(Int(currentDist)) ref=\(Int(refDist))")
            return ref.odometerMiles
        }

        let calculated = ref.odometerMiles + delta
        obdStatus = "Calculated: \(Int(calculated)) mi"
        return calculated
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
    private func sendCaptureNotification(odometer: Double, captureMode: String) async {
        let content = UNMutableNotificationContent()
        content.title = "AutoLog"
        content.body = "Mileage captured: \(Int(odometer).formatted()) mi"
        content.sound = nil
        content.interruptionLevel = .passive

        let request = UNNotificationRequest(
            identifier: "mileage-capture",
            content: content,
            trigger: nil
        )

        do {
            try await UNUserNotificationCenter.current().add(request)
        } catch {
            Log.notify("capture notification failed: \(error.localizedDescription)")
        }
    }

    private func checkStatusNotifications() async {
        do {
            let dashboard = try await NeonRepository.shared.getDashboardData()
            for row in dashboard {
                switch row.status {
                case .critical:
                    await sendNotification(
                        title: "Critical Service Alert",
                        body: "\(row.serviceType): Immediate Service Required"
                    )
                case .serviceSoon:
                    if let toCritical = row.milesToCritical, toCritical > 0 {
                        await sendNotification(
                            title: "Service Reminder",
                            body: "\(row.serviceType): Critical in \(Int(toCritical).formatted()) miles"
                        )
                    } else {
                        await sendNotification(
                            title: "Service Reminder",
                            body: "\(row.serviceType): Service due"
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
