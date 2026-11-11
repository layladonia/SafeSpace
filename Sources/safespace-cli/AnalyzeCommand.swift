import Foundation
import SafeSpaceCore

// `safespace-cli analyze` (contract §7): runs AssessmentPipeline.run on each image and writes
// run.json, images.csv, palette.csv, contrast.csv and one assessment.json per image × variant.
enum AnalyzeCommand {
    struct Options {
        var input = ""
        var out = ""
        var method = PaletteMethod.kmeansPP
        var seed: UInt64?
        var manifest: String?
        var noAnonymize = false
        var noQuality = false
        var variants = "none"
        var saveImages = false
    }
    struct ManifestRow { var imageID, roomType, peoplePresent, qualityLabel: String }
    struct Item { var url: URL; var imageID: String; var manifest: ManifestRow? }

    static let imageExtensions: Set<String> = ["jpg", "jpeg", "png", "heic", "heif", "tif", "tiff", "bmp", "gif"]
    static let s1Variants = ["resize_50", "jpeg_q70", "crop_90", "rerun"]

    static func parse(_ args: [String]) throws -> Options {
        var o = Options()
        var positional: [String] = []
        var i = 0
        func value() throws -> String {
            i += 1
            guard i < args.count else { throw CLIError.usage("\(args[i - 1]) needs a value") }
            return args[i]
        }
        while i < args.count {
            switch args[i] {
            case "--out": o.out = try value()
            case "--method":
                guard let m = PaletteMethod(rawValue: try value()) else { throw CLIError.usage("--method must be kmeans_pp or median_cut") }
                o.method = m
            case "--seed":
                guard let s = UInt64(try value()) else { throw CLIError.usage("--seed must be a whole number") }
                o.seed = s
            case "--manifest": o.manifest = try value()
            case "--no-anonymize": o.noAnonymize = true
            case "--no-quality": o.noQuality = true
            case "--variants":
                o.variants = try value()
                guard ["none", "s1"].contains(o.variants) else { throw CLIError.usage("--variants must be none or s1") }
            case "--save-images": o.saveImages = true
            case let flag where flag.hasPrefix("--"): throw CLIError.usage("Unknown option \(flag)")
            default: positional.append(args[i])
            }
            i += 1
        }
        guard positional.count == 1, !o.out.isEmpty else { throw CLIError.usage(usage) }
        o.input = positional[0]
        return o
    }

    static func run(_ args: [String]) async throws -> Int32 {
        let o = try parse(args)
        let startedAt = Date()
        let fm = FileManager.default
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: o.input, isDirectory: &isDirectory) else { throw CLIError.usage("No such file or folder: \(o.input)") }
        let outURL = URL(fileURLWithPath: o.out, isDirectory: true)
        do {
            try fm.createDirectory(at: outURL, withIntermediateDirectories: true)
            guard fm.isWritableFile(atPath: outURL.path) else { throw CLIError.notWritable(o.out) }
        } catch { throw CLIError.notWritable(o.out) }

        var manifestSHA: String?
        var manifestByPath: [String: ManifestRow] = [:]
        if let path = o.manifest {
            let data = try Data(contentsOf: URL(fileURLWithPath: path))
            manifestSHA = SHA256.hex(data)
            manifestByPath = try readManifest(data, base: URL(fileURLWithPath: path).deletingLastPathComponent())
        }

        let inputURL = URL(fileURLWithPath: o.input)
        let candidates = isDirectory.boolValue
            ? try fm.contentsOfDirectory(at: inputURL, includingPropertiesForKeys: nil)
                .filter { !$0.lastPathComponent.hasPrefix(".") }
                .sorted { $0.lastPathComponent < $1.lastPathComponent }
            : [inputURL]
        var items: [Item] = []
        for url in candidates {
            guard imageExtensions.contains(url.pathExtension.lowercased()) else {
                warn("Skipping \(url.lastPathComponent): not an image file")
                continue
            }
            let row = manifestByPath[manifestKey(url)]
            if o.manifest != nil && row == nil { warn("\(url.lastPathComponent) is not in the manifest") }
            items.append(Item(url: url, imageID: row?.imageID ?? url.deletingPathExtension().lastPathComponent, manifest: row))
        }
        let duplicateIDs = Dictionary(grouping: items, by: \.imageID).filter { $0.value.count > 1 }.keys
        guard duplicateIDs.isEmpty else { throw CLIError.usage("Duplicate image_id: \(duplicateIDs.sorted().joined(separator: ", "))") }

