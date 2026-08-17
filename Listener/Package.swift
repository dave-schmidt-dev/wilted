// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "WiltedListener",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [.library(name: "WiltedListener", targets: ["WiltedListener"])],
    dependencies: [.package(path: "../WiltedKit")],
    targets: [
        .target(name: "WiltedListener", dependencies: [.product(name: "WiltedDomain", package: "WiltedKit"), .product(name: "WiltedSync", package: "WiltedKit")]),
        .testTarget(name: "WiltedListenerTests", dependencies: ["WiltedListener", .product(name: "WiltedDomain", package: "WiltedKit"), .product(name: "WiltedSync", package: "WiltedKit")]),
    ]
)
