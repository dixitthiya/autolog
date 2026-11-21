import XCTest
@testable import AutoLog

final class UIComponentsTests: XCTestCase {

    func testMilesFormat() {
        XCTAssertEqual(Fmt.miles(117_356), "117,356 mi")
        XCTAssertEqual(Fmt.milesOrDash(0), "—")
        XCTAssertEqual(Fmt.milesOrDash(1_204), "1,204 mi")
    }

    func testMoneyAlwaysHasTwoDecimals() {
        XCTAssertTrue(Fmt.money(9.72).contains("9.72"))
        XCTAssertTrue(Fmt.money(10).hasSuffix("10.00"))
    }

    func testServerErrorsReadAsPlainSentences() {
        let server = NeonError.httpError(400, "{\"message\":\"syntax error at or near\"}")
        XCTAssertFalse(server.userMessage.contains("HTTP"))
        XCTAssertFalse(server.userMessage.contains("syntax"))
        XCTAssertEqual(server.userMessage, "The database couldn't complete that request.")
    }

    func testNetworkErrorsReadAsOffline() {
        XCTAssertEqual(URLError(.notConnectedToInternet).userMessage, "Can't reach the database — check your connection.")
        XCTAssertEqual(URLError(.badServerResponse).userMessage, "Couldn't reach the database. Try again in a moment.")
    }

    func testUnknownErrorsGetAGenericSentence() {
        struct Odd: Error {}
        XCTAssertEqual(Odd().userMessage, "Something went wrong. Please try again.")
    }
}
