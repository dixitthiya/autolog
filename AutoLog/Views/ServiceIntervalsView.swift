import SwiftUI

/// One car's service intervals (the `service_thresholds` rows that drive the
/// Dashboard, Analytics projections and reminders). Add, edit or delete them.
struct ServiceIntervalsView: View {
    let vehicleId: String

    @ObservedObject private var vehicleStore = VehicleStore.shared
    @Environment(\.dismiss) private var dismiss

    @State private var thresholds: [ServiceThreshold] = []
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var pendingDelete: ServiceThreshold?
    @State private var addingType: String?

    /// Intervals grouped by service category, categories and types A–Z.
    private var groupedThresholds: [(String, [ServiceThreshold])] {
        var byCategory: [String: [ServiceThreshold]] = [:]
        for threshold in thresholds {
            byCategory[ServiceCategory.category(for: threshold.serviceType), default: []].append(threshold)
        }
        return byCategory
            .map { ($0.key, $0.value.sorted { $0.serviceType < $1.serviceType }) }
            .sorted { $0.0 < $1.0 }
    }

    /// Catalog types this car has no interval for yet, by category.
    private var addableCategories: [ServiceCategory] {
        let existing = Set(thresholds.map(\.serviceType))
        return ServiceCategory.all.compactMap { category in
            let types = category.types.filter { !existing.contains($0) }
            return types.isEmpty ? nil : ServiceCategory(name: category.name, icon: category.icon, types: types)
        }
    }

    var body: some View {
        NavigationStack {
            List {
                TargetCarSection(vehicleId: vehicleId)

                ForEach(groupedThresholds, id: \.0) { category, items in
                    Section(category) {
                        ForEach(items, id: \.serviceType) { threshold in
                            NavigationLink {
                                EditIntervalView(vehicleId: vehicleId, threshold: threshold, isNew: false) {
                                    await intervalsChanged()
                                }
                            } label: {
                                IntervalRowView(threshold: threshold)
                            }
                            .swipeActions {
                                Button {
                                    pendingDelete = threshold
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                                .tint(.red)
                            }
                        }
                    }
                }

                Section {
                    EmptyView()
                } footer: {
                    Text("Each interval puts that service on this car's Dashboard and schedules its reminders. Swipe left to delete one; the car's service history is kept.")
                }
            }
            .overlay {
                if thresholds.isEmpty && !isLoading {
                    ContentUnavailableView("No intervals",
                        systemImage: "gauge.with.dots.needle.0percent",
                        description: Text("Tap + to track a service for this car."))
                } else if isLoading && thresholds.isEmpty {
                    ProgressView()
                }
            }
            .navigationTitle("Service Intervals")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        ForEach(addableCategories, id: \.name) { category in
                            Section(category.name) {
                                ForEach(category.types, id: \.self) { type in
                                    Button(type) { addingType = type }
                                }
                            }
                        }
                    } label: {
                        Image(systemName: "plus")
                    }
                    .accessibilityLabel("Add interval")
                    .disabled(addableCategories.isEmpty)
                }
            }
            .navigationDestination(item: $addingType) { type in
                EditIntervalView(vehicleId: vehicleId, threshold: ServiceThreshold(serviceType: type), isNew: true) {
                    await intervalsChanged()
                }
            }
            .confirmationDialog(
                "Delete this interval?",
                isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
                titleVisibility: .visible,
                presenting: pendingDelete
            ) { threshold in
                Button("Delete \(threshold.serviceType)", role: .destructive) {
                    Task { await delete(threshold) }
                }
            } message: { threshold in
                Text("\(threshold.serviceType) will no longer appear on this car's Dashboard or get reminders. Its service history is kept.")
            }
            .errorToast($errorMessage)
            .task { await load() }
        }
    }

    private func load() async {
        isLoading = true
        do {
            thresholds = try await NeonRepository.shared.getThresholds(vehicleId: vehicleId)
        } catch {
            errorMessage = error.userMessage
        }
        isLoading = false
    }

    private func delete(_ threshold: ServiceThreshold) async {
        do {
            try await NeonRepository.shared.deleteThreshold(vehicleId: vehicleId, serviceType: threshold.serviceType)
            await intervalsChanged()
        } catch {
            errorMessage = error.userMessage
        }
    }

    /// After a save or delete: reload this list, tell the Dashboard/Analytics
    /// to reload, and redo the reminders.
    private func intervalsChanged() async {
        await load()
        vehicleStore.dataDidChange()
        await ServiceReminderScheduler.reschedule()
    }
}

private struct IntervalRowView: View {
    let threshold: ServiceThreshold

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(threshold.serviceType)
                .font(.subheadline.bold())
            Text(summary)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }

    private var summary: String {
        var parts: [String] = []
        if threshold.rotorWarning != nil || threshold.rotorCritical != nil {
            let warning = threshold.rotorWarning.map { String(format: "%.1f", $0) } ?? "–"
            let critical = threshold.rotorCritical.map { String(format: "%.1f", $0) } ?? "–"
            parts.append("Rotor: due at \(warning) mm, overdue below \(critical) mm")
        }
        if threshold.milesWarning != nil || threshold.milesCritical != nil {
            let warning = threshold.milesWarning.map { Int($0).formatted() } ?? "–"
            let critical = threshold.milesCritical.map { Int($0).formatted() } ?? "–"
            parts.append("Miles: due \(warning), overdue \(critical)")
        }
        if threshold.daysWarning != nil || threshold.daysCritical != nil {
            let warning = threshold.daysWarning.map { "\($0)d" } ?? "–"
            let critical = threshold.daysCritical.map { "\($0)d" } ?? "–"
            parts.append("Time: due \(warning), overdue \(critical)")
        }
        return parts.isEmpty ? "No limits set" : parts.joined(separator: " · ")
    }
}

