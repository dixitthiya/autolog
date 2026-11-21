import SwiftUI

/// Every car the app knows: edit its name and details, retire or reactivate it.
/// Cars themselves are only created by the OBD adapter reading a new VIN.
struct VehiclesView: View {
    @ObservedObject private var vehicleStore = VehicleStore.shared
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                ForEach(vehicleStore.activeVehicles + vehicleStore.retiredVehicles) { car in
                    NavigationLink {
                        EditVehicleView(vehicle: car)
                    } label: {
                        VehicleRowView(vehicle: car, isViewed: car.id == vehicleStore.viewedVehicleId)
                    }
                }
            }
            .overlay {
                if vehicleStore.vehicles.isEmpty {
                    ContentUnavailableView(
                        "No vehicles",
                        systemImage: "car",
                        description: Text("Plug in the OBD adapter and start the car — your car is added automatically.")
                    )
                }
            }
            .refreshable { await vehicleStore.reload() }
            .task { await vehicleStore.reload() }
            .navigationTitle("Vehicles")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

private struct VehicleRowView: View {
    let vehicle: Vehicle
    let isViewed: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(vehicle.displayName)
                    .font(.subheadline.bold())
                if isViewed {
                    Image(systemName: "eye.fill")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text(vehicle.isActive ? "Active" : "Retired")
                    .font(.caption2.bold())
                    .foregroundStyle(vehicle.isActive ? .green : .orange)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background((vehicle.isActive ? Color.green : Color.orange).opacity(0.12))
                    .clipShape(Capsule())
            }
            let details = [vehicle.year.map(String.init), vehicle.make, vehicle.model]
                .compactMap { $0 }
                .filter { !$0.isEmpty }
                .joined(separator: " ")
            if !details.isEmpty {
                Text(details)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text(vehicle.vin ?? "No vehicle ID on file")
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }
}

struct EditVehicleView: View {
    let vehicle: Vehicle

    @Environment(\.dismiss) private var dismiss

    @State private var nickname: String
    @State private var make: String
    @State private var model: String
    @State private var yearText: String
    @State private var status: VehicleStatus
    @State private var isSaving = false
    @State private var isLookingUp = false
    @State private var lookupMessage: String?
    @State private var errorMessage: String?
    @State private var showRetireConfirm = false

    init(vehicle: Vehicle) {
        self.vehicle = vehicle
        _nickname = State(initialValue: vehicle.nickname ?? "")
        _make = State(initialValue: vehicle.make ?? "")
        _model = State(initialValue: vehicle.model ?? "")
        _yearText = State(initialValue: vehicle.year.map(String.init) ?? "")
        _status = State(initialValue: vehicle.status)
    }

    var body: some View {
        Form {
            Section("Name") {
                TextField("Nickname", text: $nickname)
                    .textInputAutocapitalization(.words)
            }

            Section("Details") {
                TextField("Make", text: $make)
                    .textInputAutocapitalization(.words)
                TextField("Model", text: $model)
                    .textInputAutocapitalization(.words)
                TextField("Year", text: $yearText)
                    .keyboardType(.numberPad)
            }

            Section {
                Picker("Status", selection: $status) {
                    Text("Active").tag(VehicleStatus.active)
                    Text("Retired").tag(VehicleStatus.retired)
                }
                .pickerStyle(.segmented)
            } header: {
                Text("Status")
            } footer: {
                Text("A retired car keeps its history and can still be viewed and edited, but the adapter's captures from it are skipped and it gets no reminders.")
            }

            Section {
                LabeledContent("Vehicle ID") {
                    Text(vehicle.vin ?? "Not on file")
                        .font(.body.monospaced())
                        .textSelection(.enabled)
                }
                Button {
                    Task { await lookUp() }
                } label: {
                    HStack {
                        Label("Look up details", systemImage: "magnifyingglass")
                        Spacer()
                        if isLookingUp {
                            ProgressView().controlSize(.small)
                        }
                    }
                }
                .disabled(vehicle.vin == nil || isLookingUp)
            } header: {
                Text("Vehicle ID")
            } footer: {
                Text(lookupMessage ?? "Uses the free NHTSA decoder (US cars). Fills only empty fields; tap Save to keep them.")
            }
        }
        .navigationTitle(vehicle.displayName)
        .keyboardDoneButton()
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") {
                    if vehicle.isActive && status == .retired {
                        showRetireConfirm = true
                    } else {
                        Task { await save() }
                    }
                }
                .disabled(isSaving)
            }
        }
        .confirmationDialog("Retire this car?", isPresented: $showRetireConfirm, titleVisibility: .visible) {
            Button("Retire", role: .destructive) { Task { await save() } }
        } message: {
            Text("Captures from this car will be skipped and its reminders removed. Its history stays.")
        }
        .errorToast($errorMessage)
    }

    private func clean(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// nil when empty; `.invalid` when something was typed that isn't a model year.
    private enum YearInput { case empty, year(Int), invalid }

    private var yearInput: YearInput {
        guard let text = clean(yearText) else { return .empty }
        let maxYear = Calendar.current.component(.year, from: Date()) + 1
        guard let year = Int(text), (1950...maxYear).contains(year) else { return .invalid }
        return .year(year)
    }

    private func save() async {
        var updated = vehicle
        switch yearInput {
        case .empty: updated.year = nil
        case .year(let year): updated.year = year
        case .invalid:
            errorMessage = "Year must be a 4-digit model year"
            return
        }
        updated.nickname = clean(nickname)
        updated.make = clean(make)
        updated.model = clean(model)
        updated.status = status

        isSaving = true
        do {
            try await NeonRepository.shared.updateVehicle(updated)
            await VehicleStore.shared.vehicleDidChange(updated)
            dismiss()
        } catch {
            errorMessage = error.userMessage
        }
        isSaving = false
    }

    /// Fill the form's empty fields from NHTSA. Nothing is saved until Save.
    private func lookUp() async {
        guard let vin = vehicle.vin else { return }
        isLookingUp = true
        defer { isLookingUp = false }
        do {
            let details = try await VehicleLookup.decode(vin: vin)
            var currentYear: Int? {
                if case .year(let year) = yearInput { return year }
                return nil
            }
            let automaticBefore = Vehicle.autoNickname(make: clean(make), year: currentYear)

            var filled: [String] = []
            if clean(make) == nil, let value = details.make {
                make = value
                filled.append("make")
            }
            if clean(model) == nil, let value = details.model {
                model = value
                filled.append("model")
            }
            if currentYear == nil, let value = details.year {
                yearText = String(value)
                filled.append("year")
            }
            let currentNickname = clean(nickname)
            if currentNickname == nil || currentNickname == automaticBefore,
               let automatic = Vehicle.autoNickname(make: clean(make), model: clean(model), year: currentYear),
               automatic != currentNickname {
                nickname = automatic
                filled.append("nickname")
            }
            lookupMessage = filled.isEmpty
                ? "Nothing to fill — those fields already have values."
                : "Filled \(filled.joined(separator: ", ")) from NHTSA. Tap Save to keep."
        } catch {
            lookupMessage = "Couldn't look up details: \(error.userMessage)"
        }
    }
}
