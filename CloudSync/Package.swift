// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "WiltedCloudKit",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [.library(name: "WiltedCloudKit", targets: ["WiltedCloudKit"])],
    dependencies: [
        .package(path: "../WiltedKit"),
    ],
    targets: [
        .target(name: "WiltedCloudKit", dependencies: [.product(name: "WiltedSync", package: "WiltedKit")]),
        .testTarget(name: "WiltedCloudKitTests", dependencies: ["WiltedCloudKit"]),
    ]
)
