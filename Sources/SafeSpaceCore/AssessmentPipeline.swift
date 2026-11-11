import Foundation

public struct QualityParams: Codable, Sendable, Equatable {
    public var darkMeanLuminanceMax = 0.25
    public var brightMeanLuminanceMin = 0.80
    public var clippedShareMax = 0.05
    public var blurVarianceMin = 100.0
    public var minLongSidePx = 640
    public init() {}
    public static let v1 = QualityParams()
}
public struct DetectedRegion: Codable, Sendable, Equatable {
    public var kind: String
    public var rect: NormalizedRect
    public var confidence: Double
}
public struct AnonymizationResult: Codable, Sendable, Equatable {
    public var regions: [DetectedRegion]
    public var maskedShare: Double
    public var mayBeIncomplete: Bool
}
public struct AnonymizationOutput: Sendable {
    public let result: AnonymizationResult
    public let mask: EligibilityMask
    public let anonymizedImage: SRGBImage
}
public protocol Anonymizer: Sendable {
    var methodName: String { get }
    var methodVersion: Int { get }
    func anonymize(_ copy: WorkingCopy) async throws -> AnonymizationOutput
}
public struct NoOpAnonymizer: Anonymizer {
    public var methodName: String { "not_implemented" }
    public var methodVersion: Int { 1 }
    public init() {}
    public func anonymize(_ copy: WorkingCopy) async throws -> AnonymizationOutput {
        .init(result: .init(regions: [], maskedShare: 0, mayBeIncomplete: true),
              mask: .all(width: copy.image.width, height: copy.image.height), anonymizedImage: copy.image)
    }
}
public struct PipelineOptions: Sendable {
    public var paletteMethod: PaletteMethod = .kmeansPP
    public var paletteParams: PaletteParams = .v1
    public var qualityParams: QualityParams = .v1
    public var runQuality = true
    public var anonymizer: any Anonymizer = NoOpAnonymizer()
    /// The two boxes drawn on the region-selection screen, in normalized (0-1) image
    /// coordinates. Both must be set to run contrast; leave both nil (the default) when the
    /// user hasn't selected two regions yet, which keeps the step `skipped(.notRequested)`.
    public var contrastRegion1: NormalizedRect?
    public var contrastRegion2: NormalizedRect?
    public init() {}
}
public struct PipelineOutput: Sendable {
    public let record: AssessmentRecord
    public let storedImage: SRGBImage?
    public let mask: EligibilityMask
    public let labelMap: [UInt8]?
    public let totalDurationMs: Int
}
public enum AssessmentPipeline {
    public static func run(imageData: Data, source: ImageSource, roomID: String,
                           producer: Producer, options: PipelineOptions = .init(),
                           progress: @Sendable (StepID, StepState) -> Void = { _, _ in }) async throws -> PipelineOutput {
        // Non-main-actor asynchronous entry point. All CPU work is in Core.
        let start = Date()
        try Task.checkCancellation()
        let copy: WorkingCopy
        do { copy = try ImageLoader.load(data: imageData, source: source) }
        catch is CancellationError { throw CancellationError() }
        catch let error as SafeSpaceError { throw error }
        catch { throw SafeSpaceError.load(.unreadableData) }
        let quality: StepRecord<ContractJSON> = .skipped(options.runQuality ? .notImplemented : .disabledByUser)
        progress(.quality, .skipped(quality.reason!))
        // Week-2 scope intentionally ships only NoOpAnonymizer. Do not silently
        // accept a real anonymizer and omit its method parameters/provenance.
        let privacy: StepRecord<ContractJSON>
        if options.anonymizer is NoOpAnonymizer {
            privacy = .skipped(.notImplemented)
            progress(.anonymization, .skipped(.notImplemented))
        } else {
            privacy = .init(status: .failed, reason: .anonymizationFailed, durationMs: 0,
                method: .init(name: options.anonymizer.methodName, version: options.anonymizer.methodVersion,
                              params: .object([:])), result: nil)
            progress(.anonymization, .failed(.anonymizationFailed))
        }
        let mask = EligibilityMask.all(width: copy.image.width, height: copy.image.height)
        let extractor = makePaletteExtractor(options.paletteMethod)
        let encodedParams = try AssessmentJSON.encoder().encode(options.paletteParams)
        let params = try JSONDecoder().decode(ContractJSON.self, from: encodedParams)
        let method = MethodRecord(name: extractor.method.rawValue, version: extractor.methodVersion, params: params)
        progress(.palette, .running)
        let paletteStart = Date()
        var palette: StepRecord<PaletteResult>
        var map: [UInt8]?
        do {
            let output = try extractor.extract(copy.image, mask: mask, params: options.paletteParams)
            palette = .init(status: .completed, reason: nil, durationMs: elapsed(paletteStart),
                            method: method, result: output.result)
            map = output.labelMap
            progress(.palette, .completed)
        } catch is CancellationError { throw CancellationError() }
        catch {
            let reason: ReasonCode
            if let issue = error as? PaletteExtractionError, case .noEligiblePixels = issue {
                reason = .noEligiblePixels
            } else { reason = .paletteExtractionFailed }
            palette = .init(status: .failed, reason: reason, durationMs: elapsed(paletteStart), method: method, result: nil)
            progress(.palette, .failed(reason))
        }
        // No persistent image store is included in this task. Be truthful in JSON.
        // The memory-resident working copy is a candidate for a future store.
        let image = ImageRecord(source: copy.provenance.source, original: copy.provenance.original,
                                workingCopy: copy.provenance.workingCopy, stored: false, storedFile: nil)
        let contrast: StepRecord<RegionContrastResult>
        if privacy.status == .failed {
            contrast = .skipped(.dependencyFailed)
            progress(.contrast, .skipped(.dependencyFailed))
        } else if let region1 = options.contrastRegion1, let region2 = options.contrastRegion2 {
            progress(.contrast, .running)
            let contrastStart = Date()
            let contrastMethod = MethodRecord(name: RegionContrast.methodName, version: RegionContrast.methodVersion, params: .object([:]))
            do {
                let measurement = try RegionContrast.measure(copy.image, mask: mask, region1: region1, region2: region2)
                let result = RegionContrastResult(colorSpace: "cielab", formula: "ciede2000", measurements: [measurement])
                contrast = .init(status: .completed, reason: nil, durationMs: elapsed(contrastStart),
                                 method: contrastMethod, result: result)
                progress(.contrast, .completed)
            } catch {
                contrast = .init(status: .failed, reason: .contrastCalculationFailed, durationMs: elapsed(contrastStart),
                                 method: contrastMethod, result: nil)
                progress(.contrast, .failed(.contrastCalculationFailed))
            }
        } else {
            contrast = .skipped(.notRequested)
            progress(.contrast, .skipped(.notRequested))
        }
        let now = Date(timeIntervalSince1970: floor(Date().timeIntervalSince1970))
        var record = AssessmentRecord(schemaVersion: "1", assessmentId: UUID().uuidString.lowercased(),
            roomId: roomID.lowercased(), createdAt: now, updatedAt: now, producer: producer, image: image,
            steps: .init(quality: quality, anonymization: privacy, palette: palette, contrast: contrast), findings: [])
        record.findings = Findings.generate(for: record)
        try Task.checkCancellation()
        // Structural programming errors must not be hidden as successful output.
        try AssessmentValidator.validate(record)
        return PipelineOutput(record: record, storedImage: privacy.status == .failed ? nil : copy.image,
                              mask: mask, labelMap: map, totalDurationMs: elapsed(start))
    }

