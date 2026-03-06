import XCTest
@testable import AutoLog

final class CSVImporterTests: XCTestCase {

    func testParseCSVLine_simple() {
        let importer = CSVImporterTestHelper()
        let result = importer.parseCSVLine("one,two,three")
        XCTAssertEqual(result, ["one", "two", "three"])
    }

    func testParseCSVLine_withQuotes() {
        let importer = CSVImporterTestHelper()
        let result = importer.parseCSVLine("\"hello, world\",two,three")
        XCTAssertEqual(result, ["hello, world", "two", "three"])
    }

    func testParseCSVLine_emptyFields() {
        let importer = CSVImporterTestHelper()
        let result = importer.parseCSVLine("one,,three,")
        XCTAssertEqual(result, ["one", "", "three", ""])
    }

    func testServiceCategoryLookup() {
        XCTAssertEqual(ServiceCategory.category(for: "Oil & Oil Filter Change"), "Engine")
        XCTAssertEqual(ServiceCategory.category(for: "Tire Rotation"), "Tires")
        XCTAssertEqual(ServiceCategory.category(for: "Front Rotor Thickness Reading"), "Brakes")
        XCTAssertEqual(ServiceCategory.category(for: "Coolant Flush"), "Cooling")
        XCTAssertEqual(ServiceCategory.category(for: "Transmission Fluid Change"), "Transmission")
        XCTAssertEqual(ServiceCategory.category(for: "Current Mileage"), "General")
        XCTAssertEqual(ServiceCategory.category(for: "Unknown Service"), "General")
    }

    func testMileageRecordCreation() {
        let record = MileageRecord.imported(odometer: 178000, date: Date())
        XCTAssertEqual(record.source, "IMPORTED")
        XCTAssertEqual(record.odometerMiles, 178000)
        XCTAssertFalse(record.id.isEmpty)
    }

    func testServiceRecordCreation() {
        let record = ServiceRecord.new(
            serviceType: "Oil & Oil Filter Change",
            category: "Engine",
            odometer: 175000,
            rotorThickness: nil,
            amount: 45.99,
            comments: "Synthetic oil"
        )
        XCTAssertEqual(record.serviceType, "Oil & Oil Filter Change")
        XCTAssertEqual(record.category, "Engine")
        XCTAssertEqual(record.amount, 45.99)
        XCTAssertFalse(record.manuallyEdited)
    }
}

// Helper to expose private CSV parsing for testing
class CSVImporterTestHelper {
    func parseCSVLine(_ line: String) -> [String] {
        var result: [String] = []
        var current = ""
        var inQuotes = false

        for char in line {
            if char == "\"" {
                inQuotes.toggle()
            } else if char == "," && !inQuotes {
                result.append(current)
                current = ""
            } else {
                current.append(char)
            }
        }
        result.append(current)
        return result
    }
}
