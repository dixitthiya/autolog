import SwiftUI

/// What is saved on this phone waiting to sync. Read-only apart from "Sync now".
struct QueuedRecordsView: View {
    @ObservedObject private var syncManager = SyncManager.shared
    @ObservedObject private var vehicleStore = VehicleStore.shared
    @ObservedObject private var network = NetworkMonitor.shared

    var body: some View {
        List {
            Section {
                Button {
                    Task { await syncManager.syncAll() }
                } label: {
                    HStack {
                        Label("Sync now", systemImage: "arrow.clockwise")
                        Spacer()
                        if syncManager.isSyncing {
                            ProgressView().controlSize(.small)
                        }
                    }
                }
                .disabled(syncManager.isSyncing)
            } footer: {
                if !network.isOnline {
                    Text("Offline — these will sync when the network is back.")
                }
            }

            Section {
                if syncManager.visibleRecords.isEmpty {
                    Text("Nothing waiting")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(syncManager.visibleRecords) { record in
                        row(record)
                    }
                }
            }
        }
        .navigationTitle("Waiting to Sync")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func row(_ record: PendingRecord) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(vehicleName(for: record))
                    .font(.subheadline.bold())
                Spacer()
                Text(record.kindLabel)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let time = record.eventTime {
                Text(Fmt.dateTime(time))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if record.retryCount > Config.maxRetryCount {
                Text("Needs attention")
                    .font(.caption.bold())
                    .foregroundStyle(.red)
            } else {
                Text("Will retry automatically")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let error = record.lastError, !error.isEmpty {
                Text(Self.friendly(error))
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 2)
    }

    /// Plain wording for the reasons the sync code records.
    private static func friendly(_ reason: String) -> String {
        if reason == "Offline" { return "Waiting for a connection" }
        if reason.localizedCaseInsensitiveContains("migration") { return "Waiting for the database to be ready" }
        return reason
    }

    private func vehicleName(for record: PendingRecord) -> String {
        guard let id = record.vehicleId else { return "Unidentified car" }
        return vehicleStore.vehicles.first(where: { $0.id == id })?.displayName ?? "Unknown car"
    }
}
