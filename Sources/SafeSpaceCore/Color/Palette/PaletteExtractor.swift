import Foundation

public enum PaletteMethod: String, Codable, Sendable { case kmeansPP = "kmeans_pp", medianCut = "median_cut" }
public struct PaletteParams: Codable, Sendable, Equatable {
    public var space = "oklab"
    public var kInitial = 8
    public var seed: UInt64 = 482
    public var maxIterations = 50
    public var mergeDeltaEOk = 0.04
    public var minShare = 0.01
    public var sampleStride = 1
    public init() {}
    public static let v1 = PaletteParams()
}
public struct PaletteOutput: Sendable {
    public let result: PaletteResult
    public let labelMap: [UInt8]
}
public protocol PaletteExtractor: Sendable {
    var method: PaletteMethod { get }
    var methodVersion: Int { get }
    func extract(_ image: SRGBImage, mask: EligibilityMask, params: PaletteParams) throws -> PaletteOutput
}
public func makePaletteExtractor(_ method: PaletteMethod) -> any PaletteExtractor {
    switch method { case .kmeansPP: return KMeansPlusPlus(); case .medianCut: return MedianCut() }
}
public struct KMeansPlusPlus: PaletteExtractor {
    public var method: PaletteMethod { .kmeansPP }
    public var methodVersion: Int { 1 }
    public init() {}
    public func extract(_ image: SRGBImage, mask: EligibilityMask, params: PaletteParams = .v1) throws -> PaletteOutput {
        try PaletteEngine.extract(image, mask: mask, params: params, method: method)
    }
}
public struct MedianCut: PaletteExtractor {
    public var method: PaletteMethod { .medianCut }
    public var methodVersion: Int { 1 }
    public init() {}
    public func extract(_ image: SRGBImage, mask: EligibilityMask, params: PaletteParams = .v1) throws -> PaletteOutput {
        try PaletteEngine.extract(image, mask: mask, params: params, method: method)
    }
}
public enum PaletteExtractionError: Error, Sendable { case noEligiblePixels, invalidParameters, noRetainedColors }

