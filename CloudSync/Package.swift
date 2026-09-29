// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "WiltedCloudKit",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .library(name: "WiltedCloudKit", targets: ["WiltedCloudKit"]),
        .library(name: "WiltedCloudKitLibrary", targets: ["WiltedCloudKitLibrary"]),
    ],
    dependencies: [
        .package(path: "../WiltedKit"),
    ],
    targets: [
        .target(name: "WiltedCloudKit", dependencies: [
            .product(name: "WiltedSync", package: "WiltedKit"),
            .product(name: "WiltedDomain", package: "WiltedKit"),
        ]),
        .target(name: "WiltedCloudKitLibrary", dependencies: [
            "WiltedCloudKit",
            .product(name: "WiltedLibrary", package: "WiltedKit"),
            .product(name: "WiltedDomain", package: "WiltedKit"),
        ]),
        .testTarget(name: "WiltedCloudKitTests", dependencies: ["WiltedCloudKit"]),
        .testTarget(name: "WiltedCloudKitLibraryTests", dependencies: [
            "WiltedCloudKitLibrary",
            .product(name: "WiltedLibrary", package: "WiltedKit"),
            .product(name: "WiltedDomain", package: "WiltedKit"),
        ]),
    ]
)
