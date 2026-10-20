import Foundation
import Observation

/// Every screen in the navigation skeleton. Routes carry IDs, never model values,
/// so a screen always reads the current data from `AppModel`.
enum Route: Hashable {
    case room(Room.ID)
    case newAssessment(roomID: Room.ID)
    case assessment(roomID: Room.ID, assessmentID: Assessment.ID)
}

@MainActor
@Observable
final class Router {
    var path: [Route] = []

    func push(_ route: Route) {
        path.append(route)
    }

    /// Replaces the top screen, e.g. "New Assessment" -> its saved result,
    /// so Back returns to the room rather than to the photo picker.
    func replaceTop(with route: Route) {
        if !path.isEmpty { path.removeLast() }
        path.append(route)
    }
}
