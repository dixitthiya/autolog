import Foundation
import UserNotifications

@MainActor
class MileageService: ObservableObject {
    static let shared = MileageService()

    @Published var lastSyncDate: Date?
    @Published var currentMileage: Double = 0
    @Published var isReading = false

    private var obdService: OBDCommandService?
    private var speedAccumulator: Double = 0
    private var lastSpeedReadTime: Date?

    private init() {}

    func onBLEConnected(bleManager: BLEManager) async {
        guard !isReading else { return }
        isReading = true
        defer { isReading = false }

        let obd = OBDCommandService(bleManager: bleManager)
        self.obdService = obd

        do {
            try await obd.initialize()
            let rpm = try await obd.getRPM()

            guard rpm > 0 else {
                Log.obd("engine not running (RPM=0), skipping")
                bleManager.disconnect()
                return
            }

            var odometer: Double = 0

            // Try direct odometer PID first
            do {
                odometer = try await obd.getOdometer()
            } catch {
                Log.obd("01A6 failed, trying speed accumulation fallback")
            }

            // Fallback: speed accumulation
            if odometer == 0 {
                odometer = try await accumulateFromSpeed(obd: obd)
            }

            guard odometer > 0 else {
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
                } catch {
                    SyncManager.shared.queueMileageRecord(record)
                    Log.sync("queued mileage record for retry")
                }

                currentMileage = odometer
                lastSyncDate = Date()

                await checkStatusNotifications()
            } else {
                Log.db("today's record already exists, skipping")
                currentMileage = todayRecord!.odometerMiles
            }

            // Sync any pending records
            await SyncManager.shared.syncAll()

        } catch {
            Log.obd("error during mileage read: \(error.localizedDescription)")
        }
    }

    private func accumulateFromSpeed(obd: OBDCommandService) async throws -> Double {
        let latest = try await NeonRepository.shared.getLatestMileageRecord()
        guard let baseOdometer = latest?.odometerMiles else {
            throw OBDError.notSupported
        }

        speedAccumulator = 0
        lastSpeedReadTime = Date()

        for _ in 0..<60 {
            let speed = try await obd.getSpeed()
            let now = Date()
            if let lastTime = lastSpeedReadTime {
                let deltaHours = now.timeIntervalSince(lastTime) / 3600
                speedAccumulator += PIDParser.accumulateDistance(speedKPH: speed, deltaTimeHours: deltaHours)
            }
            lastSpeedReadTime = now
            try await Task.sleep(nanoseconds: 1_000_000_000)
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
