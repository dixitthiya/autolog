import SwiftUI

struct TiresView: View {
    @State private var tires: [Tire] = []
    @State private var currentOdometer: Double = 0
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var showReplace = false
    @State private var showRotate = false
    @State private var selectedTire: Tire?

    var body: some View {
        NavigationStack {
            ZStack {
                ScrollView {
                    VStack(spacing: 16) {
                        odometerHeader
                        cornerGrid
                        emptyHint
                    }
                    .padding()
                }
                .refreshable { await load() }

                if isLoading && tires.isEmpty {
                    ProgressView()
                }
            }
            .navigationTitle("Tires")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Button { showReplace = true } label: {
                            Label("Replace a tire", systemImage: "arrow.triangle.2.circlepath")
                        }
                        Button { showRotate = true } label: {
                            Label("Log rotation", systemImage: "arrow.clockwise")
                        }
                    } label: {
                        Image(systemName: "plus.circle.fill").font(.title3)
                    }
                }
            }
            .sheet(isPresented: $showReplace) {
                AddTireView(currentOdometer: currentOdometer) { await load() }
            }
            .sheet(isPresented: $showRotate) {
                RotateTiresView(currentOdometer: currentOdometer) { await load() }
            }
            .sheet(item: $selectedTire) { tire in
                EditTireView(tire: tire) { await load() }
            }
            .overlay(alignment: .bottom) {
                if let msg = errorMessage { TireToast(message: msg) { errorMessage = nil } }
            }
            .task { await load() }
        }
    }

    private var activeTires: [Tire] { tires.filter { $0.isActive } }

    private func tire(at pos: TirePosition) -> Tire? {
        activeTires.first { $0.position == pos }
    }

    private var odometerHeader: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Current Mileage")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Text("\(Int(currentOdometer).formatted()) mi")
                .font(.system(size: 30, weight: .bold, design: .rounded))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var cornerGrid: some View {
        VStack(spacing: 12) {
            HStack(spacing: 12) {
                cornerCell(.FL)
                cornerCell(.FR)
            }
            HStack(spacing: 12) {
                cornerCell(.RL)
                cornerCell(.RR)
            }
        }
    }

    private func cornerCell(_ pos: TirePosition) -> some View {
        let t = tire(at: pos)
        return TireCornerCard(position: pos, tire: t, currentOdometer: currentOdometer)
            .contentShape(Rectangle())
            .onTapGesture { if let t = t { selectedTire = t } }
    }

    @ViewBuilder
    private var emptyHint: some View {
        if !isLoading && activeTires.isEmpty {
            Text("No tires yet. Use + to replace a tire.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func load() async {
        isLoading = true
        do {
            async let tiresTask = NeonRepository.shared.getActiveTires()
            async let mileageTask = NeonRepository.shared.getLatestMileageRecord()
            let loadedTires = try await tiresTask
            let latest = try await mileageTask
            tires = loadedTires
            currentOdometer = latest?.odometerMiles ?? MileageService.shared.currentMileage
        } catch {
            errorMessage = error.localizedDescription
            if currentOdometer == 0 { currentOdometer = MileageService.shared.currentMileage }
        }
        isLoading = false
    }
}

// MARK: - Corner Card

struct TireCornerCard: View {
    let position: TirePosition
    let tire: Tire?
    let currentOdometer: Double

    private let tireYellow = Color(red: 1.0, green: 0.8, blue: 0.0)

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(position.displayName)
                    .font(.caption.bold())
                    .foregroundStyle(.secondary)
                Spacer()
                Image(systemName: "circle.fill")
                    .font(.caption2)
                    .foregroundStyle(tireYellow)
            }

            if let tire = tire {
                Text(tire.makeModel ?? "Tire")
                    .font(.subheadline.bold())
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                Label("\(Int(tire.miles(currentOdometer: currentOdometer)).formatted()) mi", systemImage: "speedometer")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Label(ageLabel(tire.ageDays()), systemImage: "calendar")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text("No tire")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 96, alignment: .topLeading)
        .padding(12)
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private func ageLabel(_ days: Int) -> String {
        let months = days / 30
        if months >= 12 {
            let years = months / 12
            let rem = months % 12
            return rem > 0 ? "\(years)yr \(rem)mo" : "\(years)yr"
        } else if months >= 1 {
            return "\(months)mo"
        }
        return "\(days)d"
    }
}

// MARK: - Replace Tire

struct AddTireView: View {
    let currentOdometer: Double
    let onSave: () async -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var position: TirePosition = .FL
    @State private var makeModel = ""
    @State private var odometerText = ""
    @State private var date = Date()
    @State private var amountText = ""
    @State private var notes = ""
    @State private var isSaving = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("Tire") {
                    Picker("Corner", selection: $position) {
                        ForEach(TirePosition.allCases) { pos in
                            Text(pos.displayName).tag(pos)
                        }
                    }
                    TextField("Make / model", text: $makeModel)
                }

