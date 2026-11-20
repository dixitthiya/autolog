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

    func sendCommand(_ command: String, timeout: TimeInterval = Config.obdCommandTimeout) async throws -> String {
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
                try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
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

    /// Send a command, retrying once after a transient bus error (CAN ERROR,
    /// BUS ERROR, BUS BUSY, STOPPED) with a 250 ms pause. With
    /// `retryOnTimeout`, a timeout is also retried, after the late-reply drain.
    /// Returns every attempt in order (1 or 2).
    func sendRetryingTransient(_ command: String, timeout: TimeInterval = Config.obdCommandTimeout,
                               retryOnTimeout: Bool = false) async -> [CommandAttempt] {
        var attempts: [CommandAttempt] = []
        for attemptNumber in 1...2 {
            let start = Date()
            do {
                let raw = try await sendCommand(command, timeout: timeout)
                let marker = PIDParser.transientBusError(in: raw)
                attempts.append(CommandAttempt(raw: raw, errorDescription: nil, timedOut: false,
                                               transient: marker, durationMs: Self.ms(since: start)))
                if let marker, attemptNumber == 1 {
                    Log.obd("\(command): transient \(marker) — retrying")
                    try? await Task.sleep(nanoseconds: 250_000_000)
                } else {
                    return attempts
                }
            } catch OBDError.timeout {
                attempts.append(CommandAttempt(raw: nil, errorDescription: OBDError.timeout.localizedDescription,
                                               timedOut: true, transient: nil, durationMs: Self.ms(since: start)))
                guard retryOnTimeout else { return attempts }
                // A timed-out read cancels the listener, which ends the shared
                // response stream, and a reply arriving late would otherwise be
                // taken as the next command's answer. Let it land, then start a
                // fresh stream so the following reads still work.
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                await MainActor.run { bleManager.resetResponseStream() }
                guard attemptNumber == 1 else { return attempts }
            } catch {
                attempts.append(CommandAttempt(raw: nil, errorDescription: error.localizedDescription,
                                               timedOut: false, transient: nil, durationMs: Self.ms(since: start)))
                return attempts
            }
        }
        return attempts
    }

    /// Read the VIN (mode 09 PID 02) to identify which car the adapter is in.
    /// Up to two attempts of `timeout` each; retried on a transient bus error or a timeout.
    func readVIN(timeout: TimeInterval = 2) async -> (result: VINReadResult, attempts: [CommandAttempt]) {
        let attempts = await sendRetryingTransient("0902", timeout: timeout, retryOnTimeout: true)
        let raws = attempts.compactMap { $0.raw }
        let allRaw: String? = raws.isEmpty ? nil : raws.joined(separator: " | ")

        guard let last = attempts.last else { return (.failed(reason: "vin_error", raw: nil), attempts) }
        if last.timedOut { return (.failed(reason: "vin_timeout", raw: allRaw), attempts) }
        guard let raw = last.raw else {
            Log.obd("VIN read error: \(last.errorDescription ?? "unknown")")
            return (.failed(reason: "vin_error", raw: allRaw), attempts)
        }

        switch PIDParser.parseVIN(raw) {
        case .vin(let vin): return (.vin(vin, raw: raw), attempts)
        case .noData: return (.failed(reason: "vin_no_data", raw: allRaw), attempts)
        case .transient, .error: return (.failed(reason: "vin_error", raw: allRaw), attempts)
        case .invalid: return (.failed(reason: "vin_invalid", raw: allRaw), attempts)
        }
    }

    private static func ms(since start: Date) -> Int {
        Int(Date().timeIntervalSince(start) * 1000)
    }
}

/// One try of an OBD command, for per-attempt logging.
struct CommandAttempt {
    let raw: String?               // nil if the command threw
    let errorDescription: String?  // set if the command threw (timeout, no response)
    let timedOut: Bool
    let transient: String?         // e.g. "CAN ERROR" if the reply was a transient bus error
    let durationMs: Int
}

enum VINReadResult {
    case vin(String, raw: String)
    case failed(reason: String, raw: String?)
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
