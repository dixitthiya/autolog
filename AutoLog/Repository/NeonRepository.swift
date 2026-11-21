import Foundation
import CryptoKit

actor NeonRepository {
    static let shared = NeonRepository()

    private let session: URLSession
    private let dateFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    /// True once the multi_car_v1 migration is confirmed. Until then captures
    /// are blocked and reads treat a NULL vehicle_id as the Elantra. The
    /// confirmation is remembered across launches (the marker is never removed),
    /// so a launch with no network still knows the database is migrated.
    private(set) var isMultiCarReady: Bool

    private static let confirmedKey = "multiCarMigrationConfirmed"

    /// Identifies which database the confirmation was for: a hash of host and
    /// database name (credentials excluded), so pointing the app at a different
    /// database never trusts a stale flag. Never logged.
    private static func databaseFingerprint() -> String {
        let target = Config.neonConnectionString.split(separator: "@").last.map(String.init) ?? Config.neonBaseURL
        return SHA256.hash(data: Data(target.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private var schemaTask: Task<Void, Error>?

    private init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = Config.urlSessionTimeout
        config.timeoutIntervalForResource = Config.urlSessionTimeout
        self.session = URLSession(configuration: config)
        self.isMultiCarReady = UserDefaults.standard.string(forKey: Self.confirmedKey) == Self.databaseFingerprint()
    }

    /// If the migration was never confirmed, run the (idempotent) schema init
    /// again. Called on foreground, when the network returns, and before a
    /// capture, so one failed launch doesn't block captures for the session.
    /// Throws the underlying error so callers can tell "offline" from "failed".
    func ensureMultiCarReady() async throws {
        guard !isMultiCarReady else { return }
        try await initializeSchema()
    }

    /// WHERE fragment matching one vehicle's rows (`$param` = vehicle id).
    /// Before the backfill is confirmed, rows with no car yet count as the Elantra's.
    private func vehicleFilter(_ param: Int, column: String = "vehicle_id") -> String {
        isMultiCarReady
            ? "\(column) = $\(param)"
            : "COALESCE(\(column), '\(Vehicle.elantraId)') = $\(param)"
    }

    private func requireVehicle(_ vehicleId: String?) throws -> String {
        guard let vehicleId, !vehicleId.isEmpty else { throw NeonError.missingVehicle }
        return vehicleId
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

    /// One run at a time: a launch init and an `ensureMultiCarReady` retry that
    /// overlap share the same run.
    func initializeSchema() async throws {
        if let running = schemaTask {
            return try await running.value
        }
        let task = Task { try await self.performSchemaInit() }
        schemaTask = task
        defer { schemaTask = nil }
        try await task.value
    }

    private func performSchemaInit() async throws {
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

        // Add columns if table already exists without them
        try await executeNoResult("""
            ALTER TABLE mileage_records ADD COLUMN IF NOT EXISTS dist_since_codes_cleared DOUBLE PRECISION
        """)
        try await executeNoResult("""
            ALTER TABLE mileage_records ADD COLUMN IF NOT EXISTS created_at TIMESTAMPTZ DEFAULT now()
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
                capture_mode TEXT,
                created_at TIMESTAMPTZ DEFAULT now()
            )
        """)

        // Add capture_mode column if table already exists without it
        try await executeNoResult("""
            ALTER TABLE mileage_snapshots ADD COLUMN IF NOT EXISTS capture_mode TEXT
        """)

        // Auto-purge snapshots older than 7 days
        try await executeNoResult("""
            DELETE FROM mileage_snapshots WHERE timestamp < now() - INTERVAL '7 days'
        """)

        try await executeNoResult("""
            CREATE TABLE IF NOT EXISTS services (
                id TEXT PRIMARY KEY DEFAULT gen_random_uuid(),
                service_type TEXT NOT NULL UNIQUE,
                category TEXT NOT NULL
            )
        """)

        try await executeNoResult("""
            CREATE TABLE IF NOT EXISTS tires (
                id TEXT PRIMARY KEY,
                position TEXT,
                make_model TEXT,
                install_odometer DOUBLE PRECISION NOT NULL,
                install_date TIMESTAMPTZ NOT NULL,
                removed_odometer DOUBLE PRECISION,
                removed_date TIMESTAMPTZ,
                replaces_tire_id TEXT,
                notes TEXT,
                created_at TIMESTAMPTZ DEFAULT now()
            )
        """)

        try await executeNoResult("""
            CREATE TABLE IF NOT EXISTS tire_rotations (
                id TEXT PRIMARY KEY,
                timestamp TIMESTAMPTZ NOT NULL,
                odometer_miles DOUBLE PRECISION NOT NULL,
                pattern TEXT,
                comments TEXT,
                created_at TIMESTAMPTZ DEFAULT now()
            )
        """)

        try await executeNoResult("""
            CREATE TABLE IF NOT EXISTS tire_tread_readings (
                id TEXT PRIMARY KEY,
                tire_id TEXT NOT NULL,
                timestamp TIMESTAMPTZ NOT NULL,
                odometer_miles DOUBLE PRECISION NOT NULL,
                depth_32nds DOUBLE PRECISION NOT NULL,
                created_at TIMESTAMPTZ DEFAULT now()
            )
        """)

        try await migrateMultiCar()

        // Rename "Oil & Oil Filter Change" -> "Engine Oil & Filter Change" (Elantra
        // data only; the shared services catalog is renamed for everyone)
        let migratedThresholds = try await execute("""
            UPDATE service_thresholds SET service_type = 'Engine Oil & Filter Change'
            WHERE service_type = 'Oil & Oil Filter Change' AND vehicle_id = $1
            RETURNING service_type
        """, params: [Vehicle.elantraId])
        let migratedRecords = try await execute("""
            UPDATE service_records SET service_type = 'Engine Oil & Filter Change'
            WHERE service_type = 'Oil & Oil Filter Change' AND vehicle_id = $1
            RETURNING id
        """, params: [Vehicle.elantraId])
        let migratedServices = try await execute("""
            UPDATE services SET service_type = 'Engine Oil & Filter Change'
            WHERE service_type = 'Oil & Oil Filter Change'
            RETURNING service_type
        """)
        let totalMigrated = migratedThresholds.count + migratedRecords.count + migratedServices.count
        if totalMigrated > 0 {
            Log.db("migration: renamed 'Oil & Oil Filter Change' -> 'Engine Oil & Filter Change' (thresholds: \(migratedThresholds.count), records: \(migratedRecords.count), services: \(migratedServices.count))")
        }

        Log.db("schema initialized")
        try await seedThresholds()
        try await seedServiceCategories()

        // Tire model migration: replace the pair/all tire types with a single
        // corner-aware "Tire Replacement" (logged from Maintenance, which then
        // updates the per-corner tires table). Runs AFTER seedServiceCategories
        // so the count-guarded seed still populates a fresh DB; old records keep
        // their labels.
        try await executeNoResult("""
            INSERT INTO services (id, service_type, category)
            VALUES ($1, 'Tire Replacement', 'Tires')
            ON CONFLICT (service_type) DO NOTHING
        """, params: [UUID().uuidString])
        try await executeNoResult("""
            DELETE FROM services WHERE service_type IN ('New Front Tires', 'New Rear Tires', 'New All Tires')
        """)

        try await seedTires()
        try await seedRetiredTires()
    }

    // MARK: - Multi-Car Migration

    /// Phase A: idempotent DDL, safe to run every launch and safe if interrupted
    /// (each statement either already happened or happens now).
    /// Phase B: backfill + NOT NULL + thresholds PK change in ONE DO block, so it
    /// is a single transaction — all or nothing — and a no-op once the
    /// multi_car_v1 marker exists. Approved SQL; verified on a Neon branch.
    private func migrateMultiCar() async throws {
        // A1
        try await executeNoResult("""
            CREATE TABLE IF NOT EXISTS vehicles (
                id          TEXT PRIMARY KEY,
                nickname    TEXT,
                make        TEXT,
                model       TEXT,
                year        INTEGER,
                vin         TEXT UNIQUE CHECK (vin IS NULL OR vin ~ '^[A-HJ-NPR-Z0-9]{17}$'),
                status      TEXT NOT NULL DEFAULT 'active' CHECK (status IN ('active','retired')),
                created_at  TIMESTAMPTZ NOT NULL DEFAULT now()
            )
        """)

        // A2
        try await executeNoResult("""
            CREATE TABLE IF NOT EXISTS schema_migrations (
                name       TEXT PRIMARY KEY,
                applied_at TIMESTAMPTZ NOT NULL DEFAULT now()
            )
        """)

        // A3
        try await executeNoResult("""
            INSERT INTO vehicles (id, nickname, make, model, year, vin, status)
            VALUES ('vehicle-elantra-2013', '2013 Elantra', 'Hyundai', 'Elantra', 2013, NULL, 'retired')
            ON CONFLICT (id) DO NOTHING
        """)

        // A4
        for table in ["mileage_records", "mileage_snapshots", "service_records", "service_thresholds",
                      "obd_connection_logs", "tires", "tire_rotations", "tire_tread_readings"] {
            try await executeNoResult("""
                ALTER TABLE \(table) ADD COLUMN IF NOT EXISTS vehicle_id TEXT REFERENCES vehicles(id)
            """)
        }

        // A5
        try await executeNoResult("""
            ALTER TABLE obd_connection_logs ADD COLUMN IF NOT EXISTS duration_ms INTEGER
        """)

        // A6
        try await executeNoResult("""
            CREATE TABLE IF NOT EXISTS unassigned_readings (
                id                       TEXT PRIMARY KEY,
                timestamp                TIMESTAMPTZ NOT NULL,
                failure_reason           TEXT NOT NULL,
                vin_raw_response         TEXT,
                peripheral_id            TEXT,
                capture_mode             TEXT,
                rpm                      INTEGER,
                odometer_raw_response    TEXT,
                dist_since_codes_cleared DOUBLE PRECISION,
                dist_raw_response        TEXT,
                assigned_vehicle_id      TEXT REFERENCES vehicles(id),
                assigned_at              TIMESTAMPTZ,
                created_at               TIMESTAMPTZ NOT NULL DEFAULT now()
            )
        """)

        // A7
        let indexes = [
            "CREATE INDEX IF NOT EXISTS idx_mileage_records_vehicle_ts ON mileage_records (vehicle_id, timestamp DESC)",
            "CREATE INDEX IF NOT EXISTS idx_mileage_snapshots_vehicle_ts ON mileage_snapshots (vehicle_id, timestamp DESC)",
            "CREATE INDEX IF NOT EXISTS idx_service_records_vehicle_type_ts ON service_records (vehicle_id, service_type, timestamp DESC)",
            "CREATE INDEX IF NOT EXISTS idx_obd_logs_vehicle_event_ts ON obd_connection_logs (vehicle_id, event_type, timestamp DESC)",
            "CREATE INDEX IF NOT EXISTS idx_tires_vehicle ON tires (vehicle_id)",
            "CREATE INDEX IF NOT EXISTS idx_tire_rotations_vehicle_ts ON tire_rotations (vehicle_id, timestamp DESC)",
            "CREATE INDEX IF NOT EXISTS idx_tread_vehicle_tire_ts ON tire_tread_readings (vehicle_id, tire_id, timestamp DESC)",
        ]
        for sql in indexes {
            try await executeNoResult(sql)
        }

        // Phase B
        try await executeNoResult("""
            DO $$
            DECLARE
                elantra        constant text := 'vehicle-elantra-2013';
                cutoff         timestamptz;
                pk_name        text;
                pk_has_vehicle boolean;
            BEGIN
                PERFORM pg_advisory_xact_lock(hashtext('multi_car_v1'));
                IF EXISTS (SELECT 1 FROM schema_migrations WHERE name = 'multi_car_v1') THEN
                    RETURN;
                END IF;

                UPDATE mileage_records     SET vehicle_id = elantra WHERE vehicle_id IS NULL;
                UPDATE mileage_snapshots   SET vehicle_id = elantra WHERE vehicle_id IS NULL;
                UPDATE service_records     SET vehicle_id = elantra WHERE vehicle_id IS NULL;
                UPDATE service_thresholds  SET vehicle_id = elantra WHERE vehicle_id IS NULL;
                UPDATE tires               SET vehicle_id = elantra WHERE vehicle_id IS NULL;
                UPDATE tire_rotations      SET vehicle_id = elantra WHERE vehicle_id IS NULL;
                UPDATE tire_tread_readings SET vehicle_id = elantra WHERE vehicle_id IS NULL;
                SELECT created_at INTO cutoff FROM vehicles WHERE id = elantra;
                UPDATE obd_connection_logs SET vehicle_id = elantra
                 WHERE vehicle_id IS NULL AND timestamp < cutoff;

                ALTER TABLE mileage_records     ALTER COLUMN vehicle_id SET NOT NULL;
                ALTER TABLE mileage_snapshots   ALTER COLUMN vehicle_id SET NOT NULL;
                ALTER TABLE service_records     ALTER COLUMN vehicle_id SET NOT NULL;
                ALTER TABLE service_thresholds  ALTER COLUMN vehicle_id SET NOT NULL;
                ALTER TABLE tires               ALTER COLUMN vehicle_id SET NOT NULL;
                ALTER TABLE tire_rotations      ALTER COLUMN vehicle_id SET NOT NULL;
                ALTER TABLE tire_tread_readings ALTER COLUMN vehicle_id SET NOT NULL;

                SELECT c.conname,
                       EXISTS (SELECT 1 FROM pg_attribute a
                                WHERE a.attrelid = c.conrelid
                                  AND a.attnum = ANY (c.conkey)
                                  AND a.attname = 'vehicle_id')
                  INTO pk_name, pk_has_vehicle
                  FROM pg_constraint c
                 WHERE c.conrelid = 'service_thresholds'::regclass AND c.contype = 'p';

                IF NOT coalesce(pk_has_vehicle, false) THEN
                    IF pk_name IS NOT NULL THEN
                        EXECUTE format('ALTER TABLE service_thresholds DROP CONSTRAINT %I', pk_name);
                    END IF;
                    ALTER TABLE service_thresholds
                        ADD CONSTRAINT service_thresholds_pkey PRIMARY KEY (vehicle_id, service_type);
                END IF;

                INSERT INTO schema_migrations (name) VALUES ('multi_car_v1');
            END $$
        """)

        let done = try await execute("SELECT 1 AS ok FROM schema_migrations WHERE name = 'multi_car_v1'")
        isMultiCarReady = !done.isEmpty
        if isMultiCarReady {
            UserDefaults.standard.set(Self.databaseFingerprint(), forKey: Self.confirmedKey)
        }
        Log.db("multi-car migration \(isMultiCarReady ? "confirmed" : "NOT confirmed")")
    }

    /// Backfill historical retired tires from reconstructed + user-confirmed
    /// history. Deterministic ids + ON CONFLICT DO NOTHING make this idempotent,
    /// so it runs every launch but only inserts rows that are missing. Old
    /// service_records are left untouched (spend chart unaffected).
    private func seedRetiredTires() async throws {
        let dateFrom: (String) -> Date = { str in
            let f = DateFormatter()
            f.dateFormat = "yyyy-MM-dd"
            f.locale = Locale(identifier: "en_US_POSIX")
            f.timeZone = TimeZone(identifier: "UTC")
            return f.date(from: str) ?? Date()
        }
        // (id, make/model, installOdo, installDate, removedOdo, removedDate)
        let retired: [(String, String, Double, String, Double, String)] = [
            ("retired-mavis",      "Mavis ×4",             129024, "2022-02-16", 156700, "2024-08-12"),
            ("retired-michelin",   "Michelin ×2",          156700, "2024-08-12", 176125, "2026-01-22"),
            ("retired-falken",     "Falken ×2",            156700, "2024-08-12", 164796, "2025-08-09"),
            ("retired-avid-older", "Yokohama Avid Ascend", 164796, "2025-08-09", 186894, "2026-06-25"),
            ("retired-temp",       "Temporary tire",       176125, "2026-01-22", 178400, "2026-02-20"),
        ]
        for r in retired {
            let tire = Tire(
                id: r.0,
                vehicleId: Vehicle.elantraId,
                position: nil,
                makeModel: r.1,
                installOdometer: r.2,
                installDate: dateFrom(r.3),
                removedOdometer: r.4,
                removedDate: dateFrom(r.5),
                replacesTireId: nil,
                notes: nil
            )
            try await saveTire(tire)
        }
        Log.db("retired tires backfilled (\(retired.count) rows)")
    }

    /// Elantra-only seed (its reconstructed layout); never touches other cars.
    private func seedTires() async throws {
        let rows = try await execute("SELECT COUNT(*) as cnt FROM tires WHERE vehicle_id = $1", params: [Vehicle.elantraId])
        let count = parseInt(rows.first?["cnt"]) ?? 0
        guard count == 0 else {
            Log.db("tires already seeded (\(count) rows)")
            return
        }

        Log.db("seeding tires")
        let dateFrom: (String) -> Date = { str in
            let f = DateFormatter()
            f.dateFormat = "yyyy-MM-dd"
            f.locale = Locale(identifier: "en_US_POSIX")
            f.timeZone = TimeZone(identifier: "UTC")
            return f.date(from: str) ?? Date()
        }
        // Reconstructed + user-confirmed current layout.
        let seed: [(TirePosition, String, Double, String)] = [
            (.FL, "Yokohama Avid Ascend", 186894, "2026-06-25"),
            (.FR, "Yokohama Avid Ascend", 164796, "2025-08-09"),
            (.RL, "Yokohama GTX 91V", 178400, "2026-02-20"),
            (.RR, "Yokohama GTX 91V", 176125, "2026-01-22"),
        ]
        for t in seed {
            let tire = Tire.new(vehicleId: Vehicle.elantraId, position: t.0, makeModel: t.1, installOdometer: t.2, installDate: dateFrom(t.3))
            try await saveTire(tire)
        }
        Log.db("tires seeded (\(seed.count) rows)")
    }

    /// Elantra-only seed. New cars get a copy of the Elantra's rows when created.
    private func seedThresholds() async throws {
        let rows = try await execute("SELECT COUNT(*) as cnt FROM service_thresholds WHERE vehicle_id = $1", params: [Vehicle.elantraId])
        let count = parseInt(rows.first?["cnt"]) ?? 0
        guard count == 0 else {
            Log.db("thresholds already seeded (\(count) rows)")
            return
        }

        Log.db("seeding thresholds")
        let thresholds: [(String, Double?, Double?, Int?, Int?, Double?, Double?)] = [
            ("Engine Oil & Filter Change", 7000, 5000, nil, nil, nil, nil),
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
                INSERT INTO service_thresholds (service_type, miles_critical, miles_warning, days_critical, days_warning, rotor_critical, rotor_warning, vehicle_id)
                VALUES ($1, $2, $3, $4, $5, $6, $7, $8)
                ON CONFLICT (vehicle_id, service_type) DO NOTHING
            """, params: [
                t.0,
                t.1 as Any,
                t.2 as Any,
                t.3 as Any,
                t.4 as Any,
                t.5 as Any,
                t.6 as Any,
                Vehicle.elantraId
            ])
        }
        Log.db("thresholds seeded")
    }

    private func seedServiceCategories() async throws {
        let rows = try await execute("SELECT COUNT(*) as cnt FROM services")
        let count = parseInt(rows.first?["cnt"]) ?? 0
        guard count == 0 else {
            Log.db("service categories already seeded (\(count) rows)")
            return
        }

        Log.db("seeding service categories")
        let categories: [(String, String)] = [
            ("Brake Fluid Flush", "Brakes"),
            ("Brake Service", "Brakes"),
            ("Front Brakepad Replacement", "Brakes"),
            ("Rear Brakepad Replacement", "Brakes"),
            ("Front Rotor Thickness Reading", "Brakes"),
            ("Rear Rotor Thickness Reading", "Brakes"),
            ("Engine Oil & Filter Change", "Engine"),
            ("Engine Air Filter", "Engine"),
            ("Cabin Air Filter", "Engine"),
            ("Spark Plug Replacement", "Engine"),
            ("Throttle Body Cleaning", "Engine"),
            ("Coolant Flush", "Cooling"),
            ("Radiator Replacement", "Cooling"),
            ("Transmission Fluid Change", "Transmission"),
            ("Tire Replacement", "Tires"),
            ("Tire Rotation", "Tires"),
            ("Tire Balance", "Tires"),
            ("Wheel Alignment", "Steering & Suspension"),
            ("Sway Bar Link Replacement", "Steering & Suspension"),
            ("Outer Tie Rod Replacement", "Steering & Suspension"),
            ("Battery Replacement", "Electrical"),
            ("Headlight Replacement", "Electrical"),
            ("Bulb Replacement", "Electrical"),
            ("Starting System Check", "Electrical"),
            ("A/C Recharge", "HVAC"),
            ("A/C Service Valve Replacement", "HVAC"),
            ("Exterior Wash & Ceramic Detail", "Exterior"),
            ("Exterior Wash & Paste Wax", "Exterior"),
            ("Exterior Wash & Ceramic Wax", "Exterior"),
            ("Current Mileage", "General"),
            ("Parts Purchase", "General"),
            ("Tag Renewal", "General"),
            ("Vehicle Inspection", "General"),
            ("Washer Fluid Reservoir Replacement", "General"),
        ]

        for (serviceType, category) in categories {
            try await executeNoResult("""
                INSERT INTO services (id, service_type, category)
                VALUES ($1, $2, $3)
                ON CONFLICT (service_type) DO NOTHING
            """, params: [UUID().uuidString, serviceType, category])
        }
        Log.db("service categories seeded (\(categories.count) rows)")
    }

    // MARK: - Vehicles

    private let vehicleColumns = "id, nickname, make, model, year, vin, status, created_at"

    func getVehicle(id: String) async throws -> Vehicle? {
        let rows = try await execute("SELECT \(vehicleColumns) FROM vehicles WHERE id = $1", params: [id])
        return rows.first.flatMap { parseVehicle($0) }
    }

    func getVehicle(byVIN vin: String) async throws -> Vehicle? {
        let rows = try await execute("SELECT \(vehicleColumns) FROM vehicles WHERE vin = $1", params: [vin.uppercased()])
        return rows.first.flatMap { parseVehicle($0) }
    }

    /// Newest first.
    func getActiveVehicles() async throws -> [Vehicle] {
        let rows = try await execute("SELECT \(vehicleColumns) FROM vehicles WHERE status = 'active' ORDER BY created_at DESC")
        return rows.compactMap { parseVehicle($0) }
    }

    /// Newest first.
    func getAllVehicles() async throws -> [Vehicle] {
        let rows = try await execute("SELECT \(vehicleColumns) FROM vehicles ORDER BY created_at DESC")
        return rows.compactMap { parseVehicle($0) }
    }

    /// Insert a vehicle and, in the same statement (so the same transaction),
    /// copy `thresholdsFrom`'s service thresholds to it. If the VIN or id
    /// already exists nothing is inserted or copied; the stored row is returned.
    @discardableResult
    func createVehicle(_ vehicle: Vehicle, copyingThresholdsFrom sourceId: String? = nil) async throws -> Vehicle {
        let vin = vehicle.vin?.uppercased()
        let params: [Any] = [
            vehicle.id, vehicle.nickname as Any, vehicle.make as Any, vehicle.model as Any,
            vehicle.year as Any, vin as Any, vehicle.status.rawValue
        ]
        if let sourceId {
            try await executeNoResult("""
                WITH v AS (
                    INSERT INTO vehicles (id, nickname, make, model, year, vin, status)
                    VALUES ($1, $2, $3, $4, $5, $6, $7)
                    ON CONFLICT DO NOTHING
                    RETURNING id
                )
                INSERT INTO service_thresholds (vehicle_id, service_type, miles_critical, miles_warning,
                                                days_critical, days_warning, rotor_critical, rotor_warning)
                SELECT v.id, st.service_type, st.miles_critical, st.miles_warning,
                       st.days_critical, st.days_warning, st.rotor_critical, st.rotor_warning
                FROM v CROSS JOIN service_thresholds st
                WHERE st.vehicle_id = $8
                ON CONFLICT (vehicle_id, service_type) DO NOTHING
            """, params: params + [sourceId as Any])
        } else {
            try await executeNoResult("""
                INSERT INTO vehicles (id, nickname, make, model, year, vin, status)
                VALUES ($1, $2, $3, $4, $5, $6, $7)
                ON CONFLICT DO NOTHING
            """, params: params)
        }
        let stored: Vehicle?
        if let vin {
            stored = try await getVehicle(byVIN: vin)
        } else {
            stored = try await getVehicle(id: vehicle.id)
        }
        guard let stored else { throw NeonError.invalidResponse }
        return stored
    }

    /// Copy every threshold row of one car to another. Safe to repeat.
    func copyThresholds(from sourceId: String, to targetId: String) async throws {
        try await executeNoResult("""
            INSERT INTO service_thresholds (vehicle_id, service_type, miles_critical, miles_warning,
                                            days_critical, days_warning, rotor_critical, rotor_warning)
            SELECT $2::text, service_type, miles_critical, miles_warning,
                   days_critical, days_warning, rotor_critical, rotor_warning
            FROM service_thresholds WHERE vehicle_id = $1
            ON CONFLICT (vehicle_id, service_type) DO NOTHING
        """, params: [sourceId, targetId])
    }

    func setVehicleStatus(id: String, status: VehicleStatus) async throws {
        try await executeNoResult("UPDATE vehicles SET status = $2 WHERE id = $1", params: [id, status.rawValue])
    }

    /// Save the editable fields of a car (Vehicles screen). The VIN never changes.
    func updateVehicle(_ vehicle: Vehicle) async throws {
        try await executeNoResult("""
            UPDATE vehicles SET nickname = $2, make = $3, model = $4, year = $5, status = $6 WHERE id = $1
        """, params: [
            vehicle.id, vehicle.nickname as Any, vehicle.make as Any, vehicle.model as Any,
            vehicle.year as Any, vehicle.status.rawValue
        ])
    }

    /// Fill only what is still empty, in the database itself, so a lookup that
    /// finishes late can never overwrite something the user typed meanwhile.
    /// The nickname is replaced only if it is empty or still `automaticNickname`.
    func fillMissingVehicleDetails(id: String, make: String?, model: String?, year: Int?,
                                   nickname: String?, replacingAutomaticNickname automaticNickname: String?) async throws {
        try await executeNoResult("""
            UPDATE vehicles SET
                make     = COALESCE(NULLIF(make, ''), $2),
                model    = COALESCE(NULLIF(model, ''), $3),
                year     = COALESCE(year, $4),
                nickname = CASE
                    WHEN $5::text IS NOT NULL AND (nickname IS NULL OR nickname = '' OR nickname = $6::text) THEN $5::text
                    ELSE nickname
                END
            WHERE id = $1
        """, params: [id, make as Any, model as Any, year as Any, nickname as Any, automaticNickname as Any])
    }

    private func parseVehicle(_ row: [String: Any]) -> Vehicle? {
        guard let id = parseString(row["id"]) else {
            Log.db("failed to parse vehicle: \(row)")
            return nil
        }
        return Vehicle(
            id: id,
            nickname: parseString(row["nickname"]),
            make: parseString(row["make"]),
            model: parseString(row["model"]),
            year: parseInt(row["year"]),
            vin: parseString(row["vin"]),
            status: parseString(row["status"]).flatMap { VehicleStatus(rawValue: $0) } ?? .active,
            createdAt: parseDate(row["created_at"])
        )
    }

    // MARK: - Unassigned Readings

    func saveUnassignedReading(_ r: UnassignedReading) async throws {
        try await executeNoResult("""
            INSERT INTO unassigned_readings (id, timestamp, failure_reason, vin_raw_response, peripheral_id,
                capture_mode, rpm, odometer_raw_response, dist_since_codes_cleared, dist_raw_response)
            VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10)
            ON CONFLICT (id) DO NOTHING
        """, params: [
            r.id, r.timestamp, r.failureReason, r.vinRawResponse as Any, r.peripheralId as Any,
            r.captureMode as Any, r.rpm as Any, r.odometerRawResponse as Any,
            r.distSinceCodesCleared as Any, r.distRawResponse as Any
        ])
    }

    /// Readings not yet assigned to a car, newest first.
    func getUnassignedReadings() async throws -> [UnassignedReading] {
        let rows = try await execute("""
            SELECT id, timestamp, failure_reason, vin_raw_response, peripheral_id, capture_mode, rpm,
                   odometer_raw_response, dist_since_codes_cleared, dist_raw_response, assigned_vehicle_id, assigned_at
            FROM unassigned_readings WHERE assigned_vehicle_id IS NULL ORDER BY timestamp DESC
        """)
        return rows.compactMap { row in
            guard let id = parseString(row["id"]),
                  let reason = parseString(row["failure_reason"]) else { return nil }
            return UnassignedReading(
                id: id,
                timestamp: parseDate(row["timestamp"]) ?? Date(),
                failureReason: reason,
                vinRawResponse: parseString(row["vin_raw_response"]),
                peripheralId: parseString(row["peripheral_id"]),
                captureMode: parseString(row["capture_mode"]),
                rpm: parseInt(row["rpm"]),
                odometerRawResponse: parseString(row["odometer_raw_response"]),
                distSinceCodesCleared: parseDouble(row["dist_since_codes_cleared"]),
                distRawResponse: parseString(row["dist_raw_response"]),
                assignedVehicleId: parseString(row["assigned_vehicle_id"]),
                assignedAt: parseDate(row["assigned_at"])
            )
        }
    }

    func countUnassignedReadings() async throws -> Int {
        let rows = try await execute("SELECT COUNT(*) AS cnt FROM unassigned_readings WHERE assigned_vehicle_id IS NULL")
        return parseInt(rows.first?["cnt"]) ?? 0
    }

    func markUnassignedReadingAssigned(id: String, vehicleId: String) async throws {
        try await executeNoResult("""
            UPDATE unassigned_readings SET assigned_vehicle_id = $2, assigned_at = now() WHERE id = $1
        """, params: [id, vehicleId])
    }

    func deleteUnassignedReading(id: String) async throws {
        try await executeNoResult("DELETE FROM unassigned_readings WHERE id = $1", params: [id])
    }

    // MARK: - Mileage Records

    private let mileageColumns = "id, vehicle_id, timestamp, odometer_miles, source, dist_since_codes_cleared"

    func saveMileageRecord(_ record: MileageRecord) async throws {
        let vehicleId = try requireVehicle(record.vehicleId)
        Log.db("saving mileage record")
        try await executeNoResult("""
            INSERT INTO mileage_records (id, timestamp, odometer_miles, source, dist_since_codes_cleared, vehicle_id)
            VALUES ($1, $2, $3, $4, $5, $6)
            ON CONFLICT (id) DO NOTHING
        """, params: [record.id, record.timestamp, record.odometerMiles, record.source, record.distSinceCodesCleared as Any, vehicleId])
        Log.db("record saved")
    }

    func getMileageRecords(vehicleId: String) async throws -> [MileageRecord] {
        let rows = try await execute("""
            SELECT \(mileageColumns) FROM mileage_records WHERE \(vehicleFilter(1)) ORDER BY timestamp DESC
        """, params: [vehicleId])
        return rows.compactMap { parseMileageRecord($0) }
    }

    func updateMileageRecord(_ record: MileageRecord) async throws {
        try await executeNoResult("""
            UPDATE mileage_records SET timestamp = $2, odometer_miles = $3, source = $4, dist_since_codes_cleared = $5, synced_at = now() WHERE id = $1
        """, params: [record.id, record.timestamp, record.odometerMiles, record.source, record.distSinceCodesCleared as Any])
    }

    func deleteMileageRecord(id: String) async throws {
        try await executeNoResult("DELETE FROM mileage_records WHERE id = $1", params: [id])
    }

    func getTodayBLEAutoRecord(vehicleId: String) async throws -> MileageRecord? {
        // Get this car's most recent BLE_AUTO record, then check date in Swift (avoids Postgres timezone issues)
        let rows = try await execute("""
            SELECT \(mileageColumns) FROM mileage_records
            WHERE source = 'BLE_AUTO' AND \(vehicleFilter(1))
            ORDER BY timestamp DESC LIMIT 1
        """, params: [vehicleId])
        guard let record = rows.first.flatMap({ parseMileageRecord($0) }) else { return nil }

        // Compare dates in local timezone
        let cal = Calendar.current
        if cal.isDateInToday(record.timestamp) {
            return record
        }
        return nil
    }

    /// This car's BLE_AUTO record on the local calendar day of `date` (bounds are
    /// computed in Swift, like `getTodayBLEAutoRecord`). Used when replaying an
    /// offline capture, which belongs to the day it was taken, not the day it syncs.
    func getBLEAutoRecord(vehicleId: String, onDayOf date: Date) async throws -> MileageRecord? {
        let start = Calendar.current.startOfDay(for: date)
        guard let end = Calendar.current.date(byAdding: .day, value: 1, to: start) else { return nil }
        let rows = try await execute("""
            SELECT \(mileageColumns) FROM mileage_records
            WHERE source = 'BLE_AUTO' AND \(vehicleFilter(1)) AND timestamp >= $2 AND timestamp < $3
            ORDER BY timestamp DESC LIMIT 1
        """, params: [vehicleId, start, end])
        return rows.first.flatMap { parseMileageRecord($0) }
    }

    /// This car's latest record taken at or before `date` — what the car's
    /// history looked like when an offline capture was taken.
    func getLatestMileageRecord(vehicleId: String, onOrBefore date: Date) async throws -> MileageRecord? {
        let rows = try await execute("""
            SELECT \(mileageColumns) FROM mileage_records
            WHERE \(vehicleFilter(1)) AND timestamp <= $2
            ORDER BY timestamp DESC LIMIT 1
        """, params: [vehicleId, date])
        return rows.first.flatMap { parseMileageRecord($0) }
    }

    func getLatestMileageRecord(vehicleId: String) async throws -> MileageRecord? {
        let rows = try await execute("""
            SELECT \(mileageColumns) FROM mileage_records
            WHERE \(vehicleFilter(1))
            ORDER BY timestamp DESC LIMIT 1
        """, params: [vehicleId])
        return rows.first.flatMap { parseMileageRecord($0) }
    }

    /// Get this car's latest MANUAL entry — the reference point for its mileage calculation
    func getLatestManualMileageRecord(vehicleId: String) async throws -> MileageRecord? {
        let rows = try await execute("""
            SELECT \(mileageColumns) FROM mileage_records
            WHERE source = 'MANUAL' AND \(vehicleFilter(1)) ORDER BY timestamp DESC LIMIT 1
        """, params: [vehicleId])
        return rows.first.flatMap { parseMileageRecord($0) }
    }

    // MARK: - Service Records

    private let serviceColumns = "id, vehicle_id, timestamp, service_type, category, odometer_miles, rotor_thickness_mm, amount, comments, manually_edited"

    func saveServiceRecord(_ record: ServiceRecord) async throws {
        let vehicleId = try requireVehicle(record.vehicleId)
        try await executeNoResult("""
            INSERT INTO service_records (id, timestamp, service_type, category, odometer_miles, rotor_thickness_mm, amount, comments, manually_edited, vehicle_id)
            VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10)
            ON CONFLICT (id) DO NOTHING
        """, params: [
            record.id, record.timestamp, record.serviceType, record.category,
            record.odometerMiles, record.rotorThicknessMM as Any,
            record.amount as Any, record.comments as Any, record.manuallyEdited, vehicleId
        ])
    }

    func getServiceRecords(vehicleId: String) async throws -> [ServiceRecord] {
        let rows = try await execute("""
            SELECT \(serviceColumns)
            FROM service_records WHERE \(vehicleFilter(1)) ORDER BY timestamp DESC
        """, params: [vehicleId])
        return rows.compactMap { parseServiceRecord($0) }
    }

    func getLatestRecord(for serviceType: String, vehicleId: String) async throws -> ServiceRecord? {
        let rows = try await execute("""
            SELECT \(serviceColumns)
            FROM service_records WHERE service_type = $1 AND \(vehicleFilter(2)) ORDER BY timestamp DESC LIMIT 1
        """, params: [serviceType, vehicleId])
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

    func saveMileageSnapshot(vehicleId: String, odometer: Double, distSinceCodesCleared: Double?, rpm: Int?, captureMode: String,
                             timestamp: Date = Date()) async {
        do {
            try await executeNoResult("""
                INSERT INTO mileage_snapshots (id, timestamp, odometer_miles, dist_since_codes_cleared, rpm, capture_mode, vehicle_id)
                VALUES ($1, $2, $3, $4, $5, $6, $7)
            """, params: [
                UUID().uuidString, timestamp, odometer,
                distSinceCodesCleared as Any, rpm as Any, captureMode, vehicleId
            ])
            // Purge old snapshots (keep 7 days)
            try await executeNoResult("""
                DELETE FROM mileage_snapshots WHERE timestamp < now() - INTERVAL '7 days'
            """)
        } catch {
            Log.db("failed to save mileage snapshot: \(error.localizedDescription)")
        }
    }

    /// `vehicleId` has no default on purpose: every call site must say which car
    /// (nil only before the VIN is known).
    func logOBDEvent(vehicleId: String?, eventType: String, pid: String?, rawResponse: String?,
                     parsedValue: Double?, success: Bool, errorMessage: String?, durationMs: Int?) async {
        let entry = OBDLogEntry(
            id: UUID().uuidString, timestamp: Date(), vehicleId: vehicleId, eventType: eventType, pid: pid,
            rawResponse: rawResponse, parsedValue: parsedValue, success: success,
            errorMessage: errorMessage, durationMs: durationMs)
        do {
            try await writeOBDEvent(entry)
        } catch {
            Log.db("failed to log OBD event: \(error.localizedDescription)")
        }
    }

    /// Writes one log row and reports failure, for callers that queue what
    /// couldn't be written. Idempotent on `entry.id`.
    func writeOBDEvent(_ entry: OBDLogEntry) async throws {
        try await executeNoResult("""
            INSERT INTO obd_connection_logs (id, timestamp, event_type, pid, raw_response, parsed_value, success, error_message, vehicle_id, duration_ms)
            VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10)
            ON CONFLICT (id) DO NOTHING
        """, params: [
            entry.id, entry.timestamp, entry.eventType,
            entry.pid as Any, entry.rawResponse as Any, entry.parsedValue as Any,
            entry.success, entry.errorMessage as Any, entry.vehicleId as Any, entry.durationMs as Any
        ])
    }

    /// Latest successful 0131 value logged for this car. Strict match: a log
    /// with no car means "car unknown", never the Elantra.
    func getOBDDistSinceCleared(vehicleId: String) async throws -> Double? {
        let rows = try await execute("""
            SELECT parsed_value FROM obd_connection_logs
            WHERE event_type = 'dist_since_clear' AND success = true AND vehicle_id = $1
            ORDER BY timestamp DESC LIMIT 1
        """, params: [vehicleId])
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

    /// Persist a user-entered service type into the catalog so it appears in
    /// the picker on future launches. No-op if it already exists.
    func addServiceType(_ serviceType: String, category: String) async throws {
        try await executeNoResult("""
            INSERT INTO services (id, service_type, category)
            VALUES ($1, $2, $3)
            ON CONFLICT (service_type) DO NOTHING
        """, params: [UUID().uuidString, serviceType, category])
    }

    func getServiceCategories() async throws -> [ServiceCategory] {
        let rows = try await execute("SELECT service_type, category FROM services ORDER BY category, service_type")
        var catMap: [String: [String]] = [:]
        var catOrder: [String] = []
        for row in rows {
            guard let serviceType = parseString(row["service_type"]),
                  let category = parseString(row["category"]) else { continue }
            if catMap[category] == nil { catOrder.append(category) }
            catMap[category, default: []].append(serviceType)
        }
        return catOrder.map { cat in
            ServiceCategory(name: cat, icon: ServiceCategory.iconFor(cat), types: catMap[cat] ?? [])
        }
    }

    // MARK: - Tires

    private let tireColumns = "id, vehicle_id, position, make_model, install_odometer, install_date, removed_odometer, removed_date, replaces_tire_id, notes"

    func getActiveTires(vehicleId: String) async throws -> [Tire] {
        let rows = try await execute("""
            SELECT \(tireColumns)
            FROM tires WHERE removed_odometer IS NULL AND \(vehicleFilter(1))
        """, params: [vehicleId])
        return rows.compactMap { parseTire($0) }
    }

    func getAllTires(vehicleId: String) async throws -> [Tire] {
        let rows = try await execute("""
            SELECT \(tireColumns)
            FROM tires WHERE \(vehicleFilter(1)) ORDER BY install_date DESC
        """, params: [vehicleId])
        return rows.compactMap { parseTire($0) }
    }

    func saveTire(_ tire: Tire) async throws {
        try await executeNoResult("""
            INSERT INTO tires (id, position, make_model, install_odometer, install_date, removed_odometer, removed_date, replaces_tire_id, notes, vehicle_id)
            VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10)
            ON CONFLICT (id) DO NOTHING
        """, params: [
            tire.id, tire.position?.rawValue as Any, tire.makeModel as Any,
            tire.installOdometer, tire.installDate,
            tire.removedOdometer as Any, tire.removedDate as Any,
            tire.replacesTireId as Any, tire.notes as Any, tire.vehicleId
        ])
    }

    func updateTire(_ tire: Tire) async throws {
        try await executeNoResult("""
            UPDATE tires SET position = $2, make_model = $3, install_odometer = $4, install_date = $5,
            removed_odometer = $6, removed_date = $7, replaces_tire_id = $8, notes = $9
            WHERE id = $1
        """, params: [
            tire.id, tire.position?.rawValue as Any, tire.makeModel as Any,
            tire.installOdometer, tire.installDate,
            tire.removedOdometer as Any, tire.removedDate as Any,
            tire.replacesTireId as Any, tire.notes as Any
        ])
    }

    func deleteTire(id: String) async throws {
        try await executeNoResult("DELETE FROM tires WHERE id = $1", params: [id])
    }

    /// Persist an edited tire, swapping corners with any active tire already in
    /// the destination so two tires never occupy the same corner.
    func updateTireResolvingPosition(_ tire: Tire) async throws {
        let active = try await getActiveTires(vehicleId: tire.vehicleId)
        let updates = TireMove.resolve(activeTires: active, moving: tire.id, to: tire.position)
        for u in updates where u.id != tire.id {
            if var occupant = active.first(where: { $0.id == u.id }) {
                occupant.position = u.position
                try await updateTire(occupant)
            }
        }
        try await updateTire(tire)
    }

    /// Retire the active tire at `position` and install a new one in its place,
    /// linking the new tire to the retired one (1:1 lineage).
    @discardableResult
    func replaceTire(vehicleId: String, at position: TirePosition, makeModel: String?, odometer: Double, date: Date, notes: String?) async throws -> Tire {
        let active = try await getActiveTires(vehicleId: vehicleId)
        var replacesId: String? = nil
        if var old = active.first(where: { $0.position == position }) {
            old.removedOdometer = odometer
            old.removedDate = date
            old.position = nil
            try await updateTire(old)
            replacesId = old.id
        }
        let new = Tire.new(vehicleId: vehicleId, position: position, makeModel: makeModel, installOdometer: odometer, installDate: date, notes: notes, replacesTireId: replacesId)
        try await saveTire(new)
        return new
    }

    /// Apply a rotation mapping (old corner → new corner) to the active tires and log it.
    func applyRotation(vehicleId: String, mapping: [TirePosition: TirePosition], odometer: Double, date: Date, pattern: String, comments: String?) async throws {
        let active = try await getActiveTires(vehicleId: vehicleId)
        for var tire in active {
            guard let pos = tire.position, let newPos = mapping[pos] else { continue }
            tire.position = newPos
            try await updateTire(tire)
        }
        try await saveTireRotation(TireRotation.new(vehicleId: vehicleId, odometer: odometer, date: date, pattern: pattern, comments: comments))
    }

    func saveTireRotation(_ rotation: TireRotation) async throws {
        try await executeNoResult("""
            INSERT INTO tire_rotations (id, timestamp, odometer_miles, pattern, comments, vehicle_id)
            VALUES ($1, $2, $3, $4, $5, $6)
            ON CONFLICT (id) DO NOTHING
        """, params: [
            rotation.id, rotation.timestamp, rotation.odometer, rotation.pattern, rotation.comments as Any, rotation.vehicleId
        ])
    }

    func saveTreadReading(_ reading: TireTreadReading) async throws {
        try await executeNoResult("""
            INSERT INTO tire_tread_readings (id, tire_id, timestamp, odometer_miles, depth_32nds, vehicle_id)
            VALUES ($1, $2, $3, $4, $5, $6)
            ON CONFLICT (id) DO NOTHING
        """, params: [
            reading.id, reading.tireId, reading.timestamp, reading.odometer, reading.depth32nds, reading.vehicleId
        ])
    }

    func getAllTreadReadings(vehicleId: String) async throws -> [TireTreadReading] {
        let rows = try await execute("""
            SELECT id, vehicle_id, tire_id, timestamp, odometer_miles, depth_32nds FROM tire_tread_readings
            WHERE \(vehicleFilter(1)) ORDER BY timestamp ASC
        """, params: [vehicleId])
        return rows.compactMap { parseTreadReading($0) }
    }

    /// Latest reading per tire, keyed by tire id — for showing current tread.
    func getLatestTreadReadingsByTire(vehicleId: String) async throws -> [String: TireTreadReading] {
        let rows = try await execute("""
            SELECT DISTINCT ON (tire_id) id, vehicle_id, tire_id, timestamp, odometer_miles, depth_32nds
            FROM tire_tread_readings WHERE \(vehicleFilter(1)) ORDER BY tire_id, timestamp DESC
        """, params: [vehicleId])
        var map: [String: TireTreadReading] = [:]
        for row in rows {
            if let r = parseTreadReading(row) { map[r.tireId] = r }
        }
        return map
    }

    private func parseTreadReading(_ row: [String: Any]) -> TireTreadReading? {
        guard let id = parseString(row["id"]),
              let tireId = parseString(row["tire_id"]),
              let odometer = parseDouble(row["odometer_miles"]),
              let depth = parseDouble(row["depth_32nds"]) else {
            Log.db("failed to parse tread reading: \(row)")
            return nil
        }
        return TireTreadReading(
            id: id,
            vehicleId: parseString(row["vehicle_id"]) ?? Vehicle.elantraId,
            tireId: tireId,
            timestamp: parseDate(row["timestamp"]) ?? Date(),
            odometer: odometer,
            depth32nds: depth
        )
    }

    func getTireRotations(vehicleId: String) async throws -> [TireRotation] {
        let rows = try await execute("""
            SELECT id, vehicle_id, timestamp, odometer_miles, pattern, comments FROM tire_rotations
            WHERE \(vehicleFilter(1)) ORDER BY timestamp DESC
        """, params: [vehicleId])
        return rows.compactMap { row in
            guard let id = parseString(row["id"]),
                  let odometer = parseDouble(row["odometer_miles"]) else { return nil }
            let timestamp = parseDate(row["timestamp"]) ?? Date()
            return TireRotation(
                id: id,
                vehicleId: parseString(row["vehicle_id"]) ?? Vehicle.elantraId,
                timestamp: timestamp,
                odometer: odometer,
                pattern: parseString(row["pattern"]) ?? "",
                comments: parseString(row["comments"])
            )
        }
    }

    private func parseTire(_ row: [String: Any]) -> Tire? {
        guard let id = parseString(row["id"]),
              let installOdometer = parseDouble(row["install_odometer"]) else {
            Log.db("failed to parse tire: \(row)")
            return nil
        }
        let installDate = parseDate(row["install_date"]) ?? Date()
        return Tire(
            id: id,
            vehicleId: parseString(row["vehicle_id"]) ?? Vehicle.elantraId,
            position: parseString(row["position"]).flatMap { TirePosition(rawValue: $0) },
            makeModel: parseString(row["make_model"]),
            installOdometer: installOdometer,
            installDate: installDate,
            removedOdometer: parseDouble(row["removed_odometer"]),
            removedDate: parseDate(row["removed_date"]),
            replacesTireId: parseString(row["replaces_tire_id"]),
            notes: parseString(row["notes"])
        )
    }

    /// Add or change one car's interval for a service type.
    func upsertThreshold(_ threshold: ServiceThreshold, vehicleId: String) async throws {
        try await executeNoResult("""
            INSERT INTO service_thresholds (vehicle_id, service_type, miles_critical, miles_warning,
                                            days_critical, days_warning, rotor_critical, rotor_warning)
            VALUES ($1, $2, $3, $4, $5, $6, $7, $8)
            ON CONFLICT (vehicle_id, service_type) DO UPDATE SET
                miles_critical = EXCLUDED.miles_critical,
                miles_warning  = EXCLUDED.miles_warning,
                days_critical  = EXCLUDED.days_critical,
                days_warning   = EXCLUDED.days_warning,
                rotor_critical = EXCLUDED.rotor_critical,
                rotor_warning  = EXCLUDED.rotor_warning
        """, params: [
            vehicleId, threshold.serviceType,
            threshold.milesCritical as Any, threshold.milesWarning as Any,
            threshold.daysCritical as Any, threshold.daysWarning as Any,
            threshold.rotorCritical as Any, threshold.rotorWarning as Any
        ])
    }

    /// Stop tracking a service type for one car. Its service history is untouched.
    func deleteThreshold(vehicleId: String, serviceType: String) async throws {
        try await executeNoResult("""
            DELETE FROM service_thresholds WHERE vehicle_id = $1 AND service_type = $2
        """, params: [vehicleId, serviceType])
    }

    func getThresholds(vehicleId: String) async throws -> [ServiceThreshold] {
        let rows = try await execute("SELECT * FROM service_thresholds WHERE \(vehicleFilter(1))", params: [vehicleId])
        return rows.compactMap { row in
            guard let serviceType = parseString(row["service_type"]) else { return nil }
            return ServiceThreshold(
                serviceType: serviceType,
                milesCritical: parseDouble(row["miles_critical"]),
                milesWarning: parseDouble(row["miles_warning"]),
                daysCritical: parseInt(row["days_critical"]),
                daysWarning: parseInt(row["days_warning"]),
                rotorCritical: parseDouble(row["rotor_critical"]),
                rotorWarning: parseDouble(row["rotor_warning"]),
                vehicleId: parseString(row["vehicle_id"]) ?? Vehicle.elantraId
            )
        }
    }

    // MARK: - Dashboard

    func getDashboardData(vehicleId: String) async throws -> [DashboardRow] {
        let thresholds = try await getThresholds(vehicleId: vehicleId)
        let latestMileage = try await getLatestMileageRecord(vehicleId: vehicleId)
        let currentOdometer = latestMileage?.odometerMiles ?? 0

        var rows: [DashboardRow] = []
        for threshold in thresholds {
            let lastService = try await getLatestRecord(for: threshold.serviceType, vehicleId: vehicleId)
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
                milesCritical: threshold.milesCritical,
                daysWarning: threshold.daysWarning,
                daysCritical: threshold.daysCritical
            ))
        }

        return rows.sorted { a, b in
            if a.status != b.status { return a.status < b.status }
            let aUrgency = a.milesToCritical ?? .greatestFiniteMagnitude
            let bUrgency = b.milesToCritical ?? .greatestFiniteMagnitude
            if aUrgency != bUrgency { return aUrgency < bUrgency }
            return a.serviceType < b.serviceType
        }
    }

    func getTrackedItems(vehicleId: String) async throws -> [TrackedItem] {
        let currentOdometer = try await getLatestMileageRecord(vehicleId: vehicleId)?.odometerMiles ?? 0
        // IS NOT DISTINCT FROM so the join also matches before the backfill (both NULL)
        let rows = try await execute("""
            SELECT DISTINCT ON (sr.service_type)
                sr.service_type, sr.timestamp, sr.odometer_miles, sr.amount, sr.comments
            FROM service_records sr
            LEFT JOIN service_thresholds st
                   ON st.service_type = sr.service_type
                  AND st.vehicle_id IS NOT DISTINCT FROM sr.vehicle_id
            WHERE st.service_type IS NULL AND \(vehicleFilter(1, column: "sr.vehicle_id"))
            ORDER BY sr.service_type, sr.timestamp DESC
        """, params: [vehicleId])
        let items: [TrackedItem] = rows.compactMap { row in
            guard let serviceType = parseString(row["service_type"]),
                  let odometer = parseDouble(row["odometer_miles"]) else {
                Log.db("failed to parse tracked item: \(row)")
                return nil
            }
            let timestamp = parseDate(row["timestamp"]) ?? Date()
            return TrackedItem(
                serviceType: serviceType,
                lastServiceDate: timestamp,
                lastServiceMileage: odometer,
                milesSince: max(0, currentOdometer - odometer),
                amount: parseDouble(row["amount"]),
                comments: parseString(row["comments"])
            )
        }
        return items.sorted { $0.milesSince < $1.milesSince }
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
        return MileageRecord(
            id: id,
            vehicleId: parseString(row["vehicle_id"]) ?? Vehicle.elantraId,
            timestamp: timestamp,
            odometerMiles: odometer,
            source: source,
            distSinceCodesCleared: distSinceCodesCleared
        )
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
            vehicleId: parseString(row["vehicle_id"]) ?? Vehicle.elantraId,
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
    case missingVehicle

    var errorDescription: String? {
        switch self {
        // Plain sentences only: the raw HTTP status and server text are logged by `execute`.
        case .invalidURL: return "The database address is invalid."
        case .invalidResponse: return "The database sent an unexpected reply."
        case .httpError: return "The database couldn't complete that request."
        case .missingVehicle: return "No car is selected for this entry."
        }
    }
}
