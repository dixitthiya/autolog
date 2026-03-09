import Foundation

struct PIDParser {
    /// Parse PID 010C (RPM)
    /// Response: 41 0C XX YY → RPM = ((XX * 256) + YY) / 4
    static func parseRPM(_ response: String) -> Int {
        let bytes = extractBytes(from: response, expectedPrefix: "41 0C")
        guard bytes.count >= 2 else { return 0 }
        let rpm = ((Int(bytes[0]) * 256) + Int(bytes[1])) / 4
        Log.obd("RPM: \(rpm)")
        return rpm
    }

    /// Parse PID 01A6 (odometer in km)
    /// Response: 41 A6 XX YY → distance_km = (XX * 256 + YY), convert to miles
    static func parseOdometer(_ response: String) -> Double {
        let bytes = extractBytes(from: response, expectedPrefix: "41 A6")
        guard bytes.count >= 2 else {
            if response.contains("NO DATA") || response.contains("ERROR") {
                Log.obd("odometer PID not supported")
            }
            return 0
        }
        let km = Double(Int(bytes[0]) * 256 + Int(bytes[1]))
        let miles = km * 0.621371
        Log.obd("odometer: \(Int(miles)) miles")
        return miles
    }

    /// Parse PID 010D (speed in kph)
    /// Response: 41 0D XX → speed_kph = XX
    static func parseSpeed(_ response: String) -> Int {
        let bytes = extractBytes(from: response, expectedPrefix: "41 0D")
        guard bytes.count >= 1 else { return 0 }
        return Int(bytes[0])
    }

    /// Parse PID 0131 (distance since codes cleared, in km)
    /// Response: 41 31 XX YY → distance_km = (XX * 256 + YY), convert to miles
    static func parseDistanceSinceCodesCleared(_ response: String) -> Double {
        let bytes = extractBytes(from: response, expectedPrefix: "41 31")
        guard bytes.count >= 2 else {
            if response.contains("NO DATA") || response.contains("ERROR") {
                Log.obd("distance since codes cleared PID not supported")
            }
            return 0
        }
        let km = Double(Int(bytes[0]) * 256 + Int(bytes[1]))
        let miles = km * 0.621371
        Log.obd("distance since codes cleared: \(Int(miles)) miles")
        return miles
    }

    /// Calculate accumulated distance from speed readings
    static func accumulateDistance(speedKPH: Int, deltaTimeHours: Double) -> Double {
        let distanceKM = Double(speedKPH) * deltaTimeHours
        return distanceKM * 0.621371
    }

    /// Extract hex bytes from OBD response after the expected prefix
    /// Handles responses like "SEARCHING...410C0CF8" where prefix appears mid-string
    static func extractBytes(from response: String, expectedPrefix: String) -> [UInt8] {
        let cleaned = response
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespaces)

        let prefixNormalized = expectedPrefix.replacingOccurrences(of: " ", with: "").uppercased()
        let responseNormalized = cleaned.replacingOccurrences(of: " ", with: "").uppercased()

        // Find the prefix anywhere in the response (not just at start)
        guard let range = responseNormalized.range(of: prefixNormalized) else { return [] }

        let afterPrefix = String(responseNormalized[range.upperBound...])
        var bytes: [UInt8] = []
        var i = afterPrefix.startIndex
        while i < afterPrefix.endIndex {
            let next = afterPrefix.index(i, offsetBy: 2, limitedBy: afterPrefix.endIndex) ?? afterPrefix.endIndex
            let hex = String(afterPrefix[i..<next])
            if let byte = UInt8(hex, radix: 16) {
                bytes.append(byte)
            } else {
                break // Stop at non-hex characters
            }
            i = next
        }
        return bytes
    }
}
