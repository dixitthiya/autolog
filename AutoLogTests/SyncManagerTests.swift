import XCTest
@testable import AutoLog

final class SyncManagerTests: XCTestCase {

    override func setUp() {
        super.setUp()
        UserDefaults.standard.removeObject(forKey: "pendingRecords")
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: "pendingRecords")
        super.tearDown()
    }

    func testPendingRecordEncoding() {
        let record = MileageRecord.manual(vehicleId: "v1", odometer: 178000, date: Date())
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        let encoded = try? encoder.encode(record)
        XCTAssertNotNil(encoded)

        if let data = encoded {
            let decoded = try? decoder.decode(MileageRecord.self, from: data)
            XCTAssertNotNil(decoded)
            XCTAssertEqual(decoded?.odometerMiles, 178000)
            XCTAssertEqual(decoded?.source, "MANUAL")
            XCTAssertEqual(decoded?.vehicleId, "v1")
        }
    }

    // MARK: - Queue written by a pre-multi-car build

    /// Exactly what an older build stored: no vehicleId, no unassignedReading.
    private let legacyQueueJSON = """
    [
      {"type":"mileage","retryCount":2,
       "mileageRecord":{"id":"m1","timestamp":700000000,"odometerMiles":186900,"source":"BLE_AUTO","distSinceCodesCleared":4321.5}},
      {"type":"service","retryCount":0,
       "serviceRecord":{"id":"s1","timestamp":700000000,"serviceType":"Tire Rotation","category":"Tires",
                        "odometerMiles":186000,"manuallyEdited":false}}
    ]
    """

    func testLegacyQueueStillDecodes() throws {
        let records = try JSONDecoder().decode([PendingRecord].self, from: Data(legacyQueueJSON.utf8))
        XCTAssertEqual(records.count, 2)
        XCTAssertEqual(records[0].type, .mileage)
        XCTAssertEqual(records[0].retryCount, 2)
        XCTAssertNil(records[0].mileageRecord?.vehicleId)
        XCTAssertNil(records[0].unassignedReading)
        XCTAssertEqual(records[1].type, .service)
        XCTAssertNil(records[1].serviceRecord?.vehicleId)
    }

    func testLegacyRecordsReplayAsElantra() throws {
        let records = try JSONDecoder().decode([PendingRecord].self, from: Data(legacyQueueJSON.utf8))
        let mileage = try XCTUnwrap(records[0].mileageRecord).withLegacyVehicleIfMissing()
        let service = try XCTUnwrap(records[1].serviceRecord).withLegacyVehicleIfMissing()
        XCTAssertEqual(mileage.vehicleId, Vehicle.elantraId)
        XCTAssertEqual(mileage.odometerMiles, 186900)
        XCTAssertEqual(mileage.distSinceCodesCleared, 4321.5)
        XCTAssertEqual(service.vehicleId, Vehicle.elantraId)
        XCTAssertEqual(service.serviceType, "Tire Rotation")
    }

    func testStampedRecordKeepsItsCarOnReplay() {
        let record = MileageRecord.bleAuto(vehicleId: "sonata", odometer: 50_000)
        XCTAssertEqual(record.withLegacyVehicleIfMissing().vehicleId, "sonata")
    }

    func testUnassignedReadingRoundTrip() throws {
        let reading = UnassignedReading(id: "u1", timestamp: Date(), failureReason: "vin_timeout",
                                        peripheralId: "P", captureMode: "bg_auto", rpm: 800,
                                        distSinceCodesCleared: 1234)
        let wrapper = PendingRecord(type: .unassigned, mileageRecord: nil, serviceRecord: nil, unassignedReading: reading)
        let data = try JSONEncoder().encode([wrapper])
        let decoded = try JSONDecoder().decode([PendingRecord].self, from: data)
        XCTAssertEqual(decoded.first?.type, .unassigned)
        XCTAssertEqual(decoded.first?.unassignedReading?.failureReason, "vin_timeout")
        XCTAssertEqual(decoded.first?.unassignedReading?.distSinceCodesCleared, 1234)
    }

    func testServiceRecordEncoding() {
        let record = ServiceRecord.new(
            vehicleId: "v1",
            serviceType: "Engine Oil & Filter Change",
            category: "Engine",
            odometer: 175000,
            amount: 45.99,
            comments: "Test"
        )
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        let encoded = try? encoder.encode(record)
        XCTAssertNotNil(encoded)

        if let data = encoded {
            let decoded = try? decoder.decode(ServiceRecord.self, from: data)
            XCTAssertNotNil(decoded)
            XCTAssertEqual(decoded?.serviceType, "Engine Oil & Filter Change")
            XCTAssertEqual(decoded?.amount, 45.99)
        }
    }

    func testMaxRetryCount() {
        XCTAssertEqual(Config.maxRetryCount, 10)
    }

    func testURLSessionTimeout() {
        XCTAssertEqual(Config.urlSessionTimeout, 8)
    }

    func testServiceStatusSorting() {
        let statuses: [ServiceStatus] = [.allGood, .critical, .noData, .serviceSoon]
        let sorted = statuses.sorted()
        XCTAssertEqual(sorted, [.critical, .serviceSoon, .allGood, .noData])
    }

    func testServiceStatusLabels() {
        XCTAssertEqual(ServiceStatus.critical.label, "Critical - Immediate Service Required")
        XCTAssertEqual(ServiceStatus.serviceSoon.label, "Service Soon - Inspect Symptoms/Parts")
        XCTAssertEqual(ServiceStatus.allGood.label, "All Good")
        XCTAssertEqual(ServiceStatus.noData.label, "No Data")
    }
}
