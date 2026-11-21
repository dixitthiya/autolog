import SwiftUI
import UserNotifications
import Combine

@main
struct AutoLogApp: App {
    @StateObject private var bleManager = BLEManager.shared
    @StateObject private var mileageService = MileageService.shared
    @StateObject private var syncManager = SyncManager.shared
    @State private var showImport = !CSVImporter.hasImported
    @State private var isInitialized = false

    var body: some Scene {
        WindowGroup {
            Group {
                if showImport {
                    CSVImportView(showImport: $showImport)
                } else {
                    ContentView()
                }
            }
            .task {
                guard !isInitialized else { return }
                isInitialized = true
                NetworkMonitor.shared.start()
                await initialize()
                // Start background auto-scan cycle
                bleManager.startAutoScanCycle()
            }
            .onChange(of: bleManager.connectionState) { _, newState in
                if newState == .ready {
                    Task {
                        await mileageService.onBLEConnected(bleManager: bleManager)
                    }
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: UIApplication.didEnterBackgroundNotification)) { _ in
                // No background captures: don't leave a connect pending for iOS to complete later
                Task { @MainActor in
                    bleManager.cancelPendingConnectionForBackground()
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: UIApplication.willEnterForegroundNotification)) { _ in
                Task {
                    // If the migration was never confirmed (a launch with no
                    // network), confirm it now instead of waiting for a relaunch.
                    if NetworkMonitor.shared.isOnline {
                        let wasReady = await NeonRepository.shared.isMultiCarReady
                        try? await NeonRepository.shared.ensureMultiCarReady()
                        if !wasReady { await VehicleStore.shared.reload() }
                    }
                    await syncManager.syncAll()
                    // Clear throttle on foreground — always try fresh
                    mileageService.clearSkipThrottle()
                    bleManager.captureMode = "fg_resume"
                    if bleManager.connectionState == .disconnected {
                        bleManager.connectOrScan(trigger: "fg_resume")
                    }
                    // For the "Unassigned (N)" entry in the car menu
                    await VehicleStore.shared.refreshUnassignedCount()
                }
            }
        }
    }

    private func initialize() async {
        // Request notification permission
        do {
            let granted = try await UNUserNotificationCenter.current()
                .requestAuthorization(options: [.alert, .sound, .badge])
            Log.notify("notification permission: \(granted)")
        } catch {
            Log.notify("notification request failed: \(error.localizedDescription)")
        }

        // Initialize database schema
        do {
            try await NeonRepository.shared.initializeSchema()
        } catch {
            Log.db("schema init failed: \(error.localizedDescription)")
        }

        // Load cars so every screen knows which car it is showing
        await VehicleStore.shared.reload()

        // Load service categories from DB
        await ServiceCategory.loadFromDB()

        // Sync pending records
        await syncManager.syncAll()

        // For the "Unassigned (N)" entry in the car menu (after the sync, which may add some)
        await VehicleStore.shared.refreshUnassignedCount()

        // Schedule service reminder notifications
        await ServiceReminderScheduler.reschedule()
    }
}

struct ContentView: View {
    @StateObject private var syncManager = SyncManager.shared
    @ObservedObject private var mileageService = MileageService.shared
    @ObservedObject private var vehicleStore = VehicleStore.shared
    @ObservedObject private var bleManager = BLEManager.shared

    /// Brief note at the top, e.g. "Switched to 2018 Hyundai Sonata (plugged in)".
    @State private var toast: String?
    /// A retired car the adapter just connected to, offered for reactivation.
    @State private var retiredPrompt: Vehicle?

    var body: some View {
        tabs
            .onChange(of: mileageService.lastCaptureEnd) { _, event in
                if let event { captureEnded(event) }
            }
            .overlay(alignment: .top) {
                if let toast {
                    Text(toast)
                        .font(.footnote.weight(.semibold))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(.regularMaterial, in: Capsule())
                        .shadow(color: .black.opacity(0.12), radius: 6, y: 2)
                        .padding(.top, 4)
                        .transition(.move(edge: .top).combined(with: .opacity))
                        .allowsHitTesting(false)
                }
            }
            .animation(.easeInOut(duration: 0.25), value: toast)
            .sheet(item: $vehicleStore.carMenuSheet) { which in
                switch which {
                case .vehicles:
                    VehiclesView()
                case .intervals:
                    if let vehicleId = vehicleStore.viewedVehicleId {
                        ServiceIntervalsView(vehicleId: vehicleId)
                    }
                case .unassigned:
                    UnassignedReadingsView()
                }
            }
            .alert(
                "\(retiredPrompt?.displayName ?? "This car") is retired",
                isPresented: Binding(get: { retiredPrompt != nil }, set: { if !$0 { retiredPrompt = nil } }),
                presenting: retiredPrompt
            ) { car in
                Button("Reactivate") { Task { await reactivate(car) } }
                Button("Not now", role: .cancel) {}
            } message: { _ in
                Text("Reactivate it to record mileage?")
            }
    }

    /// React to how a capture ended — UI only; the capture itself is already done.
    private func captureEnded(_ event: MileageService.CaptureEndEvent) {
        guard UIApplication.shared.applicationState == .active, let vehicleId = event.vehicleId else { return }
        switch event.outcome {
        case "saved", "updated":
            // Show the car that was just captured, if it isn't the one on screen.
            guard vehicleId != vehicleStore.viewedVehicleId else { return }
            vehicleStore.selectedVehicleId = vehicleId
            let name = vehicleStore.vehicle(id: vehicleId)?.displayName ?? "the plugged-in car"
            showToast("Switched to \(name) (plugged in)")
        case "skipped_retired_vehicle":
            // One prompt per connection; don't stack a second one on top.
            guard retiredPrompt == nil else { return }
            retiredPrompt = vehicleStore.vehicle(id: vehicleId)
                ?? vehicleStore.connectedVehicle.flatMap { $0.id == vehicleId ? $0 : nil }
        default:
            break
        }
    }

    /// Same path as the Vehicles screen (status, car list, offline cache,
    /// reminders), then a capture as if the Dashboard's Capture button was tapped.
    private func reactivate(_ car: Vehicle) async {
        var active = car
        active.status = .active
        do {
            try await NeonRepository.shared.setVehicleStatus(id: car.id, status: .active)
            await vehicleStore.vehicleDidChange(active)
        } catch {
            showToast("Couldn't reactivate \(car.displayName): \(error.localizedDescription)")
            return
        }
        guard !mileageService.isReading else { return }
        bleManager.captureMode = "dashboard_button"
        bleManager.connectOrScan(trigger: "dashboard_button")
    }

    private func showToast(_ message: String) {
        toast = message
        Task {
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            if toast == message { toast = nil }
        }
    }

    private var tabs: some View {
        TabView {
            DashboardView()
                .tabItem {
                    Label("Dashboard", systemImage: "gauge.open.with.lines.needle.33percent")
                }

            MileageHistoryView()
                .tabItem {
                    Label("Mileage", systemImage: "speedometer")
                }

            MaintenanceView()
                .tabItem {
                    Label("Maintenance", systemImage: "wrench.and.screwdriver")
                }
                .badge(syncManager.failedCount > 0 ? syncManager.failedCount : 0)

            TiresView()
                .tabItem {
                    Label("Tires", systemImage: "circle.grid.2x2")
                }

            AnalyticsView()
                .tabItem {
                    Label("Analytics", systemImage: "chart.xyaxis.line")
                }
        }
    }
}
