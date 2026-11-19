import SwiftUI
import SafeSpaceCore

struct RoomDetailView: View {
    let roomID: Room.ID

    @Environment(AppModel.self) private var model
    @Environment(Router.self) private var router
    @State private var errorMessage: String?
    @State private var assessmentPendingDelete: AssessmentSummary.ID?

    var body: some View {
        if let room = model.room(id: roomID) {
            let history = model.assessments(in: roomID)

            List {
                Section {
                    VStack(alignment: .leading, spacing: 14) {
                        SafeSpaceIntro(
                            eyebrow: "Room overview",
                            title: "Explore this room’s colors",
                            subtitle: "Take or choose a photo to see its palette and compare areas.",
                            icon: "swatchpalette"
                        )
                        Button {
                            router.push(.newAssessment(roomID: roomID))
                        } label: {
                            Label("New assessment", systemImage: "camera")
                                .font(.headline)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 5)
                        }
                        .buttonStyle(.borderedProminent)
                        .buttonBorderShape(.roundedRectangle(radius: 14))
                    }
                    .listRowBackground(Color.clear)
                }
                Section {
                    if history.isEmpty {
                        Text("No assessments for this room yet.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(history) { assessment in
                        Group {
                            if assessment.canOpen {
                                NavigationLink(value: Route.assessment(roomID: roomID, assessmentID: assessment.id)) {
                                    AssessmentRow(assessment: assessment)
                                }
                            } else {
                                // Corrupt or saved by a newer app version: listed so it can still be deleted (§6).
                                Label("Can't open this assessment", systemImage: "exclamationmark.triangle")
                                    .foregroundStyle(.secondary)
                            }
                        }
                        // Same as the room list: no row-removal animation before the alert is answered.
                        .listRowBackground(SafeSpaceTheme.surface)
                        .swipeActions(allowsFullSwipe: false) {
                            Button("Delete", systemImage: "trash") { assessmentPendingDelete = assessment.id }
                                .tint(.red)
                        }
                    }
                } header: {
                    Text("Saved assessments")
                } footer: {
                    if !history.isEmpty {
                        Text("Saved only on this iPhone. \(StorageStatement.deleteAssessment)")
                    }
                }
            }
            .safeSpaceList()
            .navigationTitle(room.name)
            .alert(
                "Delete this assessment?",
                isPresented: Binding(get: { assessmentPendingDelete != nil },
                                     set: { if !$0 { assessmentPendingDelete = nil } }),
                presenting: assessmentPendingDelete
            ) { id in
                Button("Delete assessment", role: .destructive) {
                    Task {
                        do { try await model.deleteAssessments([id]) }
                        catch { errorMessage = error.localizedDescription }
                    }
                }
                Button("Cancel", role: .cancel) {}
            } message: { _ in
                Text("\(StorageStatement.deleteAssessment) This can't be undone.")
            }
            .alert("Couldn't delete", isPresented: Binding(get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } })) {
                    Button("OK", role: .cancel) { errorMessage = nil }
                } message: { Text(errorMessage ?? "") }
        } else {
            ContentUnavailableView("Room not found", systemImage: "questionmark.folder")
        }
    }
}

private struct AssessmentRow: View {
    let assessment: AssessmentSummary

    var body: some View {
        HStack(spacing: 12) {
            // The top palette colors stand in for a thumbnail, so the list never decodes photos.
            HStack(spacing: 0) {
                ForEach(Array(assessment.topColors.enumerated()), id: \.offset) { _, hex in
                    Rectangle().fill(Color(hex: hex))
                }
            }
            .frame(width: 56, height: 56)
            .background(.quaternary)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(assessment.createdAt, format: .dateTime.month().day().hour().minute())
                    .font(.headline)
                Text(assessment.overallState.label)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }
}

private extension Color {
    /// "#RRGGBB" from the stored palette.
    init(hex: String) {
        let value = UInt32(hex.dropFirst(), radix: 16) ?? 0
        self.init(.sRGB, red: Double((value >> 16) & 255) / 255, green: Double((value >> 8) & 255) / 255,
                  blue: Double(value & 255) / 255, opacity: 1)
    }
}