    /// Adds one contrast measurement to an already-saved record: the user drew two regions on
    /// the region-selection screen sometime after the photo was assessed and saved. `image` and
    /// `mask` are the ones `AssessmentStore.load` returned for this record. Bumps `updatedAt`,
    /// appends the matching finding, and re-validates. Throws `RegionContrastError.regionTooSmall`
    /// without touching `record` if either region has too few eligible pixels — per contract,
    /// failed attempts are not persisted, so the caller should show the error and keep the record
    /// it already has.
    public static func addContrast(
        to record: AssessmentRecord, image: SRGBImage, mask: EligibilityMask,
        region1: NormalizedRect, region2: NormalizedRect,
        minEligiblePixels: Int = RegionContrast.defaultMinEligiblePixels, label: String? = nil
    ) throws -> AssessmentRecord {
        let start = Date()
        let measurement = try RegionContrast.measure(image, mask: mask, region1: region1, region2: region2,
                                                      minEligiblePixels: minEligiblePixels, label: label)
        var updated = record
        let existing = updated.steps.contrast.result?.measurements ?? []
        let newIndex = existing.count
        updated.steps.contrast = .init(status: .completed, reason: nil, durationMs: elapsed(start),
            method: MethodRecord(name: RegionContrast.methodName, version: RegionContrast.methodVersion, params: .object([:])),
            result: RegionContrastResult(colorSpace: "cielab", formula: "ciede2000", measurements: existing + [measurement]))
        updated.updatedAt = Date(timeIntervalSince1970: floor(Date().timeIntervalSince1970))
        updated.findings += Findings.contrastFindings(for: updated, measurementIndex: newIndex)
        try AssessmentValidator.validate(updated)
        return updated
    }
    private static func elapsed(_ start: Date) -> Int { max(0, Int(Date().timeIntervalSince(start) * 1000)) }
}
