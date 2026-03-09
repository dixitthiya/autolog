import Foundation
import SwiftUI

@MainActor
class CSVImporter: ObservableObject {
    @Published var isImporting = false
    @Published var progress: Double = 0
    @Published var totalRows = 0
    @Published var importedCount = 0
    @Published var errorMessage: String?
    @Published var isComplete = false
    @Published var statusText: String = ""

    private static let hasImportedKey = "csvImportComplete"

    static var hasImported: Bool {
        UserDefaults.standard.bool(forKey: hasImportedKey)
    }

    static func markImported() {
        UserDefaults.standard.set(true, forKey: hasImportedKey)
    }

    func importFromURL(_ urlString: String) async {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed) else {
            errorMessage = "Invalid URL"
            return
        }

        isImporting = true
        progress = 0
        importedCount = 0
        errorMessage = nil
        statusText = "Downloading CSV..."

        let content: String
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            guard let decoded = String(data: data, encoding: .utf8) else {
                errorMessage = "Cannot decode file as UTF-8"
                isImporting = false
                return
            }
            content = decoded
            statusText = "Downloaded \(data.count) bytes"
        } catch {
            errorMessage = "Download failed: \(error.localizedDescription)"
            isImporting = false
            return
        }

        await processCSV(content)
    }

    func importFromText(_ text: String) async {
        isImporting = true
        progress = 0
        importedCount = 0
        errorMessage = nil
        statusText = "Processing CSV..."
        await processCSV(text)
    }

    private func processCSV(_ content: String) async {
        var skippedCount = 0

        let lines = content.components(separatedBy: .newlines).filter { line in
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return false }
            return !trimmed.allSatisfy { $0 == "," }
        }

        guard lines.count > 1 else {
            errorMessage = "CSV file is empty or has no data rows"
            isImporting = false
            return
        }

        let header = parseCSVLine(lines[0])
        let dataLines = Array(lines.dropFirst())
        totalRows = dataLines.count

        let colMap = Dictionary(uniqueKeysWithValues: header.enumerated().map { ($1.trimmingCharacters(in: .whitespaces).lowercased(), $0) })

        let timestampIdx = colMap["timestamp"]
        let serviceTypeIdx = colMap["service type"]
        let odometerIdx = colMap["odometer reading (miles)"]
        let rotorIdx = colMap["rotor thickness (mm)"]
        let amountIdx = colMap["amount"]
        let commentsIdx = colMap["comments"]

        guard let tsIdx = timestampIdx, let stIdx = serviceTypeIdx, let odIdx = odometerIdx else {
            errorMessage = "Missing required columns: Timestamp, Service Type, Odometer Reading (Miles)"
            isImporting = false
            return
        }

        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "M/d/yyyy H:mm:ss"
        dateFormatter.locale = Locale(identifier: "en_US_POSIX")
        let altFormatter = DateFormatter()
        altFormatter.dateFormat = "M/d/yyyy"
        altFormatter.locale = Locale(identifier: "en_US_POSIX")
        let isoFormatter = DateFormatter()
        isoFormatter.dateFormat = "yyyy-MM-dd"
        isoFormatter.locale = Locale(identifier: "en_US_POSIX")

        statusText = "Importing \(totalRows) rows..."

        for (i, line) in dataLines.enumerated() {
            let cols = parseCSVLine(line)
            guard cols.count > max(tsIdx, stIdx, odIdx) else {
                skippedCount += 1
                progress = Double(i + 1) / Double(totalRows)
                continue
            }

            let timestampStr = cols[tsIdx].trimmingCharacters(in: .whitespaces)
            let serviceType = cols[stIdx].trimmingCharacters(in: .whitespaces)
            let odometerStr = cols[odIdx].trimmingCharacters(in: .whitespaces)

            guard !serviceType.isEmpty, let odometer = Double(odometerStr.replacingOccurrences(of: ",", with: "")) else {
                skippedCount += 1
                progress = Double(i + 1) / Double(totalRows)
                continue
            }
            guard let date = dateFormatter.date(from: timestampStr) ?? altFormatter.date(from: timestampStr) ?? isoFormatter.date(from: timestampStr) else {
                skippedCount += 1
                progress = Double(i + 1) / Double(totalRows)
                continue
            }

            let rotor = rotorIdx.flatMap { idx in cols.count > idx ? Double(cols[idx].trimmingCharacters(in: .whitespaces)) : nil }
            let amount = amountIdx.flatMap { idx in
                cols.count > idx ? Double(cols[idx].trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "$", with: "").replacingOccurrences(of: ",", with: "")) : nil
            }
            let comments = commentsIdx.flatMap { idx in cols.count > idx ? cols[idx].trimmingCharacters(in: .whitespaces) : nil }

            do {
                if serviceType == "Current Mileage" {
                    let record = MileageRecord.imported(odometer: odometer, date: date)
                    try await NeonRepository.shared.saveMileageRecord(record)
                } else {
                    let category = ServiceCategory.category(for: serviceType)
                    let record = ServiceRecord(
                        id: UUID().uuidString,
                        timestamp: date,
                        serviceType: serviceType,
                        category: category,
                        odometerMiles: odometer,
                        rotorThicknessMM: rotor,
                        amount: amount,
                        comments: comments?.isEmpty == true ? nil : comments,
                        manuallyEdited: false
                    )
                    try await NeonRepository.shared.saveServiceRecord(record)
                }
                importedCount += 1
            } catch {
                skippedCount += 1
                Log.csv("error importing row \(i): \(error.localizedDescription)")
            }

            progress = Double(i + 1) / Double(totalRows)

            if (i + 1) % 10 == 0 {
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
        }

        Log.csv("import complete: \(importedCount) imported, \(skippedCount) skipped out of \(totalRows) rows")
        statusText = "\(importedCount) imported, \(skippedCount) skipped"
        CSVImporter.markImported()
        isComplete = true
        isImporting = false
    }

    private func parseCSVLine(_ line: String) -> [String] {
        var result: [String] = []
        var current = ""
        var inQuotes = false

        for char in line {
            if char == "\"" {
                inQuotes.toggle()
            } else if char == "," && !inQuotes {
                result.append(current)
                current = ""
            } else {
                current.append(char)
            }
        }
        result.append(current)
        return result
    }
}

