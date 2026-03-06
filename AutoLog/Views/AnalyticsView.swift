import SwiftUI
import Charts

struct AnalyticsView: View {
    @State private var serviceRecords: [ServiceRecord] = []
    @State private var mileageRecords: [MileageRecord] = []
    @State private var thresholds: [ServiceThreshold] = []
    @State private var isLoading = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 24) {
                    if !frontRotorData.isEmpty || !rearRotorData.isEmpty {
                        rotorWearChart
                    }
                    if !monthlyMiles.isEmpty {
                        milesPerMonthChart
                    }
                    if !spendData.isEmpty {
                        spendOverTimeChart
                    }
                    if !projectedServices.isEmpty {
                        projectedServiceDates
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

    // MARK: - Rotor Wear Chart

    private var frontRotorData: [(Date, Double)] {
        serviceRecords
            .filter { $0.serviceType == "Front Rotor Thickness Reading" && $0.rotorThicknessMM != nil }
            .sorted { $0.timestamp < $1.timestamp }
            .map { ($0.timestamp, $0.rotorThicknessMM!) }
    }

    private var rearRotorData: [(Date, Double)] {
        serviceRecords
            .filter { $0.serviceType == "Rear Rotor Thickness Reading" && $0.rotorThicknessMM != nil }
            .sorted { $0.timestamp < $1.timestamp }
            .map { ($0.timestamp, $0.rotorThicknessMM!) }
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

            Chart {
                ForEach(frontRotorData, id: \.0) { point in
                    LineMark(x: .value("Date", point.0), y: .value("mm", point.1))
                        .foregroundStyle(by: .value("Type", "Front"))
                        .symbol(.circle)
                }
                ForEach(rearRotorData, id: \.0) { point in
                    LineMark(x: .value("Date", point.0), y: .value("mm", point.1))
                        .foregroundStyle(by: .value("Type", "Rear"))
                        .symbol(.square)
                }

                if let fc = frontThreshold?.rotorCritical {
                    RuleMark(y: .value("Front Critical", fc))
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [5, 3]))
                        .foregroundStyle(.red)
                        .annotation(position: .trailing, alignment: .leading) {
                            Text("Crit")
                                .font(.caption2)
                                .foregroundStyle(.red)
                        }
                }
                if let fw = frontThreshold?.rotorWarning {
                    RuleMark(y: .value("Front Warning", fw))
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [5, 3]))
                        .foregroundStyle(.yellow)
                }

                // Projected wear for front rotors
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
            .frame(height: 250)
        }
        .padding()
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private func projectRotorWear(data: [(Date, Double)]) -> (Date, Double, Date, Double)? {
        guard data.count >= 2 else { return nil }
        let first = data.first!
        let last = data.last!
        let daysDiff = last.0.timeIntervalSince(first.0) / 86400
        guard daysDiff > 0 else { return nil }
        let rate = (first.1 - last.1) / daysDiff
        guard rate > 0 else { return nil }
        let daysAhead = 365.0
        let projected = last.1 - (rate * daysAhead)
        let futureDate = Calendar.current.date(byAdding: .day, value: Int(daysAhead), to: last.0)!
        return (last.0, last.1, futureDate, max(0, projected))
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

    private var milesPerMonthChart: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Miles Per Month")
                .font(.headline)

            Chart {
                ForEach(monthlyMiles, id: \.0) { item in
                    BarMark(x: .value("Month", item.0), y: .value("Miles", item.1))
                        .foregroundStyle(.blue.gradient)
                }
            }
            .frame(height: 200)
        }
        .padding()
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    // MARK: - Spend Over Time

    private var spendData: [(Date, Double)] {
        let withAmount = serviceRecords.filter { $0.amount != nil && $0.amount! > 0 }
            .sorted { $0.timestamp < $1.timestamp }

        var cumulative = 0.0
        return withAmount.map { record in
            cumulative += record.amount!
            return (record.timestamp, cumulative)
        }
    }

    private var spendOverTimeChart: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Cumulative Spend")
                .font(.headline)

            Chart {
                ForEach(spendData, id: \.0) { point in
                    LineMark(x: .value("Date", point.0), y: .value("$", point.1))
                        .foregroundStyle(.green)
                    AreaMark(x: .value("Date", point.0), y: .value("$", point.1))
                        .foregroundStyle(.green.opacity(0.1))
                }
            }
            .frame(height: 200)
        }
        .padding()
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    // MARK: - Projected Service Dates

    private var projectedServices: [(String, Date)] {
        guard let currentMileage = mileageRecords.first?.odometerMiles else { return [] }

        let sorted = mileageRecords.sorted { $0.timestamp < $1.timestamp }
        guard sorted.count >= 2 else { return [] }

        let first = sorted.first!
        let last = sorted.last!
        let days = last.timestamp.timeIntervalSince(first.timestamp) / 86400
        guard days > 30 else { return [] }
        let milesPerDay = (last.odometerMiles - first.odometerMiles) / days
        guard milesPerDay > 0 else { return [] }

        var results: [(String, Date)] = []
        for threshold in thresholds {
            guard let milesCritical = threshold.milesCritical else { continue }
            let lastService = serviceRecords
                .filter { $0.serviceType == threshold.serviceType }
                .sorted { $0.timestamp > $1.timestamp }
                .first

            let milesSince = currentMileage - (lastService?.odometerMiles ?? 0)
            let milesRemaining = milesCritical - milesSince
            guard milesRemaining > 0 else { continue }

            let daysUntil = milesRemaining / milesPerDay
            if let date = Calendar.current.date(byAdding: .day, value: Int(daysUntil), to: Date()) {
                results.append((threshold.serviceType, date))
            }
        }

        return results.sorted { $0.1 < $1.1 }
    }

    private var projectedServiceDates: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Projected Next Service")
                .font(.headline)

            ForEach(projectedServices, id: \.0) { item in
                HStack {
                    Text(item.0)
                        .font(.subheadline)
                    Spacer()
                    Text(item.1.formatted(date: .abbreviated, time: .omitted))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 2)
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
