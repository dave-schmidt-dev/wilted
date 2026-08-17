// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "SpeechIPCProbe",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "SpeechIPCProbeCore", targets: ["SpeechIPCProbeCore"]),
        .executable(name: "speech-ipc-probe", targets: ["speech-ipc-probe"]),
    ],
    targets: [
        .target(name: "SpeechIPCProbeCore"),
        .executableTarget(name: "speech-ipc-probe", dependencies: ["SpeechIPCProbeCore"]),
        .testTarget(name: "SpeechIPCProbeCoreTests", dependencies: ["SpeechIPCProbeCore"]),
    ]
)
