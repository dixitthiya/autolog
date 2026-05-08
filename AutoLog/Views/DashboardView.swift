import SwiftUI

struct DashboardView: View {
    @StateObject private var bleManager = BLEManager.shared
    @StateObject private var mileageService = MileageService.shared
    @StateObject private var syncManager = SyncManager.shared

    @State private var dashboardRows: [DashboardRow] = []
    @State private var trackedItems: [TrackedItem] = []
    @State private var trackedSearch = ""
    @State private var isLoading = false
    @State private var isOffline = false
    @State private var errorMessage: String?
    @FocusState private var trackedSearchFocused: Bool

    var body: some View {
        NavigationStack {
            ZStack {
                ScrollViewReader { proxy in
                    List {
                        headerSection
                        bleSection
                        if !attentionRows.isEmpty {
                            attentionSection
                        }
                        if !nonUrgentByCategory.isEmpty {
                            categorySection
                        }
                        if !trackedItems.isEmpty {
                            trackedSection
                        }
                    }
                    .scrollDismissesKeyboard(.immediately)
                    .refreshable { await loadDashboard() }
                    .onChange(of: trackedSearchFocused) { _, focused in
                        guard focused else { return }
                        Task {
                            try? await Task.sleep(nanoseconds: 350_000_000)
                            withAnimation {
                                proxy.scrollTo("trackedSearchField", anchor: .top)
                            }
                        }
                    }
                }

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

    private var attentionSection: some View {
        Section(header: Text("Needs Attention")) {
            ForEach(attentionRows) { row in
                DashboardRowView(row: row)
            }
        }
    }

    private var categorySection: some View {
        ForEach(nonUrgentByCategory, id: \.0) { category, rows in
            Section(header: Text(category)) {
                ForEach(rows) { row in
                    DashboardRowView(row: row)
                }
            }
        }
    }

    private var trackedSection: some View {
        Section(header: Text("Tracked")) {
            if trackedItems.count >= 4 {
                trackedSearchField
            }
            if filteredTrackedItems.isEmpty {
                Text("No matches")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(filteredTrackedItems) { item in
                    TrackedItemRowView(item: item)
                }
            }
        }
    }

    private var trackedSearchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.caption)
                .foregroundStyle(.secondary)
            TextField("Search tracked items", text: $trackedSearch)
                .font(.subheadline)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .focused($trackedSearchFocused)
            if !trackedSearch.isEmpty {
                Button {
                    trackedSearch = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .id("trackedSearchField")
    }

    private var filteredTrackedItems: [TrackedItem] {
        let q = trackedSearch.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return trackedItems }
        return trackedItems.filter { item in
            item.serviceType.lowercased().contains(q) ||
            (item.comments?.lowercased().contains(q) ?? false)
        }
    }

    private var attentionRows: [DashboardRow] {
        dashboardRows
            .filter { $0.status == .critical || $0.status == .serviceSoon }
            .sorted { a, b in
                if a.status != b.status { return a.status < b.status }
                let aUrgency = a.milesToCritical ?? .greatestFiniteMagnitude
                let bUrgency = b.milesToCritical ?? .greatestFiniteMagnitude
                if aUrgency != bUrgency { return aUrgency < bUrgency }
                return a.serviceType < b.serviceType
            }
    }

    private var nonUrgentByCategory: [(String, [DashboardRow])] {
        var catMap: [String: [DashboardRow]] = [:]
        for row in dashboardRows where row.status != .critical && row.status != .serviceSoon {
            let cat = ServiceCategory.category(for: row.serviceType)
            catMap[cat, default: []].append(row)
        }
        return catMap
            .map { cat, rows in
                (cat, rows.sorted { a, b in
                    if a.status != b.status { return a.status < b.status }
                    return a.serviceType < b.serviceType
                })
            }
            .sorted { $0.0 < $1.0 }
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
            trackedItems = try await NeonRepository.shared.getTrackedItems()
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

struct TrackedItemRowView: View {
    let item: TrackedItem

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(item.serviceType)
                .font(.subheadline.bold())

            HStack(spacing: 12) {
                Label(item.lastServiceDate.formatted(date: .abbreviated, time: .omitted), systemImage: "calendar")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Label("\(Int(item.lastServiceMileage).formatted()) mi", systemImage: "wrench.and.screwdriver")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if let amount = item.amount {
                    Label("$\(amount, specifier: "%.2f")", systemImage: "dollarsign.circle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            HStack(spacing: 12) {
                Label("\(Int(item.milesSince).formatted()) mi since", systemImage: "speedometer")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if item.daysSince > 0 {
                    Text("\(timeLabel(item.daysSince)) ago")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if let comments = item.comments, !comments.isEmpty {
                Text(comments)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 2)
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
