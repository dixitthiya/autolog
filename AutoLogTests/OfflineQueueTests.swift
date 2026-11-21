import XCTest
@testable import AutoLog

final class OfflineQueueTests: XCTestCase {

    private let noon = Calendar.current.date(from: DateComponents(year: 2026, month: 11, day: 20, hour: 12))!

    private func resetStorage() {
        UserDefaults.standard.removeObject(forKey: "pendingRecords")
        UserDefaults.standard.removeObject(forKey: "cachedVehicles")
    }

    private func capture(_ vehicleId: String, at date: Date, dist: Double?, odometer: Double? = nil) -> PendingCapture {
        PendingCapture(id: UUID().uuidString, vehicleId: vehicleId, timestamp: date, captureMode: "fg_timer",
                       rpm: 800, odometer: odometer, distSinceCodesCleared: dist, reason: "offline")
    }

    private func logEntry(_ n: Int) -> OBDLogEntry {
        OBDLogEntry(id: "log-\(n)", timestamp: noon, vehicleId: "sonata", eventType: "capture_end",
                    success: false, errorMessage: "queued_offline")
    }

    // MARK: - Mileage math (shared by live capture and replay)

    private func manual(_ odometer: Double, dist: Double?) -> MileageRecord {
        MileageRecord.manual(vehicleId: "v", odometer: odometer, distSinceCodesCleared: dist)
    }

    func testMathReferencePlusDelta() {
        let e = MileageMath.estimate(manualRef: manual(50_000, dist: 1_000), latest: nil, currentDist: 1_250)
        XCTAssertEqual(e.basis, .calculated)
        XCTAssertEqual(e.odometer, 50_250)
        XCTAssertFalse(e.shouldPromptManualEntry)
    }

    func testMathNoReference() {
        let e = MileageMath.estimate(manualRef: nil, latest: nil, currentDist: 1_250)
        XCTAssertEqual(e.basis, .noManualReference)
        XCTAssertTrue(e.shouldPromptManualEntry)
    }

    func testMathNegativeDeltaMeansCodesCleared() {
        let e = MileageMath.estimate(manualRef: manual(50_000, dist: 1_000), latest: nil, currentDist: 10)
        XCTAssertEqual(e.basis, .codesCleared)
        XCTAssertEqual(e.odometer, 50_000)
        XCTAssertTrue(e.shouldPromptManualEntry)
    }

    func testMathNoDistanceNeverRegressesBelowLastKnown() {
        let latest = MileageRecord.bleAuto(vehicleId: "v", odometer: 50_400)
        let e = MileageMath.estimate(manualRef: manual(50_000, dist: 1_000), latest: latest, currentDist: nil)
        XCTAssertEqual(e.basis, .noCurrentDistance)
        XCTAssertEqual(e.odometer, 50_400)
    }

    func testMathReferenceWithoutStoredDistance() {
        let e = MileageMath.estimate(manualRef: manual(50_000, dist: nil), latest: nil, currentDist: 1_250)
        XCTAssertEqual(e.basis, .referenceMissingDist)
        XCTAssertTrue(e.shouldPromptManualEntry)
    }

    // MARK: - Offline error classification

    func testOfflineErrorClassification() {
        XCTAssertTrue(NetworkMonitor.isOfflineError(URLError(.notConnectedToInternet)))
        XCTAssertTrue(NetworkMonitor.isOfflineError(URLError(.timedOut)))
        XCTAssertTrue(NetworkMonitor.isOfflineError(URLError(.networkConnectionLost)))
        XCTAssertFalse(NetworkMonitor.isOfflineError(URLError(.badURL)))
        XCTAssertFalse(NetworkMonitor.isOfflineError(NeonError.httpError(500, "boom")))
        XCTAssertFalse(NetworkMonitor.isOfflineError(NeonError.missingVehicle))
    }

    // MARK: - Queue format

    func testCaptureRecordRoundTrip() throws {
        let c = capture("sonata", at: noon, dist: 4321.5)
        let wrapper = PendingRecord(type: .capture, mileageRecord: nil, serviceRecord: nil,
                                    queueId: "q1", capture: c, queuedAt: noon)
        let data = try JSONEncoder().encode([wrapper])
        let decoded = try JSONDecoder().decode([PendingRecord].self, from: data)
        XCTAssertEqual(decoded.first?.type, .capture)
        XCTAssertEqual(decoded.first?.capture?.vehicleId, "sonata")
        XCTAssertEqual(decoded.first?.capture?.distSinceCodesCleared, 4321.5)
        XCTAssertEqual(decoded.first?.queueId, "q1")
    }

