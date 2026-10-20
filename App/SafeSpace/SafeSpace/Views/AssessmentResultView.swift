import SwiftUI

/// Result screen skeleton. Shows the saved photos and one row per pipeline step.
/// Palette swatches (Task 9), overlay (Task 10) and the contrast card (Task 17)
/// will replace the placeholder rows in later releases.
struct AssessmentResultView: View {
    let roomID: Room.ID
    let assessmentID: Assessment.ID

    @Environment(AppModel.self) private var model

    var body: some View {
        if let assessment = model.assessment(id: assessmentID, in: roomID) {
            List {
                Section("Photos") {
                    ForEach(Array(assessment.photos.enumerated()), id: \.element.id) { index, photo in
                        VStack(alignment: .leading, spacing: 6) {
                            Image(uiImage: photo.preview)
                                .resizable()
                                .scaledToFit()
                                .clipShape(RoundedRectangle(cornerRadius: 10))
                                .accessibilityLabel("Photo \(index + 1)")
                            Text("Photo \(index + 1): \(photo.summary)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 4)
                    }
                }

                Section {
                    ForEach(AnalysisComponent.allCases) { component in
                        LabeledContent(
                            component.title,
                            value: assessment.components[component, default: .pending].label
                        )
                    }
                } header: {
                    Text("Analysis")
                } footer: {
                    Text("Color analysis isn't connected yet. Results will appear here once each step runs.")
                }
            }
            .navigationTitle(assessment.createdAt.formatted(date: .abbreviated, time: .shortened))
            .navigationBarTitleDisplayMode(.inline)
        } else {
            ContentUnavailableView("Assessment not found", systemImage: "questionmark.folder")
        }
    }
}
