import SafeSpaceCore
import SwiftUI

struct RegionSelectionView: View {
    let assessmentID: AssessmentSummary.ID
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var stored: StoredAssessment?
    @State private var regionA: NormalizedRect?
    @State private var regionB: NormalizedRect?
    @State private var measurement: ContrastMeasurement?
    @State private var errorMessage: String?
    @State private var isComparing = false

    var body: some View {
        Group {
            if let stored, let image = stored.image?.uiImage {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        Text("Drag on the photo to mark region A, then region B. Each box needs at least 100 eligible pixels.")
                            .font(.subheadline)
                        RegionBoxPicker(image: image, regionA: $regionA, regionB: $regionB)
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                        HStack(spacing: 16) {
                            Label("Region A", systemImage: "square")
                                .foregroundStyle(.blue)
                            Label("Region B", systemImage: "square")
                                .foregroundStyle(.orange)
                        }
                        .font(.subheadline)
                        Button("Clear boxes", systemImage: "arrow.counterclockwise") {
                            regionA = nil
                            regionB = nil
                            measurement = nil
                            errorMessage = nil
                        }
                        .disabled(regionA == nil && regionB == nil)

                        if let measurement {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Region A vs. Region B").font(.headline)
                                Text("ΔE00 = \(measurement.deltaE.formatted(.number.precision(.fractionLength(2))))")
                                    .font(.title2.bold())
                                Text("An image-derived color difference was detected between the selected "
                                    + "regions. Larger ΔE00 values indicate greater color difference.")
                                    .font(.subheadline).foregroundStyle(.secondary)
                            }
                            .accessibilityElement(children: .combine)
                        }
                        if let errorMessage {
                            Label(errorMessage, systemImage: "exclamationmark.triangle")
                                .foregroundStyle(.orange)
                        }
                        Button {
                            compare()
                        } label: {
                            if isComparing {
                                ProgressView("Comparing areas…")
                                    .frame(maxWidth: .infinity)
                            } else {
                                Text("Compare areas")
                                    .frame(maxWidth: .infinity)
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(regionA == nil || regionB == nil || isComparing)
                    }
                    .padding()
                }
            } else if stored == nil {
                ProgressView("Loading photo…")
            } else {
                ContentUnavailableView("Photo unavailable", systemImage: "photo",
                                       description: Text("This saved assessment has no readable photo to compare."))
            }
        }
        .navigationTitle("Select regions")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Close") { dismiss() }
            }
        }
        .task(id: assessmentID) {
            do { stored = try await model.loadAssessment(id: assessmentID) }
            catch { errorMessage = error.localizedDescription }
        }
    }

    @MainActor private func compare() {
        guard let regionA, let regionB, !isComparing else { return }
        isComparing = true
        errorMessage = nil
        Task {
            defer { isComparing = false }
            do {
                let updated = try await model.addContrast(assessmentID: assessmentID, regionA: regionA, regionB: regionB)
                measurement = updated.steps.contrast.result?.measurements.last
            } catch RegionContrastError.regionTooSmall(let region) {
                let label = region == 1 ? "A" : "B"
                errorMessage = "Region \(label) is too small to measure reliably — drag a bigger box."
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}

/// Draws two boxes on the photo by dragging: the first drag marks region A, the second
/// marks region B. Pure UI/gesture code — produces `NormalizedRect`s, nothing else.
private struct RegionBoxPicker: View {
    let image: UIImage
    @Binding var regionA: NormalizedRect?
    @Binding var regionB: NormalizedRect?
    @State private var nextSide: RegionSide = .a
    @State private var draft: Draft?

    private enum RegionSide { case a, b }
    private struct Draft {
        var side: RegionSide
        var start: CGPoint
        var end: CGPoint
    }

    var body: some View {
        GeometryReader { proxy in
            let imageRect = fittedRect(in: proxy.size)
            ZStack {
                Color.black
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(width: imageRect.width, height: imageRect.height)
                    .position(x: imageRect.midX, y: imageRect.midY)
                Canvas { context, _ in
                    draw(regionA, color: .blue, imageRect: imageRect, in: &context)
                    draw(regionB, color: .orange, imageRect: imageRect, in: &context)
                    if let draft {
                        draw(rect(for: draft), color: draft.side == .a ? .blue : .orange,
                             imageRect: imageRect, in: &context)
                    }
                }
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            if draft == nil {
                                guard imageRect.contains(value.startLocation) else { return }
                                let start = normalized(value.startLocation, in: imageRect)
                                draft = Draft(side: nextSide, start: start, end: start)
                            }
                            guard var current = draft else { return }
                            current.end = normalized(value.location, in: imageRect)
                            draft = current
                        }
                        .onEnded { value in
                            guard var current = draft else { return }
                            current.end = normalized(value.location, in: imageRect)
                            let selection = rect(for: current)
                            if current.side == .a {
                                regionA = selection
                                nextSide = .b
                            } else {
                                regionB = selection
                                nextSide = .a
                            }
                            draft = nil
                        }
                )
            }
        }
        .aspectRatio(image.size.width / image.size.height, contentMode: .fit)
        .accessibilityLabel("Photo selection area. Draw a box for region A, then region B.")
    }

    private func fittedRect(in size: CGSize) -> CGRect {
        let scale = min(size.width / image.size.width, size.height / image.size.height)
        let width = image.size.width * scale
        let height = image.size.height * scale
        return CGRect(x: (size.width - width) / 2, y: (size.height - height) / 2,
                      width: width, height: height)
    }

    private func normalized(_ point: CGPoint, in imageRect: CGRect) -> CGPoint {
        CGPoint(x: min(max((point.x - imageRect.minX) / imageRect.width, 0), 1),
                y: min(max((point.y - imageRect.minY) / imageRect.height, 0), 1))
    }

    private func rect(for draft: Draft) -> NormalizedRect {
        NormalizedRect(x: min(draft.start.x, draft.end.x), y: min(draft.start.y, draft.end.y),
                       width: abs(draft.end.x - draft.start.x), height: abs(draft.end.y - draft.start.y))
    }

    private func draw(_ rect: NormalizedRect?, color: Color, imageRect: CGRect,
                      in context: inout GraphicsContext) {
        guard let rect else { return }
        let box = CGRect(x: imageRect.minX + rect.x * imageRect.width,
                         y: imageRect.minY + rect.y * imageRect.height,
                         width: rect.width * imageRect.width, height: rect.height * imageRect.height)
        context.fill(Path(box), with: .color(color.opacity(0.18)))
        context.stroke(Path(box), with: .color(color), lineWidth: 3)
    }
}
