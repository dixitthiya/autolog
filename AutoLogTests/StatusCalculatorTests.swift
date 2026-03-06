import XCTest
@testable import AutoLog

final class StatusCalculatorTests: XCTestCase {

    // MARK: - Mileage-Only Services

    func testOilChange_allGood() {
        let threshold = ServiceThreshold(
            serviceType: "Oil & Oil Filter Change",
            milesCritical: 7000, milesWarning: 5000
        )
        let status = StatusCalculator.calculate(
            serviceType: "Oil & Oil Filter Change",
            threshold: threshold,
            milesSinceService: 3000,
            daysSinceService: 90,
            rotorThickness: nil,
            hasServiceRecord: true
        )
        XCTAssertEqual(status, .allGood)
    }

    func testOilChange_serviceSoon() {
        let threshold = ServiceThreshold(
            serviceType: "Oil & Oil Filter Change",
            milesCritical: 7000, milesWarning: 5000
        )
        let status = StatusCalculator.calculate(
            serviceType: "Oil & Oil Filter Change",
            threshold: threshold,
            milesSinceService: 5500,
            daysSinceService: 120,
            rotorThickness: nil,
            hasServiceRecord: true
        )
        XCTAssertEqual(status, .serviceSoon)
    }

    func testOilChange_critical() {
        let threshold = ServiceThreshold(
            serviceType: "Oil & Oil Filter Change",
            milesCritical: 7000, milesWarning: 5000
        )
        let status = StatusCalculator.calculate(
            serviceType: "Oil & Oil Filter Change",
            threshold: threshold,
            milesSinceService: 7500,
            daysSinceService: 180,
            rotorThickness: nil,
            hasServiceRecord: true
        )
        XCTAssertEqual(status, .critical)
    }

    func testTireRotation_atExactWarning() {
        let threshold = ServiceThreshold(
            serviceType: "Tire Rotation",
            milesCritical: 7000, milesWarning: 5000
        )
        let status = StatusCalculator.calculate(
            serviceType: "Tire Rotation",
            threshold: threshold,
            milesSinceService: 5000,
            daysSinceService: 100,
            rotorThickness: nil,
            hasServiceRecord: true
        )
        XCTAssertEqual(status, .allGood) // > not >=
    }

    func testSparkPlug_critical() {
        let threshold = ServiceThreshold(
            serviceType: "Spark Plug Replacement",
            milesCritical: 90000, milesWarning: 80000
        )
        let status = StatusCalculator.calculate(
            serviceType: "Spark Plug Replacement",
            threshold: threshold,
            milesSinceService: 91000,
            daysSinceService: 1000,
            rotorThickness: nil,
            hasServiceRecord: true
        )
        XCTAssertEqual(status, .critical)
    }

    // MARK: - Mileage + Time Services

    func testEngineAirFilter_criticalByDays() {
        let threshold = ServiceThreshold(
            serviceType: "Engine Air Filter",
            milesCritical: 20000, milesWarning: 15000,
            daysCritical: 365
        )
        let status = StatusCalculator.calculate(
            serviceType: "Engine Air Filter",
            threshold: threshold,
            milesSinceService: 5000,
            daysSinceService: 400,
            rotorThickness: nil,
            hasServiceRecord: true
        )
        XCTAssertEqual(status, .critical)
    }

    func testBrakeFluidFlush_criticalByMiles() {
        let threshold = ServiceThreshold(
            serviceType: "Brake Fluid Flush",
            milesCritical: 30000, milesWarning: 25000,
            daysCritical: 1095
        )
        let status = StatusCalculator.calculate(
            serviceType: "Brake Fluid Flush",
            threshold: threshold,
            milesSinceService: 31000,
            daysSinceService: 100,
            rotorThickness: nil,
            hasServiceRecord: true
        )
        XCTAssertEqual(status, .critical)
    }

