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

    private var obdService: OBDCommandService?

    private init() {}

    func onBLEConnected(bleManager: BLEManager) async {
        guard !isReading else { return }
        isReading = true
        obdStatus = "Initializing OBD..."
        defer { isReading = false }

        let obd = OBDCommandService(bleManager: bleManager)
        self.obdService = obd

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
            obdStatus = "Checking engine..."
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
                Log.obd("RPM check failed: \(error.localizedDescription)")
            }

            // Continue even if RPM=0 — still try to read odometer
            if rpm == 0 {
                obdStatus = "RPM unavailable, trying odometer anyway..."
                Log.obd("RPM=0 or failed, continuing to odometer read")
            }

            var odometer: Double = 0
            var odometerRawResponse: String?

            // Try direct odometer PID first
            obdStatus = "Reading odometer..."
            do {
                let rawResponse = try await obd.sendCommand("01A6")
                odometerRawResponse = rawResponse
                odometer = PIDParser.parseOdometer(rawResponse)

                if odometer == 0 {
                    obdStatus = "Odometer PID not supported - trying speed fallback"
                    await NeonRepository.shared.logOBDEvent(
                        eventType: "odometer_read", pid: "01A6", rawResponse: rawResponse,
                        parsedValue: 0, success: false,
                        errorMessage: "Parse failed: response=\(rawResponse)")
                } else {
                    await NeonRepository.shared.logOBDEvent(
                        eventType: "odometer_read", pid: "01A6", rawResponse: rawResponse,
                        parsedValue: odometer, success: true, errorMessage: nil)
                }
            } catch {
                obdStatus = "Odometer read failed - trying speed fallback"
                await NeonRepository.shared.logOBDEvent(
                    eventType: "odometer_read", pid: "01A6", rawResponse: odometerRawResponse,
                    parsedValue: nil, success: false,
                    errorMessage: error.localizedDescription)
                Log.obd("01A6 failed, trying speed accumulation fallback")
            }

            // Read distance since codes cleared (PID 0131)
            obdStatus = "Reading distance since codes cleared..."
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

            // Calculate mileage: manual entry > reference + delta from 0131
            if odometer == 0 {
                odometer = try await calculateMileage(currentDistSinceCleared: distSinceCleared)
            }

            guard odometer > 0 else {
                obdStatus = "No mileage data — enter manually"
                needsManualEntry = true
                Log.obd("could not determine odometer")
                return
            }

            // Check if today's record exists
            let todayRecord = try await NeonRepository.shared.getTodayMileageRecord()
            if todayRecord == nil {
                let record = MileageRecord.bleAuto(odometer: odometer, distSinceCodesCleared: distSinceCleared)
                do {
                    try await NeonRepository.shared.saveMileageRecord(record)
                    Log.db("mileage record saved: \(Int(odometer)) miles")
                    await NeonRepository.shared.logOBDEvent(
                        eventType: "mileage_save", pid: nil, rawResponse: nil,
                        parsedValue: odometer, success: true, errorMessage: nil)
                } catch {
                    SyncManager.shared.queueMileageRecord(record)
                    Log.sync("queued mileage record for retry")
                    await NeonRepository.shared.logOBDEvent(
                        eventType: "mileage_save", pid: nil, rawResponse: nil,
                        parsedValue: odometer, success: false,
                        errorMessage: "DB save failed, queued: \(error.localizedDescription)")
                }

                currentMileage = odometer
                lastSyncDate = Date()
                obdStatus = "Mileage synced: \(Int(odometer)) mi"

                await checkStatusNotifications()
            } else {
                Log.db("today's record already exists, skipping")
                currentMileage = todayRecord!.odometerMiles
                obdStatus = "Already synced today"
            }

            // Sync any pending records
            await SyncManager.shared.syncAll()

        } catch {
            obdStatus = "Connection error"
            Log.obd("error during mileage read: \(error.localizedDescription)")
            await NeonRepository.shared.logOBDEvent(
                eventType: "connection_error", pid: nil, rawResponse: nil,
                parsedValue: nil, success: false,
                errorMessage: error.localizedDescription)
        }
    }

    /// Calculate current mileage using: manual entry (priority 1) > reference + delta from 0131
    private func calculateMileage(currentDistSinceCleared: Double?) async throws -> Double {
        // Find the latest manual entry as reference point
        let manualRef = try await NeonRepository.shared.getLatestManualMileageRecord()

        // If no manual entry exists, can't calculate — need manual entry
        guard let ref = manualRef else {
            Log.obd("no manual reference entry exists")
            needsManualEntry = true
            obdStatus = "Enter odometer manually to start tracking"
            // Fall back to latest record of any type
            let latest = try await NeonRepository.shared.getLatestMileageRecord()
            return latest?.odometerMiles ?? 0
        }

        // If we have a 0131 reading, calculate delta from reference
        guard let currentDist = currentDistSinceCleared else {
            // No 0131 reading — use reference odometer as-is
            obdStatus = "Using manual entry: \(Int(ref.odometerMiles)) mi"
            return ref.odometerMiles
        }

        guard let refDist = ref.distSinceCodesCleared else {
            // Reference was entered without OBD — no baseline to calculate delta
            // Prompt user to confirm odometer while OBD is connected
            needsManualEntry = true
            obdStatus = "Confirm odometer now to enable auto-tracking"
            return ref.odometerMiles
        }

        let delta = currentDist - refDist

        // Detect negative delta = codes were cleared (counter reset)
        if delta < 0 {
            Log.obd("codes cleared detected! delta=\(Int(delta)), current=\(Int(currentDist)), ref=\(Int(refDist))")
            needsManualEntry = true
            obdStatus = "Codes cleared — enter new odometer reading"
            await NeonRepository.shared.logOBDEvent(
                eventType: "codes_cleared_detected", pid: "0131", rawResponse: nil,
                parsedValue: currentDist, success: false,
                errorMessage: "Negative delta: current=\(Int(currentDist)) ref=\(Int(refDist))")
            return ref.odometerMiles // Don't go backwards
        }

        let calculated = ref.odometerMiles + delta
        obdStatus = "Calculated: \(Int(calculated)) mi (+\(Int(delta)) since ref)"
        Log.obd("calculated mileage: \(Int(ref.odometerMiles)) + \(Int(delta)) = \(Int(calculated))")
        return calculated
    }

    private func checkStatusNotifications() async {
        do {
            let dashboard = try await NeonRepository.shared.getDashboardData()
            for row in dashboard {
                switch row.status {
                case .critical:
                    Log.notify("status changed: \(row.serviceType) -> critical")
                    await sendNotification(
                        title: "Critical Service Alert",
                        body: "🔴 \(row.serviceType): Critical - Immediate Service Required"
                    )
                case .serviceSoon:
                    let milesRemaining = max(0, (row.currentMileage - row.lastServiceMileage))
                    Log.notify("status changed: \(row.serviceType) -> serviceSoon")
                    await sendNotification(
                        title: "Service Reminder",
                        body: "⚠️ \(row.serviceType): Service Soon - due in \(Int(milesRemaining)) miles"
                    )
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
