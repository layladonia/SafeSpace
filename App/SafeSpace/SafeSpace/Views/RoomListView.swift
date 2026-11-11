import SwiftUI
import SafeSpaceCore

struct RoomListView: View {
    @Environment(AppModel.self) private var model
    @Environment(Router.self) private var router

    @State private var isNamingRoom = false
    @State private var newRoomName = ""
    @State private var errorMessage: String?

    var body: some View {
        List {
            ForEach(model.rooms) { room in
                NavigationLink(value: Route.room(room.id)) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(room.name)
                            .font(.headline)
                        Text(assessmentCount(model.assessments(in: room.id).count))
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 4)
                }
            }
            .onDelete { offsets in
                let ids = offsets.map { model.rooms[$0].id }
                Task { await run { try await model.deleteRooms(ids) } }
            }
        }
        .overlay {
            if let loadError = model.loadError {
                ContentUnavailableView("Saved rooms can't be read", systemImage: "exclamationmark.triangle",
                                       description: Text(loadError))
            } else if model.rooms.isEmpty {
                ContentUnavailableView {
                    Label("No rooms yet", systemImage: "house")
                } description: {
                    Text("Add a room, such as Living Room, then photograph it.")
                } actions: {
                    Button("Add room") { isNamingRoom = true }
                        .buttonStyle(.borderedProminent)
                }
            }
        }
        .navigationTitle("Rooms")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    isNamingRoom = true
                } label: {
                    Label("Add room", systemImage: "plus")
                }
            }
        }
        .alert("Add room", isPresented: $isNamingRoom) {
            TextField("Room name", text: $newRoomName)
            Button("Add") {
                let name = newRoomName
                newRoomName = ""
                Task { await run { router.push(.room(try await model.addRoom(named: name))) } }
            }
            Button("Cancel", role: .cancel) { newRoomName = "" }
        } message: {
            Text("Give the room a name you'll recognize later.")
        }
        .alert("Something went wrong", isPresented: Binding(get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } })) {
                Button("OK", role: .cancel) { errorMessage = nil }
            } message: { Text(errorMessage ?? "") }
    }

    private func run(_ action: () async throws -> Void) async {
        do { try await action() } catch { errorMessage = error.localizedDescription }
    }

    private func assessmentCount(_ count: Int) -> String {
        switch count {
        case 0: "No assessments"
        case 1: "1 assessment"
        default: "\(count) assessments"
        }
    }
}

#Preview {
    NavigationStack { RoomListView() }
        .environment(AppModel(store: InMemoryAssessmentStore()))
        .environment(Router())
}
