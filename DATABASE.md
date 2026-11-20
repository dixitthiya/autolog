# AutoLog Database Schema

All tables are stored in NeonDB (Postgres) and accessed via the Neon HTTP API. Schema is auto-created on first app launch via `NeonRepository.initializeSchema()`.

The app is multi-car. Every per-car table carries `vehicle_id` (FK → `vehicles.id`). All data from before multi-car belongs to the 2013 Elantra, `vehicle_id = 'vehicle-elantra-2013'`. `services` is a shared catalog with no car.

---

## Tables

### vehicles

One row per car. The car is identified on every Bluetooth connect by reading its VIN (OBD mode 09 PID 02); an unknown VIN creates a new row with a copy of the Elantra's `service_thresholds`.

| Column | Type | Nullable | Description |
|--------|------|----------|-------------|
| id | TEXT | PK | UUID, or `vehicle-elantra-2013` for the Elantra |
| nickname | TEXT | YES | Display name, e.g. "2018 Hyundai" |
| make | TEXT | YES | Decoded offline from VIN chars 1-3 (WMI) |
| model | TEXT | YES | Not decodable offline; edited later |
| year | INTEGER | YES | Decoded offline from VIN char 10 |
| vin | TEXT | UNIQUE, YES | Uppercase, 17 chars `[A-HJ-NPR-Z0-9]` (CHECK). NULL for cars without one on file (Elantra) |
| status | TEXT | NOT NULL, DEFAULT 'active' | `active` or `retired` (CHECK). Retired cars get no captures or reminders |
| created_at | TIMESTAMPTZ | NOT NULL, DEFAULT now() | Row creation time |

---

### mileage_records

Daily odometer records — one per car per day, auto-logged via BLE or entered manually.

| Column | Type | Nullable | Description |
|--------|------|----------|-------------|
| id | TEXT | PK | UUID |
| vehicle_id | TEXT | NOT NULL, FK | Car the reading belongs to |
| timestamp | TIMESTAMPTZ | NOT NULL | When the reading was taken |
| odometer_miles | DOUBLE PRECISION | NOT NULL | Odometer reading in miles |
| source | TEXT | NOT NULL | `BLE_AUTO`, `MANUAL`, or `IMPORTED` |
| dist_since_codes_cleared | DOUBLE PRECISION | YES | PID 0131 value at time of capture |
| synced_at | TIMESTAMPTZ | DEFAULT now() | When the record was synced to Neon |
| created_at | TIMESTAMPTZ | DEFAULT now() | Row creation time |

Index: `(vehicle_id, timestamp DESC)`.

---

### mileage_snapshots

Every single OBD capture — not deduplicated, not one-per-day. Auto-purged after 7 days. Used for debugging and understanding capture behavior.

| Column | Type | Nullable | Description |
|--------|------|----------|-------------|
| id | TEXT | PK | UUID |
| vehicle_id | TEXT | NOT NULL, FK | Car captured |
| timestamp | TIMESTAMPTZ | NOT NULL | When the snapshot was taken |
| odometer_miles | DOUBLE PRECISION | NOT NULL | Odometer reading in miles |
| dist_since_codes_cleared | DOUBLE PRECISION | YES | PID 0131 value |
| rpm | INTEGER | YES | Engine RPM (PID 010C) at capture time |
| capture_mode | TEXT | YES | What triggered this capture (see below) |
| created_at | TIMESTAMPTZ | DEFAULT now() | Row creation time |

Index: `(vehicle_id, timestamp DESC)`.

#### capture_mode values

| Value | Trigger |
|-------|---------|
| `app_launch` | First capture after app starts |
| `fg_resume` | App returns to foreground |
| `fg_timer` | 2-min auto-scan timer (app in foreground) |
| `throttle_retry` | 10s retry after engine-off RPM=0 |
| `bg_auto` | Any capture while the app is not in the foreground (iOS CB reconnect, state restore, BT power on) |

---

### service_records

All maintenance service records — oil changes, brake service, tire rotations, etc.

| Column | Type | Nullable | Description |
|--------|------|----------|-------------|
| id | TEXT | PK | UUID |
| vehicle_id | TEXT | NOT NULL, FK | Car serviced |
| timestamp | TIMESTAMPTZ | NOT NULL | When the service was performed |
| service_type | TEXT | NOT NULL | e.g. "Engine Oil & Filter Change" |
| category | TEXT | NOT NULL | Grouping category |
| odometer_miles | DOUBLE PRECISION | NOT NULL | Odometer at time of service |
| rotor_thickness_mm | DOUBLE PRECISION | YES | Rotor measurement (brake services only) |
| amount | DOUBLE PRECISION | YES | Cost of service |
| comments | TEXT | YES | Free-text notes |
| manually_edited | BOOLEAN | DEFAULT false | Whether the record was edited after creation |
| created_at | TIMESTAMPTZ | DEFAULT now() | Row creation time |

