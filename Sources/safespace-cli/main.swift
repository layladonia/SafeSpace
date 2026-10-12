import Foundation
import SafeSpaceCore

let args = CommandLine.arguments.dropFirst()
guard let path = args.first else {
    print("usage: safespace-cli <image-file-or-folder>")
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
        .sorted { $0.lastPathComponent < $1.lastPathComponent }
} else {
    imageURLs = [url]
}

for imageURL in imageURLs {
    guard let colors = ImagePipeline.analyze(imageURL: imageURL) else {
        print("\(imageURL.lastPathComponent): failed to analyze")
        continue
    }
    let OKLab = colors.0
    let CIELab = colors.1
    let OKLab1 = OKLab.first.map { "\($0)" } ?? "n/a"
    let CIELab1 = CIELab.first.map { "\($0)" } ?? "n/a"
    print("\(imageURL.lastPathComponent): \(OKLab.count) pixels\nfirst pixel OKLab = \(OKLab1)\nfirst pixel CIELab = \(CIELab1)")
}
