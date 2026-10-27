// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "SafeSpace",
    platforms: [.macOS(.v13), .iOS(.v17)],
    products: [
        .library(name: "SafeSpaceCore", targets: ["SafeSpaceCore"]),
        .executable(name: "safespace-cli", targets: ["safespace-cli"])
    ],
    targets: [
        .target(name: "CStbImage"),
        .target(name: "SafeSpaceCore", dependencies: ["CStbImage"]),
        .executableTarget(name: "safespace-cli", dependencies: ["SafeSpaceCore"]),
        .testTarget(name: "SafeSpaceCoreTests", dependencies: ["SafeSpaceCore"])
    ]
)