Index: `(vehicle_id, service_type, timestamp DESC)`.

---

### service_thresholds

Service interval thresholds per car — defines when warnings and critical alerts trigger. The Elantra's rows are seeded on first launch; a new car gets a copy of them when it is created.

| Column | Type | Nullable | Description |
|--------|------|----------|-------------|
| vehicle_id | TEXT | PK (1/2), FK | Car these limits apply to |
| service_type | TEXT | PK (2/2) | Matches `service_records.service_type` |
| miles_critical | DOUBLE PRECISION | YES | Miles after service → critical |
| miles_warning | DOUBLE PRECISION | YES | Miles after service → warning |
| days_critical | INTEGER | YES | Days after service → critical |
| days_warning | INTEGER | YES | Days after service → warning |
| rotor_critical | DOUBLE PRECISION | YES | Rotor thickness mm → critical |
| rotor_warning | DOUBLE PRECISION | YES | Rotor thickness mm → warning |

Primary key: `(vehicle_id, service_type)`.

---

### services

Shared catalog of service types shown in the Add Service picker (not per car). Seeded on first launch; users can add new types from the picker.

| Column | Type | Nullable | Description |
|--------|------|----------|-------------|
| id | TEXT | PK, DEFAULT gen_random_uuid() | Row id |
| service_type | TEXT | NOT NULL, UNIQUE | e.g. "Cabin Air Filter" |
| category | TEXT | NOT NULL | Picker grouping, e.g. "Engine" |

---

### obd_connection_logs

Raw OBD event log — every PID read, init, failure, and skip is recorded here for debugging.

| Column | Type | Nullable | Description |
|--------|------|----------|-------------|
| id | TEXT | PK | UUID |
| vehicle_id | TEXT | YES, FK | Car connected. NULL = car not known yet/at all (init, failed VIN read) — never assume a car for NULL |
| timestamp | TIMESTAMPTZ | NOT NULL | When the event occurred |
| event_type | TEXT | NOT NULL | e.g. `init`, `vin_read`, `rpm_check`, `odometer_read`, `dist_since_clear`, `skipped_engine_off`, `mileage_save`, `sanity_check_failed`, `connection_error`, `codes_cleared_detected`, `retired_vehicle_connected`, `unassigned_saved`, `unassigned_skipped`, `schema_not_ready` |
| pid | TEXT | YES | OBD PID involved (e.g. `010C`, `01A6`, `0131`, `0902`) |
| raw_response | TEXT | YES | Raw ELM327 response string |
| parsed_value | DOUBLE PRECISION | YES | Parsed numeric value |
| success | BOOLEAN | NOT NULL | Whether the operation succeeded |
| error_message | TEXT | YES | Error details on failure |
| duration_ms | INTEGER | YES | How long the command took (OBD commands only) |

Index: `(vehicle_id, event_type, timestamp DESC)`.

---

### unassigned_readings

Captures whose car could not be identified (VIN read failed). Never guessed into a car and never saved to `mileage_records`; kept here to be assigned later. Only written when the capture produced a 0131 or 01A6 value.

| Column | Type | Nullable | Description |
|--------|------|----------|-------------|
| id | TEXT | PK | UUID |
| timestamp | TIMESTAMPTZ | NOT NULL | When the reading was taken |
| failure_reason | TEXT | NOT NULL | `vin_timeout`, `vin_no_data`, `vin_invalid`, `vin_error`, `vin_lookup_error` (VIN read but DB lookup failed) |
| vin_raw_response | TEXT | YES | Raw 0902 reply, if any |
| peripheral_id | TEXT | YES | Adapter's Bluetooth identifier |
| capture_mode | TEXT | YES | Same values as `mileage_snapshots.capture_mode` |
| rpm | INTEGER | YES | Engine RPM at capture |
| odometer_raw_response | TEXT | YES | Raw 01A6 reply |
| dist_since_codes_cleared | DOUBLE PRECISION | YES | Parsed 0131, miles |
| dist_raw_response | TEXT | YES | Raw 0131 reply |
| assigned_vehicle_id | TEXT | YES, FK | Car it was assigned to (NULL = still unassigned) |
| assigned_at | TIMESTAMPTZ | YES | When it was assigned |
| created_at | TIMESTAMPTZ | NOT NULL, DEFAULT now() | Row creation time |

