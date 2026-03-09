import SwiftUI
import Charts

struct AnalyticsView: View {
    @State private var serviceRecords: [ServiceRecord] = []
    @State private var mileageRecords: [MileageRecord] = []
    @State private var thresholds: [ServiceThreshold] = []
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var selectedMonth: String?
    @State private var selectedSpendDate: Date?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 24) {
                    projectedServiceDates
                    if !monthlyMiles.isEmpty {
                        milesPerMonthChart
                    }
                    if !spendData.isEmpty {
                        spendOverTimeChart
                    }
                    if !frontRotorData.isEmpty || !rearRotorData.isEmpty {
                        rotorWearChart
                    }
                }
                .padding()
            }
            .navigationTitle("Analytics")
            .overlay {
                if isLoading {
                    ProgressView()
                }
            }
            .task { await loadData() }
        }
    }

    // MARK: - Miles Per Month

    private var monthlyMiles: [(String, Double)] {
        let sorted = mileageRecords.sorted { $0.timestamp < $1.timestamp }
        guard sorted.count >= 2 else { return [] }

        let cal = Calendar.current
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM yy"

        var result: [(String, Double)] = []
        for i in 1..<sorted.count {
            let prev = sorted[i-1]
            let curr = sorted[i]
            let diff = curr.odometerMiles - prev.odometerMiles
            guard diff > 0 else { continue }

            let months = max(1, cal.dateComponents([.month], from: prev.timestamp, to: curr.timestamp).month ?? 1)
            let milesPerMonth = diff / Double(months)
            let label = formatter.string(from: curr.timestamp)
            result.append((label, milesPerMonth))
        }
        return result
    }

    private var avgMonthlyMiles: Double {
        guard !monthlyMiles.isEmpty else { return 0 }
        return monthlyMiles.map(\.1).reduce(0, +) / Double(monthlyMiles.count)
    }

    private var milesPerMonthChart: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Miles Per Month")
                    .font(.headline)
                Spacer()
                Text("Avg: \(Int(avgMonthlyMiles).formatted()) mi")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            // Selected month detail
            if let selected = selectedMonth,
               let data = monthlyMiles.first(where: { $0.0 == selected }) {
                HStack {
                    Text(data.0)
                        .font(.subheadline.bold())
                    Text("\(Int(data.1).formatted()) mi")
                        .font(.subheadline)
                        .foregroundStyle(.blue)
                }
                .padding(.vertical, 2)
            }

            Chart {
                ForEach(monthlyMiles, id: \.0) { item in
                    BarMark(x: .value("Month", item.0), y: .value("Miles", item.1))
                        .foregroundStyle(item.0 == selectedMonth ? .blue : .blue.opacity(0.7))
                }

                RuleMark(y: .value("Average", avgMonthlyMiles))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [5, 3]))
                    .foregroundStyle(.orange)
                    .annotation(position: .top, alignment: .trailing) {
                        Text("avg")
                            .font(.caption2)
                            .foregroundStyle(.orange)
                    }
            }
            .chartYAxisLabel("miles")
            .chartXSelection(value: $selectedMonth)
            .frame(height: 200)
        }
        .padding()
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    // MARK: - Spend Over Time

    private var spendData: [(Date, Double)] {
        let withAmount = serviceRecords
            .compactMap { r -> (Date, Double)? in
                guard let amount = r.amount, amount > 0 else { return nil }
                return (r.timestamp, amount)
            }
            .sorted { $0.0 < $1.0 }

        var cumulative = 0.0
        return withAmount.map { item in
            cumulative += item.1
            return (item.0, cumulative)
        }
    }

    private var individualSpend: [(Date, Double, String)] {
        serviceRecords
            .compactMap { r -> (Date, Double, String)? in
                guard let amount = r.amount, amount > 0 else { return nil }
                return (r.timestamp, amount, r.serviceType)
            }
            .sorted { $0.0 < $1.0 }
    }

    private var spendOverTimeChart: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Cumulative Spend")
                    .font(.headline)
                Spacer()
                if let total = spendData.last?.1 {
                    Text("Total: $\(Int(total).formatted())")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            // Selected point detail
            if let selected = selectedSpendDate,
               let closest = spendData.min(by: { abs($0.0.timeIntervalSince(selected)) < abs($1.0.timeIntervalSince(selected)) }),
               let individual = individualSpend.min(by: { abs($0.0.timeIntervalSince(selected)) < abs($1.0.timeIntervalSince(selected)) }) {
                HStack {
                    Text(individual.2)
                        .font(.caption)
                    Spacer()
                    Text("$\(Int(individual.1)) | Total: $\(Int(closest.1))")
                        .font(.caption.bold())
                        .foregroundStyle(.green)
                }
                .padding(.vertical, 2)
            }

            Chart {
                ForEach(spendData, id: \.0) { point in
                    LineMark(x: .value("Date", point.0), y: .value("$", point.1))
                        .foregroundStyle(.green)
                        .interpolationMethod(.monotone)
                    AreaMark(x: .value("Date", point.0), y: .value("$", point.1))
                        .foregroundStyle(.green.opacity(0.1))
                        .interpolationMethod(.monotone)
                    PointMark(x: .value("Date", point.0), y: .value("$", point.1))
                        .foregroundStyle(.green)
                        .symbolSize(30)
                }
            }
            .chartYAxisLabel("$")
            .chartXSelection(value: $selectedSpendDate)
            .frame(height: 200)
        }
        .padding()
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    // MARK: - Rotor Wear Chart

    private var frontRotorData: [(Date, Double)] {
        serviceRecords
            .filter { $0.serviceType == "Front Rotor Thickness Reading" }
            .sorted { $0.timestamp < $1.timestamp }
            .compactMap { r in r.rotorThicknessMM.map { (r.timestamp, $0) } }
    }

    private var rearRotorData: [(Date, Double)] {
        serviceRecords
            .filter { $0.serviceType == "Rear Rotor Thickness Reading" }
            .sorted { $0.timestamp < $1.timestamp }
            .compactMap { r in r.rotorThicknessMM.map { (r.timestamp, $0) } }
    }

    private var frontThreshold: ServiceThreshold? {
        thresholds.first { $0.serviceType == "Front Rotor Thickness Reading" }
    }

    private var rearThreshold: ServiceThreshold? {
        thresholds.first { $0.serviceType == "Rear Rotor Thickness Reading" }
    }

    private var rotorWearChart: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Rotor Wear")
                .font(.headline)

            // Current thickness summary
            HStack(spacing: 16) {
                if let latest = frontRotorData.last {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Front")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        HStack(spacing: 4) {
                            Text("\(latest.1, specifier: "%.1f") mm")
                                .font(.subheadline.bold())
                                .foregroundStyle(.blue)
                            if let crit = frontThreshold?.rotorCritical {
                                Text("(min \(crit, specifier: "%.1f"))")
                                    .font(.caption2)
                                    .foregroundStyle(.red)
                            }
                        }
                    }
                }
                if let latest = rearRotorData.last {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Rear")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        HStack(spacing: 4) {
                            Text("\(latest.1, specifier: "%.1f") mm")
                                .font(.subheadline.bold())
                                .foregroundStyle(.orange)
                            if let crit = rearThreshold?.rotorCritical {
                                Text("(min \(crit, specifier: "%.1f"))")
                                    .font(.caption2)
                                    .foregroundStyle(.red)
                            }
                        }
                    }
                }
            }

            Chart {
                ForEach(frontRotorData, id: \.0) { point in
                    LineMark(x: .value("Date", point.0), y: .value("mm", point.1))
                        .foregroundStyle(by: .value("Type", "Front"))
                        .symbol(.circle)
                    PointMark(x: .value("Date", point.0), y: .value("mm", point.1))
                        .foregroundStyle(by: .value("Type", "Front"))
                        .annotation(position: .top) {
                            Text("\(point.1, specifier: "%.1f")")
                                .font(.system(size: 9))
                                .foregroundStyle(.secondary)
                        }
                }
                ForEach(rearRotorData, id: \.0) { point in
                    LineMark(x: .value("Date", point.0), y: .value("mm", point.1))
                        .foregroundStyle(by: .value("Type", "Rear"))
                        .symbol(.square)
                    PointMark(x: .value("Date", point.0), y: .value("mm", point.1))
                        .foregroundStyle(by: .value("Type", "Rear"))
                        .annotation(position: .bottom) {
                            Text("\(point.1, specifier: "%.1f")")
                                .font(.system(size: 9))
                                .foregroundStyle(.secondary)
                        }
                }

                if let fc = frontThreshold?.rotorCritical {
                    RuleMark(y: .value("Critical", fc))
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [5, 3]))
                        .foregroundStyle(.red)
                        .annotation(position: .trailing, alignment: .leading) {
                            Text("Critical")
                                .font(.caption2)
                                .foregroundStyle(.red)
                        }
                }
                if let fw = frontThreshold?.rotorWarning {
                    RuleMark(y: .value("Warning", fw))
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [5, 3]))
                        .foregroundStyle(.orange)
                        .annotation(position: .trailing, alignment: .leading) {
                            Text("Warning")
                                .font(.caption2)
                                .foregroundStyle(.orange)
                        }
                }

                if let projected = projectRotorWear(data: frontRotorData) {
                    LineMark(x: .value("Date", projected.0), y: .value("mm", projected.1))
                        .foregroundStyle(.gray.opacity(0.5))
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                    LineMark(x: .value("Date", projected.2), y: .value("mm", projected.3))
                        .foregroundStyle(.gray.opacity(0.5))
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                }
            }
            .chartForegroundStyleScale([
                "Front": Color.blue,
                "Rear": Color.orange
            ])
            .chartYAxisLabel("mm")
            .frame(height: 250)
        }
        .padding()
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private func projectRotorWear(data: [(Date, Double)]) -> (Date, Double, Date, Double)? {
        guard let first = data.first, let last = data.last, data.count >= 2 else { return nil }
        let daysDiff = last.0.timeIntervalSince(first.0) / 86400
        guard daysDiff > 0 else { return nil }
        let rate = (first.1 - last.1) / daysDiff
        guard rate > 0 else { return nil }
        let daysAhead = 365.0
        let projected = last.1 - (rate * daysAhead)
        guard let futureDate = Calendar.current.date(byAdding: .day, value: Int(daysAhead), to: last.0) else { return nil }
        return (last.0, last.1, futureDate, max(0, projected))
    }

    // MARK: - Projected Service Dates

    private enum ProjectionStatus: Comparable {
        case overdue
        case projected(Date)
        case noData

        var sortOrder: Int {
            switch self {
            case .overdue: return 0
            case .projected: return 1
            case .noData: return 2
            }
        }
    }

    private var milesPerDay: Double {
        let sorted = mileageRecords.sorted { $0.timestamp < $1.timestamp }
        guard sorted.count >= 2 else { return 0 }

        // Try last 14 days first
        let twoWeeksAgo = Calendar.current.date(byAdding: .day, value: -14, to: Date()) ?? Date()
        let recent14 = sorted.filter { $0.timestamp >= twoWeeksAgo }
        if let velocity = velocity(from: recent14), velocity > 0 {
            return velocity
        }

        // Failsafe: if last 2 weeks is 0, use 3 months prior to the 2-week window
        let threeMonthsBefore = Calendar.current.date(byAdding: .month, value: -3, to: twoWeeksAgo) ?? Date()
        let prior3Months = sorted.filter { $0.timestamp >= threeMonthsBefore && $0.timestamp < twoWeeksAgo }
        if let velocity = velocity(from: prior3Months), velocity > 0 {
            return velocity
        }

        return 0
    }

    private func velocity(from records: [MileageRecord]) -> Double? {
        guard records.count >= 2, let first = records.first, let last = records.last else { return nil }
        let days = last.timestamp.timeIntervalSince(first.timestamp) / 86400
        guard days > 0 else { return nil }
        return (last.odometerMiles - first.odometerMiles) / days
    }

    private var projectedServices: [(String, ProjectionStatus)] {
        let sorted = mileageRecords.sorted { $0.timestamp < $1.timestamp }
        guard let last = sorted.last else { return [] }
        let currentMileage = last.odometerMiles
        let velocity = milesPerDay

        var results: [(String, ProjectionStatus)] = []
        for threshold in thresholds {
            guard threshold.milesWarning != nil || threshold.daysWarning != nil else { continue }

            let lastService = serviceRecords
                .filter { $0.serviceType == threshold.serviceType }
                .sorted { $0.timestamp > $1.timestamp }
                .first

            guard let lastService = lastService else {
                results.append((threshold.serviceType, .noData))
                continue
            }

            var milesDaysUntil: Double?
            if let milesWarning = threshold.milesWarning {
                let milesSince = currentMileage - lastService.odometerMiles
                let milesRemaining = milesWarning - milesSince
                if velocity > 0 {
                    milesDaysUntil = milesRemaining / velocity
                } else {
                    milesDaysUntil = milesRemaining > 0 ? nil : -1
                }
            }

            var timeDaysUntil: Double?
            if let daysWarning = threshold.daysWarning {
                let daysSince = Date().timeIntervalSince(lastService.timestamp) / 86400
                timeDaysUntil = Double(daysWarning) - daysSince
            }

            let daysUntil: Double?
            switch (milesDaysUntil, timeDaysUntil) {
            case let (m?, t?): daysUntil = min(m, t)
            case let (m?, nil): daysUntil = m
            case let (nil, t?): daysUntil = t
            case (nil, nil): daysUntil = nil
            }

            if let daysUntil = daysUntil {
                if daysUntil <= 0 {
                    results.append((threshold.serviceType, .overdue))
                } else if let date = Calendar.current.date(byAdding: .day, value: Int(daysUntil), to: Date()) {
                    results.append((threshold.serviceType, .projected(date)))
                }
            } else {
                results.append((threshold.serviceType, .noData))
            }
        }

        return results.sorted { a, b in
            if a.1.sortOrder != b.1.sortOrder { return a.1.sortOrder < b.1.sortOrder }
            switch (a.1, b.1) {
            case let (.projected(d1), .projected(d2)): return d1 < d2
            default: return a.0 < b.0
            }
        }
    }

    private var projectedServiceDates: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Projected Next Service")
                    .font(.headline)
                Spacer()
                if milesPerDay > 0 {
                    Text("\(Int(milesPerDay)) mi/day")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if projectedServices.isEmpty {
                Text("Not enough data")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(projectedServices, id: \.0) { item in
                    HStack {
                        Text(item.0)
                            .font(.subheadline)
                        Spacer()
                        switch item.1 {
                        case .overdue:
                            Text("OVERDUE")
                                .font(.caption2.bold())
                                .foregroundStyle(.white)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
                                .background(.red)
                                .clipShape(Capsule())
                        case .projected(let date):
                            Text(date.formatted(date: .abbreviated, time: .omitted))
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        case .noData:
                            Text("No data")
                                .font(.caption2.bold())
                                .foregroundStyle(.white)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
                                .background(.gray)
                                .clipShape(Capsule())
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
        }
        .padding()
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    // MARK: - Data Loading

    private func loadData() async {
        isLoading = true
        do {
            async let sr = NeonRepository.shared.getServiceRecords()
            async let mr = NeonRepository.shared.getMileageRecords()
            async let th = NeonRepository.shared.getThresholds()
            serviceRecords = try await sr
            mileageRecords = try await mr
            thresholds = try await th
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }
}
