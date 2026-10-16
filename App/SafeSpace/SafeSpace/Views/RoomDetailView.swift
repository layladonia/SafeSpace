import SwiftUI

struct RoomDetailView: View {
    let roomID: Room.ID

    @Environment(AppModel.self) private var model
    @Environment(Router.self) private var router

    var body: some View {
        if let room = model.room(id: roomID) {
            let history = room.assessments.sorted { $0.createdAt > $1.createdAt }

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
                        NavigationLink(value: Route.assessment(roomID: roomID, assessmentID: assessment.id)) {
                            AssessmentRow(assessment: assessment)
                        }
                    }
                    .onDelete { offsets in
                        let ids = Set(offsets.map { history[$0].id })
                        model.deleteAssessments(ids, in: roomID)
                    }
                }
            }
            .navigationTitle(room.name)
        } else {
            ContentUnavailableView("Room not found", systemImage: "questionmark.folder")
        }
    }
}

private struct AssessmentRow: View {
    let assessment: Assessment

    var body: some View {
        HStack(spacing: 12) {
            if let first = assessment.photos.first {
                Image(uiImage: first.preview)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 56, height: 56)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .accessibilityHidden(true)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(assessment.createdAt, format: .dateTime.month().day().hour().minute())
                    .font(.headline)
                Text("\(assessment.photos.count == 1 ? "1 photo" : "\(assessment.photos.count) photos"), \(assessment.state.label.lowercased())")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }
}
