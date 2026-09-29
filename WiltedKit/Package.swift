// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "WiltedKit",
    platforms: [
        .macOS(.v14),
        .iOS(.v17),
    ],
    products: [
        .library(name: "WiltedDomain", targets: ["WiltedDomain"]),
        .library(name: "WiltedSync", targets: ["WiltedSync"]),
        .library(name: "WiltedLibrary", targets: ["WiltedLibrary"]),
        .library(name: "WiltedSyncTesting", targets: ["WiltedSyncTesting"]),
    ],
    targets: [
        .target(name: "WiltedDomain"),
        .target(name: "WiltedSync", dependencies: ["WiltedDomain"]),
        .target(name: "WiltedLibrary", dependencies: ["WiltedDomain"]),
        .target(name: "WiltedSyncTesting", dependencies: ["WiltedSync"]),
        .testTarget(
            name: "WiltedDomainTests",
            dependencies: ["WiltedDomain"],
            resources: [.copy("Fixtures")]
        ),
        .testTarget(
            name: "WiltedLibraryTests",
            dependencies: ["WiltedDomain", "WiltedLibrary"]
        ),
        .testTarget(
            name: "WiltedSyncTests",
            dependencies: ["WiltedDomain", "WiltedSync", "WiltedSyncTesting"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
