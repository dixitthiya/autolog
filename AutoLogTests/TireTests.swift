import XCTest
@testable import AutoLog

final class TireTests: XCTestCase {

    private func makeTire(install: Double, removed: Double? = nil, pos: TirePosition? = .FL) -> Tire {
        Tire(
            id: "t1",
            position: pos,
            makeModel: "Yokohama",
            installOdometer: install,
            installDate: Date(timeIntervalSince1970: 1_700_000_000),
            removedOdometer: removed,
            removedDate: removed == nil ? nil : Date(),
            replacesTireId: nil,
            notes: nil
        )
    }

    // MARK: - Mileage

    func testActiveTireMileage() {
        let t = makeTire(install: 178_400)
        XCTAssertEqual(t.miles(currentOdometer: 186_894), 8_494)
    }

    func testRetiredTireUsesRemovedOdometer() {
        // Once retired, mileage is frozen at removal regardless of current odometer.
        let t = makeTire(install: 164_796, removed: 186_894)
        XCTAssertEqual(t.miles(currentOdometer: 250_000), 22_098)
    }

    func testMileageFlooredAtZero() {
        // A brand-new tire installed at the current odometer reads 0, never negative.
        let t = makeTire(install: 190_000)
        XCTAssertEqual(t.miles(currentOdometer: 186_894), 0)
    }

    func testIsActiveReflectsRemoval() {
        XCTAssertTrue(makeTire(install: 100).isActive)
        XCTAssertFalse(makeTire(install: 100, removed: 200).isActive)
    }

    // MARK: - Rotation mapping

    func testRearwardCrossMapping() {
        let m = RotationPattern.rearwardCross.mapping
        XCTAssertEqual(m[.FL], .RL)
        XCTAssertEqual(m[.FR], .RR)
        XCTAssertEqual(m[.RR], .FL)
        XCTAssertEqual(m[.RL], .FR)
    }

    func testRotationPatternStringInCornerOrder() {
        XCTAssertEqual(RotationPattern.rearwardCross.patternString, "FL>RL, FR>RR, RL>FR, RR>FL")
    }

    func testEveryPatternIsABijection() {
        // A rotation must be a permutation of the four corners — no corner lost or doubled.
        for pattern in RotationPattern.allCases {
            let destinations = Set(TirePosition.allCases.map { pattern.mapping[$0] ?? $0 })
            XCTAssertEqual(destinations.count, 4, "\(pattern.rawValue) is not a bijection")
        }
    }

    // MARK: - Codable

    func testTireCodableRoundTrip() {
        let t = makeTire(install: 186_894)
        guard let data = try? JSONEncoder().encode(t),
              let decoded = try? JSONDecoder().decode(Tire.self, from: data) else {
            return XCTFail("encode/decode failed")
        }
        XCTAssertEqual(decoded.installOdometer, 186_894)
        XCTAssertEqual(decoded.position, .FL)
        XCTAssertEqual(decoded.makeModel, "Yokohama")
    }
}
