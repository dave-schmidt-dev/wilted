// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "WiltedPlayback",
    platforms: [.macOS(.v14), .iOS(.v26)],
    products: [.library(name: "WiltedPlayback", targets: ["WiltedPlayback"])],
    targets: [
        .target(name: "WiltedPlayback"),
        .testTarget(name: "WiltedPlaybackTests", dependencies: ["WiltedPlayback"]),
    ]
)