        var pipeline = PipelineOptions()
        pipeline.paletteMethod = o.method
        if let seed = o.seed { pipeline.paletteParams.seed = seed }
        pipeline.runQuality = !o.noQuality
        // VisionAnonymizer is Task 21; until then every run uses NoOpAnonymizer and
        // --no-anonymize changes nothing.
        let producer = Producer(kind: "cli", appVersion: nil, coreVersion: SafeSpaceCore.version,
                                device: deviceModel(), os: ProcessInfo.processInfo.operatingSystemVersionString)

        var images = CSV.row(imagesHeader), palettes = CSV.row(paletteHeader)
        let encoder = AssessmentJSON.encoder()
        var failed = false
        for item in items {
            let data: Data
            do { data = try Data(contentsOf: item.url) }
            catch {
                warn("\(item.url.lastPathComponent): could not read (\(error.localizedDescription))")
                failed = true
                for variant in ["original"] + (o.variants == "s1" ? s1Variants : []) {
                    images += CSV.row(failedRow(item, variant))
                }
                continue
            }
            var inputs: [(variant: String, data: Data)] = [("original", data)]
            if o.variants == "s1" {
                do { inputs += try s1Inputs(data) }
                catch {
                    warn("\(item.url.lastPathComponent): could not make S1 variants (\(error.localizedDescription))")
                    failed = true
                    for variant in s1Variants { images += CSV.row(failedRow(item, variant)) }
                }
            }
            for input in inputs {
                let label = "\(item.imageID)/\(input.variant)"
                let output: PipelineOutput
                do {
                    output = try await AssessmentPipeline.run(imageData: input.data, source: .file, roomID: "cli",
                                                              producer: producer, options: pipeline)
                } catch {
                    warn("\(label): \(error.localizedDescription)")
                    failed = true
                    images += CSV.row(failedRow(item, input.variant))
                    continue
                }
                var dir = outURL.appendingPathComponent(item.imageID, isDirectory: true)
                if input.variant != "original" { dir.appendPathComponent(input.variant, isDirectory: true) }
                do {
                    try fm.createDirectory(at: dir, withIntermediateDirectories: true)
                    try AssessmentJSON.encode(output.record).write(to: dir.appendingPathComponent("assessment.json"), options: .atomic)
                    if o.saveImages { try saveImages(output, to: dir) }
                } catch let error as SafeSpaceError {
                    warn("\(label): failed validation\n\(error.localizedDescription)"); failed = true
                    images += CSV.row(failedRow(item, input.variant)); continue
                } catch { throw CLIError.notWritable(dir.path) }
                images += CSV.row(imagesRow(item, input.variant, output))
                for color in output.record.steps.palette.result?.colors ?? [] {
                    palettes += CSV.row([item.imageID, input.variant, String(color.rank), color.id, CSV.number(color.share),
                        color.hex, CSV.number(color.oklab.l), CSV.number(color.oklab.a), CSV.number(color.oklab.b),
                        CSV.number(color.oklch.c), CSV.number(color.oklch.h), CSV.number(color.cielab.l),
                        CSV.number(color.cielab.a), CSV.number(color.cielab.b)])
                }
                let palette = output.record.steps.palette
                print("\(label): palette \(palette.status.rawValue)"
                      + (palette.result.map { ", \($0.colors.count) colors" } ?? ", \(palette.reason?.rawValue ?? "")"))
            }
        }

