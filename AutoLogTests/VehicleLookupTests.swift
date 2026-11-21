import XCTest
@testable import AutoLog

final class VehicleLookupTests: XCTestCase {

    /// Trimmed-down vPIC DecodeVinValues reply: every value is a string, "" when unknown.
    private func reply(make: String, model: String, year: String) -> Data {
        let json = """
        {"Count":1,"Message":"Results returned successfully","SearchCriteria":"VIN:5NPE24AF0JH123456",
         "Results":[{"Make":"\(make)","Model":"\(model)","ModelYear":"\(year)","ErrorCode":"0","Trim":""}]}
        """
        return Data(json.utf8)
    }

    func testParsesMakeModelYear() throws {
        let details = try VehicleLookup.parse(reply(make: "HYUNDAI", model: "Sonata", year: "2018"))
        XCTAssertEqual(details, VehicleLookup.Details(make: "Hyundai", model: "Sonata", year: 2018))
    }

    func testEmptyFieldsBecomeNil() throws {
        let details = try VehicleLookup.parse(reply(make: "", model: "", year: ""))
        XCTAssertEqual(details, VehicleLookup.Details(make: nil, model: nil, year: nil))
    }

    func testUnexpectedReplyThrows() {
        XCTAssertThrowsError(try VehicleLookup.parse(Data("{\"Results\":[]}".utf8)))
        XCTAssertThrowsError(try VehicleLookup.parse(Data("not json".utf8)))
    }

    func testDisplayMake() {
        XCTAssertEqual(VehicleLookup.displayMake("HYUNDAI"), "Hyundai")
        XCTAssertEqual(VehicleLookup.displayMake("MERCEDES-BENZ"), "Mercedes-Benz")
        XCTAssertEqual(VehicleLookup.displayMake("BMW"), "BMW")
        XCTAssertEqual(VehicleLookup.displayMake("Kia"), "Kia")
    }

    func testAutoNicknameMatchesNewVehicleName() {
        let new = Vehicle.new(vin: "5NPE24AF0JH123456", make: "Hyundai", year: 2018)
        XCTAssertEqual(new.nickname, Vehicle.autoNickname(make: "Hyundai", year: 2018))
        XCTAssertEqual(Vehicle.autoNickname(make: "Hyundai", model: "Sonata", year: 2018), "2018 Hyundai Sonata")
        XCTAssertNil(Vehicle.autoNickname(make: nil, year: nil))
    }
}
