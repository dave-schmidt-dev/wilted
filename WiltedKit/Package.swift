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
    ],
    targets: [
        .target(name: "WiltedDomain"),
        .testTarget(
            name: "WiltedDomainTests",
            dependencies: ["WiltedDomain"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
