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
    @State private var hasOBDBaseline = false
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
                        if hasOBDBaseline {
                            Label("Live OBD reading from this car — auto-tracking continues from this entry", systemImage: "checkmark.circle.fill")
                                .font(.caption)
                                .foregroundStyle(.green)
                        } else {
                            Label("No OBD reading from this car in the last 10 minutes. The entry is saved without a baseline, and the next capture will ask you to confirm the odometer.", systemImage: "exclamationmark.triangle.fill")
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
                    try? await Task.sleep(nanoseconds: 300_000_000)
                    odometerFocused = true
                    if let vehicleId {
                        hasOBDBaseline = liveDistSinceCleared(vehicleId: vehicleId) != nil
                    }
                }
            }
            .navigationTitle(isEditing ? "Edit Mileage" : "Add Mileage")
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
            .overlay(alignment: .bottom) {
                if let msg = errorMessage {
                    Text(msg)
                        .font(.caption).foregroundStyle(.white)
                        .padding(.horizontal, 16).padding(.vertical, 8)
                        .background(.red.opacity(0.9)).clipShape(Capsule())
                        .padding(.bottom, 8)
                }
            }
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
            errorMessage = error.localizedDescription
            if !isEditing {
                let liveDist = liveDistSinceCleared(vehicleId: vehicleId)
                SyncManager.shared.queueMileageRecord(
                    MileageRecord.manual(vehicleId: vehicleId, odometer: odometer, date: date, distSinceCodesCleared: liveDist)
                )
            }
        }
        isSaving = false
    }

    /// This car's 0131 baseline: only a value read from it in the last 10 minutes.
    /// An older logged value is never used — the car may have been driven since,
    /// which would make every later odometer too high. With no baseline the
    /// entry is saved without one, and the next capture asks to confirm the odometer.
    private func liveDistSinceCleared(vehicleId: String) -> Double? {
        MileageService.shared.recentDistSinceCleared(for: vehicleId)
    }

    private func delete() async {
        guard let id = record?.id else { return }
        do {
            try await NeonRepository.shared.deleteMileageRecord(id: id)
            await onSave()
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