        let run = RunInfo(coreVersion: SafeSpaceCore.version, startedAt: startedAt, args: Array(CommandLine.arguments.dropFirst()),
                          manifestSha256: manifestSHA, imageCount: items.count)
        do {
            try Data(images.utf8).write(to: outURL.appendingPathComponent("images.csv"), options: .atomic)
            try Data(palettes.utf8).write(to: outURL.appendingPathComponent("palette.csv"), options: .atomic)
            // Contrast measurements come from `safespace-cli contrast` (Task 16); header only for now.
            try Data(CSV.row(contrastHeader).utf8).write(to: outURL.appendingPathComponent("contrast.csv"), options: .atomic)
            try encoder.encode(run).write(to: outURL.appendingPathComponent("run.json"), options: .atomic)
        } catch { throw CLIError.notWritable(o.out) }
        print("Wrote \(items.count) image(s) to \(outURL.path)")
        return failed ? 2 : 0
    }

    struct RunInfo: Encodable {
        let coreVersion: String, startedAt: Date, args: [String], manifestSha256: String?, imageCount: Int
        enum CodingKeys: String, CodingKey { case coreVersion, startedAt, args, manifestSha256, imageCount }
        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(coreVersion, forKey: .coreVersion); try c.encode(startedAt, forKey: .startedAt)
            try c.encode(args, forKey: .args); try c.encode(manifestSha256, forKey: .manifestSha256)
            try c.encode(imageCount, forKey: .imageCount)
        }
    }

    static let imagesHeader = ["image_id", "variant", "file", "room_type", "people_present", "quality_label", "quality_status",
        "quality_warnings", "mean_luminance", "clipped_dark_share", "clipped_bright_share", "blur_laplacian_variance",
        "original_long_side_px", "anonymization_status", "faces_detected", "people_detected", "masked_share",
        "palette_status", "palette_method", "palette_seed", "color_count", "dropped_share", "overall_state",
        "duration_ms", "core_version"]
    static let paletteHeader = ["image_id", "variant", "rank", "color_id", "share", "hex", "oklab_l", "oklab_a", "oklab_b",
        "oklch_c", "oklch_h", "cielab_l", "cielab_a", "cielab_b"]
    static let contrastHeader = ["image_id", "measurement_id", "a_x", "a_y", "a_w", "a_h", "b_x", "b_y", "b_w", "b_h",
        "a_cielab_l", "a_cielab_a", "a_cielab_b", "b_cielab_l", "b_cielab_a", "b_cielab_b", "delta_e_2000"]

    static func imagesRow(_ item: Item, _ variant: String, _ output: PipelineOutput) -> [String] {
        let r = output.record
        let palette = r.steps.palette
        var seed = ""
        if case .object(let params)? = palette.method?.params, case .number(let s)? = params["seed"] { seed = String(UInt64(s)) }
        // Quality cells (Task 19) come from the stored result, so the CSV can't disagree with
        // assessment.json; they stay empty unless the step completed. Warnings are joined with ";"
        // (contract section 7.1). Anonymization cells are Task 21 and stay empty for now.
        let q = r.qualityResult
        return [item.imageID, variant, item.url.lastPathComponent, item.manifest?.roomType ?? "",
                item.manifest?.peoplePresent ?? "", item.manifest?.qualityLabel ?? "", r.steps.quality.status.rawValue,
                q.map { $0.warnings.map(\.rawValue).joined(separator: ";") } ?? "",
                CSV.number(q?.metrics.meanLuminance), CSV.number(q?.metrics.clippedDarkShare),
                CSV.number(q?.metrics.clippedBrightShare), CSV.number(q?.metrics.blurLaplacianVariance),
                String(max(r.image.original.width, r.image.original.height)),
                r.steps.anonymization.status.rawValue, "", "", "",
                palette.status.rawValue, palette.method?.name ?? "", seed,
                palette.result.map { String($0.colors.count) } ?? "", CSV.number(palette.result?.droppedShare),
                r.overallState.rawValue, String(output.totalDurationMs), r.producer.coreVersion]
    }

    /// An image that produced no valid record still gets a row, so evaluation scripts see the gap.
    static func failedRow(_ item: Item, _ variant: String) -> [String] {
        var row = Array(repeating: "", count: imagesHeader.count)
        row[0] = item.imageID; row[1] = variant; row[2] = item.url.lastPathComponent
        row[3] = item.manifest?.roomType ?? ""; row[4] = item.manifest?.peoplePresent ?? ""
        row[5] = item.manifest?.qualityLabel ?? ""; row[imagesHeader.count - 1] = SafeSpaceCore.version
        return row
    }
    /// The four S1 variants (§7), derived from the loaded working copy and re-encoded in memory.
    /// `rerun` is the identical input bytes.
    static func s1Inputs(_ data: Data) throws -> [(variant: String, data: Data)] {
        let image = try ImageLoader.load(data: data, source: .file).image
        return [("resize_50", halved(image).pngData()), ("jpeg_q70", image.jpegData(quality: 70)),
                ("crop_90", centerCrop(image, fraction: 0.9).pngData()), ("rerun", data)]
    }
    /// 2×2 box average in gamma-encoded sRGB, matching the loader's area_average_gamma_encoded.
    static func halved(_ image: SRGBImage) -> SRGBImage {
        let w = max(1, image.width / 2), h = max(1, image.height / 2)
        var out = [UInt8](repeating: 255, count: w * h * 4)
        for y in 0..<h {
            for x in 0..<w {
                for ch in 0..<3 {
                    var sum = 0, n = 0
                    for dy in 0..<2 where y * 2 + dy < image.height {
                        for dx in 0..<2 where x * 2 + dx < image.width {
                            sum += Int(image.rgba[((y * 2 + dy) * image.width + x * 2 + dx) * 4 + ch]); n += 1
                        }
                    }
                    out[(y * w + x) * 4 + ch] = UInt8((sum + n / 2) / n)
                }
            }
        }
        return SRGBImage(width: w, height: h, rgba: out)
    }
    static func centerCrop(_ image: SRGBImage, fraction: Double) -> SRGBImage {
        let w = max(1, Int((Double(image.width) * fraction).rounded())), h = max(1, Int((Double(image.height) * fraction).rounded()))
        let x0 = (image.width - w) / 2, y0 = (image.height - h) / 2
        var out: [UInt8] = []
        out.reserveCapacity(w * h * 4)
        for y in y0..<(y0 + h) { out += image.rgba[((y * image.width + x0) * 4)..<((y * image.width + x0 + w) * 4)] }
        return SRGBImage(width: w, height: h, rgba: out)
    }

    static func saveImages(_ output: PipelineOutput, to dir: URL) throws {
        try output.storedImage?.pngData().write(to: dir.appendingPathComponent("image.png"), options: .atomic)
        try output.mask.pngData().write(to: dir.appendingPathComponent("mask.png"), options: .atomic)
        if let labels = output.labelMap {
            try SRGBImage.labelMapPNG(width: output.mask.width, height: output.mask.height, labels: labels)
                .write(to: dir.appendingPathComponent("labels.png"), options: .atomic)
        }
    }

    /// Maps each manifest row's resolved file path to its row (contract §8; `split` is optional
    /// until the manifest gains it).
    static func readManifest(_ data: Data, base: URL) throws -> [String: ManifestRow] {
        guard let text = String(data: data, encoding: .utf8) else { throw CLIError.usage("Manifest is not UTF-8") }
        let rows = CSV.parse(text)
        guard let header = rows.first else { throw CLIError.usage("Manifest is empty") }
        func column(_ name: String) throws -> Int {
            guard let i = header.firstIndex(of: name) else { throw CLIError.usage("Manifest has no \(name) column") }
            return i
        }
        let id = try column("image_id"), file = try column("filename"), room = try column("room_type")
        let people = try column("people_present"), quality = try column("quality_label")
        var result: [String: ManifestRow] = [:]
        for (n, row) in rows.dropFirst().enumerated() {
            guard row.count == header.count else { throw CLIError.usage("Manifest row \(n + 2) has \(row.count) cells, expected \(header.count)") }
            guard row[id].range(of: "^[A-Za-z0-9_-]+$", options: .regularExpression) != nil else {
                throw CLIError.usage("Manifest row \(n + 2): invalid image_id \"\(row[id])\"")
            }
            result[manifestKey(base.appendingPathComponent(row[file]))] = ManifestRow(imageID: row[id], roomType: row[room], peoplePresent: row[people], qualityLabel: row[quality])
        }
        return result
    }

    /// Folder resolved through symlinks, file name kept exactly as written: filenames must match
    /// with exact case (§8) even on case-insensitive file systems.
    static func manifestKey(_ url: URL) -> String {
        url.deletingLastPathComponent().resolvingSymlinksInPath().appendingPathComponent(url.lastPathComponent).path
    }
    static func deviceModel() -> String {
        #if os(macOS)
        var size = 0
        sysctlbyname("hw.model", nil, &size, nil, 0)
        var model = [CChar](repeating: 0, count: max(size, 1))
        sysctlbyname("hw.model", &model, &size, nil, 0)
        return String(cString: model)
        #else
        return "unknown"
        #endif
    }
    static func warn(_ text: String) { FileHandle.standardError.write(Data((text + "\n").utf8)) }

    static let usage = """
        usage: safespace-cli analyze <image-or-folder> --out <dir> [--method kmeans_pp|median_cut] [--seed N]
                                     [--manifest <manifest.csv>] [--no-anonymize] [--no-quality]
                                     [--variants none|s1] [--save-images]
               safespace-cli validate <assessment.json>...
               safespace-cli version
        """
}

enum CLIError: Error, LocalizedError {
    case usage(String), notWritable(String)
    var errorDescription: String? {
        switch self {
        case .usage(let text): return text
        case .notWritable(let path): return "Output directory is not writable: \(path)"
        }
    }
}