                Section("Details") {
                    DatePicker("Date", selection: $date, displayedComponents: [.date])
                    TextField("Odometer (miles)", text: $odometerText)
                        .keyboardType(.decimalPad)
                    TextField("Amount ($) — optional", text: $amountText)
                        .keyboardType(.decimalPad)
                    TextField("Notes", text: $notes, axis: .vertical)
                        .lineLimit(3)
                }
            }
            .navigationTitle("Replace Tire")
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
            .overlay(alignment: .bottom) {
                if let msg = errorMessage { TireToast(message: msg) { errorMessage = nil } }
            }
            .task {
                if odometerText.isEmpty && currentOdometer > 0 {
                    odometerText = String(Int(currentOdometer))
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
        let make = makeModel.trimmingCharacters(in: .whitespaces)
        do {
            try await NeonRepository.shared.replaceTire(
                at: position,
                makeModel: make.isEmpty ? nil : make,
                odometer: odometer,
                date: date,
                notes: notes.isEmpty ? nil : notes
            )
            // Keep the Monthly Spend chart working: log a cost record if entered.
            if let amount = Double(amountText), amount > 0 {
                let record = ServiceRecord.new(
                    serviceType: "New \(position.frontRear) Tires",
                    category: "Tires",
                    odometer: odometer,
                    date: date,
                    amount: amount,
                    comments: "\(make.isEmpty ? "Tire" : make) — \(position.displayName)"
                )
                do {
                    try await NeonRepository.shared.saveServiceRecord(record)
                } catch {
                    SyncManager.shared.queueServiceRecord(record)
                }
            }
            await onSave()
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
        isSaving = false
    }
}

// MARK: - Log Rotation

struct RotateTiresView: View {
    let currentOdometer: Double
    let onSave: () async -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var pattern: RotationPattern = .rearwardCross
    @State private var odometerText = ""
    @State private var date = Date()
    @State private var comments = ""
    @State private var logInterval = true
    @State private var isSaving = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("Pattern") {
                    Picker("Pattern", selection: $pattern) {
                        ForEach(RotationPattern.allCases) { p in
                            Text(p.rawValue).tag(p)
                        }
                    }
                    Text(pattern.patternString)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("Details") {
                    DatePicker("Date", selection: $date, displayedComponents: [.date])
                    TextField("Odometer (miles)", text: $odometerText)
                        .keyboardType(.decimalPad)
                    TextField("Comments", text: $comments, axis: .vertical)
                        .lineLimit(3)
                    Toggle("Also log as a rotation service", isOn: $logInterval)
                }
            }
            .navigationTitle("Log Rotation")
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
            .overlay(alignment: .bottom) {
                if let msg = errorMessage { TireToast(message: msg) { errorMessage = nil } }
            }
            .task {
                if odometerText.isEmpty && currentOdometer > 0 {
                    odometerText = String(Int(currentOdometer))
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
            try await NeonRepository.shared.applyRotation(
                mapping: pattern.mapping,
                odometer: odometer,
                date: date,
                pattern: pattern.patternString,
                comments: comments.isEmpty ? nil : comments
            )
            if logInterval {
                let record = ServiceRecord.new(
                    serviceType: "Tire Rotation",
                    category: "Tires",
                    odometer: odometer,
                    date: date,
                    comments: comments.isEmpty ? pattern.patternString : comments
                )
                do {
                    try await NeonRepository.shared.saveServiceRecord(record)
                } catch {
                    SyncManager.shared.queueServiceRecord(record)
                }
            }
            await onSave()
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
        isSaving = false
    }
}

// MARK: - Edit Tire

struct EditTireView: View {
    let tire: Tire
    let onSave: () async -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var position: TirePosition?
    @State private var makeModel: String
    @State private var odometerText: String
    @State private var date: Date
    @State private var notes: String
    @State private var showDeleteConfirm = false
    @State private var isSaving = false
    @State private var errorMessage: String?

    init(tire: Tire, onSave: @escaping () async -> Void) {
        self.tire = tire
        self.onSave = onSave
        _position = State(initialValue: tire.position)
        _makeModel = State(initialValue: tire.makeModel ?? "")
        _odometerText = State(initialValue: String(Int(tire.installOdometer)))
        _date = State(initialValue: tire.installDate)
        _notes = State(initialValue: tire.notes ?? "")
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Tire") {
                    Picker("Corner", selection: $position) {
                        Text("None").tag(TirePosition?.none)
                        ForEach(TirePosition.allCases) { pos in
                            Text(pos.displayName).tag(TirePosition?.some(pos))
                        }
                    }
                    TextField("Make / model", text: $makeModel)
                }

                Section("Install") {
                    DatePicker("Install date", selection: $date, displayedComponents: [.date])
                    TextField("Install odometer (miles)", text: $odometerText)
                        .keyboardType(.decimalPad)
                    TextField("Notes", text: $notes, axis: .vertical)
                        .lineLimit(3)
                }

                Section {
                    Button("Delete Tire", role: .destructive) {
                        showDeleteConfirm = true
                    }
                }
            }
            .navigationTitle("Edit Tire")
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
            .confirmationDialog("Delete this tire?", isPresented: $showDeleteConfirm, titleVisibility: .visible) {
                Button("Delete", role: .destructive) { Task { await delete() } }
            }
            .overlay(alignment: .bottom) {
                if let msg = errorMessage { TireToast(message: msg) { errorMessage = nil } }
            }
        }
    }

    private func save() async {
        guard let odometer = Double(odometerText) else {
            errorMessage = "Invalid odometer value"
            return
        }
        isSaving = true
        var updated = tire
        updated.position = position
        let make = makeModel.trimmingCharacters(in: .whitespaces)
        updated.makeModel = make.isEmpty ? nil : make
        updated.installOdometer = odometer
        updated.installDate = date
        updated.notes = notes.isEmpty ? nil : notes
        do {
            try await NeonRepository.shared.updateTire(updated)
            await onSave()
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
        isSaving = false
    }

    private func delete() async {
        do {
            try await NeonRepository.shared.deleteTire(id: tire.id)
            await onSave()
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

// MARK: - Toast

private struct TireToast: View {
    let message: String
    let onDone: () -> Void

    var body: some View {
        Text(message)
            .font(.caption)
            .foregroundStyle(.white)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(.red.opacity(0.9))
            .clipShape(Capsule())
            .padding(.bottom, 8)
            .onAppear {
                Task {
                    try? await Task.sleep(nanoseconds: 3_000_000_000)
                    onDone()
                }
            }
    }
}
