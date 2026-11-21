import Foundation

/// The car list as last seen online, so a capture can identify a known car by
/// VIN without the network. Refreshed whenever cars are fetched. It only ever
/// *identifies* cars that already exist; a car is never created from it.
enum VehicleCache {
    private static let key = "cachedVehicles"

    static func load() -> [Vehicle] {
        guard let data = UserDefaults.standard.data(forKey: key) else { return [] }
        return (try? JSONDecoder().decode([Vehicle].self, from: data)) ?? []
    }

    static func save(_ vehicles: [Vehicle]) {
        guard let data = try? JSONEncoder().encode(vehicles) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }

    /// Add or replace one car (after an online lookup of a single VIN).
    static func upsert(_ vehicle: Vehicle) {
        var all = load().filter { $0.id != vehicle.id }
        all.append(vehicle)
        save(all)
    }

    static func vehicle(vin: String) -> Vehicle? {
        let wanted = vin.uppercased()
        return load().first { $0.vin?.uppercased() == wanted }
    }
}