private struct SplitMix64 {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
    mutating func unit() -> Double { Double(next() >> 11) * (1.0 / 9007199254740992.0) }
}
private enum PaletteEngine {
    typealias Vector = SIMD3<Double>
    struct Point { var rgb: UInt32; var value: Vector; var count: Int }
    static func squared(_ a: Vector, _ b: Vector) -> Double {
        let d = a - b; return d.x * d.x + d.y * d.y + d.z * d.z
    }
    static func nearest(_ value: Vector, _ centers: [Vector]) -> Int {
        var best = 0, distance = Double.infinity
        for index in centers.indices {
            let candidate = squared(value, centers[index])
            if candidate < distance { best = index; distance = candidate }
        }
        return best
    }
    static func means(_ points: [Point], _ labels: [Int], _ count: Int) -> ([Vector], [Int]) {
        var sums = Array(repeating: Vector(repeating: 0), count: count)
        var counts = Array(repeating: 0, count: count)
        for i in points.indices {
            sums[labels[i]] += points[i].value * Double(points[i].count)
            counts[labels[i]] += points[i].count
        }
        for i in sums.indices where counts[i] > 0 { sums[i] /= Double(counts[i]) }
        return (sums, counts)
    }
    static func key(_ bytes: [UInt8], _ p: Int) -> UInt32 {
        UInt32(bytes[p * 4]) << 16 | UInt32(bytes[p * 4 + 1]) << 8 | UInt32(bytes[p * 4 + 2])
    }
    static func extract(_ image: SRGBImage, mask: EligibilityMask, params p: PaletteParams,
                        method: PaletteMethod) throws -> PaletteOutput {
        guard mask.width == image.width, mask.height == image.height,
              p.space == "oklab", (1...8).contains(p.kInitial), (1...1000).contains(p.maxIterations),
              p.mergeDeltaEOk.isFinite, p.mergeDeltaEOk >= 0,
              p.minShare.isFinite, (0..<1).contains(p.minShare), p.sampleStride == 1 else {
            throw PaletteExtractionError.invalidParameters
        }
        try Task.checkCancellation()
        var histogram: [UInt32: Int] = [:]
        for i in mask.eligible.indices where mask.eligible[i] {
            if i % 8192 == 0 { try Task.checkCancellation() }
            histogram[key(image.rgba, i), default: 0] += 1
        }
        let total = mask.eligibleCount
        guard total > 0 else { throw PaletteExtractionError.noEligiblePixels }
        // Sorted packed sRGB keys define all reduction/tie order. No Dictionary
        // traversal contributes to numerical calculations. Histogramming is exact.
        let keys = histogram.keys.sorted()
        let points: [Point] = keys.map { key in
            let color = ColorSpace.sRGBToOKLab(r: Double((key >> 16) & 255) / 255,
                g: Double((key >> 8) & 255) / 255, b: Double(key & 255) / 255)
            return Point(rgb: key, value: Vector(color.L, color.a, color.b), count: histogram[key]!)
        }
        let k = min(p.kInitial, points.count)
        var labels: [Int]
        var centers: [Vector]
        if method == .kmeansPP {
            var random = SplitMix64(state: p.seed)
            func pick(_ weights: [Double], _ unit: Double) -> Int {
                let sum = weights.reduce(0, +), target = unit * sum
                var cumulative = 0.0
                for i in weights.indices {
                    cumulative += weights[i]
                    if weights[i] > 0 && target < cumulative { return i }
                }
                return weights.lastIndex(where: { $0 > 0 }) ?? 0
            }
            centers = [points[pick(points.map { Double($0.count) }, random.unit())].value]
            var distances = Array(repeating: Double.infinity, count: points.count)
            while centers.count < k {
                let last = centers.last!
                for i in points.indices { distances[i] = min(distances[i], squared(points[i].value, last)) }
                let weights = points.indices.map { distances[$0] * Double(points[$0].count) }
                if weights.reduce(0, +) == 0 { break }
                centers.append(points[pick(weights, random.unit())].value)
            }
            labels = Array(repeating: -1, count: points.count)
            for _ in 0..<p.maxIterations {
                try Task.checkCancellation()
                var changed = false
                for i in points.indices {
                    if i % 8192 == 0 { try Task.checkCancellation() }
                    let next = nearest(points[i].value, centers)
                    if labels[i] != next { changed = true; labels[i] = next }
                }
                let (newCenters, counts) = means(points, labels, centers.count)
                // Empty centers remain unchanged; ties always prefer the lower index.
                for i in centers.indices where counts[i] > 0 { centers[i] = newCenters[i] }
                if !changed { break }
            }
        } else {
            // Weighted median cuts in OKLab. Box selection: largest range, lower
            // box index on ties; axis ties prefer L, a, then b.
            var boxes = [Array(points.indices)]
            while boxes.count < k {
                try Task.checkCancellation()
                var selected: Int?, axis = 0, bestRange = -1.0
                for b in boxes.indices where boxes[b].count > 1 {
                    for c in 0..<3 {
                        let values = boxes[b].map { points[$0].value[c] }
                        let range = values.max()! - values.min()!
                        if range > bestRange { selected = b; axis = c; bestRange = range }
                    }
                }
                guard let index = selected else { break }
                let sorted = boxes[index].sorted {
                    let a = points[$0].value[axis], b = points[$1].value[axis]
                    return a == b ? $0 < $1 : a < b
                }
                let count = sorted.reduce(0) { $0 + points[$1].count }
                var sum = 0, split = 1
                for i in 0..<(sorted.count - 1) {
                    sum += points[sorted[i]].count
                    split = i + 1
                    if sum * 2 >= count { break }
                }
                boxes[index] = Array(sorted[..<split]); boxes.append(Array(sorted[split...]))
            }
            labels = Array(repeating: 0, count: points.count)
            for b in boxes.indices { for i in boxes[b] { labels[i] = b } }
            centers = means(points, labels, boxes.count).0
        }
        // Remove empty clusters and renumber in original-center order.
        var stats = means(points, labels, centers.count)
        let active = stats.1.indices.filter { stats.1[$0] > 0 }
        var indexMap = Array(repeating: -1, count: centers.count)
        for (new, old) in active.enumerated() { indexMap[old] = new }
        labels = labels.map { indexMap[$0] }
        centers = active.map { stats.0[$0] }
        // Greedily merge the closest pair below threshold. Lexicographic pair
        // order breaks exact distance ties. Recompute exact weighted means.
        while centers.count > 1 {
            try Task.checkCancellation()
            var pair: (Int, Int)?, best = p.mergeDeltaEOk * p.mergeDeltaEOk
            for a in 0..<(centers.count - 1) {
                for b in (a + 1)..<centers.count {
                    let distance = squared(centers[a], centers[b])
                    if distance < best { best = distance; pair = (a, b) }
                }
            }
            guard let (a, b) = pair else { break }
            for i in labels.indices {
                if labels[i] == b { labels[i] = a }
                else if labels[i] > b { labels[i] -= 1 }
            }
            centers.remove(at: b)
            centers = means(points, labels, centers.count).0
        }
        stats = means(points, labels, centers.count)
        let retained = centers.indices.filter { Double(stats.1[$0]) / Double(total) >= p.minShare }.sorted {
            stats.1[$0] == stats.1[$1] ? $0 < $1 : stats.1[$0] > stats.1[$1]
        }
        guard !retained.isEmpty else { throw PaletteExtractionError.noRetainedColors }
        var ranks = Array(repeating: UInt8(255), count: centers.count)
        var colors: [PaletteColor] = []
        var retainedPixels = 0
        for (rankIndex, cluster) in retained.enumerated() {
            let mean = stats.0[cluster], count = stats.1[cluster]
            ranks[cluster] = UInt8(rankIndex); retainedPixels += count
            let bytes = rgb8(mean)
            let lab = ColorSpace.sRGBToCIELAB(r: Double(bytes[0]) / 255,
                g: Double(bytes[1]) / 255, b: Double(bytes[2]) / 255)
            let chroma = hypot(mean.y, mean.z)
            let hue = (atan2(mean.z, mean.y) * 180 / .pi + 360).truncatingRemainder(dividingBy: 360)
            colors.append(.init(id: "c\(rankIndex + 1)", rank: rankIndex + 1,
                share: Double(count) / Double(total), pixelCount: count,
                hex: String(format: "#%02X%02X%02X", Int(bytes[0]), Int(bytes[1]), Int(bytes[2])),
                srgb8: bytes, oklab: .init(l: mean.x, a: mean.y, b: mean.z),
                oklch: .init(l: mean.x, c: chroma, h: chroma < 0.002 ? nil : hue),
                cielab: .init(l: lab.L, a: lab.a, b: lab.b)))
        }
        var keyToRank: [UInt32: UInt8] = [:]
        for i in points.indices { keyToRank[points[i].rgb] = ranks[labels[i]] }
        var labelMap = Array(repeating: UInt8(255), count: image.width * image.height)
        for i in labelMap.indices where mask.eligible[i] { labelMap[i] = keyToRank[key(image.rgba, i)]! }
        return PaletteOutput(result: .init(maskApplied: total != mask.eligible.count,
            eligiblePixelCount: total, droppedShare: Double(total - retainedPixels) / Double(total),
            colors: colors, labelMapFile: nil), labelMap: labelMap)
    }
    static func rgb8(_ value: Vector) -> [UInt8] {
        let l = value.x + 0.3963377774 * value.y + 0.2158037573 * value.z
        let m = value.x - 0.1055613458 * value.y - 0.0638541728 * value.z
        let s = value.x - 0.0894841775 * value.y - 1.2914855480 * value.z
        let l3 = l * l * l, m3 = m * m * m, s3 = s * s * s
        let channels = [4.0767416621 * l3 - 3.3077115913 * m3 + 0.2309699292 * s3,
                        -1.2684380046 * l3 + 2.6097574011 * m3 - 0.3413193965 * s3,
                        -0.0041960863 * l3 - 0.7034186147 * m3 + 1.7076147010 * s3]
        return channels.map {
            let clipped = min(1, max(0, $0))
            let gamma = clipped <= 0.0031308 ? 12.92 * clipped : 1.055 * pow(clipped, 1 / 2.4) - 0.055
            return UInt8(min(255, max(0, (gamma * 255).rounded())))
        }
    }
}
