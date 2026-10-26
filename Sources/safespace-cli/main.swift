import Foundation
import SafeSpaceCore

// Interim CLI until Task 12: prints each image's palette and checks that `--reruns N`
// extractions give bit-identical JSON and label maps (Task 7 "done when").

var args = Array(CommandLine.arguments.dropFirst())
var reruns = 1
var method = PaletteMethod.kmeansPP
if let flag = args.firstIndex(of: "--reruns") {
    guard flag + 1 < args.count, let n = Int(args[flag + 1]), n >= 1 else {
        print("--reruns needs a whole number of at least 1")
        exit(1)
    }
    reruns = n
    args.removeSubrange(flag...(flag + 1))
}
if let flag = args.firstIndex(of: "--method") {
    guard flag + 1 < args.count, let m = PaletteMethod(rawValue: args[flag + 1]) else {
        print("--method must be kmeans_pp or median_cut")
        exit(1)
    }
    method = m
    args.removeSubrange(flag...(flag + 1))
}
guard let path = args.first else {
    print("usage: safespace-cli <image-file-or-folder> [--reruns N] [--method kmeans_pp|median_cut]")
    exit(1)
}

var isDirectory: ObjCBool = false
guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) else {
    print("No such file or folder: \(path)")
    exit(1)
}

let url = URL(fileURLWithPath: path)
let imageURLs: [URL]
if isDirectory.boolValue {
    imageURLs = ((try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)) ?? [])
        .filter { !$0.lastPathComponent.hasPrefix(".") }
        .sorted { $0.lastPathComponent < $1.lastPathComponent }
} else {
    imageURLs = [url]
}

let encoder = AssessmentJSON.encoder()
let extractor = makePaletteExtractor(method)
var failed = false

for imageURL in imageURLs {
    let name = imageURL.lastPathComponent
    let copy: WorkingCopy
    do {
        copy = try ImageLoader.load(url: imageURL)
    } catch {
        print("\(name): failed to load (\(error))")
        failed = true
        continue
    }
    let image = copy.image
    let mask = EligibilityMask.all(width: image.width, height: image.height)

    var first: (json: Data, labelMap: [UInt8])?
    var identical = true
    var durations: [Double] = []
    var palette: PaletteResult?
    do {
        for _ in 0..<reruns {
            let start = Date()
            let output = try extractor.extract(image, mask: mask, params: .v1)
            durations.append(Date().timeIntervalSince(start) * 1000)
            let json = try encoder.encode(output.result)
            if let first {
                identical = identical && json == first.json && output.labelMap == first.labelMap
            } else {
                first = (json, output.labelMap)
                palette = output.result
            }
        }
    } catch {
        print("\(name): palette extraction failed (\(error))")
        failed = true
        continue
    }

    guard let palette else { continue }
    print("\(name): \(image.width)x\(image.height) \(copy.provenance.original.colorSpace), "
          + "\(palette.colors.count) colors, dropped \(String(format: "%.1f", palette.droppedShare * 100))%, "
          + "median \(Int(durations.sorted()[durations.count / 2])) ms")
    for color in palette.colors {
        let hue = color.oklch.h.map { String(format: "%5.1f", $0) } ?? "    -"
        print(String(format: "  %@ %@ %5.1f%%  L %.3f  C %.3f  h ", color.id, color.hex, color.share * 100,
                     color.oklch.l, color.oklch.c) + hue)
    }
    if reruns > 1 {
        print("  \(reruns) reruns identical: \(identical ? "yes" : "NO")")
        if !identical { failed = true }
    }
}

exit(failed ? 2 : 0)
