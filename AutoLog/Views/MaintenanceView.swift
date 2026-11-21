import SwiftUI

struct MaintenanceView: View {
    @State private var records: [ServiceRecord] = []
    @State private var isLoading = false
    @State private var selectedFilter = "All"
    @State private var showAddSheet = false
    @State private var selectedRecord: ServiceRecord?
    @State private var errorMessage: String?
    /// The car the records on screen belong to.
    @State private var loadedVehicleId: String?
    @ObservedObject private var vehicleStore = VehicleStore.shared

    /// "All" first, then the real categories from the service catalog.
    private var filters: [String] {
        ["All"] + ServiceCategory.all.map(\.name)
    }

    var filteredRecords: [ServiceRecord] {
        if selectedFilter == "All" { return records }
        return records.filter { $0.category == selectedFilter }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // Fixed header above the filter bar: 8 pt here + the filter bar's
                // own 8 pt top padding = 16 pt from the pill to the chips.
                CarSwitcherHeader(bottom: 8)
                filterBar
                ZStack {
                    List {
                        ForEach(filteredRecords) { record in
                            ServiceRowView(record: record)
                                .contentShape(Rectangle())
                                .onTapGesture { selectedRecord = record }
                        }
                    }
                    .carSwitcherListContainer()
                    .refreshable { await loadRecords() }
                    .overlay {
                        if vehicleStore.viewedVehicleId == nil {
                            NoCarSelectedView()
                        } else if filteredRecords.isEmpty && !isLoading {
                            ContentUnavailableView("No Service Records",
                                systemImage: "wrench.and.screwdriver",
                                description: Text("Add your first service entry"))
                        }
                    }

                    if isLoading && records.isEmpty {
                        ProgressView()
                    }
                }
            }
            .carSwitcherPageBackground()
            .navigationTitle("Maintenance")
            .toolbar {
                ToolbarItemGroup(placement: .primaryAction) {
                    // Opens Service intervals through the shared car-menu sheet
                    Button { vehicleStore.carMenuSheet = .intervals } label: {
                        Image(systemName: "slider.horizontal.3")
                    }
                    .accessibilityLabel("Service intervals")
                    .disabled(vehicleStore.viewedVehicleId == nil)
                    Button { showAddSheet = true } label: {
                        Image(systemName: "plus")
                    }
                    .accessibilityLabel("Add service")
                    .disabled(vehicleStore.viewedVehicleId == nil)
                }
            }
            .sheet(isPresented: $showAddSheet) {
                if let vehicleId = vehicleStore.viewedVehicleId {
                    AddServiceView(vehicleId: vehicleId) { await loadRecords() }
                }
            }
            .sheet(item: $selectedRecord) { record in
                EditServiceView(record: record) { await loadRecords() }
            }
            .errorToast($errorMessage)
            .onChange(of: vehicleStore.viewedVehicleId) { _, _ in clearCarData() }
            .task(id: vehicleStore.viewedVehicleId) { await loadRecords() }
        }
    }

    private var filterBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(filters, id: \.self) { filter in
                    Button(filter) {
                        selectedFilter = filter
                    }
                    .font(.subheadline)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(selectedFilter == filter ? Color.accentColor : Color(.systemGray5))
                    .foregroundStyle(selectedFilter == filter ? .white : .primary)
                    .clipShape(Capsule())
                }
            }
            .padding(.horizontal, CarSwitcherLayout.titleLeading)
            .padding(.top, 8)
            .padding(.bottom, CarSwitcherLayout.bottom)
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
            let loaded = try await NeonRepository.shared.getServiceRecords(vehicleId: vehicleId)
            // The car was switched while this was loading: the result is for the wrong car.
            guard vehicleId == vehicleStore.viewedVehicleId else { return }
            records = loaded
        } catch {
            guard vehicleId == vehicleStore.viewedVehicleId else { return }
            errorMessage = error.userMessage
        }
        isLoading = false
    }
}

struct ServiceRowView: View {
    let record: ServiceRecord

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(record.serviceType)
                    .font(.subheadline.bold())
                Spacer()
                Text(record.category)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color(.systemGray5))
                    .clipShape(Capsule())
            }

            HStack(spacing: 12) {
                Label(record.timestamp.formatted(date: .abbreviated, time: .omitted), systemImage: "calendar")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Label(Fmt.miles(record.odometerMiles), systemImage: "speedometer")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if let amount = record.amount {
                    Label(Fmt.money(amount), systemImage: "dollarsign.circle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if let rotor = record.rotorThicknessMM {
                    Label("\(rotor, specifier: "%.1f") mm", systemImage: "ruler")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if let comments = record.comments, !comments.isEmpty {
                Text(comments)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 2)
    }
}
