import Foundation
import XCTest
@testable import WiltediOS

/// The build's extracted App Intents metadata (`Metadata.appintents/extract.actionsdata` in the
/// app bundle the tests are hosted in): every intent and entity is exported, and every App Shortcut
/// phrase names the app, as Siri requires. An intent that compiles but is missing here is invisible
/// to Siri and Shortcuts.
final class AppIntentsMetadataTests: XCTestCase {
    private static let intents: Set<String> = [
        "PlayNextEpisodeIntent", "PlayEpisodeIntent", "PlayFirstEpisodeIntent", "PauseEpisodeIntent",
        "ResumeEpisodeIntent", "SkipForwardIntent", "SkipBackIntent", "RestartEpisodeIntent",
        "MarkCompletedIntent", "WhatsPlayingIntent", "ListDownloadedIntent",
        "TimeLeftIntent", "SetSpeedIntent", "SleepTimerIntent", "SaveThatIntent",
    ]
    private static let audioSchemaIntents: Set<String> = ["WiltedPlayAudioIntent"]
    private static let testFixtureIntents: Set<String> = [
        "WiltedSiriFixtureSetupIntent", "WiltedSiriFixtureLoadCompletionIntent",
        "WiltedSiriFixtureProbeIntent", "WiltedSiriFixtureAudioSearchProbeIntent",
    ]
    /// Voiced by Siri's own transport commands, so they have no App Shortcut phrase.
    private static let unvoiced: Set<String> = [
        "PauseEpisodeIntent", "ResumeEpisodeIntent", "SkipForwardIntent", "SkipBackIntent",
        "SleepTimerIntent",
    ]

    private func metadata() throws -> [String: Any] {
        let root = try XCTUnwrap(
            Bundle.main.url(forResource: "Metadata", withExtension: "appintents"),
            "the build produced no Metadata.appintents: the AppIntents extraction failed")
        let data = try Data(contentsOf: root.appendingPathComponent("extract.actionsdata"))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    func testEveryIntentAndEntityIsExported() throws {
        let metadata = try metadata()
        let actionMetadata = try XCTUnwrap(metadata["actions"] as? [String: Any])
        let actions = Set(actionMetadata.keys)
        XCTAssertEqual(
            actions, Self.intents.union(Self.audioSchemaIntents).union(Self.testFixtureIntents),
            "exported intents differ from the expected set")
        for identifier in Self.testFixtureIntents {
            let action = try XCTUnwrap(actionMetadata[identifier] as? [String: Any], identifier)
            XCTAssertEqual(action["isDiscoverable"] as? Bool, false, "test-only intent \(identifier) must remain hidden")
        }
        let audioAction = try XCTUnwrap(actionMetadata["WiltedPlayAudioIntent"] as? [String: Any])
        XCTAssertEqual(audioAction["isDiscoverable"] as? Bool, true, "the production audio intent must be discoverable")
        let entities = Set(try XCTUnwrap(metadata["entities"] as? [String: Any]).keys)
        XCTAssertEqual(entities, [
            "ShowEntity", "EpisodeEntity", "WiltedPodcastShowEntity", "WiltedPodcastEpisodeEntity",
            "WiltedWarmupAudioQueueResult",
        ])
        let enums = Set((metadata["enums"] as? [[String: Any]] ?? []).compactMap { $0["identifier"] as? String })
        XCTAssertTrue(enums.isSuperset(of: ["SpeedOption", "SleepTimerOption"]), "exported enums: \(enums.sorted())")
        let queries = Set(try XCTUnwrap(metadata["queries"] as? [String: Any]).keys)
        XCTAssertEqual(queries, ["ShowEntityQuery", "EpisodeEntityQuery", "PodcastShowQuery", "PodcastEpisodeQuery"])
    }

    func testEveryAppShortcutPhraseNamesTheAppAndTheCountIsWithinTheLimit() throws {
        let shortcuts = try XCTUnwrap(try metadata()["autoShortcuts"] as? [[String: Any]])
        XCTAssertLessThanOrEqual(shortcuts.count, 10, "an app may declare at most 10 App Shortcuts")
        XCTAssertFalse(shortcuts.isEmpty)
        for shortcut in shortcuts {
            let action = shortcut["actionIdentifier"] as? String ?? "?"
            XCTAssertTrue(Self.intents.contains(action), "shortcut for an unknown intent \(action)")
            let phrases = (shortcut["phraseTemplates"] as? [[String: Any]] ?? []).compactMap { $0["key"] as? String }
            XCTAssertFalse(phrases.isEmpty, "\(action) has no phrase")
            for phrase in phrases {
                XCTAssertTrue(phrase.contains("${applicationName}"), "\"\(phrase)\" does not name the app")
            }
        }
        let withPhrases = Set(shortcuts.compactMap { $0["actionIdentifier"] as? String })
        XCTAssertEqual(
            withPhrases, Self.intents.subtracting(Self.unvoiced),
            "pause, resume and skip are voiced by Siri's own transport commands and the sleep timer has no shortcut; every other intent has a phrase")
        XCTAssertEqual(shortcuts.count, 10, "App Shortcuts must stay within the system limit")
    }

    func testNoPhraseCollidesWithSiriTransportOrStandsInForResume() throws {
        let shortcuts = try XCTUnwrap(try metadata()["autoShortcuts"] as? [[String: Any]])
        let forbidden = ["pause", "resume", "continue", "stop", "skip"]
        for shortcut in shortcuts {
            let phrases = (shortcut["phraseTemplates"] as? [[String: Any]] ?? []).compactMap { $0["key"] as? String }
            for phrase in phrases {
                let first = phrase.lowercased().split(separator: " ").first.map(String.init) ?? ""
                XCTAssertFalse(forbidden.contains(first), "\"\(phrase)\" starts like a system transport command")
            }
        }
    }

    func testEveryShortcutHasAtLeastTheDocumentedPhrases() throws {
        let shortcuts = try XCTUnwrap(try metadata()["autoShortcuts"] as? [[String: Any]])
        var phraseCount: [String: Int] = [:]
        for shortcut in shortcuts {
            let action = shortcut["actionIdentifier"] as? String ?? "?"
            phraseCount[action] = (shortcut["phraseTemplates"] as? [[String: Any]] ?? []).count
        }
        XCTAssertGreaterThanOrEqual(phraseCount["PlayNextEpisodeIntent"] ?? 0, 4)
        XCTAssertNil(phraseCount["SleepTimerIntent"], "the sleep timer is Shortcuts-app only: Siri sends \"sleep timer\" to the Clock")
        XCTAssertGreaterThanOrEqual(phraseCount["TimeLeftIntent"] ?? 0, 3)
        XCTAssertGreaterThanOrEqual(phraseCount["SetSpeedIntent"] ?? 0, 2)
        let saveThat = try XCTUnwrap(shortcuts.first { ($0["actionIdentifier"] as? String) == "SaveThatIntent" })
        let phrases = (saveThat["phraseTemplates"] as? [[String: Any]] ?? []).compactMap { $0["key"] as? String }
        XCTAssertEqual(phrases, ["Save that in ${applicationName}"], "the save action uses only the app-qualified approved phrase")
    }
}
