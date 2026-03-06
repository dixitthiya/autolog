import SwiftUI

struct AddServiceView: View {
    let onSave: () async -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var selectedCategory = ServiceCategory.all[0]
    @State private var selectedType = ""
    @State private var date = Date()
    @State private var odometerText = ""
    @State private var rotorText = ""
    @State private var amountText = ""
    @State private var comments = ""
    @State private var isSaving = false
    @State private var errorMessage: String?

    private var isRotorType: Bool {
        selectedType.contains("Rotor Thickness")
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Service") {
                    Picker("Category", selection: $selectedCategory) {
                        ForEach(ServiceCategory.all, id: \.name) { cat in
                            Text(cat.name).tag(cat)
                        }
                    }
                    .onChange(of: selectedCategory) { _, newCat in
                        selectedType = newCat.types.first ?? ""
                    }

                    Picker("Service Type", selection: $selectedType) {
                        ForEach(selectedCategory.types, id: \.self) { type in
                            Text(type).tag(type)
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
            }
            .navigationTitle("Add Service")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { Task { await save() } }
                        .disabled(isSaving || selectedType.isEmpty || odometerText.isEmpty)
                }
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
            .task { await loadDefaults() }
        }
    }

    private func loadDefaults() async {
        selectedType = selectedCategory.types.first ?? ""
        if let latest = try? await NeonRepository.shared.getLatestMileageRecord() {
            odometerText = String(Int(latest.odometerMiles))
        }
    }

    private func save() async {
        guard let odometer = Double(odometerText) else {
            errorMessage = "Invalid odometer value"
            return
        }
        isSaving = true

        let record = ServiceRecord.new(
            serviceType: selectedType,
            category: selectedCategory.name,
            odometer: odometer,
            date: date,
            rotorThickness: Double(rotorText),
            amount: Double(amountText),
            comments: comments.isEmpty ? nil : comments
        )

        do {
            try await NeonRepository.shared.saveServiceRecord(record)
            await onSave()
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
            SyncManager.shared.queueServiceRecord(record)
        }
        isSaving = false
    }
}

extension ServiceCategory: Hashable {
    static func == (lhs: ServiceCategory, rhs: ServiceCategory) -> Bool {
        lhs.name == rhs.name
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(name)
    }
}
