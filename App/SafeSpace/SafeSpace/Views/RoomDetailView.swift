import SwiftUI
import SafeSpaceCore

struct RoomDetailView: View {
    let roomID: Room.ID

    @Environment(AppModel.self) private var model
    @Environment(Router.self) private var router
    @State private var errorMessage: String?

    var body: some View {
        if let room = model.room(id: roomID) {
            let history = model.assessments(in: roomID)

            List {
                Section {
                    Button {
                        router.push(.newAssessment(roomID: roomID))
                    } label: {
                        Label("New assessment", systemImage: "photo.badge.plus")
                    }
                }

                Section("History") {
                    if history.isEmpty {
                        Text("No assessments for this room yet.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(history) { assessment in
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
                    .onDelete { offsets in
                        let ids = Set(offsets.map { history[$0].id })
                        Task {
                            do { try await model.deleteAssessments(ids) }
                            catch { errorMessage = error.localizedDescription }
                        }
                    }
                }
            }
            .navigationTitle(room.name)
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
            .clipShape(RoundedRectangle(cornerRadius: 8))
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
