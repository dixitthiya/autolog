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
            .onReceive(NotificationCenter.default.publisher(for: UIApplication.willEnterForegroundNotification)) { _ in
                Task {
                    await syncManager.syncAll()
                    // Try to connect when app comes to foreground
                    if bleManager.connectionState == .disconnected {
                        bleManager.startScanning()
                    }
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

        // Sync pending records
        await syncManager.syncAll()
    }
}

struct ContentView: View {
    @StateObject private var syncManager = SyncManager.shared

    var body: some View {
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

            AnalyticsView()
                .tabItem {
                    Label("Analytics", systemImage: "chart.xyaxis.line")
                }
        }
    }
}
