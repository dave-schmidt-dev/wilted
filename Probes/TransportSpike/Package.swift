// swift-tools-version: 6.0

import PackageDescription

// Throwaway spike: measures CloudKit transfer and handoff transports.
// SpikeCore is transport-neutral and must never import CloudKit; SpikeCloudKit is the CloudKit side.
let package = Package(
    name: "TransportSpike",
    platforms: [
        .macOS(.v14),
        .iOS(.v17),
    ],
    products: [
        .library(name: "SpikeCore", targets: ["SpikeCore"]),
        .library(name: "SpikeCloudKit", targets: ["SpikeCloudKit"]),
    ],
    targets: [
        .target(name: "SpikeCore"),
        .target(name: "SpikeCloudKit", dependencies: ["SpikeCore"]),
        .testTarget(name: "SpikeCoreTests", dependencies: ["SpikeCore"]),
        .testTarget(name: "SpikeCloudKitTests", dependencies: ["SpikeCloudKit", "SpikeCore"]),
    ]
)
