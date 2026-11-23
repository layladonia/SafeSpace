import SwiftUI

@main
struct SafeSpaceApp: App {
    @State private var model = AppModel()
    @State private var router = Router()
    @State private var isShowingSplash = true

    var body: some Scene {
        WindowGroup {
            ZStack {
                RootView()
                    .environment(model)
                    .environment(router)
                    .tint(SafeSpaceTheme.tint)
                if isShowingSplash {
                    SplashView()
                        .transition(.opacity)
                        .zIndex(1)
                }
            }
            .task {
                // The splash stays up until the saved rooms are read, so the next screen is
                // already the right one (room history, or "Add your first room"). The short
                // minimum keeps it from flashing on a fast load.
                async let minimumTime: Void? = try? Task.sleep(for: .seconds(0.8))
                await model.reload()
                _ = await minimumTime
                withAnimation(.easeInOut(duration: 0.35)) { isShowingSplash = false }
            }
        }
    }
}

/// Owns the single NavigationStack. Every screen is reached by pushing a `Route`,
/// so navigation is data-driven and easy to test or deep-link later.
struct RootView: View {
    @Environment(Router.self) private var router
    @Environment(AppModel.self) private var model

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
