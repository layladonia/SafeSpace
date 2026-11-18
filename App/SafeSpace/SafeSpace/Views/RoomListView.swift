import SwiftUI
import SafeSpaceCore

struct RoomListView: View {
    @Environment(AppModel.self) private var model
    @Environment(Router.self) private var router

    @State private var isNamingRoom = false
    @State private var newRoomName = ""
    @State private var errorMessage: String?
    @State private var isShowingStorageStatement = false
    /// Deleting a room removes all of its assessments, so it is confirmed first.
    @State private var roomPendingDelete: Room?

    var body: some View {
        List {
            Section {
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
                    roomPendingDelete = offsets.first.map { model.rooms[$0] }
                }
            } footer: {
                // Hidden while the empty-state overlay is shown, so the two don't overlap.
                if !model.rooms.isEmpty {
                    Text(StorageStatement.short)
                }
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
            ToolbarItem(placement: .topBarLeading) {
                Button {
                    isShowingStorageStatement = true
                } label: {
                    Label("What's saved", systemImage: "info.circle")
                }
            }
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
        .sheet(isPresented: $isShowingStorageStatement) { StorageStatementView() }
        .confirmationDialog(
            "Delete \u{201C}\(roomPendingDelete?.name ?? "")\u{201D}?",
            isPresented: Binding(get: { roomPendingDelete != nil }, set: { if !$0 { roomPendingDelete = nil } }),
            titleVisibility: .visible,
            presenting: roomPendingDelete
        ) { room in
            Button("Delete room", role: .destructive) {
                Task { await run { try await model.deleteRooms([room.id]) } }
            }
            Button("Cancel", role: .cancel) {}
        } message: { room in
            Text(StorageStatement.deleteRoomMessage(assessmentCount: model.assessments(in: room.id).count))
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
