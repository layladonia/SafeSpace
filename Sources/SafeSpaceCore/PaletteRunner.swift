import Foundation

public enum PaletteFallbackPolicy: Sendable {
    case disabled
    case medianCutOnFailure
}
public enum PaletteExecutionError: Error, Sendable {
    case invalidOutput
}
public struct PaletteExecution: Sendable {
    public let output: PaletteOutput
    public let requestedMethod: PaletteMethod
    public let usedMethod: PaletteMethod
    public let methodVersion: Int
    public let fallbackReason: String?
}

/// A bounded, explicit fallback. Cancellation, invalid inputs and unexpected
/// programming errors are never hidden by a second algorithm.
public enum PaletteRunner {
    public static func extract(_ image: SRGBImage, mask: EligibilityMask,
                               params: PaletteParams = .v1,
                               method: PaletteMethod = .kmeansPP,
                               fallback: PaletteFallbackPolicy = .medianCutOnFailure) throws -> PaletteExecution {
        try execute(image, mask: mask, params: params, method: method,
                    fallback: fallback, factory: makePaletteExtractor)
    }
    static func execute(_ image: SRGBImage, mask: EligibilityMask, params: PaletteParams,
                        method: PaletteMethod, fallback: PaletteFallbackPolicy,
                        factory: (PaletteMethod) -> any PaletteExtractor) throws -> PaletteExecution {
        try Task.checkCancellation()
        let primary = factory(method)
        do {
            let output = try primary.extract(image, mask: mask, params: params)
            try validate(output, image: image, mask: mask)
            try Task.checkCancellation()
            return .init(output: output, requestedMethod: method, usedMethod: method,
                         methodVersion: primary.methodVersion, fallbackReason: nil)
        } catch is CancellationError { throw CancellationError() }
        catch {
            let reason: String
            switch error {
            case PaletteExtractionError.noRetainedColors: reason = "no_retained_colors"
            case PaletteExecutionError.invalidOutput: reason = "invalid_output"
            default: throw error
            }
            guard method == .kmeansPP, case .medianCutOnFailure = fallback else { throw error }
            try Task.checkCancellation()
            let secondary = factory(.medianCut)
            let output = try secondary.extract(image, mask: mask, params: params)
            try validate(output, image: image, mask: mask)
            try Task.checkCancellation()
            return .init(output: output, requestedMethod: method, usedMethod: .medianCut,
                         methodVersion: secondary.methodVersion, fallbackReason: reason)
        }
    }
    static func validate(_ output: PaletteOutput, image: SRGBImage, mask: EligibilityMask) throws {
        let result = output.result
        guard mask.width == image.width, mask.height == image.height,
              output.labelMap.count == image.width * image.height,
              result.eligiblePixelCount == mask.eligibleCount,
              result.eligiblePixelCount > 0, (1...8).contains(result.colors.count),
              result.droppedShare.isFinite, (0...1).contains(result.droppedShare) else {
            throw PaletteExecutionError.invalidOutput
        }
        var counts = Array(repeating: 0, count: result.colors.count)
        var dropped = 0
        for i in output.labelMap.indices {
            if i % 8192 == 0 { try Task.checkCancellation() }
            let label = output.labelMap[i]
            if !mask.eligible[i] {
                guard label == 255 else { throw PaletteExecutionError.invalidOutput }
            } else if label == 255 { dropped += 1 }
            else {
                guard Int(label) < counts.count else { throw PaletteExecutionError.invalidOutput }
                counts[Int(label)] += 1
            }
        }
        var previous = Double.infinity
        let total = Double(result.eligiblePixelCount)
        for (i, color) in result.colors.enumerated() {
            guard color.rank == i + 1, color.id == "c\(i + 1)",
                  color.pixelCount > 0, counts[i] == color.pixelCount,
                  color.share.isFinite, color.share <= previous,
                  abs(color.share - Double(counts[i]) / total) <= 1e-12,
                  color.srgb8.count == 3,
                  [color.oklab.l, color.oklab.a, color.oklab.b,
                   color.oklch.l, color.oklch.c, color.cielab.l,
                   color.cielab.a, color.cielab.b].allSatisfy({ $0.isFinite }) else {
                throw PaletteExecutionError.invalidOutput
            }
            previous = color.share
        }
        guard abs(result.droppedShare - Double(dropped) / total) <= 1e-12,
              abs(result.colors.reduce(0) { $0 + $1.share } + result.droppedShare - 1) <= 1e-9 else {
            throw PaletteExecutionError.invalidOutput
        }
    }
}
