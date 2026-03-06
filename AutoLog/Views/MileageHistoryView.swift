import SwiftUI

struct MileageHistoryView: View {
    @State private var records: [MileageRecord] = []
    @State private var isLoading = false
    @State private var showAddSheet = false
    @State private var selectedRecord: MileageRecord?
    @State private var errorMessage: String?

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
                    if records.isEmpty && !isLoading {
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
                }
            }
            .sheet(isPresented: $showAddSheet) {
                EditMileageView(record: nil) { await loadRecords() }
            }
            .sheet(item: $selectedRecord) { record in
                EditMileageView(record: record) { await loadRecords() }
            }
            .overlay(alignment: .bottom) {
                if let msg = errorMessage {
                    toastMessage(msg)
                }
            }
            .task { await loadRecords() }
        }
    }

    private func loadRecords() async {
        isLoading = true
        do {
            records = try await NeonRepository.shared.getMileageRecords()
        } catch {
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
