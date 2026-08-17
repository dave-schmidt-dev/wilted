// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "ArticleExtractionProbe",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "ArticleExtractionProbeCore", targets: ["ArticleExtractionProbeCore"]),
        .executable(name: "article-extraction-probe", targets: ["article-extraction-probe"]),
    ],
    targets: [
        .target(name: "ArticleExtractionProbeCore"),
        .executableTarget(
            name: "article-extraction-probe",
            dependencies: ["ArticleExtractionProbeCore"]
        ),
        .testTarget(
            name: "ArticleExtractionProbeCoreTests",
            dependencies: ["ArticleExtractionProbeCore"]
        ),
    ]
)
