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
| nickname | TEXT | YES | Display name. Starts as "year make" from the VIN (e.g. "2018 Hyundai"); becomes "year make model" once NHTSA fills the model, unless the user changed it. Editable on the Vehicles screen |
| make | TEXT | YES | Decoded offline from VIN chars 1-3 (WMI) |
| model | TEXT | YES | Not decodable offline. Filled once in the background from NHTSA vPIC when the car is created (only if empty), or by "Look up details" / typing it on the Vehicles screen |
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
| dist_since_codes_cleared | DOUBLE PRECISION | YES | PID 0131 value at time of capture. For `MANUAL` rows, the baseline for later captures: stored only if the car's 0131 was read in the last 30 minutes and the person confirmed the car was not driven since (entry not backdated more than 5 minutes), otherwise NULL (the next capture then asks to confirm the odometer) |
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
| `dashboard_button` | Capture button on the Dashboard |
| `bg_auto` | Legacy value on old snapshots, and the tag on a `skipped_background` `capture_end`. Captures are foreground-only now, so no new snapshot carries it. A briefly *inactive* app (banner, Control Center) keeps its real trigger |

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

Service interval thresholds per car — defines when warnings and critical alerts trigger. The Elantra's rows are seeded on first launch (and again at launch if the Elantra ever has none); a new car gets a copy of them when it is created. Edited per car on the Service Intervals screen (upsert on `(vehicle_id, service_type)`; delete removes the row only, never service history).

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
| event_type | TEXT | NOT NULL | e.g. `init`, `vin_read`, `rpm_check`, `odometer_read`, `dist_since_clear`, `skipped_engine_off`, `mileage_save`, `sanity_check_failed`, `connection_error`, `codes_cleared_detected`, `retired_vehicle_connected`, `unassigned_saved`, `unassigned_skipped`, `schema_not_ready`, `capture_end`, `replay_rejected` |
| pid | TEXT | YES | OBD PID involved (e.g. `010C`, `01A6`, `0131`, `0902`) |
| raw_response | TEXT | YES | Raw ELM327 response string. For `capture_end`: `mode=<capture_mode>;app_state=<active\|inactive\|background>;trigger=<…>` |
| parsed_value | DOUBLE PRECISION | YES | Parsed numeric value (odometer for `capture_end`) |
| success | BOOLEAN | NOT NULL | Whether the operation succeeded |
| error_message | TEXT | YES | Error details on failure. For `capture_end`: the outcome (see below) |
| duration_ms | INTEGER | YES | How long the command took; for `capture_end`, the whole capture |

Index: `(vehicle_id, event_type, timestamp DESC)`.

**Retries.** `0902`, `010C` and `0131` are retried once (after 250 ms) on a transient bus error (`CAN ERROR`, `BUS ERROR`, `BUS BUSY`, `STOPPED`); `0902` also on a timeout. `01A6` is never retried. Each attempt is its own row: a transient attempt's `error_message` is `transient: CAN ERROR`, a retried one ends `— retrying`, and when a retry happened each row ends `(attempt n/2)`.

**`capture_end`** — exactly one per connect. `error_message` is one of: `saved`, `updated`, `skipped_already_reading`, `skipped_throttled`, `skipped_background` (a connect arrived while the app was in the background; nothing was read — captures are foreground-only, and only `.background` blocks, only at capture start), `skipped_schema_not_ready`, `skipped_retired_vehicle`, `skipped_engine_off`, `skipped_vehicle_unknown` (reading kept in `unassigned_readings`), `skipped_vehicle_unknown_no_data`, `skipped_needs_manual_odometer`, `skipped_sanity_check`, `queued_offline`, `queued_offline_update`, `queued_offline_save` (database unreachable; the raw reading is in the offline queue, see below), `skipped_offline_no_reading`, `failed_init`, `failed_update`, `failed_save_queued`, `failed_exception`. `success` is true only for `saved` / `updated`. `trigger` is what started the connect: `app_launch`, `loop`, `fg_resume`, `throttle`, `dashboard_button`, `power_on`, `restore`, `pending` (iOS connected with no request in flight), or `pending:<trigger>:age=<n>s` (a request iOS completed long after it was made).

**Offline rows.** While offline only `capture_end` is queued, so these rows can arrive late: their `timestamp` is when the capture ended, not when they were written. Other per-command rows (`init`, `vin_read`, `rpm_check`, …) are not written for an offline capture.

**`replay_rejected`** — written when a queued offline capture could not become a mileage row. The reading is moved to `unassigned_readings` (with `suggested_vehicle_id` set) and removed from the queue; this row is the diagnostic record. `vehicle_id` is the car it was captured under; `parsed_value` is the 0131 value; `error_message` is `<reason>: <detail>` with reason `no_manual_reference`, `negative_delta` (codes cleared), `reference_missing_0131`, `no_0131_reading` or `sanity_check` (computed odometer more than 1.5 mi below the car's last record at capture time); `raw_response` is `capture_ts=<ISO 8601> mode=<capture_mode> rpm=<n> dist=<0131> dist_raw=<raw reply> odometer_raw=<raw reply>`, the same reading is also in `unassigned_readings`. Its `timestamp` is the replay time.

---

### Offline queue (on the phone, not in Neon)

`UserDefaults["pendingRecords"]` — JSON array replayed in order by `SyncManager.syncAll()` on foreground, when the network returns, and after each online capture. Old queues still decode (every added field is optional); a record this build can't read is skipped, not fatal. Each record has a `queueId`, a `retryCount` and a `lastError`. Types: `mileage`, `service`, `unassigned` (as before; records without a car are the Elantra's), plus:

