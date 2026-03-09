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

    private var obdService: OBDCommandService?

    private init() {}

    /// Quick read: connect, read PIDs, save, disconnect (~10 seconds)
    func onBLEConnected(bleManager: BLEManager) async {
        guard !isReading else { return }
        isReading = true
        obdStatus = "Reading data..."
        defer {
            isReading = false
            // Always disconnect after read — free up adapter for other apps
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
            do {
                let rpmRaw = try await obd.sendCommand("010C")
                rpm = PIDParser.parseRPM(rpmRaw)
                await NeonRepository.shared.logOBDEvent(
                    eventType: "rpm_check", pid: "010C", rawResponse: rpmRaw,
                    parsedValue: Double(rpm), success: rpm > 0,
                    errorMessage: rpm == 0 ? "RPM=0 (engine off or parse failed)" : nil)
            } catch {
                await NeonRepository.shared.logOBDEvent(
                    eventType: "rpm_check", pid: "010C", rawResponse: nil,
                    parsedValue: nil, success: false,
                    errorMessage: error.localizedDescription)
            }

            if rpm == 0 {
                obdStatus = "RPM unavailable, continuing..."
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
                odometer: odometer, distSinceCodesCleared: distSinceCleared, rpm: rpm)

            currentMileage = odometer
            lastSyncDate = Date()
            let timeStr = Date().formatted(date: .omitted, time: .shortened)
            obdStatus = "Captured \(Int(odometer)) mi at \(timeStr)"
            lastCaptureInfo = "Mileage: \(Int(odometer)) mi at \(timeStr)"

            // Send a silent notification so user knows data was captured
            await sendCaptureNotification(odometer: odometer)

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
            obdStatus = "Using manual: \(Int(ref.odometerMiles)) mi"
            return ref.odometerMiles
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

    // MARK: - Notifications

    /// Notify user that mileage data was captured (so they know they can switch to Car Scanner Pro)
    private func sendCaptureNotification(odometer: Double) async {
        let content = UNMutableNotificationContent()
        content.title = "AutoLog"
        content.body = "Mileage captured: \(Int(odometer).formatted()) mi"
        content.sound = nil // Silent — just a banner
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
