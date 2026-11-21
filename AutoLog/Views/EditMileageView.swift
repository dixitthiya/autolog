import SwiftUI

struct EditMileageView: View {
    let record: MileageRecord?
    /// Car a new entry belongs to; an edit keeps the record's own car.
    let vehicleId: String?
    let onSave: () async -> Void
    @StateObject private var bleManager = BLEManager.shared

    @Environment(\.dismiss) private var dismiss

    @State private var date: Date
    @State private var odometerText: String
    @State private var showDeleteConfirm = false
    @State private var isSaving = false
    @State private var errorMessage: String?
    /// When the car's last distance reading was taken; nil when none is usable.
    @State private var baselineReadAt: Date?
    @State private var keepBaseline = true
    @FocusState private var odometerFocused: Bool

    init(record: MileageRecord?, vehicleId: String?, onSave: @escaping () async -> Void) {
        self.record = record
        self.vehicleId = record?.vehicleId ?? vehicleId
        self.onSave = onSave
        _date = State(initialValue: record?.timestamp ?? Date())
        _odometerText = State(initialValue: record.map { String(Int($0.odometerMiles)) } ?? "")
    }

    var isEditing: Bool { record != nil }

    var body: some View {
        NavigationStack {
            Form {
                TargetCarSection(vehicleId: vehicleId)

                Section("Details") {
                    DatePicker("Date", selection: $date, displayedComponents: [.date, .hourAndMinute])
                    TextField("Odometer (miles)", text: $odometerText)
                        .keyboardType(.numberPad)
                        .focused($odometerFocused)
                }

                if !isEditing {
                    Section {
                        if let readAt = baselineReadAt {
                            Toggle("Car hasn't been driven since the reading at \(readAt.formatted(date: .omitted, time: .shortened))", isOn: $keepBaseline)
                            if isBackdated {
                                Label("The date is more than 5 minutes ago, so the entry is saved without a baseline. The next capture will ask you to confirm the odometer.", systemImage: "exclamationmark.triangle.fill")
                                    .font(.caption)
                                    .foregroundStyle(.orange)
                            } else if keepBaseline {
                                Label("Reading taken \(ageText(of: readAt)) — auto-tracking continues from this entry", systemImage: "checkmark.circle.fill")
                                    .font(.caption)
                                    .foregroundStyle(.green)
                            } else {
                                Label("Saved without a baseline. The next capture will ask you to confirm the odometer.", systemImage: "exclamationmark.triangle.fill")
                                    .font(.caption)
                                    .foregroundStyle(.orange)
                            }
                        } else {
                            Label("No recent reading from this car (last 30 minutes). The entry is saved without a baseline, and the next capture will ask you to confirm the odometer.", systemImage: "exclamationmark.triangle.fill")
                                .font(.caption)
                                .foregroundStyle(.orange)
                        }
                    }
                }

                if isEditing {
                    Section {
                        Button("Delete Record", role: .destructive) {
                            showDeleteConfirm = true
                        }
                    }
                }
            }
            .task {
                if !isEditing {
                    if let vehicleId {
                        baselineReadAt = MileageService.shared.captureBaseline(for: vehicleId)?.readAt
                    }
                    try? await Task.sleep(nanoseconds: 300_000_000)
                    odometerFocused = true
                }
            }
            .navigationTitle(isEditing ? "Edit Mileage" : "Add Mileage")
            .keyboardDoneButton()
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { Task { await save() } }
                        .disabled(isSaving || odometerText.isEmpty || vehicleId == nil)
                }
            }
            .confirmationDialog("Delete this record?", isPresented: $showDeleteConfirm, titleVisibility: .visible) {
                Button("Delete", role: .destructive) { Task { await delete() } }
            }
            .errorToast($errorMessage)
        }
    }

    private func save() async {
        guard let odometer = Double(odometerText) else {
            errorMessage = "Invalid odometer value"
            return
        }
        guard let vehicleId else {
            errorMessage = "No vehicle for this entry"
            return
        }
        isSaving = true

        do {
            if let existing = record {
                let updated = MileageRecord(
                    id: existing.id,
                    vehicleId: existing.vehicleId,
                    timestamp: date,
                    odometerMiles: odometer,
                    source: existing.source,
                    distSinceCodesCleared: existing.distSinceCodesCleared
                )
                try await NeonRepository.shared.updateMileageRecord(updated)
            } else {
                // Baseline for this manual entry: this car's live 0131, or none
                let liveDist = liveDistSinceCleared(vehicleId: vehicleId)
                let newRecord = MileageRecord.manual(vehicleId: vehicleId, odometer: odometer, date: date, distSinceCodesCleared: liveDist)
                try await NeonRepository.shared.saveMileageRecord(newRecord)
            }
            await onSave()
            dismiss()
        } catch {
            errorMessage = error.userMessage
            if !isEditing {
                let liveDist = liveDistSinceCleared(vehicleId: vehicleId)
                SyncManager.shared.queueMileageRecord(
                    MileageRecord.manual(vehicleId: vehicleId, odometer: odometer, date: date, distSinceCodesCleared: liveDist)
                )
            }
        }
        isSaving = false
    }

    /// An entry dated more than 5 minutes ago doesn't match the reading's moment.
    private var isBackdated: Bool {
        date < Date().addingTimeInterval(-5 * 60)
    }

    private func ageText(of readAt: Date) -> String {
        let minutes = max(0, Int(Date().timeIntervalSince(readAt) / 60))
        return minutes == 0 ? "just now" : "\(minutes) min ago"
    }

    /// This car's 0131 baseline: the reading from its last capture (under 30 minutes
    /// old), used only while the person confirms the car hasn't been driven since and
    /// the entry isn't backdated — otherwise the car may have moved, which would make
    /// every later odometer too high. With no baseline the entry is saved without
    /// one, and the next capture asks to confirm the odometer.
    private func liveDistSinceCleared(vehicleId: String) -> Double? {
        guard keepBaseline, !isBackdated else { return nil }
        return MileageService.shared.captureBaseline(for: vehicleId)?.miles
    }

    private func delete() async {
        guard let id = record?.id else { return }
        do {
            try await NeonRepository.shared.deleteMileageRecord(id: id)
            await onSave()
            dismiss()
        } catch {
            errorMessage = error.userMessage
        }
    }
}
