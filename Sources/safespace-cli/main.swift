import Foundation
import SafeSpaceCore

let args = CommandLine.arguments.dropFirst()
guard let folder = args.first else {
    print("usage: safespace-cli <folder-of-images>")
    exit(1)
}
print("SafeSpace \(SafeSpaceCore.version) — would process: \(folder)")