    func testCoolantFlush_serviceSoonByDays() {
        let threshold = ServiceThreshold(
            serviceType: "Coolant Flush",
            milesCritical: 50000, milesWarning: 45000,
            daysCritical: 1825, daysWarning: 1460
        )
        let status = StatusCalculator.calculate(
            serviceType: "Coolant Flush",
            threshold: threshold,
            milesSinceService: 10000,
            daysSinceService: 1500,
            rotorThickness: nil,
            hasServiceRecord: true
        )
        XCTAssertEqual(status, .serviceSoon)
    }

    func testThrottleBody_allGood() {
        let threshold = ServiceThreshold(
            serviceType: "Throttle Body Cleaning",
            milesCritical: 40000, milesWarning: 30000,
            daysCritical: 1460, daysWarning: 1095
        )
        let status = StatusCalculator.calculate(
            serviceType: "Throttle Body Cleaning",
            threshold: threshold,
            milesSinceService: 10000,
            daysSinceService: 365,
            rotorThickness: nil,
            hasServiceRecord: true
        )
        XCTAssertEqual(status, .allGood)
    }

    // MARK: - Rotor Services

    func testFrontRotor_allGood() {
        let threshold = ServiceThreshold(
            serviceType: "Front Rotor Thickness Reading",
            rotorCritical: 21.4, rotorWarning: 21.8
        )
        let status = StatusCalculator.calculate(
            serviceType: "Front Rotor Thickness Reading",
            threshold: threshold,
            milesSinceService: 0,
            daysSinceService: 0,
            rotorThickness: 25.0,
            hasServiceRecord: true
        )
        XCTAssertEqual(status, .allGood)
    }

    func testFrontRotor_serviceSoon() {
        let threshold = ServiceThreshold(
            serviceType: "Front Rotor Thickness Reading",
            rotorCritical: 21.4, rotorWarning: 21.8
        )
        let status = StatusCalculator.calculate(
            serviceType: "Front Rotor Thickness Reading",
            threshold: threshold,
            milesSinceService: 0,
            daysSinceService: 0,
            rotorThickness: 21.6,
            hasServiceRecord: true
        )
        XCTAssertEqual(status, .serviceSoon)
    }

    func testFrontRotor_critical() {
        let threshold = ServiceThreshold(
            serviceType: "Front Rotor Thickness Reading",
            rotorCritical: 21.4, rotorWarning: 21.8
        )
        let status = StatusCalculator.calculate(
            serviceType: "Front Rotor Thickness Reading",
            threshold: threshold,
            milesSinceService: 0,
            daysSinceService: 0,
            rotorThickness: 21.0,
            hasServiceRecord: true
        )
        XCTAssertEqual(status, .critical)
    }

    func testRearRotor_atExactWarning() {
        let threshold = ServiceThreshold(
            serviceType: "Rear Rotor Thickness Reading",
            rotorCritical: 8.4, rotorWarning: 8.6
        )
        let status = StatusCalculator.calculate(
            serviceType: "Rear Rotor Thickness Reading",
            threshold: threshold,
            milesSinceService: 0,
            daysSinceService: 0,
            rotorThickness: 8.6,
            hasServiceRecord: true
        )
        XCTAssertEqual(status, .serviceSoon) // <= warning
    }

    // MARK: - No Data

    func testNoServiceRecord() {
        let threshold = ServiceThreshold(
            serviceType: "Oil & Oil Filter Change",
            milesCritical: 7000, milesWarning: 5000
        )
        let status = StatusCalculator.calculate(
            serviceType: "Oil & Oil Filter Change",
            threshold: threshold,
            milesSinceService: 0,
            daysSinceService: 0,
            rotorThickness: nil,
            hasServiceRecord: false
        )
        XCTAssertEqual(status, .noData)
    }

    func testRotor_noThicknessData() {
        let threshold = ServiceThreshold(
            serviceType: "Front Rotor Thickness Reading",
            rotorCritical: 21.4, rotorWarning: 21.8
        )
        let status = StatusCalculator.calculate(
            serviceType: "Front Rotor Thickness Reading",
            threshold: threshold,
            milesSinceService: 0,
            daysSinceService: 0,
            rotorThickness: nil,
            hasServiceRecord: true
        )
        XCTAssertEqual(status, .noData)
    }
}