    @MainActor
    func testUnreadableRecordIsSkippedNotFatal() {
        resetStorage()
        defer { resetStorage() }
        // A legacy mileage record, a record type this build doesn't know, another legacy record.
        let json = """
        [
          {"type":"mileage","retryCount":1,"queueId":"a",
           "mileageRecord":{"id":"m1","timestamp":700000000,"odometerMiles":100,"source":"BLE_AUTO"}},
          {"type":"from_the_future","retryCount":0,"queueId":"b"},
          {"type":"mileage","retryCount":0,"queueId":"c",
           "mileageRecord":{"id":"m2","timestamp":700000100,"odometerMiles":101,"source":"BLE_AUTO"}}
        ]
        """
        UserDefaults.standard.set(Data(json.utf8), forKey: "pendingRecords")

        SyncManager.shared.queueMileageRecord(MileageRecord.manual(vehicleId: "v", odometer: 5))

        let ids = SyncManager.shared.visibleRecords.compactMap { $0.queueId }
        XCTAssertEqual(ids.count, 3)
        XCTAssertTrue(ids.contains("a"))
        XCTAssertTrue(ids.contains("c"))
        XCTAssertFalse(ids.contains("b"))
    }

    // MARK: - Queueing rules

    @MainActor
    func testOneQueuedCapturePerCarPerDay() {
        resetStorage()
        defer { resetStorage() }
        let sync = SyncManager.shared

        sync.queueCapture(capture("sonata", at: noon, dist: 100))
        sync.queueCapture(capture("sonata", at: noon.addingTimeInterval(600), dist: 120))   // replaces
        sync.queueCapture(capture("elantra", at: noon, dist: 5))                            // other car
        sync.queueCapture(capture("sonata", at: noon.addingTimeInterval(86_400), dist: 130)) // other day

        let captures = sync.visibleRecords.compactMap { $0.capture }
        XCTAssertEqual(captures.count, 3)
        let sonataToday = captures.first { $0.vehicleId == "sonata" && Calendar.current.isDate($0.timestamp, inSameDayAs: noon) }
        XCTAssertEqual(sonataToday?.distSinceCodesCleared, 120)
    }

    @MainActor
    func testNewerCaptureWithNoDataDoesNotDisplaceOlderOne() {
        resetStorage()
        defer { resetStorage() }
        let sync = SyncManager.shared

        sync.queueCapture(capture("sonata", at: noon, dist: 100))
        sync.queueCapture(capture("sonata", at: noon.addingTimeInterval(600), dist: nil))

        let captures = sync.visibleRecords.compactMap { $0.capture }
        XCTAssertEqual(captures.count, 1)
        XCTAssertEqual(captures.first?.distSinceCodesCleared, 100)
    }

    @MainActor
    func testQueuedLogsAreCappedAndNeverDisplaceData() {
        resetStorage()
        defer { resetStorage() }
        let sync = SyncManager.shared

        sync.queueCapture(capture("sonata", at: noon, dist: 100))
        for n in 1...(SyncManager.maxQueuedLogs + 10) {
            sync.queueLog(logEntry(n))
        }

        // The data record is still there, and the log rows are the newest 25.
        XCTAssertEqual(sync.visibleRecords.count, 1)
        XCTAssertEqual(sync.pendingCount, 1)
        let data = UserDefaults.standard.data(forKey: "pendingRecords") ?? Data()
        let all = (try? JSONDecoder().decode([PendingRecord].self, from: data)) ?? []
        let logs = all.compactMap { $0.log }
        XCTAssertEqual(logs.count, SyncManager.maxQueuedLogs)
        XCTAssertEqual(logs.first?.id, "log-11")
        XCTAssertEqual(logs.last?.id, "log-\(SyncManager.maxQueuedLogs + 10)")
    }

    // MARK: - Vehicle cache

    func testVehicleCacheFindsByVINAndKeepsStatus() {
        resetStorage()
        defer { resetStorage() }
        let sonata = Vehicle.new(vin: "5NPE24AF0JH123456", make: "Hyundai", year: 2018)
        VehicleCache.upsert(sonata)

        XCTAssertEqual(VehicleCache.vehicle(vin: "5npe24af0jh123456")?.id, sonata.id)
        XCTAssertNil(VehicleCache.vehicle(vin: "KMHD841C3DU123456"))

        var retired = sonata
        retired.status = .retired
        VehicleCache.upsert(retired)
        XCTAssertEqual(VehicleCache.load().count, 1)
        XCTAssertEqual(VehicleCache.vehicle(vin: sonata.vin!)?.status, .retired)
    }
}
