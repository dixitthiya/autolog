import SwiftUI

struct DashboardView: View {
    @StateObject private var bleManager = BLEManager.shared
    @StateObject private var mileageService = MileageService.shared
    @StateObject private var syncManager = SyncManager.shared

    @State private var dashboardRows: [DashboardRow] = []
    @State private var isLoading = false
    @State private var isOffline = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            ZStack {
                List {
                    headerSection
                    bleSection
                    if !dashboardRows.isEmpty {
                        statusSection
                    }
                }
                .refreshable { await loadDashboard() }

                if isLoading && dashboardRows.isEmpty {
                    ProgressView()
                }
            }
            .navigationTitle("AutoLog")
            .overlay(alignment: .top) {
                if isOffline {
                    offlineBanner
                }
            }
            .overlay(alignment: .bottom) {
                if let msg = errorMessage {
                    toastView(msg)
                }
            }
            .task { await loadDashboard() }
        }
    }

    // MARK: - Sections

    private var headerSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Current Mileage")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Spacer()
                    if syncManager.pendingCount > 0 {
                        Label("\(syncManager.pendingCount) pending", systemImage: "arrow.clockwise")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                }
                Text("\(Int(mileageService.currentMileage).formatted()) mi")
                    .font(.system(size: 36, weight: .bold, design: .rounded))

                if let lastSync = mileageService.lastSyncDate {
                    Text("Last BLE sync: \(lastSync.formatted(date: .abbreviated, time: .shortened))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 4)
        }
    }

    private var bleSection: some View {
        Section {
            Button {
                if bleManager.connectionState == .disconnected {
                    bleManager.startScanning()
                } else {
                    bleManager.disconnect()
                }
            } label: {
                HStack {
                    Image(systemName: bleManager.connectionState.icon)
                        .foregroundStyle(bleManager.connectionState == .ready ? .green : .blue)
                    Text(bleManager.connectionState.displayText)
                    Spacer()
                    if bleManager.connectionState == .scanning || bleManager.connectionState == .connecting {
                        ProgressView()
                            .controlSize(.small)
                    }
                }
            }
        } header: {
            Text("OBD Connection")
        }
    }

    private var statusSection: some View {
        ForEach(groupedByCategory, id: \.0) { category, rows in
            Section(header: Text(category)) {
                ForEach(rows) { row in
                    DashboardRowView(row: row)
                }
            }
        }
    }

    private var groupedByCategory: [(String, [DashboardRow])] {
        let sorted = dashboardRows.sorted { $0.status < $1.status }
        var groups: [(String, [DashboardRow])] = []
        var seen = Set<String>()

        for row in sorted {
            let cat = ServiceCategory.category(for: row.serviceType)
            if !seen.contains(cat) {
                seen.insert(cat)
                groups.append((cat, sorted.filter { ServiceCategory.category(for: $0.serviceType) == cat }))
            }
        }
        return groups
    }

    private var offlineBanner: some View {
        Text("Offline - showing cached data")
            .font(.caption)
            .foregroundStyle(.white)
            .padding(.horizontal, 16)
            .padding(.vertical, 6)
            .background(.orange)
            .clipShape(Capsule())
            .padding(.top, 4)
    }

    private func toastView(_ message: String) -> some View {
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
                    errorMessage = nil
                }
            }
    }

    // MARK: - Data

    private func loadDashboard() async {
        isLoading = true
        do {
            dashboardRows = try await NeonRepository.shared.getDashboardData()
            if let latest = try await NeonRepository.shared.getLatestMileageRecord() {
                mileageService.currentMileage = latest.odometerMiles
            }
            isOffline = false
        } catch {
            isOffline = true
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }
}

struct DashboardRowView: View {
    let row: DashboardRow

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(row.serviceType)
                    .font(.subheadline.bold())
                Spacer()
                statusBadge
            }

            HStack(spacing: 16) {
                if row.rotorThickness != nil {
                    Label("\(row.rotorThickness!, specifier: "%.1f") mm", systemImage: "ruler")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Label("\(Int(row.milesAfterService).formatted()) mi", systemImage: "speedometer")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if let date = row.lastServiceDate {
                    Label(date.formatted(date: .abbreviated, time: .omitted), systemImage: "calendar")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if row.daysAfterService > 0 {
                    Text("\(Int(row.monthsAfterService))mo")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 2)
    }

    private var statusBadge: some View {
        HStack(spacing: 4) {
            Image(systemName: row.status.icon)
                .font(.caption)
            Text(badgeLabel)
                .font(.caption2.bold())
        }
        .foregroundStyle(row.status.color)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(row.status.color.opacity(0.12))
        .clipShape(Capsule())
    }

    private var badgeLabel: String {
        switch row.status {
        case .critical: return "CRITICAL"
        case .serviceSoon: return "SOON"
        case .allGood: return "GOOD"
        case .noData: return "N/A"
        }
    }
}
