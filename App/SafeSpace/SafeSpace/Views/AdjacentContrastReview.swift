import Foundation
import SafeSpaceCore

/// Photo-only screening heuristic. Not a visibility or accessibility standard.
struct AdjacentContrastReview: Sendable {
    static let threshold = 10.0
    static let minimumArea = 100
    static let minimumSharedEdges = 12

    struct Edge: Sendable {
        let x: Int
        let y: Int
        let vertical: Bool
    }

    struct Match: Identifiable, Sendable {
        let id: Int
        let deltaE: Double
        let edges: [Edge]
        let anchor: Edge
    }

    let width: Int
    let height: Int
    let matches: [Match]

    private struct Pair: Hashable {
        let a: Int
        let b: Int
    }

    private struct Boundary {
        var count = 0
        var edges: [Edge] = []
    }

    static func analyze(_ stored: StoredAssessment) throws -> Self? {
        guard stored.record.steps.anonymization.status == .completed,
              let image = stored.image, let mask = stored.mask,
              let labels = stored.labelMap else { return nil }
        let w = image.width, h = image.height
        let n = w * h
        guard w > 0, h > 0, mask.width == w, mask.height == h,
              labels.count == n, mask.eligible.count == n,
              image.rgba.count == n * 4 else { return nil }

        var components = [Int](repeating: -1, count: n)
        var means: [PerceptualColor?] = []
        var queue: [Int] = []
        for seed in 0..<n {
            if seed % 4096 == 0 { try Task.checkCancellation() }
            guard components[seed] == -1, labels[seed] != 255,
                  mask.eligible[seed] else { continue }
            let id = means.count
            let label = labels[seed]
            queue.removeAll(keepingCapacity: true)
            queue.append(seed)
            components[seed] = id
            var head = 0
            func visit(_ p: Int) {
                guard components[p] == -1, labels[p] == label,
                      mask.eligible[p] else { return }
                components[p] = id
                queue.append(p)
            }
            while head < queue.count {
                if head % 4096 == 0 && head > 0 { try Task.checkCancellation() }
                let p = queue[head]
                head += 1
                let x = p % w
                if x > 0 { visit(p - 1) }
                if x + 1 < w { visit(p + 1) }
                if p >= w { visit(p - w) }
                if p < n - w { visit(p + w) }
            }
            guard queue.count >= minimumArea else {
                means.append(nil)
                continue
            }
            var l = 0.0, a = 0.0, b = 0.0
            for (index, p) in queue.enumerated() {
                if index % 4096 == 0 { try Task.checkCancellation() }
                let offset = p * 4
                let lab = ColorSpace.sRGBToCIELAB(
                    r: Double(image.rgba[offset]) / 255,
                    g: Double(image.rgba[offset + 1]) / 255,
                    b: Double(image.rgba[offset + 2]) / 255
                )
                l += lab.L; a += lab.a; b += lab.b
            }
            let size = Double(queue.count)
            means.append(PerceptualColor(L: l / size, a: a / size, b: b / size))
        }

        var boundaries: [Pair: Boundary] = [:]
        func connect(_ p: Int, _ q: Int, at edge: Edge) {
            let a = components[p], b = components[q]
            guard a >= 0, b >= 0, a != b, means[a] != nil, means[b] != nil else { return }
            let pair = Pair(a: min(a, b), b: max(a, b))
            boundaries[pair, default: Boundary()].count += 1
            boundaries[pair, default: Boundary()].edges.append(edge)
        }
        for y in 0..<h {
            if y % 16 == 0 { try Task.checkCancellation() }
            for x in 0..<w {
                let p = y * w + x
                if x + 1 < w { connect(p, p + 1, at: Edge(x: x + 1, y: y, vertical: true)) }
                if y + 1 < h { connect(p, p + w, at: Edge(x: x, y: y + 1, vertical: false)) }
            }
        }

        var hits: [(Pair, Boundary, Double)] = []
        for (pair, boundary) in boundaries where boundary.count >= minimumSharedEdges {
            guard let a = means[pair.a], let b = means[pair.b] else { continue }
            let delta = ColorDifference.ciede2000(a, b)
            if delta.isFinite && delta <= threshold { hits.append((pair, boundary, delta)) }
        }
        hits.sort {
            if $0.1.count != $1.1.count { return $0.1.count > $1.1.count }
            if $0.0.a != $1.0.a { return $0.0.a < $1.0.a }
            return $0.0.b < $1.0.b
        }
        return Self(width: w, height: h, matches: hits.enumerated().map { index, hit in
            Match(id: index + 1, deltaE: hit.2, edges: hit.1.edges,
                  anchor: hit.1.edges[hit.1.count / 2])
        })
    }
}
