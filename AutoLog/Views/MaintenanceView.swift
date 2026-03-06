import SwiftUI

struct MaintenanceView: View {
    @State private var records: [ServiceRecord] = []
    @State private var isLoading = false
    @State private var selectedFilter = "All"
    @State private var showAddSheet = false
    @State private var selectedRecord: ServiceRecord?
    @State private var errorMessage: String?

    private let filters = ["All", "Brakes", "Tires", "Engine", "Cooling", "Transmission", "General"]

    var filteredRecords: [ServiceRecord] {
        if selectedFilter == "All" { return records }
        return records.filter { $0.category == selectedFilter }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                filterBar
                ZStack {
                    List {
                        ForEach(filteredRecords) { record in
                            ServiceRowView(record: record)
                                .contentShape(Rectangle())
                                .onTapGesture { selectedRecord = record }
                        }
                    }
                    .overlay {
                        if filteredRecords.isEmpty && !isLoading {
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
            .navigationTitle("Maintenance")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button { showAddSheet = true } label: {
                        Image(systemName: "plus.circle.fill")
                            .font(.title3)
                    }
                }
            }
            .sheet(isPresented: $showAddSheet) {
                AddServiceView { await loadRecords() }
            }
            .sheet(item: $selectedRecord) { record in
                EditServiceView(record: record) { await loadRecords() }
            }
            .overlay(alignment: .bottom) {
                if let msg = errorMessage {
                    Text(msg)
                        .font(.caption).foregroundStyle(.white)
                        .padding(.horizontal, 16).padding(.vertical, 8)
                        .background(.red.opacity(0.9)).clipShape(Capsule())
                        .padding(.bottom, 8)
                        .onAppear {
                            Task {
                                try? await Task.sleep(nanoseconds: 3_000_000_000)
                                errorMessage = nil
                            }
                        }
                }
            }
            .task { await loadRecords() }
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
            .padding(.horizontal)
            .padding(.vertical, 8)
        }
        .background(Color(.systemGroupedBackground))
    }

    private func loadRecords() async {
        isLoading = true
        do {
            records = try await NeonRepository.shared.getServiceRecords()
        } catch {
            errorMessage = error.localizedDescription
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

                Label("\(Int(record.odometerMiles).formatted()) mi", systemImage: "speedometer")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if let amount = record.amount {
                    Label("$\(amount, specifier: "%.2f")", systemImage: "dollarsign.circle")
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
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 2)
    }
}
