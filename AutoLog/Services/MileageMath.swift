import Foundation

/// The odometer estimate for a car that doesn't report its odometer:
/// latest MANUAL reference + (current 0131 − the reference's stored 0131).
/// Pure, so a live capture and an offline replay use exactly the same rules.
enum MileageMath {
    enum Basis {
        case noManualReference      // no MANUAL entry yet for this car
        case noCurrentDistance      // no 0131 this time: last known value
        case referenceMissingDist   // the MANUAL entry has no stored 0131
        case codesCleared           // 0131 went down: codes were cleared
        case calculated
    }

    struct Estimate {
        let odometer: Double
        let shouldPromptManualEntry: Bool
        let basis: Basis
        /// What the dashboard shows after a live capture.
        let status: String
    }

    static func estimate(manualRef: MileageRecord?, latest: MileageRecord?, currentDist: Double?) -> Estimate {
        guard let ref = manualRef else {
            return Estimate(odometer: latest?.odometerMiles ?? 0, shouldPromptManualEntry: true,
                            basis: .noManualReference, status: "Enter odometer to start tracking")
        }

        guard let currentDist else {
            // dist unavailable — never regress below last known mileage
            let best = max(ref.odometerMiles, latest?.odometerMiles ?? 0)
            return Estimate(odometer: best, shouldPromptManualEntry: false,
                            basis: .noCurrentDistance, status: "Using last known: \(Int(best)) mi")
        }

        guard let refDist = ref.distSinceCodesCleared else {
            return Estimate(odometer: ref.odometerMiles, shouldPromptManualEntry: true,
                            basis: .referenceMissingDist, status: "Confirm odometer now to enable auto-tracking")
        }

        let delta = currentDist - refDist
        if delta < 0 {
            return Estimate(odometer: ref.odometerMiles, shouldPromptManualEntry: true,
                            basis: .codesCleared, status: "Codes cleared — enter new odometer")
        }

        let calculated = ref.odometerMiles + delta
        return Estimate(odometer: calculated, shouldPromptManualEntry: false,
                        basis: .calculated, status: "Calculated: \(Int(calculated)) mi")
    }
}
