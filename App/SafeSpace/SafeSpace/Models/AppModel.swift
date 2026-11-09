import Foundation
import Observation
import SwiftUI
import UIKit
import Darwin
import SafeSpaceCore

// Compatibility presentation wrappers for existing RoomList/RoomDetail views.
// Only AssessmentRecord is encoded/exported, never these shell types.
enum AssessmentState: String {
    case pending, completed, partial, failed
    var label: String {
        switch self {
        case .pending: return "Not analyzed yet"
        case .completed: return "Complete"
        case .partial: return "Partly complete"
        case .failed: return "Analysis failed"
        }
    }
}
enum AnalysisComponent: String, CaseIterable, Identifiable {
    case imageQuality = "quality", privacy = "anonymization", colorPalette = "palette", visualContrast = "contrast"
    var id: String { rawValue }
    var title: String {
        switch self {
        case .imageQuality: return "Photo quality check"
        case .privacy: return "Hide faces and people"
        case .colorPalette: return "Color palette"
        case .visualContrast: return "Two-area color difference"
        }
    }
}
enum ComponentStatus: String {
    case pending, completed, skipped, failed
    var label: String {
        switch self {
        case .pending: return "Not run yet"
        case .completed: return "Done"
        case .skipped: return "Skipped"
        case .failed: return "Failed"
        }
    }
}
struct Assessment: Identifiable {
    let id: UUID
    let createdAt: Date
    var photos: [ImportedPhoto]
    let record: AssessmentRecord
    var state: AssessmentState {
        switch record.overallState {
        case .complete: return .completed
        case .partial: return .partial
        case .failed: return .failed
        }
    }
    var components: [AnalysisComponent: ComponentStatus] {
        [.imageQuality: status(record.steps.quality.status), .privacy: status(record.steps.anonymization.status),
         .colorPalette: status(record.steps.palette.status), .visualContrast: status(record.steps.contrast.status)]
    }
    private func status(_ value: StepStatus) -> ComponentStatus {
        switch value { case .completed: return .completed; case .skipped: return .skipped; case .failed: return .failed }
    }
}
struct Room: Identifiable {
    let id = UUID()
    var name: String
    var assessments: [Assessment] = []
}
@MainActor
@Observable
final class AppModel {
    private(set) var rooms: [Room] = []
    @discardableResult
    func addRoom(named name: String) -> Room.ID {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let room = Room(name: trimmed.isEmpty ? "Untitled room" : trimmed)
        rooms.append(room); return room.id
    }
    func deleteRooms(at offsets: IndexSet) { rooms.remove(atOffsets: offsets) }
    func room(id: Room.ID) -> Room? { rooms.first { $0.id == id } }
    func assessment(id: Assessment.ID, in roomID: Room.ID) -> Assessment? {
        room(id: roomID)?.assessments.first { $0.id == id }
    }
    func deleteAssessments(_ ids: Set<Assessment.ID>, in roomID: Room.ID) {
        guard let index = rooms.firstIndex(where: { $0.id == roomID }) else { return }
        rooms[index].assessments.removeAll { ids.contains($0.id) }
    }

    @discardableResult
    func analyzeAndAddAssessment(to roomID: Room.ID, photo: ImportedPhoto) async throws -> Assessment.ID {
        guard room(id: roomID) != nil else {
            throw SafeSpaceError.validation([
                "The room no longer exists."
            ])
        }

        let bundle = Bundle.main

        let version = bundle.object(
            forInfoDictionaryKey: "CFBundleShortVersionString"
        ) as? String ?? "dev"

        let build = bundle.object(
            forInfoDictionaryKey: "CFBundleVersion"
        ) as? String ?? "0"

        var system = utsname()
        uname(&system)

        let machineCapacity = MemoryLayout.size(
            ofValue: system.machine
        )

        let machine = withUnsafePointer(to: &system.machine) {
            $0.withMemoryRebound(
                to: CChar.self,
                capacity: machineCapacity
            ) {
                String(cString: $0)
            }
        }

        let producer = Producer(
            kind: "app",
            appVersion: "\(version) (\(build))",
            coreVersion: SafeSpaceCore.version,
            device: machine,
            os: "iOS \(UIDevice.current.systemVersion)"
        )

        // Contract defaults (PaletteParams.v1), the same ones the CLI and tests use.
        let options = PipelineOptions()

        let output = try await AssessmentPipeline.run(
            imageData: photo.originalData,
            source: photo.source == .camera ? .camera : .library,
            roomID: roomID.uuidString.lowercased(),
            producer: producer,
            options: options
        )

        try Task.checkCancellation()

        guard let index = rooms.firstIndex(where: {
            $0.id == roomID
        }),
        let id = UUID(
            uuidString: output.record.assessmentId
        ) else {
            throw SafeSpaceError.validation([
                "The room was removed or the result ID is invalid."
            ])
        }

        var displayPhoto = photo
        displayPhoto.discardOriginalData()

        let assessment = Assessment(
            id: id,
            createdAt: output.record.createdAt,
            photos: [displayPhoto],
            record: output.record
        )

        rooms[index].assessments.append(assessment)

        return id
    }
}
