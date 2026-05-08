import SwiftUI

struct EditServiceView: View {
    let record: ServiceRecord
    let onSave: () async -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var date: Date
    @State private var odometerText: String
    @State private var rotorText: String
    @State private var amountText: String
    @State private var comments: String
    @State private var selectedCategory: ServiceCategory?
    @State private var selectedType: String
    @State private var showDeleteConfirm = false
    @State private var isSaving = false
    @State private var errorMessage: String?

    private var isRotorType: Bool {
        selectedType.contains("Rotor Thickness")
    }

    init(record: ServiceRecord, onSave: @escaping () async -> Void) {
        self.record = record
        self.onSave = onSave
        _date = State(initialValue: record.timestamp)
        _odometerText = State(initialValue: String(Int(record.odometerMiles)))
        _rotorText = State(initialValue: record.rotorThicknessMM.map { String($0) } ?? "")
        _amountText = State(initialValue: record.amount.map { String($0) } ?? "")
        _comments = State(initialValue: record.comments ?? "")
        _selectedType = State(initialValue: record.serviceType)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Service") {
                    Picker("Category", selection: $selectedCategory) {
                        ForEach(ServiceCategory.all, id: \.name) { cat in
                            Text(cat.name).tag(Optional(cat))
                        }
                    }
                    .onChange(of: selectedCategory) { oldCat, newCat in
                        guard oldCat != nil else { return }
                        if let newCat, !newCat.types.contains(selectedType) {
                            selectedType = newCat.types.first ?? ""
                        }
                    }

                    if let cat = selectedCategory {
                        Picker("Service Type", selection: $selectedType) {
                            ForEach(cat.types, id: \.self) { type in
                                Text(type).tag(type)
                            }
                        }
                    }
                }

                Section("Details") {
                    DatePicker("Date", selection: $date, displayedComponents: [.date])

                    TextField("Odometer (miles)", text: $odometerText)
                        .keyboardType(.decimalPad)

                    if isRotorType {
                        TextField("Rotor Thickness (mm)", text: $rotorText)
                            .keyboardType(.decimalPad)
                    }

                    TextField("Amount ($)", text: $amountText)
                        .keyboardType(.decimalPad)

                    TextField("Comments", text: $comments, axis: .vertical)
                        .lineLimit(3)
                }

                if record.manuallyEdited {
                    Section {
                        Label("Manually edited", systemImage: "pencil.circle")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Section {
                    Button("Delete Record", role: .destructive) {
                        showDeleteConfirm = true
                    }
                }
            }
            .navigationTitle("Edit Service")
            .navigationBarTitleDisplayMode(.inline)
            .task {
                if selectedCategory == nil {
                    selectedCategory = ServiceCategory.all.first { $0.name == record.category }
                        ?? ServiceCategory.all.first
                }
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { Task { await save() } }
                        .disabled(isSaving || odometerText.isEmpty || selectedType.isEmpty)
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

        let updated = ServiceRecord(
            id: record.id,
            timestamp: date,
            serviceType: selectedType,
            category: selectedCategory?.name ?? record.category,
            odometerMiles: odometer,
            rotorThicknessMM: isRotorType ? Double(rotorText) : nil,
            amount: Double(amountText),
            comments: comments.isEmpty ? nil : comments,
            manuallyEdited: true
        )

        do {
            try await NeonRepository.shared.updateServiceRecord(updated)
            await onSave()
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
        isSaving = false
    }

    private func delete() async {
        do {
            try await NeonRepository.shared.deleteServiceRecord(id: record.id)
            await onSave()
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
