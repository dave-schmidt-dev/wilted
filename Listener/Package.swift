// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "WiltedListener",
    platforms: [.macOS(.v14), .iOS(.v26)],
    products: [.library(name: "WiltedListener", targets: ["WiltedListener"])],
    dependencies: [.package(path: "../WiltedKit"), .package(path: "../Playback")],
    targets: [
        .target(name: "WiltedListener", dependencies: [.product(name: "WiltedDomain", package: "WiltedKit"), .product(name: "WiltedSync", package: "WiltedKit"), .product(name: "WiltedPlayback", package: "Playback")]),
        .testTarget(name: "WiltedListenerTests", dependencies: ["WiltedListener", .product(name: "WiltedDomain", package: "WiltedKit"), .product(name: "WiltedSync", package: "WiltedKit")]),
    ]
)
