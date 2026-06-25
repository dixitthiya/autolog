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

    // MARK: - Manual corner change (swap)

    private func active() -> [Tire] {
        [
            Tire(id: "fl", position: .FL, makeModel: "A", installOdometer: 100, installDate: Date(), removedOdometer: nil, removedDate: nil, replacesTireId: nil, notes: nil),
            Tire(id: "fr", position: .FR, makeModel: "B", installOdometer: 100, installDate: Date(), removedOdometer: nil, removedDate: nil, replacesTireId: nil, notes: nil),
            Tire(id: "rl", position: .RL, makeModel: "C", installOdometer: 100, installDate: Date(), removedOdometer: nil, removedDate: nil, replacesTireId: nil, notes: nil),
            Tire(id: "rr", position: .RR, makeModel: "D", installOdometer: 100, installDate: Date(), removedOdometer: nil, removedDate: nil, replacesTireId: nil, notes: nil),
        ]
    }

    func testMoveToOccupiedCornerSwaps() {
        // Moving RL onto FL must push the FL tire back to RL — never two at FL.
        let updates = TireMove.resolve(activeTires: active(), moving: "rl", to: .FL)
        XCTAssertEqual(updates, [
            TireMove.Update(id: "fl", position: .RL),
            TireMove.Update(id: "rl", position: .FL),
        ])
    }

    func testMoveToEmptyCornerJustMoves() {
        // FL empty (only rl active here): moving onto it displaces nobody.
        let tires = [active()[2]] // just rl @ RL
        let updates = TireMove.resolve(activeTires: tires, moving: "rl", to: .FL)
        XCTAssertEqual(updates, [TireMove.Update(id: "rl", position: .FL)])
    }

    func testMoveToSameCornerIsNoSwap() {
        let updates = TireMove.resolve(activeTires: active(), moving: "fl", to: .FL)
        XCTAssertEqual(updates, [TireMove.Update(id: "fl", position: .FL)])
    }

    func testMoveToNoneUnassignsOnly() {
        let updates = TireMove.resolve(activeTires: active(), moving: "fl", to: nil)
        XCTAssertEqual(updates, [TireMove.Update(id: "fl", position: nil)])
    }

    func testUnknownTireProducesNoUpdates() {
        XCTAssertTrue(TireMove.resolve(activeTires: active(), moving: "ghost", to: .FL).isEmpty)
    }

    // MARK: - Codable

    // MARK: - Tread depth

    func testTreadLabelWhole() {
        XCTAssertEqual((8.0).treadLabel, "8/32")
        XCTAssertEqual((11.0).treadLabel, "11/32")
    }

    func testTreadLabelFractional() {
        XCTAssertEqual((7.5).treadLabel, "7.5/32")
    }

    func testTreadReadingCodableRoundTrip() {
        let r = TireTreadReading.new(tireId: "t1", odometer: 186_894, date: Date(timeIntervalSince1970: 1_700_000_000), depth32nds: 9)
        guard let data = try? JSONEncoder().encode(r),
              let decoded = try? JSONDecoder().decode(TireTreadReading.self, from: data) else {
            return XCTFail("encode/decode failed")
        }
        XCTAssertEqual(decoded.tireId, "t1")
        XCTAssertEqual(decoded.odometer, 186_894)
        XCTAssertEqual(decoded.depth32nds, 9)
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
