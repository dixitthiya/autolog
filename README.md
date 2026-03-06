# AutoLog

Personal iOS app that auto-logs car mileage via BLE OBD-II adapter and tracks vehicle maintenance with service interval alerts.

---

## Overview

AutoLog connects to a Vgate iCar Pro BLE OBD-II adapter to automatically log daily odometer readings and track vehicle maintenance history. When your car starts, the app detects the adapter via Bluetooth, reads the odometer, and logs the record directly to NeonDB — no manual entry required.

Built for one car, one phone, zero complexity.

---

## Features

- **Auto-logs daily mileage** via BLE OBD-II (ELM327 protocol)
- **Full maintenance history** — brakes, tires, engine, fluids, and more
- **Smart service interval alerts** — Critical / Service Soon / All Good
- **Rotor thickness tracking** with wear rate projection and safety thresholds
- **Direct NeonDB integration** — no backend middleware, no cold starts
- **Offline retry queue** — never loses a record if network fails
- **CSV import** from existing Google Sheets maintenance data
- **Push notifications** when any service becomes due or critical

---

## Tech Stack

| Layer | Technology |
|-------|-----------|
| Platform | iOS 17+ |
| Language | Swift |
| UI | SwiftUI |
| Bluetooth | CoreBluetooth |
| Analytics | Swift Charts |
| Database | NeonDB (Postgres) |
| Networking | URLSession (direct Neon HTTP API) |
| Local Queue | UserDefaults |

No third party dependencies.

---

## Architecture

```
AutoLog/
├── App/
│   └── AutoLogApp.swift
├── Bluetooth/
│   └── BLEManager.swift
├── OBD/
│   ├── OBDCommandService.swift
│   └── PIDParser.swift
├── Services/
│   ├── MileageService.swift
│   ├── StatusCalculator.swift
│   └── SyncManager.swift
├── Repository/
│   └── NeonRepository.swift
├── Models/
│   ├── MileageRecord.swift
│   ├── ServiceRecord.swift
│   └── ServiceStatus.swift
├── Views/
│   ├── DashboardView.swift
│   ├── MileageHistoryView.swift
│   ├── EditMileageView.swift
│   ├── MaintenanceView.swift
│   ├── AddServiceView.swift
│   ├── EditServiceView.swift
│   └── AnalyticsView.swift
└── Migration/
    └── CSVImporter.swift
```

---

## How It Works

```
Car starts → Vgate adapter powers on → iPhone detects BLE
      ↓
App connects → ELM327 init → checks RPM via PID 010C
      ↓
RPM > 0 (engine running) → reads odometer via PID 01A6
      ↓
Today's record exists? → skip
Today's record missing? → POST directly to NeonDB
      ↓
NeonDB unavailable? → save to local UserDefaults queue
      ↓
Retry on next BLE connection or app foreground
```

---

## NeonDB Schema

```sql
-- Daily odometer records (auto-logged via BLE)
CREATE TABLE mileage_records (
  id TEXT PRIMARY KEY,
  timestamp TIMESTAMPTZ NOT NULL,
  odometer_miles DOUBLE PRECISION NOT NULL,
  source TEXT NOT NULL,  -- 'BLE_AUTO' | 'MANUAL' | 'IMPORTED'
  synced_at TIMESTAMPTZ DEFAULT now()
);

-- All maintenance service records
CREATE TABLE service_records (
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
);

-- Service interval thresholds (editable in app)
CREATE TABLE service_thresholds (
  service_type TEXT PRIMARY KEY,
  miles_critical DOUBLE PRECISION,
  miles_warning DOUBLE PRECISION,
  days_critical INTEGER,
  days_warning INTEGER,
  rotor_critical DOUBLE PRECISION,
  rotor_warning DOUBLE PRECISION
);
```

---

## Service Intervals

| Service | Warning | Critical |
|---------|---------|----------|
| Oil & Oil Filter Change | 5,000 mi | 7,000 mi |
| Tire Rotation | 5,000 mi | 7,000 mi |
| Engine Air Filter | 15,000 mi or 1 yr | 20,000 mi |
| Cabin Air Filter | 10,000 mi or 1 yr | 14,000 mi |
| Brake Service | 18,000 mi or 2 yr | 22,000 mi |
| Brake Fluid Flush | 25,000 mi or 3 yr | 30,000 mi |
| Transmission Fluid | 25,000 mi | 30,000 mi |
| Spark Plugs | 80,000 mi | 90,000 mi |
| Coolant Flush | 45,000 mi or 4 yr | 50,000 mi or 5 yr |
| Throttle Body Cleaning | 30,000 mi or 3 yr | 40,000 mi or 4 yr |

**Rotor Thresholds:**

| Position | Warning | Critical |
|----------|---------|----------|
| Front | ≤ 21.8mm | < 21.4mm |
| Rear | ≤ 8.6mm | < 8.4mm |

---

## App Screens

| Tab | Screen | Purpose |
|-----|--------|---------|
| Dashboard | Service overview | All categories with status badges, sorted Critical first |
| Mileage | Mileage history | Auto-logged daily records, editable |
| Maintenance | Service log | Full history filtered by category |
| Analytics | Charts | Rotor wear projection, spend over time, miles per month |

---

## Configuration

Create `AutoLog/App/Config.swift` and fill in your Neon credentials:

```swift
struct Config {
    static let neonBaseURL = "YOUR_NEON_HTTP_URL"
    static let neonAPIKey  = "YOUR_NEON_API_KEY"
}
```

> ⚠️ Never commit `Config.swift` with real credentials. Add it to `.gitignore`.

---

## Getting Started

```bash
# Clone the repo
git clone git@github-dixitthiya:dixitthiya/autolog.git
cd autolog

# Open in Xcode
open AutoLog.xcodeproj
```

1. Fill in `Config.swift` with your NeonDB credentials
2. Connect your iPhone
3. Build and run — the app creates all NeonDB tables on first launch
4. On first launch you will be prompted to import existing data via CSV

---

## CSV Import

Export your Google Sheets maintenance log as CSV with these columns:

```
Timestamp, Service Type, Odometer Reading (Miles), Rotor Thickness (mm), Amount, Comments, Month
```

Import once on first app launch. Rows with `Service Type = "Current Mileage"` are imported as mileage records. All other rows are imported as service records.

---

## Hardware

- **OBD Adapter:** Vgate iCar Pro BLE
- **Protocol:** ELM327 over Bluetooth Low Energy
- **PIDs used:**
  - `010C` — Engine RPM (engine running detection)
  - `01A6` — Odometer (primary)
  - `010D` — Vehicle speed (fallback odometer calculation)

---

## Requirements

- iPhone with Bluetooth LE
- iOS 17+
- Vgate iCar Pro BLE OBD-II adapter
- NeonDB account (free tier is sufficient)

---

## License

Personal use only.
