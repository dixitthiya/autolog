# AutoLog Database Schema

All tables are stored in NeonDB (Postgres) and accessed via the Neon HTTP API. Schema is auto-created on first app launch via `NeonRepository.initializeSchema()`.

---

## Tables

### mileage_records

Daily odometer records — one per day, auto-logged via BLE or entered manually.

| Column | Type | Nullable | Description |
|--------|------|----------|-------------|
| id | TEXT | PK | UUID |
| timestamp | TIMESTAMPTZ | NOT NULL | When the reading was taken |
| odometer_miles | DOUBLE PRECISION | NOT NULL | Odometer reading in miles |
| source | TEXT | NOT NULL | `BLE_AUTO`, `MANUAL`, or `IMPORTED` |
| dist_since_codes_cleared | DOUBLE PRECISION | YES | PID 0131 value at time of capture |
| synced_at | TIMESTAMPTZ | DEFAULT now() | When the record was synced to Neon |
| created_at | TIMESTAMPTZ | DEFAULT now() | Row creation time |

---

### mileage_snapshots

Every single OBD capture — not deduplicated, not one-per-day. Auto-purged after 7 days. Used for debugging and understanding capture behavior.

| Column | Type | Nullable | Description |
|--------|------|----------|-------------|
| id | TEXT | PK | UUID |
| timestamp | TIMESTAMPTZ | NOT NULL | When the snapshot was taken |
| odometer_miles | DOUBLE PRECISION | NOT NULL | Odometer reading in miles |
| dist_since_codes_cleared | DOUBLE PRECISION | YES | PID 0131 value |
| rpm | INTEGER | YES | Engine RPM (PID 010C) at capture time |
| capture_mode | TEXT | YES | What triggered this capture (see below) |
| created_at | TIMESTAMPTZ | DEFAULT now() | Row creation time |

#### capture_mode values

| Value | Trigger |
|-------|---------|
| `app_launch` | First capture after app starts |
| `fg_resume` | App returns to foreground |
| `fg_timer` | 2-min auto-scan timer (app in foreground) |
| `throttle_retry` | 10s retry after engine-off RPM=0 |
| `bg_auto` | Any background capture (iOS CB reconnect, state restore, BT power on) |

---

### service_records

All maintenance service records — oil changes, brake service, tire rotations, etc.

| Column | Type | Nullable | Description |
|--------|------|----------|-------------|
| id | TEXT | PK | UUID |
| timestamp | TIMESTAMPTZ | NOT NULL | When the service was performed |
| service_type | TEXT | NOT NULL | e.g. "Oil & Oil Filter Change" |
| category | TEXT | NOT NULL | Grouping category |
| odometer_miles | DOUBLE PRECISION | NOT NULL | Odometer at time of service |
| rotor_thickness_mm | DOUBLE PRECISION | YES | Rotor measurement (brake services only) |
| amount | DOUBLE PRECISION | YES | Cost of service |
| comments | TEXT | YES | Free-text notes |
| manually_edited | BOOLEAN | DEFAULT false | Whether the record was edited after creation |
| created_at | TIMESTAMPTZ | DEFAULT now() | Row creation time |

---

### service_thresholds

Service interval thresholds — defines when warnings and critical alerts trigger. Seeded on first launch.

| Column | Type | Nullable | Description |
|--------|------|----------|-------------|
| service_type | TEXT | PK | Matches `service_records.service_type` |
| miles_critical | DOUBLE PRECISION | YES | Miles after service → critical |
| miles_warning | DOUBLE PRECISION | YES | Miles after service → warning |
| days_critical | INTEGER | YES | Days after service → critical |
| days_warning | INTEGER | YES | Days after service → warning |
| rotor_critical | DOUBLE PRECISION | YES | Rotor thickness mm → critical |
| rotor_warning | DOUBLE PRECISION | YES | Rotor thickness mm → warning |

---

### obd_connection_logs

Raw OBD event log — every PID read, init, failure, and skip is recorded here for debugging.

| Column | Type | Nullable | Description |
|--------|------|----------|-------------|
| id | TEXT | PK | UUID |
| timestamp | TIMESTAMPTZ | NOT NULL | When the event occurred |
| event_type | TEXT | NOT NULL | e.g. `init`, `rpm_check`, `odometer_read`, `dist_since_clear`, `skipped_engine_off`, `mileage_save`, `sanity_check_failed`, `connection_error`, `codes_cleared_detected` |
| pid | TEXT | YES | OBD PID involved (e.g. `010C`, `01A6`, `0131`) |
| raw_response | TEXT | YES | Raw ELM327 response string |
| parsed_value | DOUBLE PRECISION | YES | Parsed numeric value |
| success | BOOLEAN | NOT NULL | Whether the operation succeeded |
| error_message | TEXT | YES | Error details on failure |

---

## Migrations

Schema migrations are handled inline in `NeonRepository.initializeSchema()` using `ADD COLUMN IF NOT EXISTS`. No separate migration files.

## Data Retention

- `mileage_snapshots` — auto-purged after 7 days (on every app launch and after every snapshot save)
- All other tables — retained indefinitely