/// Edit one interval. Blank fields mean "no limit of that kind".
struct EditIntervalView: View {
    let vehicleId: String
    let threshold: ServiceThreshold
    let isNew: Bool
    let onSave: () async -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var milesWarningText: String
    @State private var milesCriticalText: String
    @State private var daysWarningText: String
    @State private var daysCriticalText: String
    @State private var rotorWarningText: String
    @State private var rotorCriticalText: String
    @State private var isSaving = false
    @State private var errorMessage: String?

    init(vehicleId: String, threshold: ServiceThreshold, isNew: Bool, onSave: @escaping () async -> Void) {
        self.vehicleId = vehicleId
        self.threshold = threshold
        self.isNew = isNew
        self.onSave = onSave
        _milesWarningText = State(initialValue: threshold.milesWarning.map { String(Int($0)) } ?? "")
        _milesCriticalText = State(initialValue: threshold.milesCritical.map { String(Int($0)) } ?? "")
        _daysWarningText = State(initialValue: threshold.daysWarning.map(String.init) ?? "")
        _daysCriticalText = State(initialValue: threshold.daysCritical.map(String.init) ?? "")
        _rotorWarningText = State(initialValue: threshold.rotorWarning.map { String($0) } ?? "")
        _rotorCriticalText = State(initialValue: threshold.rotorCritical.map { String($0) } ?? "")
    }

    private var isRotor: Bool {
        StatusCalculator.isRotorType(threshold.serviceType)
            || threshold.rotorWarning != nil || threshold.rotorCritical != nil
    }

    var body: some View {
        Form {
            TargetCarSection(vehicleId: vehicleId)

            if isRotor {
                Section {
                    LabeledField(title: "Due at or below (mm)", text: $rotorWarningText)
                    LabeledField(title: "Overdue below (mm)", text: $rotorCriticalText)
                } header: {
                    Text("Rotor thickness")
                } footer: {
                    Text("Judged from the latest thickness reading. The \"due\" value is the larger one.")
                }
            } else {
                Section {
                    LabeledField(title: "Due after (miles)", text: $milesWarningText, isWhole: true)
                    LabeledField(title: "Overdue after (miles)", text: $milesCriticalText, isWhole: true)
                } header: {
                    Text("Miles since last service")
                }
                Section {
                    LabeledField(title: "Due after (days)", text: $daysWarningText, isWhole: true)
                    LabeledField(title: "Overdue after (days)", text: $daysCriticalText, isWhole: true)
                } header: {
                    Text("Time since last service")
                } footer: {
                    Text("365 days = 1 year. Leave a field blank for no limit of that kind. Whichever limit is reached first counts.")
                }
            }
        }
        .navigationTitle(threshold.serviceType)
        .keyboardDoneButton()
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button(isNew ? "Add" : "Save") { Task { await save() } }
                    .disabled(isSaving)
            }
        }
        .errorToast($errorMessage)
    }

    /// nil for blank; throws a readable message for anything that isn't a positive number.
    private func number(_ text: String, _ name: String) throws -> Double? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard let value = Double(trimmed), value > 0 else {
            throw IntervalInputError("\(name) must be a positive number")
        }
        return value
    }

    private func save() async {
        var updated = ServiceThreshold(serviceType: threshold.serviceType)
        do {
            if isRotor {
                updated.rotorWarning = try number(rotorWarningText, "Due thickness")
                updated.rotorCritical = try number(rotorCriticalText, "Overdue thickness")
                if let warning = updated.rotorWarning, let critical = updated.rotorCritical, warning < critical {
                    throw IntervalInputError("The \"due\" thickness must be at least the \"overdue\" one")
                }
            } else {
                updated.milesWarning = try number(milesWarningText, "Due miles")
                updated.milesCritical = try number(milesCriticalText, "Overdue miles")
                updated.daysWarning = try number(daysWarningText, "Due days").map { Int($0) }
                updated.daysCritical = try number(daysCriticalText, "Overdue days").map { Int($0) }
                if let warning = updated.milesWarning, let critical = updated.milesCritical, warning > critical {
                    throw IntervalInputError("\"Due\" miles must not be more than \"overdue\" miles")
                }
                if let warning = updated.daysWarning, let critical = updated.daysCritical, warning > critical {
                    throw IntervalInputError("\"Due\" days must not be more than \"overdue\" days")
                }
            }
            let hasAnyLimit = [updated.milesWarning, updated.milesCritical, updated.rotorWarning, updated.rotorCritical]
                .contains { $0 != nil } || updated.daysWarning != nil || updated.daysCritical != nil
            guard hasAnyLimit else {
                throw IntervalInputError("Enter at least one limit")
            }
        } catch {
            errorMessage = error.userMessage
            return
        }

        isSaving = true
        do {
            try await NeonRepository.shared.upsertThreshold(updated, vehicleId: vehicleId)
            await onSave()
            dismiss()
        } catch {
            errorMessage = error.userMessage
        }
        isSaving = false
    }
}

private struct IntervalInputError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

/// A numeric field with its label on the left.
private struct LabeledField: View {
    let title: String
    @Binding var text: String
    var isWhole = false

    var body: some View {
        HStack {
            Text(title)
            Spacer()
            TextField("none", text: $text)
                .keyboardType(isWhole ? .numberPad : .decimalPad)
                .multilineTextAlignment(.trailing)
                .frame(maxWidth: 120)
        }
    }
}
