# Fuel Economy Tracking Feature

## Context
AutoLog tracks car mileage via BLE OBD-II. Adding fuel fill-up logging to calculate MPG, cost metrics, and trends. Pairs with existing odometer data. Target: 2013 Hyundai Elantra (~28-35 MPG highway, ~22-28 city, ~15 gal tank).

## Database Schema

**Table: `fuel_records`**
```sql
CREATE TABLE IF NOT EXISTS fuel_records (
    id TEXT PRIMARY KEY,
    timestamp TIMESTAMPTZ NOT NULL,
    odometer_miles DOUBLE PRECISION NOT NULL,
    gallons DOUBLE PRECISION NOT NULL,
    price_per_gallon DOUBLE PRECISION,
    total_cost DOUBLE PRECISION,
    is_full_tank BOOLEAN NOT NULL DEFAULT true,
    fuel_grade TEXT DEFAULT 'regular',
    station_name TEXT,
    comments TEXT,
    created_at TIMESTAMPTZ DEFAULT now()
)
```

No separate thresholds table — MPG warnings can be hardcoded or derived.

## Model

**`AutoLog/Models/FuelRecord.swift`**
```swift
struct FuelRecord: Codable, Identifiable {
    let id: String
    let timestamp: Date
    let odometerMiles: Double
    let gallons: Double
    var pricePerGallon: Double?
    var totalCost: Double?
    let isFullTank: Bool
    var fuelGrade: String       // "regular", "midgrade", "premium"
    var stationName: String?
    var comments: String?

    static func new(...) -> FuelRecord { ... }
}
```

## MPG Calculation (FuelCalculator.swift)

**Full-to-full method:**
- Sort records by odometer ascending
- For each full-tank fill F[i], find previous full-tank fill F[prev]
- Accumulate all gallons between (partials + F[i])
- `MPG = (F[i].odometer - F[prev].odometer) / accumulatedGallons`
- No stored MPG in DB — always computed from ordered list

**Edge cases:**
- First fill-up: no MPG (establishes baseline)
- Partial fills: gallons accumulate into next full-fill MPG, no MPG shown for partial
- Missed fills / large gaps: flag MPG > 50 or < 10 as `lowConfidence`
- Short trips < 50 mi: flag as `lowConfidence`
- Edit/delete: recalculates from full list (no cascading update issues)
- Multiple fills same day: sort by odometer, not just timestamp

**Metrics to compute:**

| Metric | Formula |
|---|---|
| MPG per tank | (odometer delta) / accumulated gallons between full fills |
| Lifetime avg MPG | mean of all tank MPGs |
| Last 5 fills MPG | mean of last 5 tank MPGs |
| Cost per mile | total fuel cost / total miles driven |
| Avg price/gallon | mean of all records with price data |
| Monthly spend | sum total_cost grouped by month |
| Estimated tank size | max gallons from any single full-tank fill |
| Estimated range | avg MPG × estimated tank size |
| Est. range remaining | (lastFillOdometer + avgMPG × tankSize) - currentOdometer |
| Monthly fuel forecast | (milesPerDay × 30.44) / avgMPG × avgPricePerGallon |
| Best/worst MPG | min/max from tank MPGs |

## Files to Create

1. `AutoLog/Models/FuelRecord.swift` — model
2. `AutoLog/Services/FuelCalculator.swift` — pure logic, all metric calculations
3. `AutoLog/Views/FuelView.swift` — history list + row view
4. `AutoLog/Views/AddFuelView.swift` — fill-up entry form
5. `AutoLog/Views/EditFuelView.swift` — edit/delete form

## Files to Modify

1. `AutoLog/Repository/NeonRepository.swift` — schema + CRUD methods + parser
2. `AutoLog/App/AutoLogApp.swift` — add 5th "Fuel" tab (fuelpump.fill icon)
3. `AutoLog/Views/AnalyticsView.swift` — add 3 fuel charts
4. `AutoLog/Views/DashboardView.swift` — add fuel economy section

## UI Design

### Tab: 5th tab "Fuel" (between Maintenance and Analytics)

### FuelView (History List)
- NavigationStack + List, same pattern as MaintenanceView
- "+" toolbar button → AddFuelView sheet
- Tap row → EditFuelView sheet
- Pull to refresh

**Row layout:**
```
| Regular                              32.4 MPG |
| Mar 1, 2026   85,230 mi   10.5 gal   $3.29   |
| Costco                                        |
```
- Partial fills: "PARTIAL" orange badge, no MPG shown

### AddFuelView (Entry Form)

**Section "Fill-Up Details" (required):**
- DatePicker (default: now)
- Odometer TextField — auto-populated from latest mileage record
- Gallons TextField (decimal pad)
- Full Tank Toggle (default: ON, helper text for partial)

**Section "Cost" (optional):**
- Price per gallon TextField
- Total cost TextField (auto-calc from gallons × price, but editable)

**Section "Other" (optional):**
- Fuel Grade segmented picker: Regular | Midgrade | Premium
- Station TextField
- Comments TextField

**Validation:**
- Odometer >= previous fill odometer (warn, allow override)
- Gallons > 0 and <= 20
- Price per gallon: warn if outside $2-$7

### Dashboard Section (between BLE section and service statuses)
```
FUEL ECONOMY
| Last Fill-Up              3 days ago |
| 10.5 gal @ $3.29                    |
| Avg MPG                        30.2 |
| Est. Range                  ~185 mi |
| This Month                   $48.20 |
```

### Analytics Charts (appended to existing AnalyticsView)
1. **MPG Trend** — LineMark (teal), RuleMark for avg, low-confidence points dashed
2. **Monthly Fuel Spend** — BarMark (green), RuleMark for monthly avg
3. **Price per Gallon Trend** — LineMark (orange), tap-to-select

## Implementation Order

1. FuelRecord model
2. NeonRepository: schema + CRUD + parser
3. FuelCalculator (pure logic)
4. FuelView + row view (history list)
5. AddFuelView (entry form)
6. EditFuelView (edit/delete)
7. Tab integration in AutoLogApp.swift
8. Dashboard fuel section
9. Analytics fuel charts

## Verification
- Build in Xcode
- Add a fill-up, verify it appears in list
- Add 2+ full fills, verify MPG calculates correctly
- Add a partial fill between two fulls, verify gallons accumulate
- Edit/delete a fill-up, verify metrics recalculate
- Check dashboard section shows latest data
- Check analytics charts render
