import SwiftUI

@main
struct SafeSpaceApp: App {
    @State private var model = AppModel()
    @State private var router = Router()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                .environment(router)
        }
    }
}

/// Owns the single NavigationStack. Every screen is reached by pushing a `Route`,
/// so navigation is data-driven and easy to test or deep-link later.
struct RootView: View {
    @Environment(Router.self) private var router

    var body: some View {
        @Bindable var router = router
        NavigationStack(path: $router.path) {
            RoomListView()
                .navigationDestination(for: Route.self) { route in
                    switch route {
                    case .room(let roomID):
                        RoomDetailView(roomID: roomID)
                    case .newAssessment(let roomID):
                        NewAssessmentView(roomID: roomID)
                    case .assessment(let roomID, let assessmentID):
                        AssessmentResultView(roomID: roomID, assessmentID: assessmentID)
                    }
                }
        }
    }
}
