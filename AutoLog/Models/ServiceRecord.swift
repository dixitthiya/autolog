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

    static let all: [ServiceCategory] = [
        ServiceCategory(name: "Brakes", icon: "circle.fill", types: [
            "Front Rotor Thickness Reading",
            "Rear Rotor Thickness Reading",
            "Front Brakepad Replacement",
            "Rear Brakepad Replacement",
            "Brake Service",
            "Brake Fluid Flush"
        ]),
        ServiceCategory(name: "Tires", icon: "circle.fill", types: [
            "New Front Tires",
            "New Rear Tires",
            "Tire Rotation"
        ]),
        ServiceCategory(name: "Engine", icon: "circle.fill", types: [
            "Oil & Oil Filter Change",
            "Engine Air Filter",
            "Cabin Air Filter",
            "Spark Plug Replacement",
            "Throttle Body Cleaning"
        ]),
        ServiceCategory(name: "Cooling", icon: "circle.fill", types: [
            "Coolant Flush",
            "Radiator Replacement"
        ]),
        ServiceCategory(name: "Transmission", icon: "gearshape.fill", types: [
            "Transmission Fluid Change"
        ]),
        ServiceCategory(name: "General", icon: "car.fill", types: [
            "Current Mileage",
            "Car Wash/Rinse & Ceramic Detailer",
            "Car Wash/Rinse & Cleaner Paste Wax",
            "Car Wash/Rinse & Liquid Ceramic Wax"
        ])
    ]

    static func category(for serviceType: String) -> String {
        for cat in all {
            if cat.types.contains(serviceType) {
                return cat.name
            }
        }
        return "General"
    }

    static var categoryColor: [String: (red: Double, green: Double, blue: Double)] {
        [
            "Brakes": (1.0, 0.231, 0.188),
            "Tires": (1.0, 0.8, 0.0),
            "Engine": (0.0, 0.478, 1.0),
            "Cooling": (0.204, 0.78, 0.349),
            "Transmission": (0.5, 0.5, 0.5),
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

    var milesRemaining: Double? {
        guard let warning = milesWarning else { return nil }
        return warning - milesAfterService
    }

    var milesToCritical: Double? {
        guard let critical = milesCritical else { return nil }
        return critical - milesAfterService
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
