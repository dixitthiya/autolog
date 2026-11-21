import SwiftUI

/// Sheets opened from the car menu.
enum CarMenuSheet: String, Identifiable {
    case vehicles, intervals, unassigned
    var id: String { rawValue }
}

/// The car picker at the top-left of every tab. Picking a car changes what the
/// screens show and where entries made in the UI go. It never affects captures,
/// which always go to the car the adapter is plugged into.
struct CarSwitcherMenu: View {
    @ObservedObject private var vehicleStore = VehicleStore.shared
    @Binding var sheet: CarMenuSheet?

    var body: some View {
        Menu {
            Section {
                ForEach(vehicleStore.activeVehicles) { car in
                    carButton(car)
                }
            }
            if !vehicleStore.retiredVehicles.isEmpty {
                Section("Retired") {
                    ForEach(vehicleStore.retiredVehicles) { car in
                        carButton(car)
                    }
                }
            }
            Section {
                if let car = vehicleStore.viewedVehicle {
                    Button {
                        sheet = .intervals
                    } label: {
                        Label("Service intervals — \(car.displayName)", systemImage: "gauge.with.dots.needle.33percent")
                    }
                }
                if vehicleStore.unassignedCount > 0 {
                    Button {
                        sheet = .unassigned
                    } label: {
                        Label("Unassigned (\(vehicleStore.unassignedCount))", systemImage: "questionmark.circle")
                    }
                }
                Button {
                    sheet = .vehicles
                } label: {
                    Label("Manage vehicles", systemImage: "car.2")
                }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "car.fill")
                Text(vehicleStore.viewedVehicle?.displayName ?? "No car")
                    .lineLimit(1)
                    .frame(maxWidth: 170, alignment: .leading)
                Image(systemName: "chevron.down")
                    .font(.caption2.bold())
            }
            .font(.subheadline.weight(.semibold))
        }
    }

    private func carButton(_ car: Vehicle) -> some View {
        Button {
            vehicleStore.selectedVehicleId = car.id
        } label: {
            let title = car.isActive ? car.displayName : "\(car.displayName) (Retired)"
            if car.id == vehicleStore.viewedVehicleId {
                Label(title, systemImage: "checkmark")
            } else {
                Text(title)
            }
        }
    }
}

/// Adds the car picker, the Vehicles sheet and the retired-car banner to a tab.
/// Apply to the content inside each tab's NavigationStack.
struct CarSwitcherModifier: ViewModifier {
    @ObservedObject private var vehicleStore = VehicleStore.shared
    @State private var sheet: CarMenuSheet?

    func body(content: Content) -> some View {
        content
            .safeAreaInset(edge: .top, spacing: 0) {
                if let car = vehicleStore.viewedVehicle, !car.isActive {
                    RetiredCarBanner(vehicle: car)
                }
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    CarSwitcherMenu(sheet: $sheet)
                }
            }
            .sheet(item: $sheet) { which in
                switch which {
                case .vehicles:
                    VehiclesView()
                case .intervals:
                    if let vehicleId = vehicleStore.viewedVehicleId {
                        ServiceIntervalsView(vehicleId: vehicleId)
                    }
                case .unassigned:
                    UnassignedReadingsView()
                }
            }
    }
}

extension View {
    func carSwitcher() -> some View {
        modifier(CarSwitcherModifier())
    }
}

/// Shown on every tab while a retired car is being viewed: entries made now
/// still go to that car.
struct RetiredCarBanner: View {
    let vehicle: Vehicle

    var body: some View {
        Label("Retired — entries go to \(vehicle.displayName)", systemImage: "archivebox.fill")
            .font(.caption.weight(.semibold))
            .foregroundStyle(.white)
            .lineLimit(1)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
            .padding(.horizontal, 16)
            .background(Color.orange)
    }
}

/// Empty state for a tab when no car is known yet.
struct NoCarSelectedView: View {
    var body: some View {
        ContentUnavailableView(
            "No car selected",
            systemImage: "car",
            description: Text("Pick a car from the menu at the top left. A car is added automatically the first time the OBD adapter reads its VIN.")
        )
    }
}

/// First section of an add/edit sheet: which car the entry will be saved to.
struct TargetCarSection: View {
    let vehicleId: String?
    @ObservedObject private var vehicleStore = VehicleStore.shared

    var body: some View {
        Section {
            let car = vehicleId.flatMap { vehicleStore.vehicle(id: $0) }
            LabeledContent("Car", value: car?.displayName ?? "Unknown car")
            if let car, !car.isActive {
                Label("Retired — entries go to \(car.displayName)", systemImage: "archivebox.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
    }
}
