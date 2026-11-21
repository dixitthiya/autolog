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
        // Start from the last known list so a launch with no network still has cars to show.
        vehicles = VehicleCache.load().sorted { ($0.createdAt ?? .distantPast) > ($1.createdAt ?? .distantPast) }
    }

    var viewedVehicle: Vehicle? {
        if let id = selectedVehicleId, let picked = vehicles.first(where: { $0.id == id }) {
            return picked
        }
        return vehicles.first(where: { $0.isActive }) ?? vehicles.first
    }

    var viewedVehicleId: String? { viewedVehicle?.id }

    var activeVehicles: [Vehicle] { vehicles.filter { $0.isActive } }
    var retiredVehicles: [Vehicle] { vehicles.filter { !$0.isActive } }

    func vehicle(id: String) -> Vehicle? {
        vehicles.first { $0.id == id }
    }

    /// After a car is edited or its status changes: refresh the list (which also
    /// refreshes the offline car cache) and the reminders, which name the car
    /// and skip retired cars.
    func vehicleDidChange(_ vehicle: Vehicle) async {
        VehicleCache.upsert(vehicle)
        if let i = vehicles.firstIndex(where: { $0.id == vehicle.id }) {
            vehicles[i] = vehicle
        }
        await reload()
        await ServiceReminderScheduler.reschedule()
    }

    func reload() async {
        do {
            vehicles = try await NeonRepository.shared.getAllVehicles()
            VehicleCache.save(vehicles)
            Log.db("loaded \(vehicles.count) vehicles")
        } catch {
            Log.db("failed to load vehicles: \(error.localizedDescription)")
        }
    }
}
