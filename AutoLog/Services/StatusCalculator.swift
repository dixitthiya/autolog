import Foundation

struct StatusCalculator {
    private static let rotorTypes = Set(["Front Rotor Thickness Reading", "Rear Rotor Thickness Reading"])
    private static let mileageAndTimeTypes = Set([
        "Engine Air Filter", "Cabin Air Filter", "Brake Fluid Flush",
        "Brake Service", "Coolant Flush", "Throttle Body Cleaning"
    ])

    static func calculate(
        serviceType: String,
        threshold: ServiceThreshold,
        milesSinceService: Double,
        daysSinceService: Int,
        rotorThickness: Double?,
        hasServiceRecord: Bool
    ) -> ServiceStatus {
        guard hasServiceRecord else { return .noData }

        if rotorTypes.contains(serviceType) {
            return calculateRotor(threshold: threshold, thickness: rotorThickness)
        }

        if mileageAndTimeTypes.contains(serviceType) {
            return calculateMileageAndTime(
                threshold: threshold,
                miles: milesSinceService,
                days: daysSinceService
            )
        }

        return calculateMileageOnly(threshold: threshold, miles: milesSinceService)
    }

    private static func calculateMileageOnly(threshold: ServiceThreshold, miles: Double) -> ServiceStatus {
        if let critical = threshold.milesCritical, miles > critical {
            return .critical
        }
        if let warning = threshold.milesWarning, miles > warning {
            return .serviceSoon
        }
        return .allGood
    }

    private static func calculateMileageAndTime(
        threshold: ServiceThreshold,
        miles: Double,
        days: Int
    ) -> ServiceStatus {
        let milesCrit = threshold.milesCritical.map { miles > $0 } ?? false
        let daysCrit = threshold.daysCritical.map { days > $0 } ?? false
        if milesCrit || daysCrit {
            return .critical
        }

        let milesWarn = threshold.milesWarning.map { miles > $0 } ?? false
        let daysWarn = threshold.daysWarning.map { days > $0 } ?? false
        if milesWarn || daysWarn {
            return .serviceSoon
        }

        return .allGood
    }

    private static func calculateRotor(threshold: ServiceThreshold, thickness: Double?) -> ServiceStatus {
        guard let thickness = thickness else { return .noData }
        if let critical = threshold.rotorCritical, thickness < critical {
            return .critical
        }
        if let warning = threshold.rotorWarning, thickness <= warning {
            return .serviceSoon
        }
        return .allGood
    }
}