- `capture` — a raw reading taken while the database was unreachable: car id (from the VIN at capture time, never from replay time), timestamp, 0131, 01A6 if reported, rpm. On replay the odometer is computed with the same math as a live capture (`MileageMath`) from the car's history *as of the capture time*, then the car's BLE_AUTO row for the capture's *day* is updated or inserted (an existing newer row is left alone). One queued capture per car per day. Rejected captures are saved to `unassigned_readings` (`failure_reason` = the rejection code, `suggested_vehicle_id` = the car) and logged (`replay_rejected`), and only then leave the queue.
- `log` — a queued `capture_end` row. At most 25 are kept, oldest dropped first; data records are never dropped to make room.

Offline failures don't count as retries. A record stops being retried after `Config.maxRetryCount` failures that are not network errors, and stays visible in the "waiting to sync" list.

Also on the phone: `multiCarMigrationConfirmed` (set once `multi_car_v1` is confirmed, together with a hash of the database host/name so a different database isn't trusted) and `cachedVehicles` (the car list as last fetched, used to identify a known car by VIN offline; a car is never created offline).

---

### unassigned_readings

Captures whose car could not be identified (VIN read failed). Never guessed into a car; kept here to be assigned later on the Unassigned Readings screen. Only written when the capture produced a 0131 or 01A6 value. Also receives queued offline readings that couldn't be converted to an odometer on replay: `failure_reason` is then the rejection code (`no_manual_reference`, `negative_delta`, `reference_missing_0131`, `no_0131_reading`, `sanity_check`) and `suggested_vehicle_id` is the car; the row id is the capture's id, so a retried replay is a no-op.

**Assigning** (to an active car only): the odometer is worked out with the same rules as an offline-queue replay (`ReadingImporter`: the car's manual reference, its history as of the reading's time, the 1.5 mi sanity check), then written as that car's BLE_AUTO row for the reading's day — inserted with the reading's `id`, or updating that day's row only if the reading is newer; a newer row is left alone. If the odometer can't be worked out, the user types the odometer at that moment and it is saved as a `MANUAL` row (id = the reading's id, timestamp = the reading's, `dist_since_codes_cleared` = the reading's 0131). `assigned_vehicle_id` / `assigned_at` are set only after that save. No snapshot is written for an assigned reading.

| Column | Type | Nullable | Description |
|--------|------|----------|-------------|
| id | TEXT | PK | UUID |
| timestamp | TIMESTAMPTZ | NOT NULL | When the reading was taken |
| failure_reason | TEXT | NOT NULL | `vin_timeout` (no reply, after retry), `vin_no_data` (a clean NO DATA), `vin_error` (bus error after retry, or other adapter error), `vin_invalid` (reply isn't a valid VIN), `vin_lookup_error` (VIN read but DB lookup failed), `vin_unknown_offline` (no network and the VIN is not in the saved car list; the VIN is in `vin_raw_response`) |
| vin_raw_response | TEXT | YES | Raw 0902 reply; both replies joined with ` \| ` if it was retried |
| peripheral_id | TEXT | YES | Adapter's Bluetooth identifier |
| capture_mode | TEXT | YES | Same values as `mileage_snapshots.capture_mode` |
| rpm | INTEGER | YES | Engine RPM at capture |
| odometer_raw_response | TEXT | YES | Raw 01A6 reply |
| dist_since_codes_cleared | DOUBLE PRECISION | YES | Parsed 0131, miles |
| dist_raw_response | TEXT | YES | Raw 0131 reply; joined with ` \| ` if it was retried |
| assigned_vehicle_id | TEXT | YES, FK | Car it was assigned to (NULL = still unassigned) |
| assigned_at | TIMESTAMPTZ | YES | When it was assigned |
| suggested_vehicle_id | TEXT | YES, FK | Car a rejected offline reading was captured under; pre-selected on the Assign screen. NULL for readings whose car was never identified |
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
- Phase A (every launch, each statement idempotent): create `vehicles`, `schema_migrations`, `unassigned_readings` (+ `suggested_vehicle_id`); insert the Elantra; add `vehicle_id` to the 8 per-car tables and `duration_ms` to `obd_connection_logs`; create indexes.
- Phase B (one `DO` block = one transaction, skipped once the `multi_car_v1` marker exists): backfill every NULL `vehicle_id` to the Elantra (logs only if older than the Elantra row), `SET NOT NULL` on all per-car tables except `obd_connection_logs`, change the `service_thresholds` PK to `(vehicle_id, service_type)` (guarded via `pg_constraint`), write the marker.
- Until the marker is confirmed in a launch the app makes no captures, and reads treat a NULL `vehicle_id` as the Elantra.

## Data Retention

- `mileage_snapshots` — auto-purged after 7 days (on every app launch and after every snapshot save)
- All other tables — retained indefinitely
