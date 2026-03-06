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
        let record = MileageRecord.manual(odometer: 178000, date: Date())
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        let encoded = try? encoder.encode(record)
        XCTAssertNotNil(encoded)

        if let data = encoded {
            let decoded = try? decoder.decode(MileageRecord.self, from: data)
            XCTAssertNotNil(decoded)
            XCTAssertEqual(decoded?.odometerMiles, 178000)
            XCTAssertEqual(decoded?.source, "MANUAL")
        }
    }

    func testServiceRecordEncoding() {
        let record = ServiceRecord.new(
            serviceType: "Oil & Oil Filter Change",
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
            XCTAssertEqual(decoded?.serviceType, "Oil & Oil Filter Change")
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
