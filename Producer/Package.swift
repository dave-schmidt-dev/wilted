// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "WiltedProducer",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "WiltedProducer", targets: ["WiltedProducer"]),
    ],
    dependencies: [
        .package(path: "../WiltedKit"),
    ],
    targets: [
        .target(
            name: "WiltedProducer",
            dependencies: [.product(name: "WiltedDomain", package: "WiltedKit")]
        ),
        .testTarget(
            name: "WiltedProducerTests",
            dependencies: ["WiltedProducer", .product(name: "WiltedDomain", package: "WiltedKit")]
        ),
    ]
)
