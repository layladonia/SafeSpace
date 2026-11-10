import Foundation
import Observation
import SwiftUI
import UIKit
import Darwin
import SafeSpaceCore

/// Thin @Observable wrapper over an `AssessmentStore` (contract §5.11). Rooms and assessment
/// summaries are cached for the list screens; everything else is read from the store.
@MainActor
@Observable
final class AppModel {
    let store: any AssessmentStore
    private(set) var rooms: [Room] = []
    private(set) var summaries: [Room.ID: [AssessmentSummary]] = [:]
    /// Set when the store can't be read; shown on the room list.
    var loadError: String?

    init(store: any AssessmentStore = AppModel.makeDefaultStore()) {
        self.store = store
    }

    /// `<Application Support>/SafeSpace` (§6). Falls back to memory if the folder is unavailable,
    /// so the app still runs, without saving.
    nonisolated static func makeDefaultStore() -> any AssessmentStore {
        guard let support = try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                        appropriateFor: nil, create: true) else {
            return InMemoryAssessmentStore()
        }
        return FileAssessmentStore(root: support.appendingPathComponent("SafeSpace", isDirectory: true))
    }

    func reload() async {
        do {
            let rooms = try await store.rooms()
            var summaries: [Room.ID: [AssessmentSummary]] = [:]
            // One unreadable room must not hide the others.
            for room in rooms { summaries[room.id] = (try? await store.assessments(inRoom: room.id)) ?? [] }
            self.rooms = rooms
            self.summaries = summaries
            loadError = nil
        } catch {
            loadError = error.localizedDescription
        }
    }

    func room(id: Room.ID) -> Room? { rooms.first { $0.id == id } }
    func assessments(in roomID: Room.ID) -> [AssessmentSummary] { summaries[roomID] ?? [] }

    func addRoom(named name: String) async throws -> Room.ID {
        let room = try await store.createRoom(name: name)
        await reload()
        return room.id
    }
    func deleteRooms(_ ids: [Room.ID]) async throws {
        try await reloading { for id in ids { try await store.deleteRoom(id: id) } }
    }
    func deleteAssessments(_ ids: Set<AssessmentSummary.ID>) async throws {
        try await reloading { for id in ids { try await store.deleteAssessment(id: id) } }
    }
    /// Refreshes the lists afterwards even if `body` fails partway.
    private func reloading(_ body: () async throws -> Void) async throws {
        do { try await body() } catch { await reload(); throw error }
        await reload()
    }
    /// Reopens exactly what was saved; nothing is recomputed.
    func loadAssessment(id: AssessmentSummary.ID) async throws -> StoredAssessment {
        try await store.load(assessmentID: id)
    }

    /// Runs the pipeline on the photo and saves the result. The original bytes are not stored.
    func analyzeAndSave(to roomID: Room.ID, photo: ImportedPhoto) async throws -> AssessmentSummary.ID {
        guard room(id: roomID) != nil else { throw SafeSpaceError.storage(.notFound) }
        let output = try await AssessmentPipeline.run(
            imageData: photo.originalData,
            source: photo.source == .camera ? .camera : .library,
            roomID: roomID,
            producer: Self.producer(),
            // Contract defaults (PaletteParams.v1), the same ones the CLI and tests use.
            options: PipelineOptions()
        )
        try Task.checkCancellation()
        let saved = try await store.save(output)
        // A cancel that arrives during the save must still leave nothing saved (§5.9).
        if Task.isCancelled {
            try? await store.deleteAssessment(id: saved.assessmentId)
            throw CancellationError()
        }
        await reload()
        return saved.assessmentId
    }

    private static func producer() -> Producer {
        let bundle = Bundle.main
        let version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
        let build = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"
        var system = utsname()
        uname(&system)
        let capacity = MemoryLayout.size(ofValue: system.machine)
        let machine = withUnsafePointer(to: &system.machine) {
            $0.withMemoryRebound(to: CChar.self, capacity: capacity) { String(cString: $0) }
        }
        return Producer(kind: "app", appVersion: "\(version) (\(build))", coreVersion: SafeSpaceCore.version,
                        device: machine, os: "iOS \(UIDevice.current.systemVersion)")
    }
}

extension OverallState {
    var label: String {
        switch self {
        case .complete: return "Complete"
        case .partial: return "Partly complete"
        case .failed: return "Analysis failed"
        }
    }
}

extension SRGBImage {
    /// The stored working copy as a UIImage (sRGB, opaque).
    var uiImage: UIImage? {
        guard let provider = CGDataProvider(data: Data(rgba) as CFData),
              let space = CGColorSpace(name: CGColorSpace.sRGB),
              let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                                  bytesPerRow: width * 4, space: space,
                                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                                  provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
        else { return nil }
        return UIImage(cgImage: image)
    }
}
