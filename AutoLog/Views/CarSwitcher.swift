import SwiftUI

/// Sheets opened from the car menu (or, for intervals, from Maintenance). The
/// current one lives in `VehicleStore.carMenuSheet` and is presented once, by
/// `ContentView`, so every tab shares it.
enum CarMenuSheet: String, Identifiable {
    case vehicles, intervals, unassigned
    var id: String { rawValue }
}

/// The row at the top of each tab's content: the car picker, and a "Retired"
/// capsule beside it when the viewed car is retired. All tabs read and write
/// the one shared `VehicleStore.viewedVehicleId`.
struct CarSwitcherRow: View {
    @ObservedObject private var vehicleStore = VehicleStore.shared

    var body: some View {
        HStack(spacing: 8) {
            CarSwitcherMenu()
            if let car = vehicleStore.viewedVehicle, !car.isActive {
                RetiredPill()
            }
            Spacer(minLength: 0)
        }
    }
}

extension View {
    /// An empty-state message shown as a plain row below the picker.
    func emptyStateListRow() -> some View {
        self
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
    }
}

/// The car picker. Picking a car changes what the screens show and where
/// entries made in the UI go. It never affects captures, which always go to the
/// car the adapter is plugged into.
struct CarSwitcherMenu: View {
    @ObservedObject private var vehicleStore = VehicleStore.shared

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
                if vehicleStore.unassignedCount > 0 {
                    Button {
                        vehicleStore.carMenuSheet = .unassigned
                    } label: {
                        Label("Unassigned (\(vehicleStore.unassignedCount))", systemImage: "questionmark.circle")
                    }
                }
                Button {
                    vehicleStore.carMenuSheet = .vehicles
                } label: {
                    Label("Manage vehicles", systemImage: "car.2")
                }
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "car.fill")
                Text(vehicleStore.viewedVehicle?.displayName ?? "No car")
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.caption2.bold())
            }
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(Color.accentColor)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Color.accentColor.opacity(0.15), in: Capsule())
        }
    }

    private func carButton(_ car: Vehicle) -> some View {
        Button {
            vehicleStore.selectedVehicleId = car.id
        } label: {
            if car.id == vehicleStore.viewedVehicleId {
                Label(car.displayName, systemImage: "checkmark")
            } else if !car.isActive {
                Label(car.displayName, systemImage: "archivebox")
            } else {
                Text(car.displayName)
            }
        }
    }
}

/// Orange "Retired" capsule: shown beside the car picker and in add/edit sheets
/// while the car is retired (entries still go to that car).
struct RetiredPill: View {
    var body: some View {
        Label("Retired", systemImage: "archivebox")
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(Color.orange)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Color.orange.opacity(0.15), in: Capsule())
    }
}

/// Empty state for a tab when no car is known yet.
struct NoCarSelectedView: View {
    var body: some View {
        ContentUnavailableView(
            "No car selected",
            systemImage: "car",
            description: Text("Plug in the OBD adapter and start the car — your car is added automatically.")
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
            LabeledContent("Car") {
                if let car, !car.isActive {
                    RetiredPill()
                } else {
                    Text(car?.displayName ?? "Unknown car")
                }
            }
        }
    }
}