struct CSVImportView: View {
    @StateObject private var importer = CSVImporter()
    @Binding var showImport: Bool
    @State private var csvURL: String = ""
    @FocusState private var isURLFieldFocused: Bool

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                Image(systemName: "doc.text")
                    .font(.system(size: 50))
                    .foregroundStyle(.blue)

                Text("Import Service History")
                    .font(.title2.bold())

                if !importer.isImporting && !importer.isComplete {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Paste a direct link to your CSV file:")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)

                        TextField("https://docs.google.com/...export?format=csv", text: $csvURL)
                            .textFieldStyle(.roundedBorder)
                            .keyboardType(.URL)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                            .focused($isURLFieldFocused)

                        Text("In Google Sheets: File > Share > Publish to web > CSV format")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal)
                }

                if !importer.statusText.isEmpty {
                    Text(importer.statusText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if importer.isImporting {
                    VStack(spacing: 12) {
                        ProgressView(value: importer.progress)
                            .progressViewStyle(.linear)
                        Text("Importing \(importer.importedCount) of \(importer.totalRows) records...")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 32)
                } else if importer.isComplete {
                    VStack(spacing: 8) {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 40))
                            .foregroundStyle(.green)
                        Text("Successfully imported \(importer.importedCount) records")
                            .font(.headline)
                    }
                } else if let error = importer.errorMessage {
                    Text(error)
                        .foregroundStyle(.red)
                        .font(.caption)
                        .padding(.horizontal)
                }

                Spacer()

                if importer.isComplete {
                    Button("Continue") {
                        showImport = false
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                } else if !importer.isImporting {
                    VStack(spacing: 12) {
                        Button("Import CSV") {
                            isURLFieldFocused = false
                            Task {
                                await importer.importFromURL(csvURL)
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                        .disabled(csvURL.trimmingCharacters(in: .whitespaces).isEmpty)

                        Button("Skip Import") {
                            CSVImporter.markImported()
                            showImport = false
                        }
                        .foregroundStyle(.secondary)
                    }
                }
            }
            .padding()
            .navigationTitle("Data Migration")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}
