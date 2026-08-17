// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "PersistenceProbe",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "PersistenceProbeCore", targets: ["PersistenceProbeCore"]),
        .executable(name: "persistence-probe", targets: ["persistence-probe"]),
    ],
    targets: [
        .target(name: "PersistenceProbeCore"),
        .executableTarget(name: "persistence-probe", dependencies: ["PersistenceProbeCore"]),
        .testTarget(name: "PersistenceProbeCoreTests", dependencies: ["PersistenceProbeCore"]),
    ]
)
