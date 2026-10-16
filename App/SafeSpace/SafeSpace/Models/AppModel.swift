import Foundation
import Observation
import SwiftUI

// MARK: - Placeholder types
//
// These mirror the vocabulary of the assessment.json contract (Task 2, owner C)
// so the screens can be built now. When SafeSpaceCore publishes the real
// contract types, delete these and import SafeSpaceCore instead.

/// Assessment-level state from the contract: pending, completed, partial, failed.
enum AssessmentState: String {
    case pending, completed, partial, failed

    var label: String {
        switch self {
        case .pending: "Not analyzed yet"
        case .completed: "Complete"
        case .partial: "Partly complete"
        case .failed: "Analysis failed"
        }
    }
}

/// Pipeline steps, in the order the report's architecture lists them.
enum AnalysisComponent: String, CaseIterable, Identifiable {
    case imageQuality = "image_quality"
    case privacy = "privacy"
    case colorPalette = "color_palette"
    case visualContrast = "visual_contrast"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .imageQuality: "Photo quality check"
        case .privacy: "Hide faces and people"
        case .colorPalette: "Color palette"
        case .visualContrast: "Two-area color difference"
        }
    }
}

/// Component-level status. `pending` means the step has not run yet.
enum ComponentStatus: String {
    case pending, completed, skipped, failed

    var label: String {
        switch self {
        case .pending: "Not run yet"
        case .completed: "Done"
        case .skipped: "Skipped"
        case .failed: "Failed"
        }
    }
}

struct Assessment: Identifiable {
    let id = UUID()
    let createdAt = Date()
    var photos: [ImportedPhoto]
    var state: AssessmentState = .pending
    var components: [AnalysisComponent: ComponentStatus] =
        Dictionary(uniqueKeysWithValues: AnalysisComponent.allCases.map { ($0, .pending) })
}

struct Room: Identifiable {
    let id = UUID()
    var name: String
    var assessments: [Assessment] = []
}

// MARK: - Store

/// In-memory store for the shell. Nothing is written to disk yet; save/reopen
/// (Task 14) replaces this with versioned JSON in the app sandbox.
@MainActor
@Observable
final class AppModel {
    private(set) var rooms: [Room] = []

    @discardableResult
    func addRoom(named name: String) -> Room.ID {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let room = Room(name: trimmed.isEmpty ? "Untitled room" : trimmed)
        rooms.append(room)
        return room.id
    }

    func deleteRooms(at offsets: IndexSet) {
        rooms.remove(atOffsets: offsets)
    }

    func room(id: Room.ID) -> Room? {
        rooms.first { $0.id == id }
    }

    func assessment(id: Assessment.ID, in roomID: Room.ID) -> Assessment? {
        room(id: roomID)?.assessments.first { $0.id == id }
    }

    @discardableResult
    func addAssessment(to roomID: Room.ID, photos: [ImportedPhoto]) -> Assessment.ID? {
        guard let index = rooms.firstIndex(where: { $0.id == roomID }) else { return nil }
        let assessment = Assessment(photos: photos)
        rooms[index].assessments.append(assessment)
        return assessment.id
    }

    func deleteAssessments(_ ids: Set<Assessment.ID>, in roomID: Room.ID) {
        guard let index = rooms.firstIndex(where: { $0.id == roomID }) else { return }
        rooms[index].assessments.removeAll { ids.contains($0.id) }
    }
}
