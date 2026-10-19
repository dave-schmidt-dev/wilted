// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "WiltedKit",
    platforms: [
        .macOS(.v14),
        .iOS(.v26),
    ],
    products: [
        .library(name: "WiltedDomain", targets: ["WiltedDomain"]),
        .library(name: "WiltedLibrary", targets: ["WiltedLibrary"]),
        .library(name: "WiltedCatalog", targets: ["WiltedCatalog"]),
        .library(name: "WiltedWeather", targets: ["WiltedWeather"]),
    ],
    targets: [
        .target(name: "WiltedDomain"),
        .target(name: "WiltedLibrary", dependencies: ["WiltedDomain"]),
        .target(name: "WiltedCatalog"),
        .target(name: "WiltedWeather", dependencies: ["WiltedLibrary"]),
        .testTarget(
            name: "WiltedWeatherTests",
            dependencies: ["WiltedWeather", "WiltedLibrary"],
            resources: [.copy("Fixtures")]
        ),
        .testTarget(name: "WiltedCatalogTests", dependencies: ["WiltedCatalog"]),
        .testTarget(
            name: "WiltedDomainTests",
            dependencies: ["WiltedDomain"],
            resources: [.copy("Fixtures")]
        ),
        .testTarget(
            name: "WiltedLibraryTests",
            dependencies: ["WiltedDomain", "WiltedLibrary"]
        ),
    ]
)
