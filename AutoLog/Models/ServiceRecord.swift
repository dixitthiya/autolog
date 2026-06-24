import Foundation

struct ServiceRecord: Codable, Identifiable {
    let id: String
    let timestamp: Date
    let serviceType: String
    let category: String
    let odometerMiles: Double
    var rotorThicknessMM: Double?
    var amount: Double?
    var comments: String?
    var manuallyEdited: Bool

    static func new(
        serviceType: String,
        category: String,
        odometer: Double,
        date: Date = Date(),
        rotorThickness: Double? = nil,
        amount: Double? = nil,
        comments: String? = nil
    ) -> ServiceRecord {
        ServiceRecord(
            id: UUID().uuidString,
            timestamp: date,
            serviceType: serviceType,
            category: category,
            odometerMiles: odometer,
            rotorThicknessMM: rotorThickness,
            amount: amount,
            comments: comments,
            manuallyEdited: false
        )
    }
}

struct ServiceCategory {
    let name: String
    let icon: String
    let types: [String]

    // Loaded from DB; falls back to empty until populated
    @MainActor static var all: [ServiceCategory] = []

    @MainActor static func loadFromDB() async {
        do {
            let categories = try await NeonRepository.shared.getServiceCategories()
            if !categories.isEmpty {
                all = categories
                Log.db("loaded \(categories.count) service categories from DB")
            }
        } catch {
            Log.db("failed to load service categories: \(error.localizedDescription)")
        }
    }

    @MainActor static func category(for serviceType: String) -> String {
        for cat in all {
            if cat.types.contains(serviceType) {
                return cat.name
            }
        }
        return "General"
    }

    static func iconFor(_ categoryName: String) -> String {
        switch categoryName {
        case "Brakes": return "circle.fill"
        case "Tires": return "circle.fill"
        case "Engine": return "circle.fill"
        case "Cooling": return "snowflake"
        case "Transmission": return "gearshape.fill"
        case "Steering & Suspension": return "arrow.left.and.right"
        case "Electrical": return "bolt.fill"
        case "HVAC": return "thermometer.medium"
        case "Exterior": return "sparkles"
        default: return "car.fill"
        }
    }

    static var categoryColor: [String: (red: Double, green: Double, blue: Double)] {
        [
            "Brakes": (1.0, 0.231, 0.188),
            "Tires": (1.0, 0.8, 0.0),
            "Engine": (0.0, 0.478, 1.0),
            "Cooling": (0.204, 0.78, 0.349),
            "Transmission": (0.5, 0.5, 0.5),
            "Steering & Suspension": (0.6, 0.4, 0.8),
            "Electrical": (1.0, 0.6, 0.0),
            "HVAC": (0.0, 0.7, 0.7),
            "Exterior": (0.4, 0.7, 1.0),
            "General": (0.6, 0.6, 0.6)
        ]
    }
}

struct DashboardRow: Identifiable {
    let id: String
    let serviceType: String
    let milesAfterService: Double
    let status: ServiceStatus
    let currentMileage: Double
    let lastServiceMileage: Double
    let lastServiceDate: Date?
    let rotorThickness: Double?
    let daysAfterService: Int
    let monthsAfterService: Double
    let milesWarning: Double?
    let milesCritical: Double?
    let daysWarning: Int?
    let daysCritical: Int?

    var milesRemaining: Double? {
        guard let warning = milesWarning else { return nil }
        return warning - milesAfterService
    }

    var milesToCritical: Double? {
        guard let critical = milesCritical else { return nil }
        return critical - milesAfterService
    }

    var daysRemaining: Int? {
        guard let warning = daysWarning else { return nil }
        return warning - daysAfterService
    }

    var daysToCritical: Int? {
        guard let critical = daysCritical else { return nil }
        return critical - daysAfterService
    }

    var monthsRemaining: Double? {
        guard let days = daysRemaining else { return nil }
        return Double(days) / 30.44
    }

    var monthsToCritical: Double? {
        guard let days = daysToCritical else { return nil }
        return Double(days) / 30.44
    }
}

struct TrackedItem: Identifiable {
    var id: String { serviceType }
    let serviceType: String
    let lastServiceDate: Date
    let lastServiceMileage: Double
    let milesSince: Double
    let amount: Double?
    let comments: String?

    var daysSince: Int {
        Calendar.current.dateComponents([.day], from: lastServiceDate, to: Date()).day ?? 0
    }
}

struct ServiceThreshold: Codable {
    let serviceType: String
    var milesCritical: Double?
    var milesWarning: Double?
    var daysCritical: Int?
    var daysWarning: Int?
    var rotorCritical: Double?
    var rotorWarning: Double?
}

extension ServiceThreshold {
    /// The single shared "is this service past its limit?" rule.
    /// Both the Dashboard (StatusCalculator) and Analytics (projected dates)
    /// call this so the two screens can never disagree about due/overdue.
    /// A limit counts as reached when EITHER the mileage or the elapsed-time
    /// threshold is exceeded; an unset threshold is simply ignored.
    func hasReachedCritical(milesSince: Double, daysSince: Int) -> Bool {
        isPast(miles: milesCritical, days: daysCritical, milesSince: milesSince, daysSince: daysSince)
    }

    func hasReachedWarning(milesSince: Double, daysSince: Int) -> Bool {
        isPast(miles: milesWarning, days: daysWarning, milesSince: milesSince, daysSince: daysSince)
    }

    private func isPast(miles: Double?, days: Int?, milesSince: Double, daysSince: Int) -> Bool {
        let milesPast = miles.map { milesSince > $0 } ?? false
        let daysPast = days.map { daysSince > $0 } ?? false
        return milesPast || daysPast
    }
}
