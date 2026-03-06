import Foundation

actor OBDCommandService {
    private let bleManager: BLEManager
    private var isInitialized = false

    init(bleManager: BLEManager) {
        self.bleManager = bleManager
    }

    func initialize() async throws {
        let initCommands = ["ATZ", "ATE0", "ATL0", "ATH0", "ATS0", "ATSP0"]
        for cmd in initCommands {
            _ = try await sendCommand(cmd)
        }
        isInitialized = true
        Log.obd("ELM327 initialized")
    }

    func sendCommand(_ command: String) async throws -> String {
        await MainActor.run {
            bleManager.send(command)
        }

        let stream = await MainActor.run { bleManager.dataStream! }

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

            let result = try await group.next()!
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
