import SwiftUI

/// A service type picked for a sheet (long-press on a Dashboard row).
struct ServiceTypeTarget: Identifiable {
    let serviceType: String
    var id: String { serviceType }
}

/// Edit one service type's interval for a car, from the Dashboard. If the car
/// has no interval for the type yet, opens in "add" mode.
struct IntervalEditSheet: View {
    let vehicleId: String
    let serviceType: String

    @Environment(\.dismiss) private var dismiss

    @State private var threshold: ServiceThreshold?
    @State private var isNew = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Group {
                if let threshold {
                    EditIntervalView(vehicleId: vehicleId, threshold: threshold, isNew: isNew) {
                        VehicleStore.shared.dataDidChange()
                        await ServiceReminderScheduler.reschedule()
                    }
                } else if let errorMessage {
                    ContentUnavailableView("Couldn't load interval",
                        systemImage: "exclamationmark.triangle",
                        description: Text(errorMessage))
                } else {
                    ProgressView()
                }
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        .task { await load() }
    }

    private func load() async {
        do {
            let all = try await NeonRepository.shared.getThresholds(vehicleId: vehicleId)
            if let existing = all.first(where: { $0.serviceType == serviceType }) {
                threshold = existing
                isNew = false
            } else {
                threshold = ServiceThreshold(serviceType: serviceType)
                isNew = true
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

/// Read-only list of one service type's records for a car, newest first.
struct ServiceHistorySheet: View {
    let vehicleId: String
    let serviceType: String

    @Environment(\.dismiss) private var dismiss

    @State private var records: [ServiceRecord] = []
    @State private var isLoading = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            List {
                TargetCarSection(vehicleId: vehicleId)

                Section {
                    ForEach(records) { record in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(record.timestamp.formatted(date: .abbreviated, time: .omitted))
                                    .font(.subheadline.bold())
                                Spacer()
                                if let amount = record.amount {
                                    Text(amount, format: .currency(code: "USD"))
                                        .font(.subheadline)
                                }
                            }
                            Text("\(Int(record.odometerMiles).formatted()) mi")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            if let comments = record.comments, !comments.isEmpty {
                                Text(comments)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        .padding(.vertical, 2)
                    }
                }
            }
            .overlay {
                if let errorMessage {
                    ContentUnavailableView("Couldn't load history",
                        systemImage: "exclamationmark.triangle",
                        description: Text(errorMessage))
                } else if records.isEmpty && !isLoading {
                    ContentUnavailableView("No records",
                        systemImage: "wrench.and.screwdriver",
                        description: Text("No \(serviceType) entries for this car yet."))
                } else if isLoading && records.isEmpty {
                    ProgressView()
                }
            }
            .navigationTitle(serviceType)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .task { await load() }
    }

    private func load() async {
        isLoading = true
        do {
            let all = try await NeonRepository.shared.getServiceRecords(vehicleId: vehicleId)
            records = all
                .filter { $0.serviceType == serviceType }
                .sorted { $0.timestamp > $1.timestamp }
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }
}
