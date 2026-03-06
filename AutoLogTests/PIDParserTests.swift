import XCTest
@testable import AutoLog

final class PIDParserTests: XCTestCase {

    // MARK: - RPM Tests (PID 010C)

    func testParseRPM_normalResponse() {
        // 41 0C 0C 44 → RPM = ((12 * 256) + 68) / 4 = (3072 + 68) / 4 = 785
        let rpm = PIDParser.parseRPM("41 0C 0C 44")
        XCTAssertEqual(rpm, 785)
    }

    func testParseRPM_idle() {
        // 41 0C 03 20 → RPM = ((3 * 256) + 32) / 4 = 200
        let rpm = PIDParser.parseRPM("41 0C 03 20")
        XCTAssertEqual(rpm, 200)
    }

    func testParseRPM_zero() {
        let rpm = PIDParser.parseRPM("41 0C 00 00")
        XCTAssertEqual(rpm, 0)
    }

    func testParseRPM_invalidResponse() {
        let rpm = PIDParser.parseRPM("NO DATA")
        XCTAssertEqual(rpm, 0)
    }

    func testParseRPM_noSpaces() {
        let rpm = PIDParser.parseRPM("410C0C44")
        XCTAssertEqual(rpm, 785)
    }

    // MARK: - Odometer Tests (PID 01A6)

    func testParseOdometer_normalResponse() {
        // 41 A6 B0 5E → km = (176 * 256 + 94) = 45150 → miles = 45150 * 0.621371 ≈ 28054
        let miles = PIDParser.parseOdometer("41 A6 B0 5E")
        XCTAssertEqual(Int(miles), 28054)
    }

    func testParseOdometer_zero() {
        let miles = PIDParser.parseOdometer("41 A6 00 00")
        XCTAssertEqual(miles, 0.0)
    }

    func testParseOdometer_noData() {
        let miles = PIDParser.parseOdometer("NO DATA")
        XCTAssertEqual(miles, 0.0)
    }

    func testParseOdometer_error() {
        let miles = PIDParser.parseOdometer("ERROR")
        XCTAssertEqual(miles, 0.0)
    }

    // MARK: - Speed Tests (PID 010D)

    func testParseSpeed_normalResponse() {
        // 41 0D 3C → speed = 60 kph
        let speed = PIDParser.parseSpeed("41 0D 3C")
        XCTAssertEqual(speed, 60)
    }

    func testParseSpeed_zero() {
        let speed = PIDParser.parseSpeed("41 0D 00")
        XCTAssertEqual(speed, 0)
    }

    // MARK: - Distance Accumulation

    func testAccumulateDistance() {
        // 60 kph for 0.5 hours = 30 km = 18.64 miles
        let miles = PIDParser.accumulateDistance(speedKPH: 60, deltaTimeHours: 0.5)
        XCTAssertEqual(miles, 30.0 * 0.621371, accuracy: 0.01)
    }

    // MARK: - Byte Extraction

    func testExtractBytes_withSpaces() {
        let bytes = PIDParser.extractBytes(from: "41 0C 0C 44", expectedPrefix: "41 0C")
        XCTAssertEqual(bytes, [0x0C, 0x44])
    }

    func testExtractBytes_noSpaces() {
        let bytes = PIDParser.extractBytes(from: "410C0C44", expectedPrefix: "410C")
        XCTAssertEqual(bytes, [0x0C, 0x44])
    }

    func testExtractBytes_invalidPrefix() {
        let bytes = PIDParser.extractBytes(from: "41 0D 3C", expectedPrefix: "41 0C")
        XCTAssertEqual(bytes, [])
    }
}
