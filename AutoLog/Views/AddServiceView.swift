import SwiftUI

struct AddServiceView: View {
    let onSave: () async -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var selectedCategory: ServiceCategory?
    @State private var selectedType = ""
    @State private var date = Date()
    @State private var odometerText = ""
    @State private var rotorText = ""
    @State private var amountText = ""
    @State private var comments = ""
    @State private var isSaving = false
    @State private var errorMessage: String?
    @State private var rotationPattern: RotationPattern = .rearwardCross
    @State private var replacementCorners: Set<TirePosition> = []
    @State private var tireMakeModel = ""

    private var isRotorType: Bool {
        selectedType.contains("Rotor Thickness")
    }
    private var isTireRotation: Bool { selectedType == "Tire Rotation" }
    private var isTireReplacement: Bool { selectedType == "Tire Replacement" }

    var body: some View {
        NavigationStack {
            Form {
                Section("Service") {
                    Picker("Category", selection: $selectedCategory) {
                        ForEach(ServiceCategory.all, id: \.name) { cat in
                            Text(cat.name).tag(Optional(cat))
                        }
                    }
                    .onChange(of: selectedCategory) { _, newCat in
                        selectedType = newCat?.types.first ?? ""
                    }

                    if let cat = selectedCategory {
                        Picker("Service Type", selection: $selectedType) {
                            ForEach(cat.types, id: \.self) { type in
                                Text(type).tag(type)
                            }
                        }
                    }
                }

                if isTireRotation {
                    Section("Rotation") {
                        Picker("Pattern", selection: $rotationPattern) {
                            ForEach(RotationPattern.allCases) { p in
                                Text(p.rawValue).tag(p)
                            }
                        }
                        RotationDiagram(pattern: rotationPattern)
                            .frame(height: 150)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 4)
                        Text(rotationPattern.patternString)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .center)
                    }
                }

                if isTireReplacement {
                    Section("Replaced tire(s)") {
                        ForEach(TirePosition.allCases) { pos in
                            Button {
                                if replacementCorners.contains(pos) {
                                    replacementCorners.remove(pos)
                                } else {
                                    replacementCorners.insert(pos)
                                }
                            } label: {
                                HStack {
                                    Text(pos.displayName).foregroundStyle(.primary)
                                    Spacer()
                                    if replacementCorners.contains(pos) {
                                        Image(systemName: "checkmark").foregroundStyle(.tint)
                                    }
                                }
                            }
                        }
                        TextField("Make / model", text: $tireMakeModel)
                    }
                }

                Section("Details") {
                    DatePicker("Date", selection: $date, displayedComponents: [.date])

                    TextField("Odometer (miles)", text: $odometerText)
                        .keyboardType(.decimalPad)

                    if isRotorType {
                        TextField("Rotor Thickness (mm)", text: $rotorText)
                            .keyboardType(.decimalPad)
                    }

                    TextField("Amount ($)", text: $amountText)
                        .keyboardType(.decimalPad)

                    TextField("Comments", text: $comments, axis: .vertical)
                        .lineLimit(3)
                }
            }
            .navigationTitle("Add Service")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { Task { await save() } }
                        .disabled(isSaving || selectedType.isEmpty || odometerText.isEmpty || (isTireReplacement && replacementCorners.isEmpty))
                }
            }
            .overlay(alignment: .bottom) {
                if let msg = errorMessage {
                    Text(msg)
                        .font(.caption).foregroundStyle(.white)
                        .padding(.horizontal, 16).padding(.vertical, 8)
                        .background(.red.opacity(0.9)).clipShape(Capsule())
                        .padding(.bottom, 8)
                }
            }
            .task { await loadDefaults() }
        }
    }

    private func loadDefaults() async {
        if selectedCategory == nil, let first = ServiceCategory.all.first {
            selectedCategory = first
            selectedType = first.types.first ?? ""
        }
        if let latest = try? await NeonRepository.shared.getLatestMileageRecord() {
            odometerText = String(Int(latest.odometerMiles))
        }
    }

    private func save() async {
        guard let odometer = Double(odometerText) else {
            errorMessage = "Invalid odometer value"
            return
        }
        isSaving = true

        let record = ServiceRecord.new(
            serviceType: selectedType,
            category: selectedCategory?.name ?? "General",
            odometer: odometer,
            date: date,
            rotorThickness: Double(rotorText),
            amount: Double(amountText),
            comments: recordComments()
        )

        do {
            try await NeonRepository.shared.saveServiceRecord(record)
            try await applyTireSideEffects(odometer: odometer)
            await onSave()
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
            SyncManager.shared.queueServiceRecord(record)
        }
        isSaving = false
    }

    /// For a tire replacement with no comment, summarize make + corners so the
    /// maintenance history row is still readable.
    private func recordComments() -> String? {
        if !comments.isEmpty { return comments }
        if isTireReplacement {
            let make = tireMakeModel.trimmingCharacters(in: .whitespaces)
            let corners = TirePosition.allCases.filter { replacementCorners.contains($0) }
                .map { $0.rawValue }.joined(separator: "/")
            let summary = [make.isEmpty ? nil : make, corners.isEmpty ? nil : corners]
                .compactMap { $0 }.joined(separator: " ")
            return summary.isEmpty ? nil : summary
        }
        if isTireRotation {
            return rotationPattern.patternString
        }
        return nil
    }

    /// Logging a rotation or replacement in Maintenance also updates the
    /// physical tire layout so the Tires view reflects it.
    private func applyTireSideEffects(odometer: Double) async throws {
        if isTireRotation {
            try await NeonRepository.shared.applyRotation(
                mapping: rotationPattern.mapping,
                odometer: odometer,
                date: date,
                pattern: rotationPattern.patternString,
                comments: comments.isEmpty ? nil : comments
            )
        } else if isTireReplacement {
            let make = tireMakeModel.trimmingCharacters(in: .whitespaces)
            for corner in TirePosition.allCases where replacementCorners.contains(corner) {
                try await NeonRepository.shared.replaceTire(
                    at: corner,
                    makeModel: make.isEmpty ? nil : make,
                    odometer: odometer,
                    date: date,
                    notes: comments.isEmpty ? nil : comments
                )
            }
        }
    }
}

