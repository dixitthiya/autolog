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

/// Adds the car picker row (with the retired capsule) and the car-menu sheets to a tab.
/// Apply to the content inside each tab's NavigationStack.
struct CarSwitcherModifier: ViewModifier {
    @ObservedObject private var vehicleStore = VehicleStore.shared
    @State private var sheet: CarMenuSheet?

    func body(content: Content) -> some View {
        content
            // One row directly under the navigation title: the car picker, and
            // a "Retired" capsule beside it when the viewed car is retired.
            .safeAreaInset(edge: .top, spacing: 0) {
                HStack(spacing: 8) {
                    CarSwitcherMenu(sheet: $sheet)
                    if let car = vehicleStore.viewedVehicle, !car.isActive {
                        RetiredPill()
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 6)
                .background(.bar)
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
            description: Text("Pick a car from the menu under the title. A car is added automatically the first time the OBD adapter reads its VIN.")
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
