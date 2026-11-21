import SwiftUI

struct DashboardView: View {
    @StateObject private var bleManager = BLEManager.shared
    @StateObject private var mileageService = MileageService.shared
    @StateObject private var syncManager = SyncManager.shared
    @ObservedObject private var vehicleStore = VehicleStore.shared

    @State private var dashboardRows: [DashboardRow] = []
    @State private var trackedItems: [TrackedItem] = []
    @State private var trackedSearch = ""
    @State private var isLoading = false
    @State private var isOffline = false
    @State private var errorMessage: String?
    /// The car the rows on screen belong to.
    @State private var loadedVehicleId: String?
    /// Service type whose interval / history sheet is open (long-press on a tracked row).
    @State private var intervalTarget: ServiceTypeTarget?
    @State private var historyTarget: ServiceTypeTarget?
    @FocusState private var trackedSearchFocused: Bool

    var body: some View {
        NavigationStack {
            ZStack {
                ScrollViewReader { proxy in
                    List {
                        Section {
                            CarSwitcherHeader(leadingInset: 0)
                        }
                        .carSwitcherListHeader()
                        if isOffline {
                            offlineSection
                        }
                        if vehicleStore.viewedVehicleId == nil {
                            Section { NoCarSelectedView() }
                        } else {
                            headerSection
                        }
                        if syncManager.pendingCount > 0 {
                            queueSection
                        }
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
                    .carSwitcherListContainer()
                    .scrollDismissesKeyboard(.immediately)
                    .refreshable { await loadDashboard() }
                    .onChange(of: trackedSearchFocused) { _, focused in
                        guard focused else { return }
                        Task {
                            try? await Task.sleep(nanoseconds: 350_000_000)
                            guard trackedSearchFocused else { return }
                            withAnimation {
                                proxy.scrollTo("trackedSearchField", anchor: .top)
                            }
                        }
                    }
                    .onChange(of: trackedSearch) { oldValue, newValue in
                        guard oldValue.isEmpty && !newValue.isEmpty else { return }
                        Task {
                            try? await Task.sleep(nanoseconds: 100_000_000)
                            guard trackedSearchFocused else { return }
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
            .errorToast($errorMessage)
            .sheet(item: $intervalTarget) { target in
                if let vehicleId = vehicleStore.viewedVehicleId {
                    IntervalEditSheet(vehicleId: vehicleId, serviceType: target.serviceType)
                }
            }
            .sheet(item: $historyTarget) { target in
                if let vehicleId = vehicleStore.viewedVehicleId {
                    ServiceHistorySheet(vehicleId: vehicleId, serviceType: target.serviceType)
                }
            }
            .onChange(of: vehicleStore.viewedVehicleId) { _, _ in clearCarData() }
            // Reload when the car changes, or when intervals / an assigned reading changed its data
            .task(id: "\(vehicleStore.viewedVehicleId ?? "-")#\(vehicleStore.dataVersion)") { await loadDashboard() }
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
                }
                let odometer = mileageService.currentMileage(for: vehicleStore.viewedVehicleId)
                Text(Fmt.milesOrDash(odometer))
                    .font(.system(size: 36, weight: .bold, design: .rounded))
                if odometer <= 0 {
                    Text("Enter odometer to start tracking")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if isViewedCarRetired {
                    Text("Retired — as of last reading")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 4)
        }
    }

    /// Readings and records saved on this phone, waiting for the database.
    private var queueSection: some View {
        Section {
            NavigationLink {
                QueuedRecordsView()
            } label: {
                let count = syncManager.pendingCount
                Label("\(count) \(count == 1 ? "reading" : "readings") waiting to sync", systemImage: "arrow.triangle.2.circlepath")
                    .font(.subheadline)
                    .foregroundStyle(.orange)
            }
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
                    if let lastSync = mileageService.lastSyncDate {
                        Text("Last sync from car: \(Fmt.dateTime(lastSync))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
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
                    // The prompt belongs to the car that triggered it, not the viewed car
                    EditMileageView(record: nil, vehicleId: mileageService.manualEntryVehicleId ?? vehicleStore.viewedVehicleId) {
                        mileageService.needsManualEntry = false
                        mileageService.manualEntryVehicleId = nil
                        await loadDashboard()
                    }
                } label: {
                    Label(manualEntryPromptTitle, systemImage: "pencil.circle.fill")
                        .font(.subheadline.bold())
                        .foregroundStyle(.orange)
                }
            }
            Button {
                guard !mileageService.isReading else { return }
                bleManager.captureMode = "dashboard_button"
                bleManager.connectOrScan(trigger: "dashboard_button")
            } label: {
                Label("Read from car now", systemImage: "arrow.clockwise")
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity, minHeight: 44)
            }
            .disabled(mileageService.isReading)
            .accessibilityLabel("Read from car now")
        } header: {
            Label(connectedCarTitle, systemImage: "antenna.radiowaves.left.and.right")
                .lineLimit(1)
        } footer: {
            Text(captureFooter)
        }
    }

    /// The adapter's car, which is where captures go — not necessarily the car on screen.
    private var connectedCarTitle: String {
        switch bleManager.connectionState {
        case .disconnected:
            if let car = vehicleStore.connectedVehicle { return "Last connected: \(car.displayName)" }
            return "Adapter not connected"
        case .scanning, .connecting:
            return "Connecting…"
        case .connected, .ready:
            if let car = vehicleStore.connectedVehicle { return "Connected: \(car.displayName)" }
            return "Connected"
        }
    }

    private var captureFooter: String {
        if let connected = vehicleStore.connectedVehicle,
           let viewed = vehicleStore.viewedVehicle,
           connected.id != viewed.id {
            return "Readings go to \(connected.displayName), the car the adapter is plugged into — not \(viewed.displayName), the car shown here."
        }
        return "Readings go to the car the adapter is plugged into."
    }

    private var manualEntryPromptTitle: String {
        guard let id = mileageService.manualEntryVehicleId, let car = vehicleStore.vehicle(id: id) else {
            return "Enter Odometer Reading"
        }
        return "Enter Odometer Reading for \(car.displayName)"
    }

    private var bleStatusText: String {
        // During throttle countdown, suppress status flickering
        if mileageService.isThrottled {
            return "Auto-capture active"
        }
        switch bleManager.connectionState {
        case .disconnected:
            return mileageService.lastCaptureInfo.isEmpty ? "Waiting for the adapter" : "Auto-capture active"
        case .scanning: return "Looking for adapter…"
        case .connecting: return "Connecting…"
        case .connected: return "Connected"
        case .ready: return "Reading from the car…"
        }
    }

    private var bleConnectionColor: Color {
        if mileageService.isReading { return .blue }
        if !mileageService.lastCaptureInfo.isEmpty { return .green }
        return bleManager.connectionState == .disconnected ? .secondary : .blue
    }

    private var isViewedCarRetired: Bool {
        vehicleStore.viewedVehicle.map { !$0.isActive } ?? false
    }

    private var attentionSection: some View {
        Section(header: Text("Needs Attention")) {
            ForEach(attentionRows) { row in
                DashboardRowView(row: row, neutral: false)
                    .contextMenu { serviceRowMenu(row.serviceType) }
            }
        }
    }

    /// Long-press menu shared by every service row on the Dashboard.
    @ViewBuilder
    private func serviceRowMenu(_ serviceType: String) -> some View {
        Button {
            intervalTarget = ServiceTypeTarget(serviceType: serviceType)
        } label: {
            Label("Edit interval", systemImage: "slider.horizontal.3")
        }
        Button {
            historyTarget = ServiceTypeTarget(serviceType: serviceType)
        } label: {
            Label("View history", systemImage: "clock.arrow.circlepath")
        }
    }

    private var categorySection: some View {
        ForEach(nonUrgentByCategory, id: \.0) { category, rows in
            Section(header: Text(category)) {
                ForEach(rows) { row in
                    DashboardRowView(row: row, neutral: isViewedCarRetired)
                        .contextMenu { serviceRowMenu(row.serviceType) }
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
                        .contextMenu { serviceRowMenu(item.serviceType) }
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
                .accessibilityLabel("Clear search")
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
        // A retired car has nothing to act on, so it has no "Needs Attention" list
        // (its rows show in their categories, in neutral grey).
        if isViewedCarRetired { return [] }
        return dashboardRows
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
        for row in dashboardRows where isViewedCarRetired || (row.status != .critical && row.status != .serviceSoon) {
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

    /// A normal row below the car picker; only for real network problems.
    private var offlineSection: some View {
        Section {
            Label("Can't reach the database — changes will sync later", systemImage: "wifi.slash")
                .font(.subheadline)
                .foregroundStyle(.orange)
        }
    }

    // MARK: - Data

    /// Drop the previous car's rows so they are never shown under another car.
    private func clearCarData() {
        dashboardRows = []
        trackedItems = []
        trackedSearch = ""
        loadedVehicleId = vehicleStore.viewedVehicleId
    }

    private func loadDashboard() async {
        guard let vehicleId = vehicleStore.viewedVehicleId else {
            clearCarData()
            return
        }
        if loadedVehicleId != vehicleId { clearCarData() }
        isLoading = true
        do {
            let rows = try await NeonRepository.shared.getDashboardData(vehicleId: vehicleId)
            let tracked = try await NeonRepository.shared.getTrackedItems(vehicleId: vehicleId)
            let latest = try await NeonRepository.shared.getLatestMileageRecord(vehicleId: vehicleId)
            // The car was switched while this was loading: the result is for the wrong car.
            guard vehicleId == vehicleStore.viewedVehicleId else { return }
            dashboardRows = rows
            trackedItems = tracked
            if let latest {
                mileageService.setCurrentMileage(latest.odometerMiles, for: vehicleId)
            }
            isOffline = false
            // Keeps "Unassigned (N)" in the car menu current
            await vehicleStore.refreshUnassignedCount()
        } catch is CancellationError {
            // Pull-to-refresh retracting cancels the in-flight request — not a real error.
        } catch let urlError as URLError where urlError.code == .cancelled {
            // Same: a cancelled URL request, don't flip offline or toast.
        } catch {
            guard vehicleId == vehicleStore.viewedVehicleId else { return }
            if NetworkMonitor.isOfflineError(error) {
                isOffline = true
            } else {
                errorMessage = error.userMessage
            }
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

                Label(Fmt.miles(item.lastServiceMileage), systemImage: "wrench.and.screwdriver")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if let amount = item.amount {
                    Label(Fmt.money(amount), systemImage: "dollarsign.circle")
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
    /// Retired car: grey statuses instead of red/orange alarm colours.
    var neutral = false

    private var statusColor: Color { neutral ? .secondary : row.status.color }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(row.serviceType)
                    .font(.subheadline.bold())
                Spacer()
                if row.status != .noData {
                    statusBadge
                }
            }

            if row.status == .noData && row.rotorThickness == nil {
                Label("No service logged", systemImage: "tray")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
            HStack(spacing: 16) {
                if row.rotorThickness != nil {
                    Label("\(row.rotorThickness!, specifier: "%.1f") mm", systemImage: "ruler")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Label(Fmt.miles(row.milesAfterService), systemImage: "speedometer")
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
                            .foregroundStyle(statusColor)
                    }
                case .serviceSoon:
                    let parts = remainingParts(
                        miles: row.milesToCritical.flatMap { $0 > 0 ? "\(Int($0).formatted()) mi" : nil },
                        days: row.daysToCritical.flatMap { $0 > 0 ? timeLabel($0) : nil }
                    )
                    if !parts.isEmpty {
                        Label("Critical in \(parts)", systemImage: "exclamationmark.triangle")
                            .font(.caption)
                            .foregroundStyle(statusColor)
                    }
                case .critical:
                    let parts = remainingParts(
                        miles: row.milesToCritical.map { "\(Int(abs($0)).formatted()) mi" },
                        days: row.daysToCritical.flatMap { $0 < 0 ? timeLabel(abs($0)) : nil }
                    )
                    if !parts.isEmpty {
                        Label("Overdue by \(parts)", systemImage: "exclamationmark.circle.fill")
                            .font(.caption)
                            .foregroundStyle(statusColor)
                    }
                case .noData:
                    EmptyView()
                }
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
        .foregroundStyle(statusColor)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(statusColor.opacity(0.12))
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
