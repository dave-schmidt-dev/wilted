import Foundation
import XCTest
@testable import WiltediOS

/// The build's extracted App Intents metadata (`Metadata.appintents/extract.actionsdata` in the
/// app bundle the tests are hosted in): every intent and entity is exported, and every App Shortcut
/// phrase names the app, as Siri requires. An intent that compiles but is missing here is invisible
/// to Siri and Shortcuts.
final class AppIntentsMetadataTests: XCTestCase {
    private static let intents: Set<String> = [
        "PlayNextEpisodeIntent", "PlayEpisodeIntent", "PlayLatestIntent", "PauseEpisodeIntent",
        "ResumeEpisodeIntent", "SkipForwardIntent", "SkipBackIntent", "RestartEpisodeIntent",
        "MarkCompletedIntent", "WhatsPlayingIntent", "ListDownloadedIntent",
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
        let actions = Set(try XCTUnwrap(metadata["actions"] as? [String: Any]).keys)
        XCTAssertEqual(actions, Self.intents, "exported intents differ from the expected set")
        let entities = Set(try XCTUnwrap(metadata["entities"] as? [String: Any]).keys)
        XCTAssertEqual(entities, ["ShowEntity", "EpisodeEntity"])
        let queries = Set(try XCTUnwrap(metadata["queries"] as? [String: Any]).keys)
        XCTAssertEqual(queries, ["ShowEntityQuery", "EpisodeEntityQuery"])
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
            withPhrases, Self.intents.subtracting(["PauseEpisodeIntent", "ResumeEpisodeIntent"]),
            "pause and resume are voiced by Siri's own transport commands, every other intent has a phrase")
    }
}
