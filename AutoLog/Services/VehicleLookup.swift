import Foundation

/// NHTSA vPIC VIN decoder (free, no key; US-market cars). Only ever fills
/// empty make/model/year fields — captures never depend on it.
enum VehicleLookup {
    struct Details: Equatable {
        var make: String?
        var model: String?
        var year: Int?
    }

    enum LookupError: LocalizedError {
        case badResponse
        case noMatch

        var errorDescription: String? {
            switch self {
            case .badResponse: return "NHTSA lookup returned an unexpected response"
            case .noMatch: return "NHTSA has no details for this VIN"
            }
        }
    }

    static func decode(vin: String) async throws -> Details {
        let cleaned = vin.uppercased()
        guard VINDecoder.isValidFormat(cleaned),
              let url = URL(string: "https://vpic.nhtsa.dot.gov/api/vehicles/DecodeVinValues/\(cleaned)?format=json") else {
            throw LookupError.badResponse
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw LookupError.badResponse
        }
        let details = try parse(data)
        guard details.make != nil || details.model != nil || details.year != nil else {
            throw LookupError.noMatch
        }
        return details
    }

    /// Make / Model / ModelYear from the first result. vPIC returns every field
    /// as a string, "" when it doesn't know.
    static func parse(_ data: Data) throws -> Details {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let results = json["Results"] as? [[String: Any]],
              let first = results.first else {
            throw LookupError.badResponse
        }
        func value(_ key: String) -> String? {
            guard let text = first[key] as? String else { return nil }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty || trimmed == "Not Applicable" ? nil : trimmed
        }
        return Details(
            make: value("Make").map(displayMake),
            model: value("Model"),
            year: value("ModelYear").flatMap { Int($0) }
        )
    }

    /// vPIC spells makes in capitals ("HYUNDAI"). Show "Hyundai", but keep short
    /// all-caps makes such as "BMW" or "GMC" as they are.
    static func displayMake(_ make: String) -> String {
        make == make.uppercased() && make.count > 3 ? make.capitalized : make
    }

    // MARK: - Filling a stored car

    /// Right after a new car is created: look it up without anyone waiting.
    /// Any failure is silent; "Look up details" on the Vehicles screen can retry.
    @MainActor
    static func fillMissingDetailsInBackground(vehicleId: String) {
        Task { @MainActor in
            await VehicleLookup.fillMissingDetails(vehicleId: vehicleId)
        }
    }

    /// Fill the car's empty make/model/year, and its nickname if it is still the
    /// automatic one, then refresh the car list (and offline cache) and reminders.
    @MainActor
    static func fillMissingDetails(vehicleId: String) async {
        do {
            guard let stored = try await NeonRepository.shared.getVehicle(id: vehicleId),
                  let vin = stored.vin else { return }
            let details = try await decode(vin: vin)

            let make = nonEmpty(stored.make) ?? details.make
            let model = nonEmpty(stored.model) ?? details.model
            let year = stored.year ?? details.year
            try await NeonRepository.shared.fillMissingVehicleDetails(
                id: vehicleId, make: details.make, model: details.model, year: details.year,
                nickname: Vehicle.autoNickname(make: make, model: model, year: year),
                replacingAutomaticNickname: Vehicle.autoNickname(make: stored.make, year: stored.year))

            guard let updated = try await NeonRepository.shared.getVehicle(id: vehicleId), updated != stored else { return }
            Log.db("vehicle details filled from NHTSA: \(updated.displayName)")
            await VehicleStore.shared.vehicleDidChange(updated)
        } catch {
            Log.db("NHTSA lookup skipped: \(error.localizedDescription)")
        }
    }

    private static func nonEmpty(_ text: String?) -> String? {
        guard let text, !text.isEmpty else { return nil }
        return text
    }
}