---

### tires

Physical tires, tracked per corner. Mileage is bound to the tire (install odometer),
so it survives rotation. One row per physical tire; retired tires are kept for history
(`removed_odometer` set) and linked from the tire that replaced them.

| Column | Type | Nullable | Description |
|--------|------|----------|-------------|
| id | TEXT | PK | UUID |
| vehicle_id | TEXT | NOT NULL, FK | Car the tire is on |
| position | TEXT | YES | Current corner: `FL`, `FR`, `RL`, `RR` (NULL once retired) |
| make_model | TEXT | YES | e.g. "Yokohama Avid Ascend" |
| install_odometer | DOUBLE PRECISION | NOT NULL | Odometer when installed |
| install_date | TIMESTAMPTZ | NOT NULL | When installed |
| removed_odometer | DOUBLE PRECISION | YES | Odometer when replaced (NULL = active) |
| removed_date | TIMESTAMPTZ | YES | When replaced |
| replaces_tire_id | TEXT | YES | The tire this one replaced (1:1 lineage) |
| notes | TEXT | YES | Free-text notes |
| created_at | TIMESTAMPTZ | DEFAULT now() | Row creation time |

Mileage on a tire = `currentOdometer − install_odometer` (or `removed_odometer − install_odometer` once retired). The Elantra is seeded once with its 4-corner layout plus its retired-tire history. Index: `(vehicle_id)`.

---

### tire_rotations

Audit log of rotations — each records the corner mapping applied to the active tires.

| Column | Type | Nullable | Description |
|--------|------|----------|-------------|
| id | TEXT | PK | UUID |
| vehicle_id | TEXT | NOT NULL, FK | Car rotated |
| timestamp | TIMESTAMPTZ | NOT NULL | When the rotation was performed |
| odometer_miles | DOUBLE PRECISION | NOT NULL | Odometer at rotation |
| pattern | TEXT | YES | Mapping applied, e.g. `FL>RL, FR>RR, RL>FR, RR>FL` |
| comments | TEXT | YES | Free-text notes |
| created_at | TIMESTAMPTZ | DEFAULT now() | Row creation time |

Index: `(vehicle_id, timestamp DESC)`.

---

### tire_tread_readings

Tread-depth measurements per physical tire over time. Captured at rotations
(one per corner), replacements (initial depth), and manual edits. Forms a
wear curve for projection, analogous to rotor thickness readings.

| Column | Type | Nullable | Description |
|--------|------|----------|-------------|
| id | TEXT | PK | UUID |
| vehicle_id | TEXT | NOT NULL, FK | Car of the tire (copied from the tire) |
| tire_id | TEXT | NOT NULL | The tire measured (references `tires.id`) |
| timestamp | TIMESTAMPTZ | NOT NULL | When measured |
| odometer_miles | DOUBLE PRECISION | NOT NULL | Odometer at measurement |
| depth_32nds | DOUBLE PRECISION | NOT NULL | Tread depth in 32nds of an inch |
| created_at | TIMESTAMPTZ | DEFAULT now() | Row creation time |

Index: `(vehicle_id, tire_id, timestamp DESC)`.

---

### schema_migrations

Markers for one-time migrations.

| Column | Type | Nullable | Description |
|--------|------|----------|-------------|
| name | TEXT | PK | e.g. `multi_car_v1` |
| applied_at | TIMESTAMPTZ | NOT NULL, DEFAULT now() | When it ran |

---

## Migrations

Schema migrations are handled inline in `NeonRepository.initializeSchema()` using `IF NOT EXISTS` / `ON CONFLICT DO NOTHING`, so they are safe to run on every launch. No separate migration files.

**multi_car_v1** (`migrateMultiCar()`):
- Phase A (every launch, each statement idempotent): create `vehicles`, `schema_migrations`, `unassigned_readings`; insert the Elantra; add `vehicle_id` to the 8 per-car tables and `duration_ms` to `obd_connection_logs`; create indexes.
- Phase B (one `DO` block = one transaction, skipped once the `multi_car_v1` marker exists): backfill every NULL `vehicle_id` to the Elantra (logs only if older than the Elantra row), `SET NOT NULL` on all per-car tables except `obd_connection_logs`, change the `service_thresholds` PK to `(vehicle_id, service_type)` (guarded via `pg_constraint`), write the marker.
- Until the marker is confirmed in a launch the app makes no captures, and reads treat a NULL `vehicle_id` as the Elantra.

## Data Retention

- `mileage_snapshots` — auto-purged after 7 days (on every app launch and after every snapshot save)
- All other tables — retained indefinitely
