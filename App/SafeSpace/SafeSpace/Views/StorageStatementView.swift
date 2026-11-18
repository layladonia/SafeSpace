import SwiftUI

/// Task 15: the plain-language statement of what the app stores and what delete removes.
/// The sentences must match what `FileAssessmentStore` actually does (contract §6, decision D4):
/// files live in Application Support, are excluded from backup, and delete removes the whole
/// assessment (or room) folder. Change them together.
enum StorageStatement {
    /// Contract §6 wording for deleting one assessment.
    static let deleteAssessment =
        "Deleting removes the saved photo copy, the color results and the text for that assessment from this iPhone."
    static let deleteRoom =
        "Deleting a room removes its name and all of its assessments from this iPhone."
    /// One line for list footers; the full statement is in `StorageStatementView`.
    static let short =
        "Rooms and assessments are saved only on this iPhone. Your original photos are not saved by this app."

    static func deleteRoomMessage(assessmentCount: Int) -> String {
        let assessments = switch assessmentCount {
        case 0: "It has no assessments."
        case 1: "Its 1 assessment, with its saved photo copy, color results and text, will also be removed."
        default: "Its \(assessmentCount) assessments, with their saved photo copies, color results and text, will also be removed."
        }
        return "\(assessments) This can't be undone."
    }
}

/// Sheet opened from the room list's "What's saved" button.
struct StorageStatementView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section("Where it's saved") {
                    Text("Everything is saved only on this iPhone. Nothing is uploaded, and it isn't included in iCloud or device backups.")
                    Text("Analysis runs on this iPhone.")
                }
                Section("What's saved") {
                    Label("Room names you add", systemImage: "house")
                    Label("For each assessment: a smaller copy of the analyzed photo (when one is kept), the color results and the text on the result screen", systemImage: "square.stack")
                }
                Section("What isn't saved") {
                    Text("Your original photo is not saved by this app. A photo chosen from your library stays in Photos, unchanged. A photo taken with the camera here is not added to Photos.")
                }
                Section("Deleting") {
                    Text(StorageStatement.deleteAssessment)
                    Text(StorageStatement.deleteRoom)
                    Text("Deleting the app removes everything it saved.")
                }
            }
            .navigationTitle("What's saved")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

#Preview {
    StorageStatementView()
}
