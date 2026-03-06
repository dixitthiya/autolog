import SwiftUI

struct EditMileageView: View {
    let record: MileageRecord?
    let onSave: () async -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var date: Date
    @State private var odometerText: String
    @State private var showDeleteConfirm = false
    @State private var isSaving = false
    @State private var errorMessage: String?

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

                if isEditing {
                    Section {
                        Button("Delete Record", role: .destructive) {
                            showDeleteConfirm = true
                        }
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
                    source: existing.source
                )
                try await NeonRepository.shared.updateMileageRecord(updated)
            } else {
                let newRecord = MileageRecord.manual(odometer: odometer, date: date)
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
