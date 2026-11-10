import XCTest
@testable import SafeSpaceCore

final class AssessmentStoreTests: XCTestCase {
    private var root: URL!
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("SafeSpaceStoreTests-\(UUID().uuidString)")
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    private func analyze(roomID: String) async throws -> PipelineOutput {
        let pixels: [[UInt8]] = Array(repeating: [220, 205, 180], count: 12) + Array(repeating: [90, 60, 40], count: 4)
        let image = SRGBImage(width: 4, height: 4, rgba: pixels.flatMap { $0 + [255] })
        let producer = Producer(kind: "app", appVersion: "test", coreVersion: SafeSpaceCore.version, device: "test", os: "test")
        var options = PipelineOptions()
        options.anonymizer = NoOpAnonymizer()
        return try await AssessmentPipeline.run(imageData: image.pngData(), source: .library, roomID: roomID,
                                                producer: producer, options: options)
    }
    private func stores() -> [(String, any AssessmentStore)] {
        [("file", FileAssessmentStore(root: root)), ("memory", InMemoryAssessmentStore())]
    }

    func testRoomsCreateRenameDelete() async throws {
        for (name, store) in stores() {
            let a = try await store.createRoom(name: "  Living room ")
            let b = try await store.createRoom(name: "   ")
            XCTAssertEqual(a.name, "Living room", name)
            XCTAssertEqual(b.name, "Untitled room", name)
            try await store.renameRoom(id: b.id, to: "Kitchen")
            let names = try await store.rooms().map(\.name)
            XCTAssertEqual(Set(names), ["Living room", "Kitchen"], name)
            try await store.deleteRoom(id: a.id)
            let left = try await store.rooms().map(\.id)
            XCTAssertEqual(left, [b.id], name)
            do { try await store.renameRoom(id: a.id, to: "x"); XCTFail(name) }
            catch { XCTAssertEqual(error as? SafeSpaceError, .storage(.notFound), name) }
        }
    }

    func testSaveThenReopenReturnsExactlyWhatWasSaved() async throws {
        for (name, store) in stores() {
            let room = try await store.createRoom(name: "Bedroom")
            let output = try await analyze(roomID: room.id)
            let saved = try await store.save(output)
            // Storage fills in the stored-image fields; nothing is recomputed.
            XCTAssertTrue(saved.image.stored, name)
            XCTAssertEqual(saved.image.storedFile, "image.png", name)
            XCTAssertEqual(saved.steps.palette.result?.labelMapFile, "labels.png", name)
            XCTAssertEqual(saved.steps.contrast.reason, .notRequested, name)
            XCTAssertEqual(saved.steps.palette.result, output.record.steps.palette.result.map {
                var r = $0; r.labelMapFile = "labels.png"; return r }, name)
            let loaded = try await store.load(assessmentID: saved.assessmentId)
            XCTAssertEqual(loaded.record, saved, name)
            XCTAssertEqual(loaded.image, output.storedImage, name)
            XCTAssertEqual(loaded.mask, output.mask, name)
            XCTAssertEqual(loaded.labelMap, output.labelMap, name)
            let list = try await store.assessments(inRoom: room.id)
            XCTAssertEqual(list.map(\.id), [saved.assessmentId], name)
            XCTAssertEqual(list.first?.topColors, saved.steps.palette.result?.colors.prefix(5).map(\.hex), name)
            XCTAssertEqual(list.first?.canOpen, true, name)
        }
    }

    func testReopenAfterRelaunchAndFolderLayout() async throws {
        let first = FileAssessmentStore(root: root)
        let room = try await first.createRoom(name: "Hallway")
        let saved = try await first.save(try await analyze(roomID: room.id))
        // A new store over the same folder is what the app sees after a relaunch (S6).
        let second = FileAssessmentStore(root: root)
        let reopened = try await second.load(assessmentID: saved.assessmentId)
        XCTAssertEqual(reopened.record, saved)
        let rooms = try await second.rooms()
        XCTAssertEqual(rooms, [room])
        let folder = root.appendingPathComponent("rooms/\(room.id)/assessments/\(saved.assessmentId)")
        let files = try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted()
        // Only the §6 files: the original photo is never written.
        XCTAssertEqual(files, ["assessment.json", "image.png", "labels.png", "mask.png"])
    }

