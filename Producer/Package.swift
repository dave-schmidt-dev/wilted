// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "WiltedProducer",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "WiltedProducer", targets: ["WiltedProducer"]),
        .executable(name: "wilted-podcast-import", targets: ["wilted-podcast-import"]),
    ],
    dependencies: [
        .package(path: "../WiltedKit"),
    ],
    targets: [
        .target(
            name: "WiltedProducer",
            dependencies: [
                .product(name: "WiltedDomain", package: "WiltedKit"),
                .product(name: "WiltedSync", package: "WiltedKit"),
            ]
        ),
        .executableTarget(
            name: "wilted-podcast-import",
            dependencies: [
                "WiltedProducer",
                .product(name: "WiltedDomain", package: "WiltedKit"),
            ]
        ),
        .testTarget(
            name: "WiltedProducerTests",
            dependencies: [
                "WiltedProducer",
                .product(name: "WiltedDomain", package: "WiltedKit"),
                .product(name: "WiltedSync", package: "WiltedKit"),
            ]
        ),
    ]
)
