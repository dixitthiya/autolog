import Foundation

enum VINParseResult: Equatable {
    case vin(String)        // valid, uppercased
    case noData             // adapter/ECU answered with an error (NO DATA, ERROR, ...)
    case invalid            // a reply, but not a valid VIN (truncated, bad chars, bad check digit)
}

extension PIDParser {
    /// Parse a mode 09 PID 02 (VIN) reply. On CAN the VIN spans several ISO-TP
    /// frames, which the ELM327 prints (headers off) as a byte-count line followed
    /// by numbered lines:
    ///
    ///     014
    ///     0:490201354E50
    ///     1:4532344146304A
    ///     2:48313233343536
    ///
    /// Steps: drop the count line, strip the "n:" prefixes, join, skip
    /// 49 02 <item count>, decode ASCII, uppercase, then validate.
    static func parseVIN(_ response: String) -> VINParseResult {
        let failureMarkers = ["NO DATA", "ERROR", "STOPPED", "UNABLE TO CONNECT", "BUS", "?"]
        var lines = response.uppercased()
            .components(separatedBy: CharacterSet(charactersIn: "\r\n"))
            .map { $0.replacingOccurrences(of: ">", with: "").trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.contains("SEARCHING") }

        if lines.contains(where: { line in failureMarkers.contains { line.contains($0) } }) {
            Log.obd("VIN not available: \(response)")
            return .noData
        }

        // Byte-count line ("014"): 1-3 hex digits, no colon, ahead of the frames.
        if let first = lines.first, !first.contains(":"), first.count <= 3, hexBytes(first.count % 2 == 0 ? first : "0" + first) != nil {
            lines.removeFirst()
        }

        let compact = lines.map { $0.replacingOccurrences(of: " ", with: "") }
        let hex: String
        if compact.contains(where: { $0.contains(":") }) {
            // Multi-frame: keep only what follows each "n:" prefix, in arrival order.
            hex = compact.compactMap { line in
                line.firstIndex(of: ":").map { String(line[line.index(after: $0)...]) }
            }.joined()
        } else {
            hex = compact.joined()
        }

        guard let bytes = hexBytes(hex),
              let start = bytes.indices.first(where: { $0 + 1 < bytes.count && bytes[$0] == 0x49 && bytes[$0 + 1] == 0x02 }),
              start + 3 <= bytes.count else {
            Log.obd("VIN reply unreadable: \(response)")
            return .invalid
        }

        // Skip 49 02 and the item-count byte; some ECUs pad the front with 00.
        let payload = bytes[(start + 3)...].filter { $0 != 0x00 }
        guard payload.allSatisfy({ (0x20...0x7E).contains($0) }) else { return .invalid }
        let vin = String(decoding: payload, as: UTF8.self)
            .trimmingCharacters(in: .whitespaces)
            .uppercased()

        guard VINDecoder.isValid(vin) else {
            Log.obd("VIN failed validation: \(vin)")
            return .invalid
        }
        return .vin(vin)
    }

    /// "4902" → [0x49, 0x02]; nil if odd length or any non-hex character.
    private static func hexBytes(_ hex: String) -> [UInt8]? {
        guard hex.count % 2 == 0 else { return nil }
        var bytes: [UInt8] = []
        bytes.reserveCapacity(hex.count / 2)
        var i = hex.startIndex
        while i < hex.endIndex {
            let next = hex.index(i, offsetBy: 2)
            guard let byte = UInt8(hex[i..<next], radix: 16) else { return nil }
            bytes.append(byte)
            i = next
        }
        return bytes
    }
}

/// Offline VIN checks and decoding — no network.
enum VINDecoder {
    private static let allowed = Set("ABCDEFGHJKLMNPRSTUVWXYZ0123456789")

    /// 17 characters, letters and digits only, never I, O or Q.
    static func isValidFormat(_ vin: String) -> Bool {
        vin.count == 17 && vin.allSatisfy { allowed.contains($0) }
    }

    /// North American VINs (first character 1-5) carry a check digit at position 9.
    static func requiresCheckDigit(_ vin: String) -> Bool {
        guard let digit = vin.first?.wholeNumberValue else { return false }
        return (1...5).contains(digit)
    }

    static func checkDigitMatches(_ vin: String) -> Bool {
        let values: [Character: Int] = [
            "A": 1, "B": 2, "C": 3, "D": 4, "E": 5, "F": 6, "G": 7, "H": 8,
            "J": 1, "K": 2, "L": 3, "M": 4, "N": 5, "P": 7, "R": 9,
            "S": 2, "T": 3, "U": 4, "V": 5, "W": 6, "X": 7, "Y": 8, "Z": 9,
        ]
        let weights = [8, 7, 6, 5, 4, 3, 2, 10, 0, 9, 8, 7, 6, 5, 4, 3, 2]
        let chars = Array(vin)
        guard chars.count == 17 else { return false }
        var sum = 0
        for (i, c) in chars.enumerated() {
            guard let v = c.wholeNumberValue ?? values[c] else { return false }
            sum += v * weights[i]
        }
        let remainder = sum % 11
        let expected: Character = remainder == 10 ? "X" : Character(String(remainder))
        return chars[8] == expected
    }

    static func isValid(_ vin: String) -> Bool {
        guard isValidFormat(vin) else { return false }
        return !requiresCheckDigit(vin) || checkDigitMatches(vin)
    }

    /// Make from the World Manufacturer Identifier (characters 1-3). Small,
    /// offline table; unknown makers return nil (editable later).
    static func make(fromVIN vin: String) -> String? {
        let wmi = String(vin.prefix(3))
        switch wmi {
        case "KMH", "KM8", "5NP", "5NM", "KMF", "KMJ": return "Hyundai"
        case "KNA", "KND", "KNM", "5XY", "5XX", "3KP": return "Kia"
        case "KMT": return "Genesis"
        default: return nil
        }
    }

    /// Model year from character 10. Codes repeat every 30 years; pick the
    /// latest year that isn't more than one year in the future.
    static func modelYear(fromVIN vin: String, referenceYear: Int = Calendar.current.component(.year, from: Date())) -> Int? {
        let codes = Array("ABCDEFGHJKLMNPRSTVWXY123456789")   // 1980...2009
        let chars = Array(vin)
        guard chars.count >= 10, let index = codes.firstIndex(of: chars[9]) else { return nil }
        var year = 1980 + index
        while year + 30 <= referenceYear + 1 { year += 30 }
        return year
    }
}
