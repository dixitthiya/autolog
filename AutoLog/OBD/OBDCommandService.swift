import Foundation

actor OBDCommandService {
    private let bleManager: BLEManager
    private var isInitialized = false

    init(bleManager: BLEManager) {
        self.bleManager = bleManager
    }

    func initialize() async throws {
        // ATZ resets, wait a bit for adapter to be ready
        _ = try await sendCommand("ATZ")
        try await Task.sleep(nanoseconds: 1_000_000_000)

        let initCommands = [
            "ATE0",   // Echo off
            "ATL0",   // Linefeeds off
            "ATH0",   // Headers off
            "ATS0",   // Spaces off
            "ATSP6",  // Force ISO 15765-4 CAN (11-bit, 500kbaud) — matches user's vehicle
            "ATCRA7E8", // Only accept responses from engine ECU — filters ghost values from other modules
        ]
        for cmd in initCommands {
            _ = try await sendCommand(cmd)
        }
        isInitialized = true
        Log.obd("ELM327 initialized with CAN protocol")
    }

    func sendCommand(_ command: String) async throws -> String {
        await MainActor.run {
            bleManager.send(command)
        }

        guard let stream = await MainActor.run(body: { bleManager.dataStream }) else {
            throw OBDError.noResponse
        }

        return try await withThrowingTaskGroup(of: String.self) { group in
            group.addTask {
                for await data in stream {
                    if let response = String(data: data, encoding: .ascii) {
                        let cleaned = response
                            .replacingOccurrences(of: ">", with: "")
                            .trimmingCharacters(in: .whitespacesAndNewlines)
                        Log.obd("response: \(cleaned)")
                        return cleaned
                    }
                }
                throw OBDError.noResponse
            }

            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(Config.obdCommandTimeout * 1_000_000_000))
                throw OBDError.timeout
            }

            guard let result = try await group.next() else {
                throw OBDError.noResponse
            }
            group.cancelAll()
            return result
        }
    }

    func getRPM() async throws -> Int {
        let response = try await sendCommand("010C")
        return PIDParser.parseRPM(response)
    }

    func getOdometer() async throws -> Double {
        let response = try await sendCommand("01A6")
        return PIDParser.parseOdometer(response)
    }

    func getSpeed() async throws -> Int {
        let response = try await sendCommand("010D")
        return PIDParser.parseSpeed(response)
    }

    func getDistanceSinceCodesCleared() async throws -> Double {
        let response = try await sendCommand("0131")
        return PIDParser.parseDistanceSinceCodesCleared(response)
    }
}

enum OBDError: LocalizedError {
    case timeout
    case noResponse
    case invalidResponse(String)
    case notSupported

    var errorDescription: String? {
        switch self {
        case .timeout: return "OBD command timed out"
        case .noResponse: return "No response from OBD adapter"
        case .invalidResponse(let r): return "Invalid OBD response: \(r)"
        case .notSupported: return "PID not supported by vehicle"
        }
    }
}
