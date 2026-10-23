import Foundation

public enum ImageSource: String, Codable, Sendable { case library, camera, file }
public enum StepID: String, Codable, Sendable, CaseIterable { case quality, anonymization, palette, contrast }
public enum StepState: Sendable, Equatable {
    case pending, running, completed, skipped(ReasonCode), failed(ReasonCode)
}
public enum StepStatus: String, Codable, Sendable { case completed, skipped, failed }
public enum ReasonCode: String, Codable, Sendable, CaseIterable {
    case notImplemented = "not_implemented", disabledByUser = "disabled_by_user"
    case notRequested = "not_requested", dependencyFailed = "dependency_failed"
    case imageUnavailable = "image_unavailable", qualityCheckFailed = "quality_check_failed"
    case detectionUnavailable = "detection_unavailable", anonymizationFailed = "anonymization_failed"
    case noEligiblePixels = "no_eligible_pixels", paletteExtractionFailed = "palette_extraction_failed"
    case contrastCalculationFailed = "contrast_calculation_failed"
}
public enum OverallState: String, Codable, Sendable { case complete, partial, failed }
public enum LoadFailure: String, Codable, Sendable {
    case unreadableData, unsupportedFormat, unsupportedColorSpace, emptyImage
}
public enum SafeSpaceError: Error, Equatable, Sendable, LocalizedError {
    case load(LoadFailure)
    case validation([String])
    public var errorDescription: String? {
        switch self {
        case .load(let failure): return "The photo could not be loaded (\(failure.rawValue))."
        case .validation(let messages): return messages.joined(separator: "\n")
        }
    }
}

// Unimplemented steps have null results. These opaque JSON values permit the
// complete wire shape without pretending to implement those later modules.
public enum ContractJSON: Codable, Equatable, Sendable {
    case null, bool(Bool), number(Double), string(String), array([ContractJSON]), object([String: ContractJSON])
    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let v = try? c.decode(Bool.self) { self = .bool(v) }
        else if let v = try? c.decode(Double.self) { self = .number(v) }
        else if let v = try? c.decode(String.self) { self = .string(v) }
        else if let v = try? c.decode([ContractJSON].self) { self = .array(v) }
        else { self = .object(try c.decode([String: ContractJSON].self)) }
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let v): try c.encode(v)
        case .number(let v): try c.encode(v)
        case .string(let v): try c.encode(v)
        case .array(let v): try c.encode(v)
        case .object(let v): try c.encode(v)
        }
    }
}

