import SwiftUI

/// Readings whose car couldn't be identified when they were taken. Each can be
/// assigned to an active car (turned into that car's mileage row) or deleted.
struct UnassignedReadingsView: View {
    @ObservedObject private var vehicleStore = VehicleStore.shared
    @Environment(\.dismiss) private var dismiss

    @State private var readings: [UnassignedReading] = []
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var pendingDelete: UnassignedReading?

    var body: some View {
        NavigationStack {
            List {
                ForEach(readings) { reading in
                    NavigationLink {
                        AssignReadingView(reading: reading) { await load() }
                    } label: {
                        UnassignedReadingRowView(reading: reading)
                    }
                    .swipeActions {
                        Button {
                            pendingDelete = reading
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                        .tint(.red)
                    }
                }
            }
            .overlay {
                if readings.isEmpty && !isLoading {
                    ContentUnavailableView("Nothing to assign",
                        systemImage: "checkmark.circle",
                        description: Text("Every reading has a car."))
                } else if isLoading && readings.isEmpty {
                    ProgressView()
                }
            }
            .refreshable { await load() }
            .navigationTitle("Unassigned Readings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .confirmationDialog(
                "Delete this reading?",
                isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
                titleVisibility: .visible,
                presenting: pendingDelete
            ) { reading in
                Button("Delete", role: .destructive) {
                    Task { await delete(reading) }
                }
            } message: { reading in
                Text("The reading from \(reading.timestamp.formatted(date: .abbreviated, time: .shortened)) is removed for good. No car's mileage changes.")
            }
            .errorToast($errorMessage)
            .task { await load() }
        }
    }

    private func load() async {
        isLoading = true
        do {
            readings = try await NeonRepository.shared.getUnassignedReadings()
        } catch {
            errorMessage = error.userMessage
        }
        isLoading = false
        await vehicleStore.refreshUnassignedCount()
    }

    private func delete(_ reading: UnassignedReading) async {
        do {
            try await NeonRepository.shared.deleteUnassignedReading(id: reading.id)
            await load()
        } catch {
            errorMessage = error.userMessage
        }
    }
}

private struct UnassignedReadingRowView: View {
    let reading: UnassignedReading

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(reading.timestamp.formatted(date: .abbreviated, time: .shortened))
                .font(.subheadline.bold())
            HStack(spacing: 12) {
                Text("Distance since codes cleared: \(UnassignedReading.milesText(reading.distSinceCodesCleared))")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            Text(UnassignedReading.reasonText(reading.failureReason))
                .font(.caption)
                .foregroundStyle(.orange)
        }
        .padding(.vertical, 2)
    }
}

extension UnassignedReading {
    static func milesText(_ miles: Double?) -> String {
        guard let miles else { return "–" }
        return String(format: "%.1f mi", miles)
    }

    /// Why the car wasn't identified, in plain words.
    static func reasonText(_ reason: String) -> String {
        switch reason {
        case "vin_timeout": return "Car didn't answer the vehicle ID request"
        case "vin_no_data": return "Car didn't provide a vehicle ID"
        case "vin_error": return "Adapter error while reading the vehicle ID"
        case "vin_invalid": return "Vehicle ID reply was unreadable"
        case "vin_lookup_error": return "Vehicle ID read, but the car lookup failed"
        case "vin_unknown_offline": return "Offline, and the vehicle ID wasn't a known car"
        // Offline readings that couldn't be converted to an odometer (car already known)
        case "no_manual_reference": return "Taken offline — this car has no odometer entry to work from"
        case "reference_missing_0131": return "Taken offline — the car's last odometer entry has no baseline reading"
        case "negative_delta": return "Taken offline — the distance reading is lower than at the car's last odometer entry"
        case "no_0131_reading": return "Taken offline — the reading has no distance value"
        case "sanity_check": return "Taken offline — the worked-out odometer was lower than an earlier reading"
        default: return reason
        }
    }
}

/// Assign one reading to an active car: preview the result, confirm, save.
struct AssignReadingView: View {
    let reading: UnassignedReading
    let onDone: () async -> Void

    @ObservedObject private var vehicleStore = VehicleStore.shared
    @Environment(\.dismiss) private var dismiss

    @State private var selectedVehicleId: String?
    @State private var preview: Preview?
    @State private var isComputing = false
    @State private var isSaving = false
    @State private var manualOdometerText = ""
    @State private var showConfirm = false
    @State private var errorMessage: String?

    private enum Preview {
        /// The odometer could be worked out; `effect` says what happens to that day's row.
        case computed(odometer: Double, effect: ReadingImporter.DayRowEffect)
        /// No usable manual reference (or the result looked wrong): ask for the odometer.
        case needsOdometer(reason: String, detail: String)
        case failed(String)
    }

    private var selectedCar: Vehicle? {
        selectedVehicleId.flatMap { vehicleStore.vehicle(id: $0) }
    }

    private var readingTime: String {
        reading.timestamp.formatted(date: .abbreviated, time: .shortened)
    }

    private var readingDay: String {
        reading.timestamp.formatted(date: .abbreviated, time: .omitted)
    }

