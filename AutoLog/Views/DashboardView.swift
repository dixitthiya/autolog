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
            HStack {
                Image(systemName: bleManager.connectionState.icon)
                    .foregroundStyle(bleConnectionColor)
                VStack(alignment: .leading, spacing: 2) {
                    Text(bleStatusText)
                        .font(.subheadline)
                    if !mileageService.obdStatus.isEmpty {
                        Text(mileageService.obdStatus)
                            .font(.caption)
                            .foregroundStyle(mileageService.needsManualEntry ? .orange : .secondary)
                    }
                    if !mileageService.lastCaptureInfo.isEmpty && !mileageService.isReading {
                        Text(mileageService.lastCaptureInfo)
                            .font(.caption)
                            .foregroundStyle(.green)
                    }
                }
                Spacer()
                if mileageService.isReading {
                    ProgressView()
                        .controlSize(.small)
                }
            }
            if mileageService.needsManualEntry {
                NavigationLink {
                    EditMileageView(record: nil) {
                        mileageService.needsManualEntry = false
                        await loadDashboard()
                    }
                } label: {
                    Label("Enter Odometer Reading", systemImage: "pencil.circle.fill")
                        .font(.subheadline.bold())
                        .foregroundStyle(.orange)
                }
            }
        } header: {
            HStack {
                Text("OBD Auto-Capture")
                Spacer()
                Button {
                    guard !mileageService.isReading else { return }
                    bleManager.captureMode = "dashboard_button"
                    bleManager.connectOrScan()
                } label: {
                    Label("Capture", systemImage: "arrow.clockwise")
                        .font(.caption2.bold())
                }
                .disabled(mileageService.isReading)
            }
        }
    }

    private var bleStatusText: String {
        // During throttle countdown, suppress BLE state flickering
        if mileageService.isThrottled {
            return "Auto-capture active"
        }
        switch bleManager.connectionState {
        case .disconnected:
            return mileageService.lastCaptureInfo.isEmpty ? "Waiting for OBD adapter" : "Auto-capture active"
        case .scanning: return "Scanning..."
        case .connecting: return "Connecting..."
        case .connected: return "Connected"
        case .ready: return "Reading data..."
        }
    }

    private var bleConnectionColor: Color {
        if mileageService.isReading { return .blue }
        if !mileageService.lastCaptureInfo.isEmpty { return .green }
        return bleManager.connectionState == .disconnected ? .secondary : .blue
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
        var catMap: [String: [DashboardRow]] = [:]
        for row in dashboardRows {
            let cat = ServiceCategory.category(for: row.serviceType)
            catMap[cat, default: []].append(row)
        }
        return catMap.keys.sorted().map { cat in
            (cat, catMap[cat]!.sorted { $0.serviceType < $1.serviceType })
        }
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
                    Text(timeLabel(row.daysAfterService))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if row.rotorThickness == nil, (row.milesWarning != nil || row.daysWarning != nil) {
                switch row.status {
                case .allGood:
                    let parts = remainingParts(
                        miles: row.milesRemaining.flatMap { $0 > 0 ? "\(Int($0).formatted()) mi" : nil },
                        days: row.daysRemaining.flatMap { $0 > 0 ? timeLabel($0) : nil }
                    )
                    if !parts.isEmpty {
                        Label("\(parts) remaining", systemImage: "arrow.forward.circle")
                            .font(.caption)
                            .foregroundStyle(row.status.color)
                    }
                case .serviceSoon:
                    let parts = remainingParts(
                        miles: row.milesToCritical.flatMap { $0 > 0 ? "\(Int($0).formatted()) mi" : nil },
                        days: row.daysToCritical.flatMap { $0 > 0 ? timeLabel($0) : nil }
                    )
                    if !parts.isEmpty {
                        Label("Critical in \(parts)", systemImage: "exclamationmark.triangle")
                            .font(.caption)
                            .foregroundStyle(row.status.color)
                    }
                case .critical:
                    let parts = remainingParts(
                        miles: row.milesToCritical.map { "\(Int(abs($0)).formatted()) mi" },
                        days: row.daysToCritical.flatMap { $0 < 0 ? timeLabel(abs($0)) : nil }
                    )
                    if !parts.isEmpty {
                        Label("Overdue by \(parts)", systemImage: "exclamationmark.circle.fill")
                            .font(.caption)
                            .foregroundStyle(row.status.color)
                    }
                case .noData:
                    EmptyView()
                }
            }
        }
        .padding(.vertical, 2)
    }

    private func remainingParts(miles: String?, days: String?) -> String {
        [miles, days].compactMap { $0 }.joined(separator: " / ")
    }

    private func timeLabel(_ days: Int) -> String {
        let months = days / 30
        if months >= 12 {
            let years = months / 12
            let rem = months % 12
            return rem > 0 ? "\(years)yr \(rem)mo" : "\(years)yr"
        } else if months >= 1 {
            return "\(months)mo"
        } else {
            return "\(days)d"
        }
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
        case .critical: return "OVERDUE"
        case .serviceSoon: return "DUE"
        case .allGood: return "GOOD"
        case .noData: return "N/A"
        }
    }
}
