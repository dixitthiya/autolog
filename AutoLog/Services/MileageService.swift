import Foundation
import UserNotifications

@MainActor
class MileageService: ObservableObject {
    static let shared = MileageService()

    @Published var lastSyncDate: Date?
    @Published var currentMileage: Double = 0
    @Published var isReading = false
    @Published var obdStatus: String = ""

    private var obdService: OBDCommandService?
    private var speedAccumulator: Double = 0
    private var lastSpeedReadTime: Date?

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

            // Fallback: speed accumulation
            if odometer == 0 {
                obdStatus = "Accumulating speed data (60s)..."
                do {
                    odometer = try await accumulateFromSpeed(obd: obd)
                    await NeonRepository.shared.logOBDEvent(
                        eventType: "speed_fallback", pid: "010D", rawResponse: nil,
                        parsedValue: odometer, success: odometer > 0,
                        errorMessage: odometer == 0 ? "Zero accumulation" : nil)
                } catch {
                    await NeonRepository.shared.logOBDEvent(
                        eventType: "speed_fallback", pid: "010D", rawResponse: nil,
                        parsedValue: nil, success: false,
                        errorMessage: error.localizedDescription)
                }
            }

            guard odometer > 0 else {
                obdStatus = "Could not read mileage"
                Log.obd("could not determine odometer")
                return
            }

            // Check if today's record exists
            let todayRecord = try await NeonRepository.shared.getTodayMileageRecord()
            if todayRecord == nil {
                let record = MileageRecord.bleAuto(odometer: odometer)
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

    private func accumulateFromSpeed(obd: OBDCommandService) async throws -> Double {
        let latest = try await NeonRepository.shared.getLatestMileageRecord()
        guard let baseOdometer = latest?.odometerMiles else {
            await NeonRepository.shared.logOBDEvent(
                eventType: "speed_fallback", pid: "010D", rawResponse: nil,
                parsedValue: nil, success: false,
                errorMessage: "No base odometer record exists for speed accumulation")
            throw OBDError.notSupported
        }

        speedAccumulator = 0
        lastSpeedReadTime = Date()
        var failedReads = 0

        for i in 0..<60 {
            do {
                let speedRaw = try await obd.sendCommand("010D")
                let speed = PIDParser.parseSpeed(speedRaw)
                let now = Date()
                if let lastTime = lastSpeedReadTime {
                    let deltaHours = now.timeIntervalSince(lastTime) / 3600
                    speedAccumulator += PIDParser.accumulateDistance(speedKPH: speed, deltaTimeHours: deltaHours)
                }
                lastSpeedReadTime = now
            } catch {
                failedReads += 1
                Log.obd("speed read \(i) failed: \(error.localizedDescription)")
            }
            try await Task.sleep(nanoseconds: 1_000_000_000)
        }

        if failedReads > 0 {
            await NeonRepository.shared.logOBDEvent(
                eventType: "speed_reads", pid: "010D", rawResponse: nil,
                parsedValue: speedAccumulator,
                success: failedReads < 30,
                errorMessage: "\(failedReads)/60 speed reads failed")
        }

        return baseOdometer + speedAccumulator
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
