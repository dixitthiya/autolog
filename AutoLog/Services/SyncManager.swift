import Foundation

@MainActor
class SyncManager: ObservableObject {
    static let shared = SyncManager()

    @Published var pendingCount = 0
    @Published var failedCount = 0

    private let pendingKey = "pendingRecords"
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    private init() {
        loadCounts()
    }

    private func loadCounts() {
        let pending = getPendingRecords()
        pendingCount = pending.count
        failedCount = pending.filter { $0.retryCount > Config.maxRetryCount }.count
    }

    func queueMileageRecord(_ record: MileageRecord) {
        var pending = getPendingRecords()
        let wrapper = PendingRecord(type: .mileage, mileageRecord: record, serviceRecord: nil)
        pending.append(wrapper)
        savePendingRecords(pending)
        Log.sync("\(pending.count) pending records (added mileage)")
    }

    func queueServiceRecord(_ record: ServiceRecord) {
        var pending = getPendingRecords()
        let wrapper = PendingRecord(type: .service, mileageRecord: nil, serviceRecord: record)
        pending.append(wrapper)
        savePendingRecords(pending)
        Log.sync("\(pending.count) pending records (added service)")
    }

    func queueUnassignedReading(_ reading: UnassignedReading) {
        var pending = getPendingRecords()
        let wrapper = PendingRecord(type: .unassigned, mileageRecord: nil, serviceRecord: nil, unassignedReading: reading)
        pending.append(wrapper)
        savePendingRecords(pending)
        Log.sync("\(pending.count) pending records (added unassigned reading)")
    }

    func syncAll() async {
        var pending = getPendingRecords()
        guard !pending.isEmpty else { return }

        Log.sync("\(pending.count) pending records found")
        var synced: [Int] = []

        for (i, record) in pending.enumerated() {
            guard record.retryCount <= Config.maxRetryCount else { continue }

            do {
                // The car was stamped when the record was queued; only records
                // queued before multi-car have none, and those are the Elantra's.
                switch record.type {
                case .mileage:
                    if let mr = record.mileageRecord {
                        try await NeonRepository.shared.saveMileageRecord(mr.withLegacyVehicleIfMissing())
                    }
                case .service:
                    if let sr = record.serviceRecord {
                        try await NeonRepository.shared.saveServiceRecord(sr.withLegacyVehicleIfMissing())
                    }
                case .unassigned:
                    if let ur = record.unassignedReading {
                        try await NeonRepository.shared.saveUnassignedReading(ur)
                    }
                }
                synced.append(i)
                Log.sync("record synced successfully")
            } catch {
                pending[i].retryCount += 1
                Log.sync("retry \(pending[i].retryCount) failed: \(error.localizedDescription)")
            }
        }

        for i in synced.reversed() {
            pending.remove(at: i)
        }

        savePendingRecords(pending)
    }

    private func getPendingRecords() -> [PendingRecord] {
        guard let data = UserDefaults.standard.data(forKey: pendingKey) else { return [] }
        return (try? decoder.decode([PendingRecord].self, from: data)) ?? []
    }

    private func savePendingRecords(_ records: [PendingRecord]) {
        if let data = try? encoder.encode(records) {
            UserDefaults.standard.set(data, forKey: pendingKey)
        }
        loadCounts()
    }
}

/// Stored as JSON in UserDefaults. New fields must stay optional so queues
/// written by older builds still decode.
struct PendingRecord: Codable {
    enum RecordType: String, Codable { case mileage, service, unassigned }
    let type: RecordType
    let mileageRecord: MileageRecord?
    let serviceRecord: ServiceRecord?
    var unassignedReading: UnassignedReading? = nil
    var retryCount: Int = 0
}