public struct MethodRecord: Codable, Equatable, Sendable {
    public var name: String
    public var version: Int
    public var params: ContractJSON
}
public struct StepRecord<Result: Codable & Equatable & Sendable>: Codable, Equatable, Sendable {
    public var status: StepStatus
    public var reason: ReasonCode?
    public var durationMs: Int?
    public var method: MethodRecord?
    public var result: Result?
    enum CodingKeys: String, CodingKey { case status, reason, durationMs, method, result }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(status, forKey: .status)
        try c.encode(reason, forKey: .reason)
        try c.encode(durationMs, forKey: .durationMs)
        try c.encode(method, forKey: .method)
        try c.encode(result, forKey: .result)
    }
    public static func skipped(_ reason: ReasonCode) -> Self {
        .init(status: .skipped, reason: reason, durationMs: nil, method: nil, result: nil)
    }
}
public struct Producer: Codable, Equatable, Sendable {
    public var kind: String
    public var appVersion: String?
    public var coreVersion: String
    public var device: String
    public var os: String
    public init(kind: String, appVersion: String?, coreVersion: String, device: String, os: String) {
        self.kind = kind; self.appVersion = appVersion; self.coreVersion = coreVersion
        self.device = device; self.os = os
    }
    enum CodingKeys: String, CodingKey { case kind, appVersion, coreVersion, device, os }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(kind, forKey: .kind); try c.encode(appVersion, forKey: .appVersion)
        try c.encode(coreVersion, forKey: .coreVersion); try c.encode(device, forKey: .device)
        try c.encode(os, forKey: .os)
    }
}
public struct OriginalImageInfo: Codable, Equatable, Sendable {
    public var format: String
    public var colorSpace: String
    public var width: Int
    public var height: Int
    public var exifOrientation: Int
    public var retained: Bool
}
public struct WorkingImageInfo: Codable, Equatable, Sendable {
    public var colorSpace: String
    public var width: Int
    public var height: Int
    public var maxLongSide: Int
    public var resizeMethod: String
    public var orientationApplied: Bool
    public var gamutMapping: String
}
public struct ImageProvenance: Codable, Equatable, Sendable {
    public var source: ImageSource
    public var original: OriginalImageInfo
    public var workingCopy: WorkingImageInfo
}
public struct ImageRecord: Codable, Equatable, Sendable {
    public var source: ImageSource
    public var original: OriginalImageInfo
    public var workingCopy: WorkingImageInfo
    public var stored: Bool
    public var storedFile: String?
    enum CodingKeys: String, CodingKey { case source, original, workingCopy, stored, storedFile }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(source, forKey: .source); try c.encode(original, forKey: .original)
        try c.encode(workingCopy, forKey: .workingCopy); try c.encode(stored, forKey: .stored)
        try c.encode(storedFile, forKey: .storedFile)
    }
}
public struct LabValue: Codable, Equatable, Sendable { public var l, a, b: Double }
public struct LChValue: Codable, Equatable, Sendable {
    public var l, c: Double
    public var h: Double?
    enum CodingKeys: String, CodingKey { case l, c, h }
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(l, forKey: .l); try container.encode(c, forKey: .c)
        try container.encode(h, forKey: .h)
    }
}
public struct PaletteColor: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var rank: Int
    public var share: Double
    public var pixelCount: Int
    public var hex: String
    public var srgb8: [UInt8]
    public var oklab: LabValue
    public var oklch: LChValue
    public var cielab: LabValue
}
public struct PaletteResult: Codable, Equatable, Sendable {
    public var maskApplied: Bool
    public var eligiblePixelCount: Int
    public var droppedShare: Double
    public var colors: [PaletteColor]
    public var labelMapFile: String?
    enum CodingKeys: String, CodingKey { case maskApplied, eligiblePixelCount, droppedShare, colors, labelMapFile }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(maskApplied, forKey: .maskApplied)
        try c.encode(eligiblePixelCount, forKey: .eligiblePixelCount)
        try c.encode(droppedShare, forKey: .droppedShare); try c.encode(colors, forKey: .colors)
        try c.encode(labelMapFile, forKey: .labelMapFile)
    }
}
public enum FindingKind: String, Codable, Sendable {
    case paletteOverall = "palette_overall", paletteDominant = "palette_dominant"
    case paletteAccent = "palette_accent", quality, anonymization, contrast, limitation
}
public struct Finding: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var kind: FindingKind
    public var templateId: String
    public var templateVersion: Int
    public var text: String
    public var sources: [String]
}
public struct AssessmentSteps: Codable, Equatable, Sendable {
    public var quality: StepRecord<ContractJSON>
    public var anonymization: StepRecord<ContractJSON>
    public var palette: StepRecord<PaletteResult>
    public var contrast: StepRecord<ContractJSON>
}
public struct AssessmentRecord: Codable, Equatable, Sendable, Identifiable {
    public var schemaVersion: String
    public var assessmentId: String
    public var roomId: String
    public var createdAt: Date
    public var updatedAt: Date
    public var producer: Producer
    public var image: ImageRecord
    public var steps: AssessmentSteps
    public var findings: [Finding]
    public var id: String { assessmentId }
    public var overallState: OverallState {
        guard steps.palette.status == .completed else { return .failed }
        return [steps.quality.status, steps.anonymization.status, steps.contrast.status].contains(.failed)
            ? .partial : .complete
    }
}
public enum AssessmentJSON {
    public static func encoder() -> JSONEncoder {
        let e = JSONEncoder(); e.keyEncodingStrategy = .convertToSnakeCase
        e.dateEncodingStrategy = .iso8601; e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }
    public static func decoder() -> JSONDecoder {
        let d = JSONDecoder(); d.keyDecodingStrategy = .convertFromSnakeCase
        d.dateDecodingStrategy = .iso8601; return d
    }
    public static func encode(_ record: AssessmentRecord) throws -> Data {
        try AssessmentValidator.validate(record)
        return try encoder().encode(record)
    }
    public static func decode(_ data: Data) throws -> AssessmentRecord {
        try EarlyBuildWireCheck.validate(data)
        let record = try decoder().decode(AssessmentRecord.self, from: data)
        try AssessmentValidator.validate(record); return record
    }
}
