// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "AudioContractProbe",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .library(name: "AudioContractProbeCore", targets: ["AudioContractProbeCore"]),
        .executable(name: "audio-contract-probe", targets: ["audio-contract-probe"]),
    ],
    targets: [
        .target(name: "AudioContractProbeCore"),
        .executableTarget(
            name: "audio-contract-probe",
            dependencies: ["AudioContractProbeCore"]
        ),
        .testTarget(
            name: "AudioContractProbeCoreTests",
            dependencies: ["AudioContractProbeCore"]
        ),
    ]
)
