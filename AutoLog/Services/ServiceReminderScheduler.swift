import Foundation
import UserNotifications

struct ServiceReminderScheduler {

    /// Recalculate and reschedule all service reminder notifications.
    /// Call on every app launch and after every OBD capture.
    static func reschedule() async {
        do {
            let thresholds = try await NeonRepository.shared.getThresholds()
            let mileageRecords = try await NeonRepository.shared.getMileageRecords()
            let currentOdometer = mileageRecords
                .sorted { $0.timestamp > $1.timestamp }
                .first?.odometerMiles ?? 0

            let milesPerDay = calculateMilesPerDay(from: mileageRecords)

            // Remove all previously scheduled service reminders
            let center = UNUserNotificationCenter.current()
            let pending = await center.pendingNotificationRequests()
            let reminderIDs = pending
                .filter { $0.identifier.hasPrefix("service-reminder-") }
                .map(\.identifier)
            center.removePendingNotificationRequests(withIdentifiers: reminderIDs)

            // Schedule new reminders for each service
            for threshold in thresholds {
                let lastService = try await NeonRepository.shared.getLatestRecord(for: threshold.serviceType)
                guard let lastService = lastService else { continue }

                let milesSince = currentOdometer - lastService.odometerMiles
                let daysSince = Calendar.current.dateComponents([.day], from: lastService.timestamp, to: Date()).day ?? 0

                // Time-based reminders (exact)
                scheduleTimeReminder(
                    serviceType: threshold.serviceType,
                    lastServiceDate: lastService.timestamp,
                    daysThreshold: threshold.daysWarning,
                    level: "warning",
                    center: center
                )
                scheduleTimeReminder(
                    serviceType: threshold.serviceType,
                    lastServiceDate: lastService.timestamp,
                    daysThreshold: threshold.daysCritical,
                    level: "critical",
                    center: center
                )

                // Mileage-based reminders (estimated)
                scheduleMilesReminder(
                    serviceType: threshold.serviceType,
                    milesSince: milesSince,
                    milesThreshold: threshold.milesWarning,
                    milesPerDay: milesPerDay,
                    level: "warning",
                    center: center
                )
                scheduleMilesReminder(
                    serviceType: threshold.serviceType,
                    milesSince: milesSince,
                    milesThreshold: threshold.milesCritical,
                    milesPerDay: milesPerDay,
                    level: "critical",
                    center: center
                )
            }

            let newPending = await center.pendingNotificationRequests()
            let scheduled = newPending.filter { $0.identifier.hasPrefix("service-reminder-") }.count
            Log.notify("scheduled \(scheduled) service reminders (velocity: \(Int(milesPerDay)) mi/day)")
        } catch {
            Log.notify("failed to schedule reminders: \(error.localizedDescription)")
        }
    }

    // MARK: - Time-Based (Exact)

    private static func scheduleTimeReminder(
        serviceType: String,
        lastServiceDate: Date,
        daysThreshold: Int?,
        level: String,
        center: UNUserNotificationCenter
    ) {
        guard let days = daysThreshold else { return }
        guard let dueDate = Calendar.current.date(byAdding: .day, value: days, to: lastServiceDate) else { return }

        // Only schedule future notifications
        guard dueDate > Date() else { return }

        // Schedule for 9 AM on the due date
        var components = Calendar.current.dateComponents([.year, .month, .day], from: dueDate)
        components.hour = 9

        let content = UNMutableNotificationContent()
        if level == "critical" {
            content.title = "Service Overdue"
            content.body = "\(serviceType): \(days) days since last service — schedule now"
        } else {
            content.title = "Service Reminder"
            content.body = "\(serviceType): Due soon — \(days) days since last service"
        }
        content.sound = .default

        let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
        let id = "service-reminder-time-\(level)-\(serviceType)"
        let request = UNNotificationRequest(identifier: id, content: content, trigger: trigger)

        center.add(request) { error in
            if let error = error {
                Log.notify("failed to schedule time reminder for \(serviceType): \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Mileage-Based (Estimated)

    private static func scheduleMilesReminder(
        serviceType: String,
        milesSince: Double,
        milesThreshold: Double?,
        milesPerDay: Double,
        level: String,
        center: UNUserNotificationCenter
    ) {
        guard let threshold = milesThreshold else { return }
        guard milesPerDay > 0 else { return }

        let milesRemaining = threshold - milesSince
        guard milesRemaining > 0 else { return } // already past threshold

        let daysUntil = milesRemaining / milesPerDay
        guard let dueDate = Calendar.current.date(byAdding: .day, value: Int(daysUntil), to: Date()) else { return }
        guard dueDate > Date() else { return }

        var components = Calendar.current.dateComponents([.year, .month, .day], from: dueDate)
        components.hour = 9

        let content = UNMutableNotificationContent()
        if level == "critical" {
            content.title = "Service Estimated Overdue"
            content.body = "\(serviceType): ~\(Int(threshold).formatted()) mi since last service (estimated from recent driving)"
        } else {
            content.title = "Service Estimate"
            content.body = "\(serviceType): Estimated ~\(Int(milesRemaining).formatted()) mi remaining (based on recent driving)"
        }
        content.sound = .default

        let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
        let id = "service-reminder-miles-\(level)-\(serviceType)"
        let request = UNNotificationRequest(identifier: id, content: content, trigger: trigger)

        center.add(request) { error in
            if let error = error {
                Log.notify("failed to schedule miles reminder for \(serviceType): \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Velocity Calculation

    /// Same logic as AnalyticsView: 14-day velocity, fallback to 3 months prior
    private static func calculateMilesPerDay(from records: [MileageRecord]) -> Double {
        let sorted = records.sorted { $0.timestamp < $1.timestamp }
        guard sorted.count >= 2 else { return 0 }

        let twoWeeksAgo = Calendar.current.date(byAdding: .day, value: -14, to: Date()) ?? Date()
        let recent14 = sorted.filter { $0.timestamp >= twoWeeksAgo }
        if let v = velocity(from: recent14), v > 0 { return v }

        let threeMonthsBefore = Calendar.current.date(byAdding: .month, value: -3, to: twoWeeksAgo) ?? Date()
        let prior3Months = sorted.filter { $0.timestamp >= threeMonthsBefore && $0.timestamp < twoWeeksAgo }
        if let v = velocity(from: prior3Months), v > 0 { return v }

        return 0
    }

    private static func velocity(from records: [MileageRecord]) -> Double? {
        guard records.count >= 2, let first = records.first, let last = records.last else { return nil }
        let days = last.timestamp.timeIntervalSince(first.timestamp) / 86400
        guard days > 0 else { return nil }
        return (last.odometerMiles - first.odometerMiles) / days
    }
}
