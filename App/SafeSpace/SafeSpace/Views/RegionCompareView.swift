import SwiftUI
import SafeSpaceCore

/// Lets the user drag two fixed-size boxes over the saved photo and measure the color
/// difference between them, using the existing `RegionContrast`/`ColorDifference.ciede2000`
/// math (contract §4.8) via `AppModel.addContrastMeasurement`.
struct RegionCompareView: View {
    let roomID: Room.ID
    let assessmentID: AssessmentSummary.ID
    @Environment(AppModel.self) private var model
    @State private var assessment: StoredAssessment?
    @State private var loadError: String?
    @State private var displayRect: CGRect = .zero
    @State private var box1Center: CGPoint = .zero
    @State private var box2Center: CGPoint = .zero
    @State private var hasPlacedDefaults = false
    @State private var isComputing = false
    @State private var resultText: String?
    @State private var errorMessage: String?

    private static let boxSize = CGSize(width: 60, height: 60)

    var body: some View {
        Group {
            if let assessment, let image = assessment.image, let mask = assessment.mask, let uiImage = image.uiImage {
                GeometryReader { geo in
                    ZStack {
                        Image(uiImage: uiImage).resizable().scaledToFit()
                        DraggableBox(color: .blue, label: "1", dashed: false, size: Self.boxSize,
                                     center: $box1Center, bounds: displayRect)
                        DraggableBox(color: .orange, label: "2", dashed: true, size: Self.boxSize,
                                     center: $box2Center, bounds: displayRect)
                    }
                    .frame(width: geo.size.width, height: geo.size.height)
                    .onAppear { placeDefaultsIfNeeded(containerSize: geo.size) }
                }
                .overlay(alignment: .bottom) {
                    VStack(spacing: 8) {
                        if let resultText { Text(resultText).font(.headline) }
                        Button {
                            compute(image: image, mask: mask, record: assessment.record)
                        } label: {
                            if isComputing { ProgressView() } else { Text("Compute") }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(isComputing)
                    }
                    .padding()
                    .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12))
                    .padding()
                }
            } else if assessment != nil {
                ContentUnavailableView("No saved photo", systemImage: "photo",
                    description: Text("This assessment didn't keep a photo copy, so areas can't be compared."))
            } else if let loadError {
                ContentUnavailableView("Can't open this assessment", systemImage: "exclamationmark.triangle",
                    description: Text(loadError))
            } else {
                ProgressView()
            }
        }
        .navigationTitle("Compare two areas")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: assessmentID) {
            do { assessment = try await model.loadAssessment(id: assessmentID) }
            catch { loadError = error.localizedDescription }
        }
        .alert("Can't measure this", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("OK", role: .cancel) { errorMessage = nil }
        } message: { Text(errorMessage ?? "") }
    }

    /// Where the image is actually drawn within the GeometryReader, accounting for the
    /// letterboxing `scaledToFit` introduces when the image's aspect ratio doesn't match
    /// the container's.
    private func placeDefaultsIfNeeded(containerSize: CGSize) {
        guard !hasPlacedDefaults, let image = assessment?.image else { return }
        let rect = Self.displayRect(containerSize: containerSize, imageWidth: image.width, imageHeight: image.height)
        guard rect.width > 0 else { return }
        displayRect = rect
        box1Center = CGPoint(x: rect.minX + rect.width * 0.25, y: rect.minY + rect.height * 0.25)
        box2Center = CGPoint(x: rect.minX + rect.width * 0.75, y: rect.minY + rect.height * 0.75)
        hasPlacedDefaults = true
    }

    private static func displayRect(containerSize: CGSize, imageWidth: Int, imageHeight: Int) -> CGRect {
        guard containerSize.width > 0, containerSize.height > 0, imageWidth > 0, imageHeight > 0 else { return .zero }
        let imageSize = CGSize(width: CGFloat(imageWidth), height: CGFloat(imageHeight))
        let scale = min(containerSize.width / imageSize.width, containerSize.height / imageSize.height)
        let size = CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
        let origin = CGPoint(x: (containerSize.width - size.width) / 2, y: (containerSize.height - size.height) / 2)
        return CGRect(origin: origin, size: size)
    }

    /// Converts a box (center + fixed size, in the same local space as `displayRect`) to a
    /// `NormalizedRect` relative to the image, as `RegionContrast.measure` expects.
    private func normalizedRect(center: CGPoint) -> NormalizedRect {
        guard displayRect.width > 0, displayRect.height > 0 else { return NormalizedRect(x: 0, y: 0, width: 0, height: 0) }
        let origin = CGPoint(x: center.x - Self.boxSize.width / 2, y: center.y - Self.boxSize.height / 2)
        let rect = CGRect(origin: origin, size: Self.boxSize).intersection(displayRect)
        return NormalizedRect(
            x: (rect.minX - displayRect.minX) / displayRect.width,
            y: (rect.minY - displayRect.minY) / displayRect.height,
            width: rect.width / displayRect.width,
            height: rect.height / displayRect.height
        )
    }

    private func compute(image: SRGBImage, mask: EligibilityMask, record: AssessmentRecord) {
        let region1 = normalizedRect(center: box1Center)
        let region2 = normalizedRect(center: box2Center)
        isComputing = true
        Task {
            defer { isComputing = false }
            do {
                let updated = try await model.addContrastMeasurement(
                    to: record, image: image, mask: mask, region1: region1, region2: region2
                )
                guard let result = updated.steps.contrast.result, let measurement = result.measurements.last else { return }
                resultText = "ΔE \(measurement.deltaE.formatted(.number.precision(.fractionLength(1)))) "
                    + "· \(result.colorSpace.uppercased()) · \(result.formula.uppercased())"
            } catch RegionContrastError.regionTooSmall(let region) {
                errorMessage = "Area \(region) is too small to measure reliably — drag it over a bigger patch of color."
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}

/// One draggable comparison box. Drag moves it; size is fixed. `bounds` (the image's
/// letterboxed display rect) clamps the box so it can never leave the photo.
private struct DraggableBox: View {
    let color: Color
    let label: String
    let dashed: Bool
    let size: CGSize
    @Binding var center: CGPoint
    let bounds: CGRect
    @GestureState private var dragOffset: CGSize = .zero

    var body: some View {
        ZStack {
            Rectangle().strokeBorder(color, style: StrokeStyle(lineWidth: 2, dash: dashed ? [6, 4] : []))
            Text(label).font(.caption.bold()).padding(4).background(color, in: Capsule()).foregroundStyle(.white)
        }
        .frame(width: size.width, height: size.height)
        .position(x: center.x + dragOffset.width, y: center.y + dragOffset.height)
        .gesture(
            DragGesture()
                .updating($dragOffset) { value, state, _ in state = value.translation }
                .onEnded { value in
                    let proposed = CGPoint(x: center.x + value.translation.width, y: center.y + value.translation.height)
                    center = clamp(proposed)
                }
        )
    }

    private func clamp(_ point: CGPoint) -> CGPoint {
        guard bounds.width > 0, bounds.height > 0 else { return point }
        let halfW = size.width / 2, halfH = size.height / 2
        return CGPoint(x: min(max(point.x, bounds.minX + halfW), bounds.maxX - halfW),
                        y: min(max(point.y, bounds.minY + halfH), bounds.maxY - halfH))
    }
}
