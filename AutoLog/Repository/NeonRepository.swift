import Foundation

actor NeonRepository {
    static let shared = NeonRepository()

    private let session: URLSession
    private let dateFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = Config.urlSessionTimeout
        config.timeoutIntervalForResource = Config.urlSessionTimeout
        self.session = URLSession(configuration: config)
    }

    // MARK: - Raw Query

    private func execute(_ sql: String, params: [Any] = []) async throws -> [[String: Any]] {
        guard let url = URL(string: Config.neonBaseURL) else {
            throw NeonError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(Config.neonConnectionString, forHTTPHeaderField: "Neon-Connection-String")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let paramValues: [Any] = params.map { param in
            if let date = param as? Date {
                return dateFormatter.string(from: date)
            }
            return param
        }

        let body: [String: Any] = ["query": sql, "params": paramValues]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw NeonError.invalidResponse
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            let message = String(data: data, encoding: .utf8) ?? "Unknown error"
            Log.db("HTTP \(httpResponse.statusCode): \(message)")
            throw NeonError.httpError(httpResponse.statusCode, message)
        }

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            Log.db("response is not a JSON object")
            return []
        }

        // Neon HTTP API returns rows as dictionaries: [{"col": "val"}, ...]
        if let dictRows = json["rows"] as? [[String: Any]] {
            return dictRows
        }

        // Fallback: rows as arrays with separate fields metadata
        if let arrayRows = json["rows"] as? [[Any]] {
            let columnNames: [String]
            if let fields = json["fields"] as? [[String: Any]] {
                columnNames = fields.compactMap { $0["name"] as? String }
            } else {
                Log.db("array rows but no fields metadata")
                return []
            }
            return arrayRows.map { row in
                var dict: [String: Any] = [:]
                for (i, col) in columnNames.enumerated() where i < row.count {
                    dict[col] = row[i]
                }
                return dict
            }
        }

        Log.db("no 'rows' in response. Keys: \(Array(json.keys))")
        return []
    }

    private func executeNoResult(_ sql: String, params: [Any] = []) async throws {
        _ = try await execute(sql, params: params)
    }

    // MARK: - Schema Init

    func initializeSchema() async throws {
        Log.db("initializing schema")

        try await executeNoResult("""
            CREATE TABLE IF NOT EXISTS mileage_records (
                id TEXT PRIMARY KEY,
                timestamp TIMESTAMPTZ NOT NULL,
                odometer_miles DOUBLE PRECISION NOT NULL,
                source TEXT NOT NULL,
                dist_since_codes_cleared DOUBLE PRECISION,
                synced_at TIMESTAMPTZ DEFAULT now()
            )
        """)

        // Add column if table already exists without it
        try await executeNoResult("""
            ALTER TABLE mileage_records ADD COLUMN IF NOT EXISTS dist_since_codes_cleared DOUBLE PRECISION
        """)

        try await executeNoResult("""
            CREATE TABLE IF NOT EXISTS service_records (
                id TEXT PRIMARY KEY,
                timestamp TIMESTAMPTZ NOT NULL,
                service_type TEXT NOT NULL,
                category TEXT NOT NULL,
                odometer_miles DOUBLE PRECISION NOT NULL,
                rotor_thickness_mm DOUBLE PRECISION,
                amount DOUBLE PRECISION,
                comments TEXT,
                manually_edited BOOLEAN DEFAULT false,
                created_at TIMESTAMPTZ DEFAULT now()
            )
        """)

        try await executeNoResult("""
            CREATE TABLE IF NOT EXISTS service_thresholds (
                service_type TEXT PRIMARY KEY,
                miles_critical DOUBLE PRECISION,
                miles_warning DOUBLE PRECISION,
                days_critical INTEGER,
                days_warning INTEGER,
                rotor_critical DOUBLE PRECISION,
                rotor_warning DOUBLE PRECISION
            )
        """)

        try await executeNoResult("""
            CREATE TABLE IF NOT EXISTS obd_connection_logs (
                id TEXT PRIMARY KEY,
                timestamp TIMESTAMPTZ NOT NULL,
                event_type TEXT NOT NULL,
                pid TEXT,
                raw_response TEXT,
                parsed_value DOUBLE PRECISION,
                success BOOLEAN NOT NULL,
                error_message TEXT
            )
        """)

        try await executeNoResult("""
            CREATE TABLE IF NOT EXISTS mileage_snapshots (
                id TEXT PRIMARY KEY,
                timestamp TIMESTAMPTZ NOT NULL,
                odometer_miles DOUBLE PRECISION NOT NULL,
                dist_since_codes_cleared DOUBLE PRECISION,
                rpm INTEGER,
                created_at TIMESTAMPTZ DEFAULT now()
            )
        """)

        // Auto-purge snapshots older than 7 days
        try await executeNoResult("""
            DELETE FROM mileage_snapshots WHERE timestamp < now() - INTERVAL '7 days'
        """)

        Log.db("schema initialized")
        try await seedThresholds()
    }

    private func seedThresholds() async throws {
        let rows = try await execute("SELECT COUNT(*) as cnt FROM service_thresholds")
        let count = parseInt(rows.first?["cnt"]) ?? 0
        guard count == 0 else {
            Log.db("thresholds already seeded (\(count) rows)")
            return
        }

        Log.db("seeding thresholds")
        let thresholds: [(String, Double?, Double?, Int?, Int?, Double?, Double?)] = [
            ("Oil & Oil Filter Change", 7000, 5000, nil, nil, nil, nil),
            ("Tire Rotation", 7000, 5000, nil, nil, nil, nil),
            ("Engine Air Filter", 20000, 15000, 365, nil, nil, nil),
            ("Cabin Air Filter", 14000, 10000, 365, nil, nil, nil),
            ("Transmission Fluid Change", 30000, 25000, nil, nil, nil, nil),
            ("Brake Fluid Flush", 30000, 25000, 1095, nil, nil, nil),
            ("Brake Service", 22000, 18000, 730, nil, nil, nil),
            ("Spark Plug Replacement", 90000, 80000, nil, nil, nil, nil),
            ("Coolant Flush", 50000, 45000, 1825, 1460, nil, nil),
            ("Throttle Body Cleaning", 40000, 30000, 1460, 1095, nil, nil),
            ("Front Rotor Thickness Reading", nil, nil, nil, nil, 21.4, 21.8),
            ("Rear Rotor Thickness Reading", nil, nil, nil, nil, 8.4, 8.6),
        ]

        for t in thresholds {
            try await executeNoResult("""
                INSERT INTO service_thresholds (service_type, miles_critical, miles_warning, days_critical, days_warning, rotor_critical, rotor_warning)
                VALUES ($1, $2, $3, $4, $5, $6, $7)
                ON CONFLICT (service_type) DO NOTHING
            """, params: [
                t.0,
                t.1 as Any,
                t.2 as Any,
                t.3 as Any,
                t.4 as Any,
                t.5 as Any,
                t.6 as Any
            ])
        }
        Log.db("thresholds seeded")
    }

    // MARK: - Mileage Records

    func saveMileageRecord(_ record: MileageRecord) async throws {
        Log.db("saving mileage record")
        try await executeNoResult("""
            INSERT INTO mileage_records (id, timestamp, odometer_miles, source, dist_since_codes_cleared)
            VALUES ($1, $2, $3, $4, $5)
            ON CONFLICT (id) DO NOTHING
        """, params: [record.id, record.timestamp, record.odometerMiles, record.source, record.distSinceCodesCleared as Any])
        Log.db("record saved")
    }

    func getMileageRecords() async throws -> [MileageRecord] {
        let rows = try await execute("SELECT id, timestamp, odometer_miles, source, dist_since_codes_cleared FROM mileage_records ORDER BY timestamp DESC")
        return rows.compactMap { parseMileageRecord($0) }
    }

    func updateMileageRecord(_ record: MileageRecord) async throws {
        try await executeNoResult("""
            UPDATE mileage_records SET timestamp = $2, odometer_miles = $3, source = $4, dist_since_codes_cleared = $5 WHERE id = $1
        """, params: [record.id, record.timestamp, record.odometerMiles, record.source, record.distSinceCodesCleared as Any])
    }

    func deleteMileageRecord(id: String) async throws {
        try await executeNoResult("DELETE FROM mileage_records WHERE id = $1", params: [id])
    }

    func getTodayBLEAutoRecord() async throws -> MileageRecord? {
        let rows = try await execute("""
            SELECT id, timestamp, odometer_miles, source, dist_since_codes_cleared FROM mileage_records
            WHERE DATE(timestamp) = CURRENT_DATE AND source = 'BLE_AUTO'
            ORDER BY timestamp DESC LIMIT 1
        """)
        return rows.first.flatMap { parseMileageRecord($0) }
    }

    func getLatestMileageRecord() async throws -> MileageRecord? {
        let rows = try await execute("""
            SELECT id, timestamp, odometer_miles, source, dist_since_codes_cleared FROM mileage_records
            ORDER BY timestamp DESC LIMIT 1
        """)
        return rows.first.flatMap { parseMileageRecord($0) }
    }

    /// Get the latest MANUAL entry — this is the reference point for mileage calculation
    func getLatestManualMileageRecord() async throws -> MileageRecord? {
        let rows = try await execute("""
            SELECT id, timestamp, odometer_miles, source, dist_since_codes_cleared FROM mileage_records
            WHERE source = 'MANUAL' ORDER BY timestamp DESC LIMIT 1
        """)
        return rows.first.flatMap { parseMileageRecord($0) }
    }

    // MARK: - Service Records

    func saveServiceRecord(_ record: ServiceRecord) async throws {
        try await executeNoResult("""
            INSERT INTO service_records (id, timestamp, service_type, category, odometer_miles, rotor_thickness_mm, amount, comments, manually_edited)
            VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9)
            ON CONFLICT (id) DO NOTHING
        """, params: [
            record.id, record.timestamp, record.serviceType, record.category,
            record.odometerMiles, record.rotorThicknessMM as Any,
            record.amount as Any, record.comments as Any, record.manuallyEdited
        ])
    }

    func getServiceRecords() async throws -> [ServiceRecord] {
        let rows = try await execute("""
            SELECT id, timestamp, service_type, category, odometer_miles, rotor_thickness_mm, amount, comments, manually_edited
            FROM service_records ORDER BY timestamp DESC
        """)
        return rows.compactMap { parseServiceRecord($0) }
    }

    func getLatestRecord(for serviceType: String) async throws -> ServiceRecord? {
        let rows = try await execute("""
            SELECT id, timestamp, service_type, category, odometer_miles, rotor_thickness_mm, amount, comments, manually_edited
            FROM service_records WHERE service_type = $1 ORDER BY timestamp DESC LIMIT 1
        """, params: [serviceType])
        return rows.first.flatMap { parseServiceRecord($0) }
    }

    func updateServiceRecord(_ record: ServiceRecord) async throws {
        try await executeNoResult("""
            UPDATE service_records SET timestamp = $2, service_type = $3, category = $4,
            odometer_miles = $5, rotor_thickness_mm = $6, amount = $7, comments = $8, manually_edited = $9
            WHERE id = $1
        """, params: [
            record.id, record.timestamp, record.serviceType, record.category,
            record.odometerMiles, record.rotorThicknessMM as Any,
            record.amount as Any, record.comments as Any, record.manuallyEdited
        ])
    }

    func deleteServiceRecord(id: String) async throws {
        try await executeNoResult("DELETE FROM service_records WHERE id = $1", params: [id])
    }

    // MARK: - OBD Connection Logs

    func saveMileageSnapshot(odometer: Double, distSinceCodesCleared: Double?, rpm: Int?) async {
        do {
            try await executeNoResult("""
                INSERT INTO mileage_snapshots (id, timestamp, odometer_miles, dist_since_codes_cleared, rpm)
                VALUES ($1, $2, $3, $4, $5)
            """, params: [
                UUID().uuidString, Date(), odometer,
                distSinceCodesCleared as Any, rpm as Any
            ])
            // Purge old snapshots (keep 7 days)
            try await executeNoResult("""
                DELETE FROM mileage_snapshots WHERE timestamp < now() - INTERVAL '7 days'
            """)
        } catch {
            Log.db("failed to save mileage snapshot: \(error.localizedDescription)")
        }
    }

    func logOBDEvent(eventType: String, pid: String?, rawResponse: String?, parsedValue: Double?, success: Bool, errorMessage: String?) async {
        do {
            try await executeNoResult("""
                INSERT INTO obd_connection_logs (id, timestamp, event_type, pid, raw_response, parsed_value, success, error_message)
                VALUES ($1, $2, $3, $4, $5, $6, $7, $8)
            """, params: [
                UUID().uuidString, Date(), eventType,
                pid as Any, rawResponse as Any, parsedValue as Any,
                success, errorMessage as Any
            ])
        } catch {
            Log.db("failed to log OBD event: \(error.localizedDescription)")
        }
    }

    /// Get the latest dist_since_codes_cleared value from OBD logs
    func getOBDDistSinceCleared() async throws -> Double? {
        let rows = try await execute("""
            SELECT parsed_value FROM obd_connection_logs
            WHERE event_type = 'dist_since_clear' AND success = true
            ORDER BY timestamp DESC LIMIT 1
        """)
        return parseDouble(rows.first?["parsed_value"])
    }

    func getOBDFailureCount() async throws -> (total: Int, days: Int) {
        let rows = try await execute("""
            SELECT COUNT(*) as total_failures,
                   COUNT(DISTINCT DATE(timestamp)) as failure_days
            FROM obd_connection_logs WHERE success = false
        """)
        let total = parseInt(rows.first?["total_failures"]) ?? 0
        let days = parseInt(rows.first?["failure_days"]) ?? 0
        return (total, days)
    }

    // MARK: - Diagnostics

    func runDiagnostics() async -> String {
        var result = ""
        result += "URL: \(Config.neonBaseURL)\n"
        result += "ConnStr: \(Config.neonConnectionString.prefix(30))...\n\n"

        // First: dump raw HTTP response to see actual format
        do {
            let rawBody = try await executeRaw("SELECT COUNT(*) as cnt FROM mileage_records")
            result += "RAW RESPONSE:\n\(rawBody.prefix(500))\n\n"
        } catch {
            result += "RAW QUERY FAILED: \(error.localizedDescription)\n\n"
        }

        // Test parsed queries
        do {
            let mileageRows = try await execute("SELECT COUNT(*) as cnt FROM mileage_records")
            let mileageCount = parseString(mileageRows.first?["cnt"]) ?? "nil"
            result += "Mileage records: \(mileageCount)\n"
        } catch {
            result += "Mileage query FAILED: \(error.localizedDescription)\n"
        }

        do {
            let serviceRows = try await execute("SELECT COUNT(*) as cnt FROM service_records")
            let serviceCount = parseString(serviceRows.first?["cnt"]) ?? "nil"
            result += "Service records: \(serviceCount)\n"
        } catch {
            result += "Service query FAILED: \(error.localizedDescription)\n"
        }

        do {
            let thresholdRows = try await execute("SELECT COUNT(*) as cnt FROM service_thresholds")
            let thresholdCount = parseString(thresholdRows.first?["cnt"]) ?? "nil"
            result += "Thresholds: \(thresholdCount)\n"
        } catch {
            result += "Threshold query FAILED: \(error.localizedDescription)\n"
        }

        // Test a raw SELECT to see the actual response format
        do {
            let sample = try await execute("SELECT id, odometer_miles, source FROM mileage_records LIMIT 1")
            if let first = sample.first {
                result += "\nSample row keys: \(Array(first.keys))\n"
                for (k, v) in first {
                    result += "  \(k): \(type(of: v)) = \(v)\n"
                }
            } else {
                result += "\nSample: no rows returned\n"
            }
        } catch {
            result += "\nSample query FAILED: \(error.localizedDescription)\n"
        }

        return result
    }

    /// Returns the raw HTTP response body as a string for debugging
    private func executeRaw(_ sql: String) async throws -> String {
        guard let url = URL(string: Config.neonBaseURL) else {
            throw NeonError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(Config.neonConnectionString, forHTTPHeaderField: "Neon-Connection-String")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body: [String: Any] = ["query": sql, "params": []]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await session.data(for: request)
        let httpResponse = response as? HTTPURLResponse
        let statusCode = httpResponse?.statusCode ?? -1
        let bodyStr = String(data: data, encoding: .utf8) ?? "<non-utf8>"
        return "HTTP \(statusCode): \(bodyStr)"
    }

    // MARK: - Thresholds

    func getThresholds() async throws -> [ServiceThreshold] {
        let rows = try await execute("SELECT * FROM service_thresholds")
        return rows.compactMap { row in
            guard let serviceType = parseString(row["service_type"]) else { return nil }
            return ServiceThreshold(
                serviceType: serviceType,
                milesCritical: parseDouble(row["miles_critical"]),
                milesWarning: parseDouble(row["miles_warning"]),
                daysCritical: parseInt(row["days_critical"]),
                daysWarning: parseInt(row["days_warning"]),
                rotorCritical: parseDouble(row["rotor_critical"]),
                rotorWarning: parseDouble(row["rotor_warning"])
            )
        }
    }

    // MARK: - Dashboard

    func getDashboardData() async throws -> [DashboardRow] {
        let thresholds = try await getThresholds()
        let latestMileage = try await getLatestMileageRecord()
        let currentOdometer = latestMileage?.odometerMiles ?? 0

        var rows: [DashboardRow] = []
        for threshold in thresholds {
            let lastService = try await getLatestRecord(for: threshold.serviceType)
            let lastMileage = lastService?.odometerMiles ?? 0
            let milesAfter = currentOdometer - lastMileage
            let lastDate = lastService?.timestamp
            let daysAfter = lastDate.map { Calendar.current.dateComponents([.day], from: $0, to: Date()).day ?? 0 } ?? 0
            let monthsAfter = Double(daysAfter) / 30.44

            let status = StatusCalculator.calculate(
                serviceType: threshold.serviceType,
                threshold: threshold,
                milesSinceService: milesAfter,
                daysSinceService: daysAfter,
                rotorThickness: lastService?.rotorThicknessMM,
                hasServiceRecord: lastService != nil
            )

            rows.append(DashboardRow(
                id: threshold.serviceType,
                serviceType: threshold.serviceType,
                milesAfterService: milesAfter,
                status: status,
                currentMileage: currentOdometer,
                lastServiceMileage: lastMileage,
                lastServiceDate: lastDate,
                rotorThickness: lastService?.rotorThicknessMM,
                daysAfterService: daysAfter,
                monthsAfterService: monthsAfter,
                milesWarning: threshold.milesWarning,
                milesCritical: threshold.milesCritical
            ))
        }

        return rows.sorted { $0.status < $1.status }
    }

    // MARK: - Parsing Helpers

    private func parseDouble(_ value: Any?) -> Double? {
        if let d = value as? Double { return d }
        if let n = value as? NSNumber { return n.doubleValue }
        if let s = value as? String { return Double(s) }
        return nil
    }

    private func parseInt(_ value: Any?) -> Int? {
        if let i = value as? Int { return i }
        if let n = value as? NSNumber { return n.intValue }
        if let s = value as? String { return Int(s) }
        if let d = value as? Double { return Int(d) }
        return nil
    }

    private func parseString(_ value: Any?) -> String? {
        if let s = value as? String { return s }
        if let n = value as? NSNumber { return n.stringValue }
        return nil
    }

    private func parseBool(_ value: Any?) -> Bool {
        if let b = value as? Bool { return b }
        if let s = value as? String { return s == "true" || s == "t" }
        if let n = value as? NSNumber { return n.boolValue }
        return false
    }

    private func parseMileageRecord(_ row: [String: Any]) -> MileageRecord? {
        guard let id = parseString(row["id"]),
              let odometer = parseDouble(row["odometer_miles"]),
              let source = parseString(row["source"]) else {
            Log.db("failed to parse mileage record: \(row)")
            return nil
        }
        let timestamp = parseDate(row["timestamp"]) ?? Date()
        let distSinceCodesCleared = parseDouble(row["dist_since_codes_cleared"])
        return MileageRecord(id: id, timestamp: timestamp, odometerMiles: odometer, source: source, distSinceCodesCleared: distSinceCodesCleared)
    }

    private func parseServiceRecord(_ row: [String: Any]) -> ServiceRecord? {
        guard let id = parseString(row["id"]),
              let serviceType = parseString(row["service_type"]),
              let category = parseString(row["category"]),
              let odometer = parseDouble(row["odometer_miles"]) else {
            Log.db("failed to parse service record: \(row)")
            return nil
        }
        let timestamp = parseDate(row["timestamp"]) ?? Date()
        return ServiceRecord(
            id: id,
            timestamp: timestamp,
            serviceType: serviceType,
            category: category,
            odometerMiles: odometer,
            rotorThicknessMM: parseDouble(row["rotor_thickness_mm"]),
            amount: parseDouble(row["amount"]),
            comments: parseString(row["comments"]),
            manuallyEdited: parseBool(row["manually_edited"])
        )
    }

    private func parseDate(_ value: Any?) -> Date? {
        guard let str = value as? String else { return nil }
        if let d = dateFormatter.date(from: str) { return d }
        let fallback = ISO8601DateFormatter()
        fallback.formatOptions = [.withInternetDateTime]
        if let d = fallback.date(from: str) { return d }
        // Handle Postgres timestamp format: "2025-12-13 19:08:54+00"
        let pgFormatter = DateFormatter()
        pgFormatter.dateFormat = "yyyy-MM-dd HH:mm:ssxx"
        pgFormatter.locale = Locale(identifier: "en_US_POSIX")
        if let d = pgFormatter.date(from: str) { return d }
        pgFormatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSSSSSxx"
        return pgFormatter.date(from: str)
    }
}

enum NeonError: LocalizedError {
    case invalidURL
    case invalidResponse
    case httpError(Int, String)

    var errorDescription: String? {
        switch self {
        case .invalidURL: return "Invalid Neon database URL"
        case .invalidResponse: return "Invalid response from server"
        case .httpError(let code, let msg): return "HTTP \(code): \(msg)"
        }
    }
}
