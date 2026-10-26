import SwiftUI
import UniformTypeIdentifiers
import SafeSpaceCore

struct AssessmentResultView: View {
    let roomID: Room.ID
    let assessmentID: Assessment.ID
    @Environment(AppModel.self) private var model
    @State private var exportDocument: AssessmentJSONDocument?
    @State private var isExporting = false
    @State private var errorMessage: String?

    var body: some View {
        Group {
            if let assessment = model.assessment(id: assessmentID, in: roomID) {
                List {
                    Section("Photo") {
                        ForEach(assessment.photos) { photo in
                            VStack(alignment: .leading, spacing: 8) {
                                Image(uiImage: photo.preview).resizable().scaledToFit()
                                    .clipShape(RoundedRectangle(cornerRadius: 10))
                                    .accessibilityLabel("Analyzed photo")
                                Text(photo.summary).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                    if let result = assessment.record.steps.palette.result {
                        Section {
                            ForEach(result.colors) { color in PaletteSwatchRow(color: color) }
                        } header: {
                            Text("Color palette")
                        } footer: {
                            Text("Shares describe eligible image pixels, not physical room area. Percentages are rounded for display. \((result.droppedShare * 100).formatted(.number.precision(.fractionLength(1))))% was omitted as small color groups.")
                        }
                    } else {
                        Section("Color palette") {
                            Label("The palette could not be produced.", systemImage: "exclamationmark.triangle")
                            Text(assessment.record.steps.palette.reason?.rawValue ?? "No result")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Section("Limitations") {
                        ForEach(
                            assessment.record.findings.filter {
                                $0.kind == .limitation
                            }
                        ) { finding in
                            Text(finding.text)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    Section {
                        statusRow(
                            "Photo quality check",
                            assessment.record.steps.quality.status,
                            assessment.record.steps.quality.reason
                        )

                        statusRow(
                            "Hide faces and people",
                            assessment.record.steps.anonymization.status,
                            assessment.record.steps.anonymization.reason
                        )

                        statusRow(
                            "Color palette",
                            assessment.record.steps.palette.status,
                            assessment.record.steps.palette.reason
                        )

                        statusRow(
                            "Two-area color difference",
                            assessment.record.steps.contrast.status,
                            assessment.record.steps.contrast.reason
                        )
                    } header: {
                        Text("Analysis")
                    } footer: {
                        Text(
                            """
                            Results are in memory only. Export JSON to keep a result file. \
                            Restarting the app clears room history in this build.
                            """
                        )
                    }
                }
                .navigationTitle(assessment.createdAt.formatted(date: .abbreviated, time: .shortened))
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Export JSON", systemImage: "square.and.arrow.up") {
                            do {
                                exportDocument = AssessmentJSONDocument(data: try AssessmentJSON.encode(assessment.record))
                                isExporting = true
                            } catch { errorMessage = error.localizedDescription }
                        }
                    }
                }
            } else {
                ContentUnavailableView("Assessment not found", systemImage: "questionmark.folder")
            }
        }
        .fileExporter(isPresented: $isExporting, document: exportDocument,
                      contentType: .json, defaultFilename: "assessment") { result in
            if case .failure(let error) = result, (error as NSError).code != NSUserCancelledError {
                errorMessage = error.localizedDescription
            }
        }
        .alert("Export failed", isPresented: Binding(get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } })) {
                Button("OK", role: .cancel) { errorMessage = nil }
            } message: { Text(errorMessage ?? "Unknown error") }
    }
    private func statusRow(_ title: String, _ status: StepStatus, _ reason: ReasonCode?) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            LabeledContent(title, value: status == .completed ? "Done" : status == .failed ? "Failed" : "Skipped")
            if let reason {
                Text(reason == .notImplemented ? "This check isn't available in this version."
                    : reason == .imageUnavailable ? "No working image has been saved to disk."
                    : reason.rawValue.replacingOccurrences(of: "_", with: " "))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}
struct PaletteSwatchRow: View {
    let color: PaletteColor
    @ScaledMetric(relativeTo: .body) private var side = 58
    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            RoundedRectangle(cornerRadius: 10)
                .fill(Color(.sRGB, red: Double(color.srgb8[0]) / 255,
                            green: Double(color.srgb8[1]) / 255, blue: Double(color.srgb8[2]) / 255, opacity: 1))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(.primary.opacity(0.4)))
                .frame(width: min(side, 88), height: min(side, 88)).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 5) {
                Text("Color \(color.rank) · \(color.share.formatted(.percent.precision(.fractionLength(1))))")
                    .font(.headline)
                Text(color.hex).font(.body.monospaced()).foregroundStyle(.secondary)
                Text("OKLCh lightness \(color.oklch.l.formatted(.number.precision(.fractionLength(3)))), chroma \(color.oklch.c.formatted(.number.precision(.fractionLength(3))))")
                    .font(.caption)
                if let hue = color.oklch.h {
                    Text("Hue \(hue.formatted(.number.precision(.fractionLength(1))))°").font(.caption)
                } else { Text("No meaningful hue (achromatic)").font(.caption) }
            }.fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }
}
struct AssessmentJSONDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }
    var data: Data
    init(data: Data) { self.data = data }
    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else { throw CocoaError(.fileReadCorruptFile) }
        self.data = data
    }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}
