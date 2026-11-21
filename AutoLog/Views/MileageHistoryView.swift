import SwiftUI

struct MileageHistoryView: View {
    @State private var records: [MileageRecord] = []
    @State private var isLoading = false
    @State private var showAddSheet = false
    @State private var selectedRecord: MileageRecord?
    @State private var errorMessage: String?
    /// The car the records on screen belong to.
    @State private var loadedVehicleId: String?
    @ObservedObject private var vehicleStore = VehicleStore.shared

    var body: some View {
        NavigationStack {
            ZStack {
                List {
                    ForEach(records) { record in
                        MileageRowView(record: record)
                            .contentShape(Rectangle())
                            .onTapGesture { selectedRecord = record }
                    }
                }
                .refreshable { await loadRecords() }
                .overlay {
                    if vehicleStore.viewedVehicleId == nil {
                        NoCarSelectedView()
                    } else if records.isEmpty && !isLoading {
                        ContentUnavailableView("No Mileage Records",
                            systemImage: "speedometer",
                            description: Text("Add your first mileage entry"))
                    }
                }

                if isLoading && records.isEmpty {
                    ProgressView()
                }
            }
            .navigationTitle("Mileage")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button { showAddSheet = true } label: {
                        Image(systemName: "plus.circle.fill")
                            .font(.title3)
                    }
                    .disabled(vehicleStore.viewedVehicleId == nil)
                }
            }
            .sheet(isPresented: $showAddSheet) {
                EditMileageView(record: nil, vehicleId: vehicleStore.viewedVehicleId) { await loadRecords() }
            }
            .sheet(item: $selectedRecord) { record in
                EditMileageView(record: record, vehicleId: record.vehicleId) { await loadRecords() }
            }
            .overlay(alignment: .bottom) {
                if let msg = errorMessage {
                    toastMessage(msg)
                }
            }
            .carSwitcher()
            .onChange(of: vehicleStore.viewedVehicleId) { _, _ in clearCarData() }
            // Reload when the car changes, or when an assigned reading added a record
            .task(id: "\(vehicleStore.viewedVehicleId ?? "-")#\(vehicleStore.dataVersion)") { await loadRecords() }
        }
    }

    /// Drop the previous car's records so they are never shown under another car.
    private func clearCarData() {
        records = []
        loadedVehicleId = vehicleStore.viewedVehicleId
    }

    private func loadRecords() async {
        guard let vehicleId = vehicleStore.viewedVehicleId else {
            clearCarData()
            return
        }
        if loadedVehicleId != vehicleId { clearCarData() }
        isLoading = true
        do {
            let loaded = try await NeonRepository.shared.getMileageRecords(vehicleId: vehicleId)
            // The car was switched while this was loading: the result is for the wrong car.
            guard vehicleId == vehicleStore.viewedVehicleId else { return }
            records = loaded
        } catch is CancellationError {
            // Pull-to-refresh retracting cancels the in-flight request — not a real error.
        } catch let urlError as URLError where urlError.code == .cancelled {
            // Same: a cancelled URL request, don't surface it.
        } catch {
            guard vehicleId == vehicleStore.viewedVehicleId else { return }
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }

    private func toastMessage(_ msg: String) -> some View {
        Text(msg)
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
                    errorMessage = nil
                }
            }
    }
}

struct MileageRowView: View {
    let record: MileageRecord

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(record.timestamp.formatted(date: .abbreviated, time: .shortened))
                    .font(.subheadline)
                Text("\(Int(record.odometerMiles).formatted()) miles")
                    .font(.headline.monospacedDigit())
            }
            Spacer()
            sourceBadge
        }
        .padding(.vertical, 2)
    }

    private var sourceBadge: some View {
        Text(record.source == "BLE_AUTO" ? "AUTO" : (record.source == "IMPORTED" ? "CSV" : "MANUAL"))
            .font(.caption2.bold())
            .foregroundStyle(badgeColor)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(badgeColor.opacity(0.12))
            .clipShape(Capsule())
    }

    private var badgeColor: Color {
        switch record.source {
        case "BLE_AUTO": return .blue
        case "IMPORTED": return .purple
        default: return .green
        }
    }
}
