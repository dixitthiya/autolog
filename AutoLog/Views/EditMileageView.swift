import SwiftUI

struct EditMileageView: View {
    let record: MileageRecord?
    let onSave: () async -> Void
    @StateObject private var bleManager = BLEManager.shared

    @Environment(\.dismiss) private var dismiss

    @State private var date: Date
    @State private var odometerText: String
    @State private var showDeleteConfirm = false
    @State private var isSaving = false
    @State private var errorMessage: String?
    @State private var hasOBDBaseline = false

    init(record: MileageRecord?, onSave: @escaping () async -> Void) {
        self.record = record
        self.onSave = onSave
        _date = State(initialValue: record?.timestamp ?? Date())
        _odometerText = State(initialValue: record.map { String(Int($0.odometerMiles)) } ?? "")
    }

    var isEditing: Bool { record != nil }

    var body: some View {
        NavigationStack {
            Form {
                Section("Details") {
                    DatePicker("Date", selection: $date, displayedComponents: [.date, .hourAndMinute])
                    TextField("Odometer (miles)", text: $odometerText)
                        .keyboardType(.numberPad)
                }

                if !isEditing {
                    Section {
                        if hasOBDBaseline {
                            Label("OBD baseline available — auto-tracking will be enabled", systemImage: "checkmark.circle.fill")
                                .font(.caption)
                                .foregroundStyle(.green)
                        } else {
                            Label("Connect to OBD before saving to enable auto-tracking", systemImage: "exclamationmark.triangle.fill")
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
                    hasOBDBaseline = await getLatestDistSinceCleared() != nil
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
                        .disabled(isSaving || odometerText.isEmpty)
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
        isSaving = true

        do {
            if let existing = record {
                let updated = MileageRecord(
                    id: existing.id,
                    timestamp: date,
                    odometerMiles: odometer,
                    source: existing.source,
                    distSinceCodesCleared: existing.distSinceCodesCleared
                )
                try await NeonRepository.shared.updateMileageRecord(updated)
            } else {
                // Capture latest 0131 reading as baseline for this manual entry
                let latestDist = await getLatestDistSinceCleared()
                let newRecord = MileageRecord.manual(odometer: odometer, date: date, distSinceCodesCleared: latestDist)
                try await NeonRepository.shared.saveMileageRecord(newRecord)
            }
            await onSave()
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
            if !isEditing {
                SyncManager.shared.queueMileageRecord(
                    MileageRecord.manual(odometer: odometer, date: date)
                )
            }
        }
        isSaving = false
    }

    /// Get the latest dist_since_codes_cleared from OBD logs or recent mileage records
    private func getLatestDistSinceCleared() async -> Double? {
        // Check if there's a recent OBD reading with 0131 value
        do {
            let rows = try await NeonRepository.shared.getOBDDistSinceCleared()
            return rows
        } catch {
            return nil
        }
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
