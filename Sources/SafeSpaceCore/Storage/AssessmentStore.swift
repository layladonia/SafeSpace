import Foundation

// Storage API (contract §5.11, Task 14). FileAssessmentStore writes the §6 layout;
// InMemoryAssessmentStore has the same behavior for previews and tests.
//
// Differences from the §5.11 sketch, to be added to the contract:
// - AssessmentSummary.canOpen (marks corrupt / newer-format assessments for the §6 list behavior).
// - save(_:) returns the record as stored (storage fills in the stored-image fields).
// - Both stores are actors rather than final classes; callers use them the same way (async).

public struct Room: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public var name: String
    public let createdAt: Date
}
/// For lists; cheap to load. `canOpen == false` marks a corrupt or newer-format assessment,
/// which the room list shows as "Can't open this assessment" with a Delete action (§6).
public struct AssessmentSummary: Sendable, Equatable, Identifiable {
    public let id: String
    public let roomID: String
    public let createdAt: Date
    public let overallState: OverallState
    public let topColors: [String]
    public let hasImage: Bool
    public let canOpen: Bool
}
public struct StoredAssessment: Sendable {
    public let record: AssessmentRecord
    public let image: SRGBImage?
    public let mask: EligibilityMask?
    public let labelMap: [UInt8]?
}

public protocol AssessmentStore: Sendable {
    /// Sorted by createdAt.
    func rooms() async throws -> [Room]
    /// An empty or blank name becomes "Untitled room".
    func createRoom(name: String) async throws -> Room
    func renameRoom(id: String, to name: String) async throws
    /// Removes the room and all its assessments.
    func deleteRoom(id: String) async throws
    /// Newest first.
    func assessments(inRoom roomID: String) async throws -> [AssessmentSummary]
    /// Validates first and writes atomically. Returns the record as stored, which differs from
    /// `output.record` when the image is kept (stored-image fields, label map, contrast reason).
    @discardableResult func save(_ output: PipelineOutput) async throws -> AssessmentRecord
    /// Never recomputes: returns exactly what was saved.
    func load(assessmentID: String) async throws -> StoredAssessment
    /// After addContrast; validates and replaces assessment.json atomically.
    func update(_ record: AssessmentRecord) async throws
    /// Removes the whole assessment folder.
    func deleteAssessment(id: String) async throws
}

enum StoreRules {
    static let storedImageFile = "image.png", maskFile = "mask.png", labelMapFile = "labels.png"

    /// The record exactly as it will be saved. The pipeline doesn't know whether the image will
    /// be kept, so it writes `stored: false` and contrast `image_unavailable`. When there is an
    /// image to keep (D2: not after a failed anonymization; `storedImage` is nil then), storage
    /// fills in the file names and contrast becomes `not_requested`.
    ///
    /// PRIVACY (until Task 21): with NoOpAnonymizer the step is `skipped`, so per D2 the working
    /// copy is stored *without* faces or people hidden. Use only test photos without people.
    /// Once VisionAnonymizer lands, `storedImage` is the anonymized copy and this needs no change.
    static func recordToSave(_ output: PipelineOutput) throws -> AssessmentRecord {
        var record = output.record
        if output.storedImage != nil {
            record.image.stored = true
            record.image.storedFile = storedImageFile
            if record.steps.palette.status == .completed, output.labelMap != nil {
                record.steps.palette.result?.labelMapFile = labelMapFile
            }
            if record.steps.contrast.status == .skipped, record.steps.contrast.reason == .imageUnavailable {
                record.steps.contrast = .skipped(.notRequested)
            }
        }
        try AssessmentValidator.validate(record)
        return record
    }
    static func roomName(_ name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Untitled room" : trimmed
    }
    /// IDs become folder names, so only lowercase UUIDs are accepted.
    static func isValidID(_ id: String) -> Bool {
        id.range(of: "^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$", options: .regularExpression) != nil
    }
    /// Whole seconds, so dates survive the ISO 8601 round trip unchanged.
    static func now() -> Date { Date(timeIntervalSince1970: floor(Date().timeIntervalSince1970)) }
    static func summary(_ record: AssessmentRecord) -> AssessmentSummary {
        .init(id: record.assessmentId, roomID: record.roomId, createdAt: record.createdAt,
              overallState: record.overallState,
              topColors: (record.steps.palette.result?.colors ?? []).prefix(5).map(\.hex),
              hasImage: record.image.stored, canOpen: true)
    }
    static func newestFirst(_ a: AssessmentSummary, _ b: AssessmentSummary) -> Bool {
        a.createdAt != b.createdAt ? a.createdAt > b.createdAt : a.id > b.id
    }
}

public actor InMemoryAssessmentStore: AssessmentStore {
    private var roomList: [Room] = []
    private var stored: [String: StoredAssessment] = [:]
    public init() {}

    public func rooms() -> [Room] { roomList.sorted { $0.createdAt < $1.createdAt } }
    public func createRoom(name: String) -> Room {
        let room = Room(id: UUID().uuidString.lowercased(), name: StoreRules.roomName(name), createdAt: StoreRules.now())
        roomList.append(room)
        return room
    }
    public func renameRoom(id: String, to name: String) throws {
        guard let i = roomList.firstIndex(where: { $0.id == id }) else { throw SafeSpaceError.storage(.notFound) }
        roomList[i].name = StoreRules.roomName(name)
    }
    public func deleteRoom(id: String) throws {
        guard roomList.contains(where: { $0.id == id }) else { throw SafeSpaceError.storage(.notFound) }
        roomList.removeAll { $0.id == id }
        stored = stored.filter { $0.value.record.roomId != id }
    }
    public func assessments(inRoom roomID: String) throws -> [AssessmentSummary] {
        guard roomList.contains(where: { $0.id == roomID }) else { throw SafeSpaceError.storage(.notFound) }
        return stored.values.filter { $0.record.roomId == roomID }.map { StoreRules.summary($0.record) }
            .sorted(by: StoreRules.newestFirst)
    }
    @discardableResult public func save(_ output: PipelineOutput) throws -> AssessmentRecord {
        let record = try StoreRules.recordToSave(output)
        guard roomList.contains(where: { $0.id == record.roomId }) else { throw SafeSpaceError.storage(.notFound) }
        // Same as the file store: IDs are never overwritten.
        guard stored[record.assessmentId] == nil else { throw SafeSpaceError.storage(.writeFailed) }
        let keep = record.image.stored
        stored[record.assessmentId] = .init(record: record, image: keep ? output.storedImage : nil,
            mask: keep ? output.mask : nil, labelMap: record.steps.palette.result?.labelMapFile != nil ? output.labelMap : nil)
        return record
    }
    public func load(assessmentID: String) throws -> StoredAssessment {
        guard let value = stored[assessmentID] else { throw SafeSpaceError.storage(.notFound) }
        return value
    }
    public func update(_ record: AssessmentRecord) throws {
        guard let old = stored[record.assessmentId], old.record.roomId == record.roomId else {
            throw SafeSpaceError.storage(.notFound)
        }
        try AssessmentValidator.validate(record)
        stored[record.assessmentId] = .init(record: record, image: old.image, mask: old.mask, labelMap: old.labelMap)
    }
    public func deleteAssessment(id: String) throws {
        guard stored.removeValue(forKey: id) != nil else { throw SafeSpaceError.storage(.notFound) }
    }
}
