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
| service_type | TEXT | NOT NULL | e.g. "Engine Oil & Filter Change" |
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

### tires

Physical tires, tracked per corner. Mileage is bound to the tire (install odometer),
so it survives rotation. One row per physical tire; retired tires are kept for history
(`removed_odometer` set) and linked from the tire that replaced them.

| Column | Type | Nullable | Description |
|--------|------|----------|-------------|
| id | TEXT | PK | UUID |
| position | TEXT | YES | Current corner: `FL`, `FR`, `RL`, `RR` (NULL once retired) |
| make_model | TEXT | YES | e.g. "Yokohama Avid Ascend" |
| install_odometer | DOUBLE PRECISION | NOT NULL | Odometer when installed |
| install_date | TIMESTAMPTZ | NOT NULL | When installed |
| removed_odometer | DOUBLE PRECISION | YES | Odometer when replaced (NULL = active) |
| removed_date | TIMESTAMPTZ | YES | When replaced |
| replaces_tire_id | TEXT | YES | The tire this one replaced (1:1 lineage) |
| notes | TEXT | YES | Free-text notes |
| created_at | TIMESTAMPTZ | DEFAULT now() | Row creation time |

Mileage on a tire = `currentOdometer − install_odometer` (or `removed_odometer − install_odometer` once retired). Seeded once with the current 4-corner layout.

---

### tire_rotations

Audit log of rotations — each records the corner mapping applied to the active tires.

| Column | Type | Nullable | Description |
|--------|------|----------|-------------|
| id | TEXT | PK | UUID |
| timestamp | TIMESTAMPTZ | NOT NULL | When the rotation was performed |
| odometer_miles | DOUBLE PRECISION | NOT NULL | Odometer at rotation |
| pattern | TEXT | YES | Mapping applied, e.g. `FL>RL, FR>RR, RL>FR, RR>FL` |
| comments | TEXT | YES | Free-text notes |
| created_at | TIMESTAMPTZ | DEFAULT now() | Row creation time |

---

### tire_tread_readings

Tread-depth measurements per physical tire over time. Captured at rotations
(one per corner), replacements (initial depth), and manual edits. Forms a
wear curve for projection, analogous to rotor thickness readings.

| Column | Type | Nullable | Description |
|--------|------|----------|-------------|
| id | TEXT | PK | UUID |
| tire_id | TEXT | NOT NULL | The tire measured (references `tires.id`) |
| timestamp | TIMESTAMPTZ | NOT NULL | When measured |
| odometer_miles | DOUBLE PRECISION | NOT NULL | Odometer at measurement |
| depth_32nds | DOUBLE PRECISION | NOT NULL | Tread depth in 32nds of an inch |
| created_at | TIMESTAMPTZ | DEFAULT now() | Row creation time |

---

## Migrations

Schema migrations are handled inline in `NeonRepository.initializeSchema()` using `ADD COLUMN IF NOT EXISTS`. No separate migration files.

## Data Retention

- `mileage_snapshots` — auto-purged after 7 days (on every app launch and after every snapshot save)
- All other tables — retained indefinitely
