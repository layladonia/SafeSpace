import Foundation

/// Quality thresholds (contract §4.5). Recorded in method.params.
/// Task 19 calibrated darkMeanLuminanceMax to 0.08 rather than the old 0.25
/// placeholder. The earlier value flagged 18 of 39 acceptable development images.
/// Clearly dark examples measured 0.018 and 0.045; the darkest acceptable example
/// measured 0.118. Only two clearly dark examples were available, so Task 22 must
/// recheck calibration. The other defaults remain v1 placeholders.
/// After the first tagged build with completed quality results, changes to defaults
/// require a QualityCheck.methodVersion bump. See QualityCheck.warnings(for:params:).
public struct QualityParams: Codable, Sendable, Equatable {
    public var darkMeanLuminanceMax = 0.08
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
    func encodedParameters() throws -> ContractJSON
    func anonymize(_ copy: WorkingCopy) async throws -> AnonymizationOutput
}
public struct NoOpAnonymizer: Anonymizer {
    public var methodName: String { "not_implemented" }
    public var methodVersion: Int { 1 }
    public init() {}
    public func encodedParameters() throws -> ContractJSON { .object([:]) }
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
    public var anonymizer: any Anonymizer = VisionAnonymizer()
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
        // Non-actor-isolated async entry point. Under this package's Swift 5.9
        // execution model, processing runs on the generic executor rather than
        // inheriting the caller's MainActor isolation.
        let start = Date()
        try Task.checkCancellation()
        let copy: WorkingCopy
        do { copy = try ImageLoader.load(data: imageData, source: source) }
        catch is CancellationError { throw CancellationError() }
        catch let error as SafeSpaceError { throw error }
        catch { throw SafeSpaceError.load(.unreadableData) }
        let quality = try runQuality(copy, options: options, progress: progress)
        var analysisImage = copy.image
        var storedImage: SRGBImage?
        var mask = EligibilityMask.all(width: copy.image.width, height: copy.image.height)
        let privacy: StepRecord<AnonymizationResult>
        if options.anonymizer is NoOpAnonymizer {
            // Explicit dev/CLI opt-out only; preserve §3.4 / D2 skipped behavior.
            privacy = .skipped(.notImplemented)
            storedImage = copy.image
            progress(.anonymization, .skipped(.notImplemented))
        } else {
            let json = try options.anonymizer.encodedParameters()
            let method = MethodRecord(name: options.anonymizer.methodName,
                version: options.anonymizer.methodVersion, params: json)
            let privacyStart = Date()
            progress(.anonymization, .running)
            do {
                let output = try await options.anonymizer.anonymize(copy)
                // Validate every anonymizer's output at the pipeline boundary,
                // including that eligible pixels were not changed.
                try PrivacyMasking.validate(output, against: copy.image)
                try Task.checkCancellation()
                analysisImage = output.anonymizedImage
                storedImage = output.anonymizedImage
                mask = output.mask
                privacy = .init(status: .completed, reason: nil, durationMs: elapsed(privacyStart),
                                method: method, result: output.result)
                progress(.anonymization, .completed)
            } catch is CancellationError { throw CancellationError() }
            catch {
                let reason: ReasonCode
                if let failure = error as? AnonymizationError, case .detectionUnavailable = failure {
                    reason = .detectionUnavailable
                } else { reason = .anonymizationFailed }
                privacy = .init(status: .failed, reason: reason, durationMs: elapsed(privacyStart),
                                method: method, result: nil)
                // §3.4: palette continues unmasked. D2: never persist this photo.
                storedImage = nil
                progress(.anonymization, .failed(reason))
            }
        }
        let extractor = makePaletteExtractor(options.paletteMethod)
        let encodedParams = try AssessmentJSON.encoder().encode(options.paletteParams)
        let params = try JSONDecoder().decode(ContractJSON.self, from: encodedParams)
        let method = MethodRecord(name: extractor.method.rawValue, version: extractor.methodVersion, params: params)
        progress(.palette, .running)
        let paletteStart = Date()
        var palette: StepRecord<PaletteResult>
        var map: [UInt8]?
        do {
            let output = try extractor.extract(analysisImage, mask: mask, params: options.paletteParams)
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
        return PipelineOutput(record: record, storedImage: storedImage,
                              mask: mask, labelMap: map, totalDurationMs: elapsed(start))
    }
    /// Quality runs on the unmasked working copy and only warns. Cancellation and
    /// unencodable/nonfinite configuration propagate; measurement failures do not block analysis.
    private static func runQuality(_ copy: WorkingCopy, options: PipelineOptions,
                                   progress: @Sendable (StepID, StepState) -> Void) throws -> StepRecord<ContractJSON> {
        guard options.runQuality else {
            progress(.quality, .skipped(.disabledByUser))
            return .skipped(.disabledByUser)
        }
        let p = options.qualityParams
        guard [p.darkMeanLuminanceMax, p.brightMeanLuminanceMin, p.clippedShareMax, p.blurVarianceMin].allSatisfy(\.isFinite),
              let params = try? ContractJSON.encoding(p) else {
            throw SafeSpaceError.validation(["Quality params must be finite numbers"])
        }
        let method = MethodRecord(name: QualityCheck.methodName, version: QualityCheck.methodVersion, params: params)
        progress(.quality, .running)
        let start = Date()
        do {
            let result = try ContractJSON.encoding(QualityCheck.run(copy, params: p))
            let record = StepRecord<ContractJSON>(status: .completed, reason: nil, durationMs: elapsed(start),
                                                  method: method, result: result)
            progress(.quality, .completed)
            return record
        } catch is CancellationError { throw CancellationError() }
        catch {
            progress(.quality, .failed(.qualityCheckFailed))
            return .init(status: .failed, reason: .qualityCheckFailed, durationMs: elapsed(start), method: method, result: nil)
        }
    }
    private static func elapsed(_ start: Date) -> Int { max(0, Int(Date().timeIntervalSince(start) * 1000)) }
}