    var body: some View {
        Form {
            Section("Reading") {
                LabeledContent("Taken", value: readingTime)
                LabeledContent("Distance since codes cleared", value: UnassignedReading.milesText(reading.distSinceCodesCleared))
                Text(UnassignedReading.reasonText(reading.failureReason))
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            Section {
                Picker("Car", selection: $selectedVehicleId) {
                    Text("Choose…").tag(String?.none)
                    ForEach(vehicleStore.activeVehicles) { car in
                        Text(car.displayName).tag(Optional(car.id))
                    }
                }
            } header: {
                Text("Assign to")
            } footer: {
                Text("Only active cars. The distance reading only makes sense for the car it came from — pick the car that was running at that time.")
            }

            if selectedVehicleId != nil {
                previewSection
            }

            Section {
                Button {
                    showConfirm = true
                } label: {
                    HStack {
                        Text("Assign…")
                        Spacer()
                        if isSaving { ProgressView().controlSize(.small) }
                    }
                }
                .disabled(!canAssign)
            }
        }
        .navigationTitle("Assign Reading")
        .keyboardDoneButton()
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog("Assign to \(selectedCar?.displayName ?? "this car")?", isPresented: $showConfirm, titleVisibility: .visible) {
            Button("Assign") { Task { await assign() } }
        } message: {
            Text(confirmMessage)
        }
        .errorToast($errorMessage)
        .task {
            if selectedVehicleId == nil {
                selectedVehicleId = suggestedVehicleId()
            }
        }
        .task(id: selectedVehicleId) { await computePreview() }
    }

    @ViewBuilder
    private var previewSection: some View {
        Section("Result") {
            if isComputing {
                ProgressView()
            } else if let preview {
                switch preview {
                case .computed(let odometer, let effect):
                    LabeledContent("Odometer", value: "\(Int(odometer).formatted()) mi")
                    Text(effectText(effect))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                case .needsOdometer(let reason, _):
                    Text(needsOdometerText(reason))
                        .font(.caption)
                        .foregroundStyle(.orange)
                    HStack {
                        Text("Odometer at \(readingTime)")
                        Spacer()
                        TextField("miles", text: $manualOdometerText)
                            .keyboardType(.numberPad)
                            .multilineTextAlignment(.trailing)
                            .frame(maxWidth: 110)
                    }
                    Text("Saved as a manual entry at the reading's time, with this reading's distance reading (\(UnassignedReading.milesText(reading.distSinceCodesCleared))) as the baseline for later captures.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                case .failed(let message):
                    Text("Couldn't work it out: \(message)")
                        .font(.caption)
                        .foregroundStyle(.red)
                    Button("Try again") { Task { await computePreview() } }
                }
            }
        }
    }

    private var canAssign: Bool {
        guard !isSaving, !isComputing, selectedCar?.isActive == true, let preview else { return false }
        switch preview {
        case .computed: return true
        case .needsOdometer: return manualOdometer != nil
        case .failed: return false
        }
    }

    private var manualOdometer: Double? {
        let text = manualOdometerText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let value = Double(text), value > 0 else { return nil }
        return value
    }

    private var confirmMessage: String {
        let car = selectedCar?.displayName ?? "this car"
        guard let preview else { return "" }
        switch preview {
        case .computed(let odometer, let effect):
            switch effect {
            case .insert, .update:
                return "Saves \(Int(odometer).formatted()) mi for \(car) on \(readingDay) as that day's automatic reading."
            case .keepNewer:
                return "Nothing is saved: \(car) already has a newer reading for \(readingDay). The reading is marked as assigned."
            }
        case .needsOdometer:
            let miles = manualOdometer.map { Int($0).formatted() } ?? "?"
            return "Saves \(miles) mi as a manual entry for \(car) at \(readingTime), with this reading's distance reading as the baseline."
        case .failed:
            return ""
        }
    }

    private func effectText(_ effect: ReadingImporter.DayRowEffect) -> String {
        switch effect {
        case .insert:
            return "Adds this car's automatic reading for \(readingDay)."
        case .update(let existing):
            return "Replaces this car's \(readingDay) automatic reading (\(Int(existing.odometerMiles).formatted()) mi at \(existing.timestamp.formatted(date: .omitted, time: .shortened))), which is older."
        case .keepNewer(let existing):
            return "This car already has a newer \(readingDay) reading (\(Int(existing.odometerMiles).formatted()) mi at \(existing.timestamp.formatted(date: .omitted, time: .shortened))). Nothing changes; the reading is marked as assigned."
        }
    }

    private func needsOdometerText(_ reason: String) -> String {
        switch reason {
        case "no_manual_reference":
            return "This car has no manual odometer entry yet, so the reading can't be converted. Enter what the odometer showed at that moment."
        case "reference_missing_0131":
            return "This car's latest manual odometer entry has no baseline reading, so the reading can't be converted. Enter what the odometer showed at that moment."
        case "negative_delta":
            return "The reading's distance value is below the one at this car's latest manual entry (that entry is newer than the reading, or the codes were cleared). Enter what the odometer showed at that moment."
        case "sanity_check":
            let known = reading.suggestedVehicleId != nil && selectedVehicleId == reading.suggestedVehicleId
            return known
                ? "The worked-out odometer is lower than a reading this car already had before then. Enter what the odometer showed at that moment."
                : "The worked-out odometer is lower than a reading this car already had before then — the reading may belong to another car. Only continue if you know the odometer at that moment."
        case "no_0131_reading":
            return "The reading has no distance value to work from. Enter what the odometer showed at that moment."
        default:
            return "The reading can't be converted (\(reason)). Enter what the odometer showed at that moment."
        }
    }

    /// The car whose VIN appears in the reading's raw VIN reply, if it is a known active car.
    private func suggestedVehicleId() -> String? {
        // A rejected offline reading already knows its car.
        if let known = reading.suggestedVehicleId,
           vehicleStore.vehicle(id: known)?.isActive == true {
            return known
        }
        guard let raw = reading.vinRawResponse else { return nil }
        for part in raw.components(separatedBy: " | ") {
            guard case .vin(let vin) = PIDParser.parseVIN(part) else { continue }
            let car = vehicleStore.vehicles.first { $0.vin?.uppercased() == vin } ?? VehicleCache.vehicle(vin: vin)
            if let car, car.isActive { return car.id }
        }
        return nil
    }

    private func capture(for vehicleId: String) -> PendingCapture {
        let reported = reading.odometerRawResponse.map { PIDParser.parseOdometer($0) } ?? 0
        return PendingCapture(
            id: reading.id,
            vehicleId: vehicleId,
            timestamp: reading.timestamp,
            captureMode: reading.captureMode ?? "unassigned",
            rpm: reading.rpm,
            odometer: reported > 0 ? reported : nil,
            odometerRawResponse: reading.odometerRawResponse,
            distSinceCodesCleared: reading.distSinceCodesCleared,
            distRawResponse: reading.distRawResponse,
            reason: "assigned"
        )
    }

    /// Read-only: what assigning to the selected car would do.
    private func computePreview() async {
        guard let vehicleId = selectedVehicleId else {
            preview = nil
            return
        }
        preview = nil
        isComputing = true
        let c = capture(for: vehicleId)
        let result: Preview
        do {
            switch try await ReadingImporter.evaluate(c) {
            case .rejected(let reason, let detail):
                result = .needsOdometer(reason: reason, detail: detail)
            case .odometer(let odometer):
                let effect = try await ReadingImporter.dayRowEffect(c)
                result = .computed(odometer: odometer, effect: effect)
            }
        } catch {
            result = .failed(error.userMessage)
        }
        // A different car was picked while this was working.
        guard vehicleId == selectedVehicleId else { return }
        preview = result
        isComputing = false
    }

    private func assign() async {
        guard let vehicleId = selectedVehicleId, let car = vehicleStore.vehicle(id: vehicleId), car.isActive,
              let preview else { return }
        isSaving = true
        defer { isSaving = false }
        let repo = NeonRepository.shared
        do {
            var savedOdometer: Double?
            switch preview {
            case .computed:
                // Worked out again at save time, so it reflects the database as it is now.
                switch try await ReadingImporter.importCapture(capture(for: vehicleId), saveSnapshot: false) {
                case .rejected(let reason, let detail):
                    self.preview = .needsOdometer(reason: reason, detail: detail)
                    errorMessage = "The reading can no longer be converted — enter the odometer instead."
                    return
                case .saved(let odometer), .updated(let odometer):
                    savedOdometer = odometer
                case .superseded:
                    savedOdometer = nil
                }
            case .needsOdometer:
                guard let odometer = manualOdometer else { return }
                if let before = try await repo.getLatestMileageRecord(vehicleId: vehicleId, onOrBefore: reading.timestamp),
                   odometer < before.odometerMiles - 1.5 {
                    errorMessage = "Lower than \(Int(before.odometerMiles).formatted()) mi recorded for \(car.displayName) on \(before.timestamp.formatted(date: .abbreviated, time: .omitted))"
                    return
                }
                // The reading's id makes this idempotent (ON CONFLICT DO NOTHING).
                try await repo.saveMileageRecord(MileageRecord(
                    id: reading.id,
                    vehicleId: vehicleId,
                    timestamp: reading.timestamp,
                    odometerMiles: odometer,
                    source: "MANUAL",
                    distSinceCodesCleared: reading.distSinceCodesCleared
                ))
                savedOdometer = odometer
            case .failed:
                return
            }

            // Only now that the row is saved (or a newer one stands) is the reading done.
            try await repo.markUnassignedReadingAssigned(id: reading.id, vehicleId: vehicleId)

            if let savedOdometer, savedOdometer > MileageService.shared.currentMileage(for: vehicleId) {
                MileageService.shared.setCurrentMileage(savedOdometer, for: vehicleId)
            }
            vehicleStore.dataDidChange()
            await vehicleStore.refreshUnassignedCount()
            await ServiceReminderScheduler.reschedule()
            await onDone()
            dismiss()
        } catch {
            errorMessage = error.userMessage
        }
    }
}
