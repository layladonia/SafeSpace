import Foundation
import SafeSpaceCore

// Separate command mode; preserves the existing single-method CLI.
enum PaletteComparisonCommand {
    static func run(_ args: [String]) throws -> Bool {
        guard args.first == "--compare" else { return false }
        guard args.count == 4 else {
            throw CommandError.usage("Usage: safespace-cli --compare <image-folder> <manifest.txt> <output-folder>")
        }
        let directory = URL(fileURLWithPath: args[1], isDirectory: true)
        let manifest = try String(contentsOfFile: args[2], encoding: .utf8)
        let names = manifest.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
        guard names.count == 10, Set(names).count == 10,
              names.allSatisfy({ ($0 as NSString).lastPathComponent == $0 && $0 != "." && $0 != ".." }) else {
            throw CommandError.usage("Manifest must contain exactly 10 distinct basenames.")
        }
        let destination = URL(fileURLWithPath: args[3], isDirectory: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let params = PaletteParams.v1
        let methods: [PaletteMethod] = [.kmeansPP, .medianCut]
        var rows = [["image", "method", "status", "width", "height", "colors", "dropped_share",
                     "median_extract_ms", "same_seed_identical_3_runs", "mean_nearest_oklab_error",
                     "seed_sensitivity_chamfer_oklab", "palette_hex_and_shares", "error"]]
        var failures = false
        for (imageIndex, name) in names.enumerated() {
            let copy: WorkingCopy
            do { copy = try ImageLoader.load(url: directory.appendingPathComponent(name)) }
            catch {
                failures = true
                for method in methods {
                    rows.append([name, method.rawValue, "load_failed", "", "", "", "", "", "", "", "", "", String(describing: error)])
                }
                continue
            }
            let image = copy.image
            let mask = EligibilityMask.all(width: image.width, height: image.height)
            // Alternate execution order across images to reduce systematic order bias.
            let ordered = imageIndex % 2 == 0 ? methods : Array(methods.reversed())
            for method in ordered {
                do {
                    let extractor = makePaletteExtractor(method)
                    _ = try extractor.extract(image, mask: mask, params: params) // untimed warm-up
                    var first: PaletteOutput?
                    var durations: [Double] = []
                    var identical = true
                    for _ in 0..<3 {
                        let start = DispatchTime.now().uptimeNanoseconds
                        let output = try extractor.extract(image, mask: mask, params: params)
                        let end = DispatchTime.now().uptimeNanoseconds
                        durations.append(Double(end - start) / 1_000_000)
                        if let baseline = first {
                            identical = identical && baseline.result == output.result && baseline.labelMap == output.labelMap
                        } else { first = output }
                    }
                    guard let output = first else { throw CommandError.usage("Missing extraction output") }
                    var sensitivity = 0.0
                    for seed in [params.seed &+ 1, params.seed &+ 2] {
                        var alternative = params
                        alternative.seed = seed
                        let other = try extractor.extract(image, mask: mask, params: alternative)
                        sensitivity += chamfer(output.result, other.result) / 2
                    }
                    let error = try reconstructionError(image, mask: mask, result: output.result)
                    let palette = output.result.colors.map { "\($0.hex):\($0.share)" }.joined(separator: ";")
                    rows.append([name, method.rawValue, "ok", String(image.width), String(image.height),
                                 String(output.result.colors.count), String(output.result.droppedShare),
                                 String(durations.sorted()[1]), String(identical), String(error),
                                 String(sensitivity), palette, ""])
                    let base = "\((name as NSString).deletingPathExtension)-\(method.rawValue)"
                    try AssessmentJSON.encoder().encode(output.result).write(
                        to: destination.appendingPathComponent(base + ".json"), options: .atomic)
                    try Data(output.labelMap).write(to: destination.appendingPathComponent(base + ".labels.bin"), options: .atomic)
                    if !identical { failures = true }
                } catch is CancellationError { throw CancellationError() }
                catch {
                    failures = true
                    rows.append([name, method.rawValue, "extract_failed", String(image.width), String(image.height),
                                 "", "", "", "", "", "", "", String(describing: error)])
                }
            }
        }
        let csv = rows.map { $0.map(csvCell).joined(separator: ",") }.joined(separator: "\n") + "\n"
        try csv.write(to: destination.appendingPathComponent("comparison.csv"), atomically: true, encoding: .utf8)
        let metadata = Metadata(coreVersion: SafeSpaceCore.version,
            os: ProcessInfo.processInfo.operatingSystemVersionString,
            processorCount: ProcessInfo.processInfo.processorCount,
            createdAt: Date(), params: params, images: names,
            notes: "Native Swift. Fallback disabled. One warm-up, three timed extractions. Loading, metrics and serialization excluded from timing. Seed probe: base, base+1, base+2. Error uses nearest retained OKLab centroid over all eligible pixels; not object contrast or accuracy ground truth.")
        let encoder = AssessmentJSON.encoder()
        try encoder.encode(metadata).write(to: destination.appendingPathComponent("run-metadata.json"), options: .atomic)
        print("Saved \(rows.count - 1) method rows to \(destination.path)/comparison.csv")
        if failures { throw CommandError.usage("Table saved, but one or more rows failed or were not repeatable. Inspect comparison.csv.") }
        return true
    }
    private struct Metadata: Encodable {
        let coreVersion: String
        let os: String
        let processorCount: Int
        let createdAt: Date
        let params: PaletteParams
        let images: [String]
        let notes: String
    }
    enum CommandError: Error, LocalizedError {
        case usage(String)
        var errorDescription: String? { if case .usage(let text) = self { return text }; return nil }
    }
    private static func csvCell(_ value: String) -> String {
        "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }
    private static func distance(_ a: LabValue, _ b: LabValue) -> Double {
        sqrt(pow(a.l - b.l, 2) + pow(a.a - b.a, 2) + pow(a.b - b.b, 2))
    }
    private static func chamfer(_ a: PaletteResult, _ b: PaletteResult) -> Double {
        func directed(_ a: PaletteResult, _ b: PaletteResult) -> Double {
            let mass = a.colors.reduce(0) { $0 + $1.share }
            return a.colors.reduce(0) { value, color in
                value + color.share * b.colors.map { distance(color.oklab, $0.oklab) }.min()!
            } / mass
        }
        return (directed(a, b) + directed(b, a)) / 2
    }
    private static func reconstructionError(_ image: SRGBImage, mask: EligibilityMask,
                                            result: PaletteResult) throws -> Double {
        var histogram: [UInt32: Int] = [:]
        for i in mask.eligible.indices where mask.eligible[i] {
            if i % 8192 == 0 { try Task.checkCancellation() }
            let p = i * 4
            let key = UInt32(image.rgba[p]) << 16 | UInt32(image.rgba[p + 1]) << 8 | UInt32(image.rgba[p + 2])
            histogram[key, default: 0] += 1
        }
        var sum = 0.0
        for key in histogram.keys.sorted() {
            let lab = ColorSpace.sRGBToOKLab(r: Double((key >> 16) & 255) / 255,
                                            g: Double((key >> 8) & 255) / 255,
                                            b: Double(key & 255) / 255)
            let nearest = result.colors.map {
                sqrt(pow(lab.L - $0.oklab.l, 2) + pow(lab.a - $0.oklab.a, 2) + pow(lab.b - $0.oklab.b, 2))
            }.min()!
            sum += Double(histogram[key]!) * nearest
        }
        return sum / Double(mask.eligibleCount)
    }
}
