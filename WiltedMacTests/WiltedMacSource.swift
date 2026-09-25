import Foundation

/// Source text of the Mac app, for tests that assert on it.
///
/// The model and root view used to be two files. They now span `WiltedMac/Models`,
/// `WiltedMac/ViewModel`, and `WiltedMac/Views`. Each accessor joins one area's files
/// in the order their code had in the original file, so an assertion that slices
/// between two markers still finds them in that order. Files added later are
/// appended in name order, so absence checks cover them too. A listed file that is
/// missing throws rather than silently narrowing what a test reads.
enum WiltedMacSource {
    static let modelFiles = [
        "Models/WiltedMacLibraryTypes.swift",
        "Models/WiltedAutomationSettings.swift",
        "Models/WiltedMacEpisodeTypes.swift",
        "Models/WiltedMacProcessingTypes.swift",
        "Models/WiltedMacStartup.swift",
        "ViewModel/WiltedMacModel.swift",
        "ViewModel/WiltedMacModel+Automation.swift",
        "ViewModel/WiltedMacModel+Library.swift",
        "ViewModel/WiltedMacModel+Downloads.swift",
        "ViewModel/WiltedMacModel+Preparation.swift",
        "ViewModel/WiltedMacModel+Subscriptions.swift",
        "ViewModel/WiltedMacModel+Episodes.swift",
        "ViewModel/WiltedMacModel+MenuSearch.swift",
        "ViewModel/WiltedMacModel+Intake.swift",
        "ViewModel/WiltedMacModel+MenuOrdering.swift",
        "ViewModel/WiltedMacModel+Playback.swift",
        "ViewModel/WiltedMacModel+Publication.swift",
        "ViewModel/WiltedMacModel+StoreBootstrap.swift",
        "ViewModel/WiltedMacModel+LibraryLoading.swift",
        "ViewModel/WiltedMacModel+Fixtures.swift",
        "ViewModel/WiltedMacFixtureBackends.swift",
    ]

    static let viewFiles = [
        "Views/WiltedMacRootView.swift",
        "Views/WiltedMacFeedsView.swift",
        "Views/WiltedMacFeedsComponents.swift",
        "Views/WiltedMacMenuView.swift",
        "Views/WiltedMacMenuView+Sections.swift",
        "Views/WiltedMacMenuView+Rows.swift",
        "Views/WiltedMacPlayer.swift",
        "Views/WiltedMacPlayerContent.swift",
        "Views/WiltedMacPlayerContent+Sections.swift",
        "Views/WiltedMacSettingsView.swift",
    ]

    /// The model layer: `WiltedMac/Models` and `WiltedMac/ViewModel`.
    static func model(root: URL) throws -> String {
        try joined(root: root, directories: ["Models", "ViewModel"], ordered: modelFiles)
    }

    /// The Mac views: `WiltedMac/Views`.
    static func views(root: URL) throws -> String {
        try joined(root: root, directories: ["Views"], ordered: viewFiles)
    }

    private static func joined(root: URL, directories: [String], ordered: [String]) throws -> String {
        let app = root.appendingPathComponent("WiltedMac")
        var names = ordered
        for directory in directories {
            let found = try FileManager.default
                .contentsOfDirectory(atPath: app.appendingPathComponent(directory).path)
                .filter { $0.hasSuffix(".swift") }
                .map { "\(directory)/\($0)" }
                .sorted()
            names += found.filter { !ordered.contains($0) }
        }
        return try names
            .map { try String(contentsOf: app.appendingPathComponent($0), encoding: .utf8) }
            .joined(separator: "\n")
    }
}
