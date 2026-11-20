import XCTest
@testable import AutoLog

final class VINTests: XCTestCase {

    // 5NPE24AF0JH123456 — US-built (5) Hyundai (5NP), 2018 (J), valid check digit (0).
    // Hex: 35 4E 50 45 32 34 41 46 30 4A 48 31 32 33 34 35 36
    // CAN reply = 49 02 01 + 17 VIN bytes = 20 bytes over three ISO-TP frames.
    private let sonataReplyNoSpaces = "014\r0:490201354E50\r1:4532344146304A\r2:48313233343536\r\r>"
    private let sonataReplyWithSpaces = "014 \r0: 49 02 01 35 4E 50 \r1: 45 32 34 41 46 30 4A \r2: 48 31 32 33 34 35 36 \r\r>"

    // MARK: - Parser

    func testParseVIN_multiFrameNoSpaces() {
        XCTAssertEqual(PIDParser.parseVIN(sonataReplyNoSpaces), .vin("5NPE24AF0JH123456"))
    }

    func testParseVIN_multiFrameWithSpaces() {
        XCTAssertEqual(PIDParser.parseVIN(sonataReplyWithSpaces), .vin("5NPE24AF0JH123456"))
    }

    func testParseVIN_noData() {
        XCTAssertEqual(PIDParser.parseVIN("NO DATA\r\r>"), .noData)
    }

    func testParseVIN_canErrorIsTransient() {
        XCTAssertEqual(PIDParser.parseVIN("CAN ERROR\r\r>"), .transient)
    }

    func testParseVIN_otherBusErrorsAreTransient() {
        XCTAssertEqual(PIDParser.parseVIN("BUS BUSY\r\r>"), .transient)
        XCTAssertEqual(PIDParser.parseVIN("BUS ERROR\r\r>"), .transient)
        XCTAssertEqual(PIDParser.parseVIN("STOPPED\r\r>"), .transient)
    }

    func testParseVIN_transientWinsOverNoData() {
        XCTAssertEqual(PIDParser.parseVIN("NO DATA\rCAN ERROR\r\r>"), .transient)
    }

    func testParseVIN_unknownCommandIsError() {
        XCTAssertEqual(PIDParser.parseVIN("?\r\r>"), .error)
        XCTAssertEqual(PIDParser.parseVIN("UNABLE TO CONNECT\r\r>"), .error)
    }

    // MARK: - Transient detection (any PID)

    func testTransientBusErrorDetection() {
        XCTAssertEqual(PIDParser.transientBusError(in: "CAN ERROR\r\r>"), "CAN ERROR")
        XCTAssertEqual(PIDParser.transientBusError(in: "bus busy"), "BUS BUSY")
        XCTAssertNil(PIDParser.transientBusError(in: "NO DATA\r\r>"))
        XCTAssertNil(PIDParser.transientBusError(in: "41 31 05 C6"))
        XCTAssertNil(PIDParser.transientBusError(in: "4131413105C6"))
    }

    func testParseVIN_truncatedReplyIsInvalid() {
        XCTAssertEqual(PIDParser.parseVIN("014\r0:490201354E50\r1:4532344146304A\r\r>"), .invalid)
    }

    func testParseVIN_badCheckDigitIsInvalid() {
        // Position 9 changed 0 → 1 (0x30 → 0x31); North American, so enforced.
        let reply = "014\r0:490201354E50\r1:4532344146314A\r2:48313233343536\r\r>"
        XCTAssertEqual(PIDParser.parseVIN(reply), .invalid)
    }

    func testParseVIN_nonNorthAmericanSkipsCheckDigit() {
        // KMHD841C9DU123456 — Korean-built (K); check digit deliberately wrong (should be 3).
        let reply = "014\r0:4902014B4D48\r1:44383431433944\r2:55313233343536\r\r>"
        XCTAssertEqual(PIDParser.parseVIN(reply), .vin("KMHD841C9DU123456"))
    }

    func testParseVIN_rejectsLetterO() {
        // KMHD841C3DU12345O — last character O (0x4F) is never allowed in a VIN.
        let reply = "014\r0:4902014B4D48\r1:44383431433344\r2:5531323334354F\r\r>"
        XCTAssertEqual(PIDParser.parseVIN(reply), .invalid)
    }

    func testParseVIN_uppercasesResult() {
        // Lowercase "kmh" (6B 6D 68) from a sloppy ECU is uppercased before use.
        let reply = "014\r0:4902016B6D68\r1:44383431433344\r2:55313233343536\r\r>"
        XCTAssertEqual(PIDParser.parseVIN(reply), .vin("KMHD841C3DU123456"))
    }

    // MARK: - Format / check digit

    func testFormatRejectsIOQAndWrongLength() {
        XCTAssertTrue(VINDecoder.isValidFormat("5NPE24AF0JH123456"))
        XCTAssertFalse(VINDecoder.isValidFormat("5NPE24AF0JH12345"))      // 16
        XCTAssertFalse(VINDecoder.isValidFormat("5NPE24AF0JH1234567"))    // 18
        XCTAssertFalse(VINDecoder.isValidFormat("5NPE24AF0JH12345I"))
        XCTAssertFalse(VINDecoder.isValidFormat("5NPE24AF0JH12345Q"))
    }

    func testCheckDigitOnlyRequiredForNorthAmerica() {
        XCTAssertTrue(VINDecoder.requiresCheckDigit("5NPE24AF0JH123456"))
        XCTAssertTrue(VINDecoder.requiresCheckDigit("1HGCM82633A004352"))
        XCTAssertFalse(VINDecoder.requiresCheckDigit("KMHD841C3DU123456"))
        XCTAssertFalse(VINDecoder.requiresCheckDigit("WBA3A5C51CF256985"))
    }

    func testCheckDigit() {
        XCTAssertTrue(VINDecoder.checkDigitMatches("5NPE24AF0JH123456"))
        XCTAssertTrue(VINDecoder.checkDigitMatches("1HGCM82633A004352"))   // textbook example
        XCTAssertFalse(VINDecoder.checkDigitMatches("5NPE24AF1JH123456"))
    }

    // MARK: - Offline decode

    func testDecodeMake() {
        XCTAssertEqual(VINDecoder.make(fromVIN: "5NPE24AF0JH123456"), "Hyundai")
        XCTAssertEqual(VINDecoder.make(fromVIN: "KMHD841C3DU123456"), "Hyundai")
        XCTAssertEqual(VINDecoder.make(fromVIN: "KNAFX4A68E5123456"), "Kia")
        XCTAssertNil(VINDecoder.make(fromVIN: "1HGCM82633A004352"))
    }

    func testDecodeModelYear() {
        XCTAssertEqual(VINDecoder.modelYear(fromVIN: "5NPE24AF0JH123456", referenceYear: 2026), 2018)  // J
        XCTAssertEqual(VINDecoder.modelYear(fromVIN: "KMHD841C3DU123456", referenceYear: 2026), 2013)  // D
        XCTAssertEqual(VINDecoder.modelYear(fromVIN: "1HGCM82633A004352", referenceYear: 2026), 2003)  // 3
        XCTAssertEqual(VINDecoder.modelYear(fromVIN: "XXXXXXXXXTXXXXXXX", referenceYear: 2026), 2026)  // T
        XCTAssertEqual(VINDecoder.modelYear(fromVIN: "XXXXXXXXXVXXXXXXX", referenceYear: 2026), 2027)  // V, next year's models
    }
}
