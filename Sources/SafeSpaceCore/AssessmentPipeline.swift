import Foundation

/// Quality thresholds (contract §4.5). These are the v1 PLACEHOLDERS. They get calibrated
/// against the Task 22 labels, and changing any default bumps `QualityCheck.methodVersion`.
/// They are written into `method.params` so every saved result records the thresholds it used.
/// Warning rules are in `QualityCheck.warnings(for:params:)`.
public struct QualityParams: Codable, Sendable, Equatable {
    public var darkMeanLuminanceMax = 0.25      // too_dark when mean luminance ≤ this
    public var brightMeanLuminanceMin = 0.80    // too_bright when mean luminance ≥ this
    public var clippedShareMax = 0.05           // over/underexposed when a clipped share > this
    public var blurVarianceMin = 100.0          // blurry when Laplacian variance < this
    public var minLongSidePx = 640              // low_resolution when the original's long side < this
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
        let quality = try runQuality(copy, options: options, progress: progress)
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
        let contrast: StepRecord<ContractJSON> = .skipped(.imageUnavailable)
        progress(.contrast, .skipped(.imageUnavailable))
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
    /// Quality step (Task 19). It runs on the unmasked working copy and only ever warns: a
    /// completed step with warnings still lets the palette run (decision log Oct 11). An error
    /// inside the check becomes `failed / quality_check_failed`, with method and duration kept
    /// (contract §4.4), and never stops the assessment. Only cancellation propagates.
    private static func runQuality(_ copy: WorkingCopy, options: PipelineOptions,
                                   progress: @Sendable (StepID, StepState) -> Void) throws -> StepRecord<ContractJSON> {
        guard options.runQuality else {
            progress(.quality, .skipped(.disabledByUser))
            return .skipped(.disabledByUser)
        }
        let method = MethodRecord(name: QualityCheck.methodName, version: QualityCheck.methodVersion,
                                  params: try ContractJSON.encoding(options.qualityParams))
        progress(.quality, .running)
        let start = Date()
        do {
            let result = try QualityCheck.run(copy, params: options.qualityParams)
            progress(.quality, .completed)
            return .init(status: .completed, reason: nil, durationMs: elapsed(start), method: method,
                         result: try ContractJSON.encoding(result))
        } catch is CancellationError { throw CancellationError() }
        catch {
            progress(.quality, .failed(.qualityCheckFailed))
            return .init(status: .failed, reason: .qualityCheckFailed, durationMs: elapsed(start), method: method, result: nil)
        }
    }
    private static func elapsed(_ start: Date) -> Int { max(0, Int(Date().timeIntervalSince(start) * 1000)) }
}
