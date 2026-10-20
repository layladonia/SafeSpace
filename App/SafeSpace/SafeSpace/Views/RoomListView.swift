import SwiftUI

struct RoomListView: View {
    @Environment(AppModel.self) private var model
    @Environment(Router.self) private var router

    @State private var isNamingRoom = false
    @State private var newRoomName = ""

    var body: some View {
        List {
            ForEach(model.rooms) { room in
                NavigationLink(value: Route.room(room.id)) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(room.name)
                            .font(.headline)
                        Text(assessmentCount(room.assessments.count))
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 4)
                }
            }
            .onDelete { model.deleteRooms(at: $0) }
        }
        .overlay {
            if model.rooms.isEmpty {
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
                let id = model.addRoom(named: newRoomName)
                newRoomName = ""
                router.push(.room(id))
            }
            Button("Cancel", role: .cancel) { newRoomName = "" }
        } message: {
            Text("Give the room a name you'll recognize later.")
        }
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
        .environment(AppModel())
        .environment(Router())
}