    func testDeleteRemovesTheWholeFolder() async throws {
        let store = FileAssessmentStore(root: root)
        let room = try await store.createRoom(name: "Kitchen")
        let a = try await store.save(try await analyze(roomID: room.id))
        let b = try await store.save(try await analyze(roomID: room.id))
        let assessments = root.appendingPathComponent("rooms/\(room.id)/assessments")
        try await store.deleteAssessment(id: a.assessmentId)
        XCTAssertFalse(FileManager.default.fileExists(atPath: assessments.appendingPathComponent(a.assessmentId).path))
        let remaining = try await store.assessments(inRoom: room.id).map(\.id)
        XCTAssertEqual(remaining, [b.assessmentId])
        try await store.deleteRoom(id: room.id)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("rooms/\(room.id)").path))
        do { _ = try await store.load(assessmentID: b.assessmentId); XCTFail() }
        catch { XCTAssertEqual(error as? SafeSpaceError, .storage(.notFound)) }
    }

    func testCorruptAndNewerFilesDoNotBreakTheList() async throws {
        let store = FileAssessmentStore(root: root)
        let room = try await store.createRoom(name: "Bathroom")
        let good = try await store.save(try await analyze(roomID: room.id))
        let corrupt = try await store.save(try await analyze(roomID: room.id))
        let newer = try await store.save(try await analyze(roomID: room.id))
        let dir = root.appendingPathComponent("rooms/\(room.id)/assessments")
        try Data("{ not json".utf8).write(to: dir.appendingPathComponent("\(corrupt.assessmentId)/assessment.json"))
        let newerFile = dir.appendingPathComponent("\(newer.assessmentId)/assessment.json")
        let text = try String(contentsOf: newerFile, encoding: .utf8).replacingOccurrences(of: "\"schema_version\" : \"1\"", with: "\"schema_version\" : \"2\"")
        try Data(text.utf8).write(to: newerFile)

        let list = try await store.assessments(inRoom: room.id)
        XCTAssertEqual(list.count, 3)
        XCTAssertEqual(Set(list.filter(\.canOpen).map(\.id)), [good.assessmentId])
        do { _ = try await store.load(assessmentID: corrupt.assessmentId); XCTFail() }
        catch { XCTAssertEqual(error as? SafeSpaceError, .storage(.corrupt)) }
        do { _ = try await store.load(assessmentID: newer.assessmentId); XCTFail() }
        catch { XCTAssertEqual(error as? SafeSpaceError, .storage(.unsupportedSchemaVersion("2"))) }
        // An unreadable assessment can still be deleted.
        try await store.deleteAssessment(id: corrupt.assessmentId)
        let count = try await store.assessments(inRoom: room.id).count
        XCTAssertEqual(count, 2)
    }

    func testLeftoverTempFilesAreRemovedAtLaunch() async throws {
        let store = FileAssessmentStore(root: root)
        let room = try await store.createRoom(name: "Den")
        let saved = try await store.save(try await analyze(roomID: room.id))
        let dir = root.appendingPathComponent("rooms/\(room.id)/assessments")
        let tempFolder = dir.appendingPathComponent(UUID().uuidString.lowercased() + ".tmp")
        try FileManager.default.createDirectory(at: tempFolder, withIntermediateDirectories: true)
        let tempFile = dir.appendingPathComponent("\(saved.assessmentId)/assessment.json.tmp")
        try Data("partial".utf8).write(to: tempFile)
        _ = FileAssessmentStore(root: root)
        XCTAssertFalse(FileManager.default.fileExists(atPath: tempFolder.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: tempFile.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent("\(saved.assessmentId)/assessment.json").path))
    }

    func testUpdateReplacesTheRecord() async throws {
        for (name, store) in stores() {
            let room = try await store.createRoom(name: "Office")
            var record = try await store.save(try await analyze(roomID: room.id))
            record.updatedAt = record.createdAt.addingTimeInterval(60)
            try await store.update(record)
            let loaded = try await store.load(assessmentID: record.assessmentId)
            XCTAssertEqual(loaded.record, record, name)
            var invalid = record
            invalid.findings = []
            do { try await store.update(invalid); XCTFail(name) } catch { XCTAssertTrue(error is SafeSpaceError, name) }
            let unchanged = try await store.load(assessmentID: record.assessmentId)
            XCTAssertEqual(unchanged.record, record, name)
        }
    }

    func testSaveRequiresAnExistingRoom() async throws {
        for (name, store) in stores() {
            let output = try await analyze(roomID: UUID().uuidString.lowercased())
            do { _ = try await store.save(output); XCTFail(name) }
            catch { XCTAssertEqual(error as? SafeSpaceError, .storage(.notFound), name) }
        }
    }

    func testSavingTheSameAssessmentTwiceIsRejected() async throws {
        for (name, store) in stores() {
            let room = try await store.createRoom(name: "Studio")
            let output = try await analyze(roomID: room.id)
            let first = try await store.save(output)
            do { _ = try await store.save(output); XCTFail(name) }
            catch { XCTAssertEqual(error as? SafeSpaceError, .storage(.writeFailed), name) }
            let loaded = try await store.load(assessmentID: first.assessmentId)
            XCTAssertEqual(loaded.record, first, name)
        }
    }

    func testFailedAnonymizationIsNotStored() async throws {
        // D2: no stored image after a failed anonymization.
        let store = FileAssessmentStore(root: root)
        let room = try await store.createRoom(name: "Porch")
        let output = try await analyze(roomID: room.id)
        var record = output.record
        record.steps.anonymization = .init(status: .failed, reason: .anonymizationFailed, durationMs: 0,
            method: .init(name: "test", version: 1, params: .object([:])), result: nil)
        let failed = PipelineOutput(record: record, storedImage: nil, mask: output.mask, labelMap: output.labelMap,
                                    totalDurationMs: 0)
        let saved = try await store.save(failed)
        XCTAssertFalse(saved.image.stored)
        XCTAssertNil(saved.steps.palette.result?.labelMapFile)
        let folder = root.appendingPathComponent("rooms/\(room.id)/assessments/\(saved.assessmentId)")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.path), ["assessment.json"])
        let loaded = try await store.load(assessmentID: saved.assessmentId)
        XCTAssertNil(loaded.image)
    }
}