extension ServiceCategory: Hashable {
    static func == (lhs: ServiceCategory, rhs: ServiceCategory) -> Bool {
        lhs.name == rhs.name
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(name)
    }
}

/// A small top-down car schematic with arrows showing where each tire moves
/// for the selected rotation pattern. Helps the user understand the pattern
/// without knowing the FL/RL shorthand.
struct RotationDiagram: View {
    let pattern: RotationPattern

    var body: some View {
        Canvas { context, size in
            let inset: CGFloat = 24
            let topPad: CGFloat = 16
            let pts: [TirePosition: CGPoint] = [
                .FL: CGPoint(x: inset, y: topPad + 8),
                .FR: CGPoint(x: size.width - inset, y: topPad + 8),
                .RL: CGPoint(x: inset, y: size.height - inset),
                .RR: CGPoint(x: size.width - inset, y: size.height - inset)
            ]

            // Car body outline
            let bodyRect = CGRect(x: inset - 12, y: topPad - 6,
                                  width: size.width - 2 * (inset - 12),
                                  height: size.height - (topPad - 6) - (inset - 12))
            let body = Path(roundedRect: bodyRect, cornerRadius: 18)
            context.stroke(body, with: .color(.secondary.opacity(0.35)), lineWidth: 1.5)
            // Windshield line near the front
            var windshield = Path()
            windshield.move(to: CGPoint(x: bodyRect.minX + 14, y: bodyRect.minY + 22))
            windshield.addLine(to: CGPoint(x: bodyRect.maxX - 14, y: bodyRect.minY + 22))
            context.stroke(windshield, with: .color(.secondary.opacity(0.25)), lineWidth: 1)
            drawLabel(context, Text("FRONT").font(.system(size: 8, weight: .semibold)),
                      color: .secondary, at: CGPoint(x: size.width / 2, y: bodyRect.minY + 9))

            // Movement arrows
            for src in TirePosition.allCases {
                let dst = pattern.mapping[src] ?? src
                guard src != dst, let p1 = pts[src], let p2 = pts[dst] else { continue }
                drawArrow(context, from: p1, to: p2)
            }

            // Corner dots + labels
            for pos in TirePosition.allCases {
                guard let p = pts[pos] else { continue }
                let dot = Path(ellipseIn: CGRect(x: p.x - 5, y: p.y - 5, width: 10, height: 10))
                context.fill(dot, with: .color(.accentColor))
                let labelY = pos.rawValue.hasPrefix("F") ? p.y - 15 : p.y + 15
                drawLabel(context, Text(pos.rawValue).font(.system(size: 10, weight: .bold)),
                          color: .primary, at: CGPoint(x: p.x, y: labelY))
            }
        }
        .accessibilityLabel("Rotation pattern \(pattern.rawValue): \(pattern.patternString)")
    }

    /// Draw a Text label with an explicit color. Uses resolve+shading because
    /// GraphicsContext.draw requires a `Text`, and `.foregroundStyle` on Text
    /// returns a View, not Text.
    private func drawLabel(_ context: GraphicsContext, _ text: Text, color: Color, at point: CGPoint) {
        var resolved = context.resolve(text)
        resolved.shading = .color(color)
        context.draw(resolved, at: point)
    }

    private func drawArrow(_ context: GraphicsContext, from: CGPoint, to: CGPoint) {
        let angle = atan2(to.y - from.y, to.x - from.x)
        let gap: CGFloat = 10
        let start = CGPoint(x: from.x + cos(angle) * gap, y: from.y + sin(angle) * gap)
        let end = CGPoint(x: to.x - cos(angle) * gap, y: to.y - sin(angle) * gap)

        var shaft = Path()
        shaft.move(to: start)
        shaft.addLine(to: end)
        context.stroke(shaft, with: .color(.cyan), style: StrokeStyle(lineWidth: 2, lineCap: .round))

        let head: CGFloat = 7
        var arrow = Path()
        arrow.move(to: end)
        arrow.addLine(to: CGPoint(x: end.x - cos(angle - .pi / 6) * head, y: end.y - sin(angle - .pi / 6) * head))
        arrow.move(to: end)
        arrow.addLine(to: CGPoint(x: end.x - cos(angle + .pi / 6) * head, y: end.y - sin(angle + .pi / 6) * head))
        context.stroke(arrow, with: .color(.cyan), style: StrokeStyle(lineWidth: 2, lineCap: .round))
    }
}
