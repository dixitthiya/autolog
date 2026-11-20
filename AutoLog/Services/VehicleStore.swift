import Foundation

/// App-wide vehicle state.
/// - viewed: the car the screens show and where manual entries from the UI go.
///   Follows an explicit pick (Prompt B picker) if there is one, otherwise the
///   newest active car, otherwise the most recent car.
/// - connected: the car the adapter is plugged into right now, set from its
///   VIN. Captures only ever use this, never the viewed car.
@MainActor
final class VehicleStore: ObservableObject {
    static let shared = VehicleStore()

    private static let selectedKey = "selectedVehicleId"

    /// Newest first.
    @Published private(set) var vehicles: [Vehicle] = []
    /// Explicit choice from the picker; nil = follow the default.
    @Published var selectedVehicleId: String? {
        didSet { UserDefaults.standard.set(selectedVehicleId, forKey: Self.selectedKey) }
    }
    @Published var connectedVehicle: Vehicle?

    private init() {
        selectedVehicleId = UserDefaults.standard.string(forKey: Self.selectedKey)
    }

    var viewedVehicle: Vehicle? {
        if let id = selectedVehicleId, let picked = vehicles.first(where: { $0.id == id }) {
            return picked
        }
        return vehicles.first(where: { $0.isActive }) ?? vehicles.first
    }

    var viewedVehicleId: String? { viewedVehicle?.id }

    var activeVehicles: [Vehicle] { vehicles.filter { $0.isActive } }

    func reload() async {
        do {
            vehicles = try await NeonRepository.shared.getAllVehicles()
            Log.db("loaded \(vehicles.count) vehicles")
        } catch {
            Log.db("failed to load vehicles: \(error.localizedDescription)")
        }
    }
}
