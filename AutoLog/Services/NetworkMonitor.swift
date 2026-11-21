import Foundation
import Network

/// Is the phone online? Used to skip database calls that would only time out,
/// and to sync the offline queue as soon as the network comes back.
///
/// The path status is only a hint (it can lag, or say "online" behind a dead
/// Wi-Fi). Anything that actually fails is still classified from its error with
/// `isOfflineError`, which is what decides whether a capture gets queued.
@MainActor
final class NetworkMonitor: ObservableObject {
    static let shared = NetworkMonitor()

    /// Assumed online until the system says otherwise.
    @Published private(set) var isOnline = true

    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "autolog.network-monitor")

    private init() {
        monitor.pathUpdateHandler = { [weak self] path in
            let online = path.status == .satisfied
            Task { @MainActor in self?.update(online: online) }
        }
        monitor.start(queue: queue)
    }

    /// Touch the singleton so the monitor is running.
    func start() {}

    private func update(online: Bool) {
        let wasOnline = isOnline
        isOnline = online
        guard online, !wasOnline else { return }
        Log.sync("network restored")
        Task { await Self.recoverAfterReconnect() }
    }

    /// Back online: confirm the migration if it never was, refresh the cars,
    /// then replay whatever was queued while offline.
    private static func recoverAfterReconnect() async {
        // Give the connection a moment to become usable.
        try? await Task.sleep(nanoseconds: 1_000_000_000)
        try? await NeonRepository.shared.ensureMultiCarReady()
        await VehicleStore.shared.reload()
        await ServiceCategory.loadFromDB()
        await SyncManager.shared.syncAll()
        await VehicleStore.shared.refreshUnassignedCount()
    }

    /// True when `error` means "couldn't reach the database" rather than "the
    /// database said no". Only these are worth queueing for a later retry.
    nonisolated static func isOfflineError(_ error: Error) -> Bool {
        guard let urlError = error as? URLError else { return false }
        switch urlError.code {
        case .notConnectedToInternet, .networkConnectionLost, .timedOut,
             .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed,
             .dataNotAllowed, .internationalRoamingOff, .callIsActive:
            return true
        default:
            return false
        }
    }
}
