import Foundation
import CStbImage

/// Contract §6 layout under `root` (the app passes `<Application Support>/SafeSpace`):
///
///     rooms/<room_id>/room.json
///     rooms/<room_id>/assessments/<assessment_id>/{assessment.json, image.png, mask.png, labels.png}
///
/// Saves write `<assessment_id>.tmp/` and rename it; updates write `assessment.json.tmp` and
/// replace. Leftover `*.tmp` entries from an interrupted write are deleted when the store opens.
/// The original photo is never written.
///
/// Use one store per `root`: the leftover cleanup in `init` would delete another instance's
/// in-progress `.tmp` save.
public actor FileAssessmentStore: AssessmentStore {
    private let root: URL
    private let fm = FileManager.default

    public init(root: URL) {
        self.root = root
        Self.removeLeftovers(in: root.appendingPathComponent("rooms", isDirectory: true))
    }

    // MARK: Rooms

    /// A room whose room.json can't be read is left out of the list (its folder stays on disk).
    /// Unlike assessments, §6 doesn't define a "can't open" row for rooms; revisit if it happens.
    public func rooms() throws -> [Room] {
        try roomIDs().compactMap { try? readRoom($0) }.sorted { $0.createdAt != $1.createdAt ? $0.createdAt < $1.createdAt : $0.id < $1.id }
    }
    public func createRoom(name: String) throws -> Room {
        let room = Room(id: UUID().uuidString.lowercased(), name: StoreRules.roomName(name), createdAt: StoreRules.now())
        try ensureRootExists()
        try writing { try fm.createDirectory(at: assessmentsDir(room.id), withIntermediateDirectories: true) }
        try writeRoom(room)
        return room
    }
    public func renameRoom(id: String, to name: String) throws {
        var room = try readRoom(id)
        room.name = StoreRules.roomName(name)
        try writeRoom(room)
    }
    public func deleteRoom(id: String) throws {
        let dir = try existingRoomDir(id)
        try writing { try fm.removeItem(at: dir) }
    }

    // MARK: Assessments

    public func assessments(inRoom roomID: String) throws -> [AssessmentSummary] {
        let dir = assessmentsDir(try existingRoomDir(roomID).lastPathComponent)
        let ids = ((try? fm.contentsOfDirectory(atPath: dir.path)) ?? []).filter(StoreRules.isValidID)
        return ids.map { id in
            let folder = dir.appendingPathComponent(id, isDirectory: true)
            if let record = try? readRecord(folder.appendingPathComponent("assessment.json")) {
                return StoreRules.summary(record)
            }
            // Never fail the whole list over one unreadable assessment (§6).
            let attributes = try? fm.attributesOfItem(atPath: folder.path)
            let date = attributes?[.creationDate] as? Date ?? attributes?[.modificationDate] as? Date ?? .distantPast
            return AssessmentSummary(id: id, roomID: roomID, createdAt: date, overallState: .failed,
                                     topColors: [], hasImage: false, canOpen: false)
        }.sorted(by: StoreRules.newestFirst)
    }

    @discardableResult public func save(_ output: PipelineOutput) throws -> AssessmentRecord {
        let record = try StoreRules.recordToSave(output)
        let dir = assessmentsDir(try existingRoomDir(record.roomId).lastPathComponent)
        guard StoreRules.isValidID(record.assessmentId) else { throw SafeSpaceError.validation(["Invalid assessment_id"]) }
        let final = dir.appendingPathComponent(record.assessmentId, isDirectory: true)
        let temp = dir.appendingPathComponent(record.assessmentId + ".tmp", isDirectory: true)
        guard !fm.fileExists(atPath: final.path) else { throw SafeSpaceError.storage(.writeFailed) }
        do {
            try writing {
                try? fm.removeItem(at: temp)
                try fm.createDirectory(at: temp, withIntermediateDirectories: true)
                try write(AssessmentJSON.encode(record), to: temp.appendingPathComponent("assessment.json"))
                if record.image.stored, let image = output.storedImage {
                    try write(image.pngData(), to: temp.appendingPathComponent(StoreRules.storedImageFile))
                    try write(output.mask.pngData(), to: temp.appendingPathComponent(StoreRules.maskFile))
                    if record.steps.palette.result?.labelMapFile != nil, let labels = output.labelMap {
                        try write(LabelMapPNG.encode(width: output.mask.width, height: output.mask.height, labels: labels),
                                  to: temp.appendingPathComponent(StoreRules.labelMapFile))
                    }
                }
                try fm.moveItem(at: temp, to: final)
            }
        } catch {
            try? fm.removeItem(at: temp)
            throw error
        }
        return record
    }

    public func load(assessmentID: String) throws -> StoredAssessment {
        let folder = try existingAssessmentDir(assessmentID)
        let record = try readRecord(folder.appendingPathComponent("assessment.json"))
        guard record.image.stored else { return .init(record: record, image: nil, mask: nil, labelMap: nil) }
        do {
            let w = record.image.workingCopy.width, h = record.image.workingCopy.height
            let image = try SRGBImage(pngData: Data(contentsOf: folder.appendingPathComponent(StoreRules.storedImageFile)))
            let mask = try EligibilityMask(pngData: Data(contentsOf: folder.appendingPathComponent(StoreRules.maskFile)))
            var labels: [UInt8]?
            if record.steps.palette.result?.labelMapFile != nil {
                labels = try LabelMapPNG.decode(Data(contentsOf: folder.appendingPathComponent(StoreRules.labelMapFile)),
                                                width: w, height: h)
            }
            guard image.width == w, image.height == h, mask.width == w, mask.height == h else {
                throw SafeSpaceError.storage(.corrupt)
            }
            return .init(record: record, image: image, mask: mask, labelMap: labels)
        } catch {
            throw SafeSpaceError.storage(.corrupt)
        }
    }

    public func update(_ record: AssessmentRecord) throws {
        let folder = try existingAssessmentDir(record.assessmentId)
        let file = folder.appendingPathComponent("assessment.json")
        guard (try readRecord(file)).roomId == record.roomId else { throw SafeSpaceError.storage(.notFound) }
        let data = try AssessmentJSON.encode(record)
        let temp = folder.appendingPathComponent("assessment.json.tmp")
        try writing {
            try write(data, to: temp)
            try atomicReplace(file, with: temp)
        }
    }

    public func deleteAssessment(id: String) throws {
        let folder = try existingAssessmentDir(id)
        try writing { try fm.removeItem(at: folder) }
    }

    // MARK: Files

    private var roomsDir: URL { root.appendingPathComponent("rooms", isDirectory: true) }
    private func roomDir(_ id: String) -> URL { roomsDir.appendingPathComponent(id, isDirectory: true) }
    private func assessmentsDir(_ roomID: String) -> URL { roomDir(roomID).appendingPathComponent("assessments", isDirectory: true) }

    private func roomIDs() throws -> [String] {
        ((try? fm.contentsOfDirectory(atPath: roomsDir.path)) ?? []).filter(StoreRules.isValidID)
    }
    private func existingRoomDir(_ id: String) throws -> URL {
        guard StoreRules.isValidID(id), fm.fileExists(atPath: roomDir(id).appendingPathComponent("room.json").path) else {
            throw SafeSpaceError.storage(.notFound)
        }
        return roomDir(id)
    }
    private func existingAssessmentDir(_ id: String) throws -> URL {
        guard StoreRules.isValidID(id) else { throw SafeSpaceError.storage(.notFound) }
        for roomID in try roomIDs() {
            let folder = assessmentsDir(roomID).appendingPathComponent(id, isDirectory: true)
            if fm.fileExists(atPath: folder.path) { return folder }
        }
        throw SafeSpaceError.storage(.notFound)
    }

    private struct RoomFile: Codable {
        var schemaVersion: String, roomId: String, name: String, createdAt: Date
    }
    private func readRoom(_ id: String) throws -> Room {
        let url = try existingRoomDir(id).appendingPathComponent("room.json")
        guard let file = try? AssessmentJSON.decoder().decode(RoomFile.self, from: Data(contentsOf: url)),
              file.roomId == id else { throw SafeSpaceError.storage(.corrupt) }
        guard file.schemaVersion == "1" else { throw SafeSpaceError.storage(.unsupportedSchemaVersion(file.schemaVersion)) }
        return Room(id: file.roomId, name: file.name, createdAt: file.createdAt)
    }
    private func writeRoom(_ room: Room) throws {
        let data = try AssessmentJSON.encoder().encode(RoomFile(schemaVersion: "1", roomId: room.id, name: room.name,
                                                                createdAt: room.createdAt))
        try writing { try write(data, to: roomDir(room.id).appendingPathComponent("room.json")) }
    }
    /// Unknown schema versions are reported as such (§6), before full decoding.
    private func readRecord(_ url: URL) throws -> AssessmentRecord {
        guard let data = try? Data(contentsOf: url),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw SafeSpaceError.storage(.corrupt)
        }
        let version = object["schema_version"] as? String ?? "unknown"
        guard version == "1" else { throw SafeSpaceError.storage(.unsupportedSchemaVersion(version)) }
        guard let record = try? AssessmentJSON.decode(data) else { throw SafeSpaceError.storage(.corrupt) }
        return record
    }

    private func ensureRootExists() throws {
        if !fm.fileExists(atPath: roomsDir.path) {
            try writing { try fm.createDirectory(at: roomsDir, withIntermediateDirectories: true) }
        }
        #if canImport(Darwin)
        // D4: keep assessments out of iCloud and device backups, so "only on this iPhone" stays true.
        // Set on every room creation, not only the first, in case the folder already existed.
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var url = root
        try? url.setResourceValues(values)
        #endif
    }
    private func write(_ data: Data, to url: URL) throws {
        #if os(iOS)
        try data.write(to: url, options: [.atomic, .completeFileProtection])
        #else
        try data.write(to: url, options: .atomic)
        #endif
    }
    /// `FileManager.replaceItemAt` traps with "not yet implemented" in swift-corelibs-foundation
    /// on Windows, so that platform falls back to remove-then-move (non-atomic, but this is a
    /// single-writer local store).
    private func atomicReplace(_ destination: URL, with temp: URL) throws {
        #if os(Windows)
        if fm.fileExists(atPath: destination.path) { try fm.removeItem(at: destination) }
        try fm.moveItem(at: temp, to: destination)
        #else
        _ = try fm.replaceItemAt(destination, withItemAt: temp)
        #endif
    }
    /// Maps file-system errors to the contract's storage failures.
    private func writing(_ body: () throws -> Void) throws {
        do { try body() }
        catch let error as SafeSpaceError { throw error }
        catch let error as CocoaError where error.code == .fileWriteOutOfSpace { throw SafeSpaceError.storage(.insufficientSpace) }
        catch { throw SafeSpaceError.storage(.writeFailed) }
    }

    private static func removeLeftovers(in roomsDir: URL) {
        let fm = FileManager.default
        for room in (try? fm.contentsOfDirectory(at: roomsDir, includingPropertiesForKeys: nil)) ?? [] {
            let assessments = room.appendingPathComponent("assessments", isDirectory: true)
            for entry in (try? fm.contentsOfDirectory(at: assessments, includingPropertiesForKeys: nil)) ?? [] {
                if entry.pathExtension == "tmp" { try? fm.removeItem(at: entry); continue }
                try? fm.removeItem(at: entry.appendingPathComponent("assessment.json.tmp"))
            }
        }
    }
}

/// 8-bit grayscale PNG holding `rank - 1` per pixel, or 255 (§4.7 `labels.png`).
/// PR #10 (CLI) adds an equivalent encoder, `SRGBImage.labelMapPNG`; keep one when both merge.
enum LabelMapPNG {
    static func encode(width: Int, height: Int, labels: [UInt8]) -> Data {
        PNGCodec.encode(width: width, height: height, bytes: labels, gray: true)
    }
    static func decode(_ data: Data, width: Int, height: Int) throws -> [UInt8] {
        var w: Int32 = 0, h: Int32 = 0, channels: Int32 = 0
        guard let pixels = data.withUnsafeBytes({ raw -> UnsafeMutablePointer<UInt8>? in
            stbi_load_from_memory(raw.bindMemory(to: UInt8.self).baseAddress, Int32(data.count), &w, &h, &channels, 1)
        }) else { throw SafeSpaceError.storage(.corrupt) }
        defer { stbi_image_free(pixels) }
        guard Int(w) == width, Int(h) == height else { throw SafeSpaceError.storage(.corrupt) }
        return Array(UnsafeBufferPointer(start: pixels, count: width * height))
    }
}
