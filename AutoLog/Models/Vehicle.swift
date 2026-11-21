import Foundation

enum VehicleStatus: String, Codable {
    case active
    case retired
}

/// A car tracked by the app. Every per-car row in Neon carries its `id` as
/// `vehicle_id`. Cars are identified on connect by VIN; a retired car never
/// receives captures or reminders.
struct Vehicle: Codable, Identifiable, Hashable {
    let id: String
    var nickname: String?
    var make: String?
    var model: String?
    var year: Int?
    var vin: String?
    var status: VehicleStatus
    var createdAt: Date?

    /// Fixed id of the 2013 Elantra — owner of all data from before multi-car.
    static let elantraId = "vehicle-elantra-2013"

    var isActive: Bool { status == .active }

    /// Nickname, else "year make model", else the VIN.
    var displayName: String {
        if let nickname, !nickname.isEmpty { return nickname }
        let parts = [year.map(String.init), make, model].compactMap { $0 }.filter { !$0.isEmpty }
        if !parts.isEmpty { return parts.joined(separator: " ") }
        return vin ?? "Vehicle"
    }

    /// The name a car gets automatically: "year make" (what `new` produces),
    /// plus the model once it is known. Used to tell whether the nickname is
    /// still the automatic one before replacing it.
    static func autoNickname(make: String?, model: String? = nil, year: Int?) -> String? {
        let name = [year.map(String.init), make, model]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        return name.isEmpty ? nil : name
    }

    /// A newly seen car, named from what can be decoded offline from its VIN.
    static func new(vin: String, make: String?, year: Int?) -> Vehicle {
        let name = [year.map(String.init), make].compactMap { $0 }.joined(separator: " ")
        return Vehicle(
            id: UUID().uuidString,
            nickname: name.isEmpty ? nil : name,
            make: make,
            model: nil,
            year: year,
            vin: vin.uppercased(),
            status: .active,
            createdAt: Date()
        )
    }
}

/// A capture whose car couldn't be identified (VIN read failed). Kept so it
/// can be assigned to a car later instead of being guessed or discarded.
struct UnassignedReading: Codable, Identifiable {
    let id: String
    let timestamp: Date
    let failureReason: String        // vin_timeout | vin_no_data | vin_invalid | vin_error | vin_lookup_error
    var vinRawResponse: String?
    var peripheralId: String?
    var captureMode: String?
    var rpm: Int?
    var odometerRawResponse: String?
    var distSinceCodesCleared: Double?
    var distRawResponse: String?
    var assignedVehicleId: String?
    var assignedAt: Date?
}
