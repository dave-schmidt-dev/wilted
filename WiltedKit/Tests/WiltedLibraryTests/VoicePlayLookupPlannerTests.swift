import Foundation
import WiltedDomain
import XCTest
@testable import WiltedLibrary

/// `playEpisode(title:show:)` and `playLatest(show:)`; rows are in docs/siri-voice-commands.md.
final class VoicePlayLookupPlannerTests: XCTestCase {
    private func item(_ id: String) -> ItemID {
        try! ItemID(rawValue: "item-\(id)")
    }

    private func episode(_ id: String, _ title: String, _ show: String, day: Int = 0) -> VoiceEpisode {
        VoiceEpisode(
            id: item(id), title: title, showTitle: show,
            publishedAt: Date(timeIntervalSince1970: Double(day) * 86_400)
        )
    }

    private var snapshot: VoiceSnapshot {
        VoiceSnapshot(
            downloaded: [
                episode("1", "The Gold Rush", "Planet Money", day: 10),
                episode("2", "Why Chips Are Scarce", "Planet Money", day: 30),
                episode("3", "Gold Rush Redux", "Short Wave", day: 20),
                episode("4", "Tide Pools", "Short Wave", day: 20),
            ],
            knownShowTitles: ["Planet Money", "Short Wave", "Empty Show"],
            nowPlaying: nil
        )
    }

    private func plan(_ command: VoiceCommand, _ snap: VoiceSnapshot? = nil) -> VoicePlan {
        VoiceCommandPlanner.plan(command, snapshot: snap ?? snapshot)
    }

    // MARK: playEpisode

    func testEpisodeByExactTitle() {
        let result = plan(.playEpisode(title: "Tide Pools", show: nil))
        XCTAssertEqual(result.action, .play(item("4")))
        XCTAssertEqual(result.dialog, "Playing Tide Pools.")
        XCTAssertFalse(result.needsConfirmation)
    }

    func testEpisodeByLooseSpokenTitle() {
        XCTAssertEqual(plan(.playEpisode(title: "why chips are scarce", show: nil)).action, .play(item("2")))
        XCTAssertEqual(plan(.playEpisode(title: "gold rush", show: "planet money")).action, .play(item("1")))
    }

    func testEpisodeTitleScopedToShowIgnoresOtherShows() {
        let result = plan(.playEpisode(title: "Tide Pools", show: "Planet Money"))
        XCTAssertEqual(result.action, .none)
        XCTAssertEqual(result.dialog, "I can't find an episode called Tide Pools on your phone.")
    }

    func testEpisodeTitleNoMatch() {
        let result = plan(.playEpisode(title: "Quantum Sandwiches", show: nil))
        XCTAssertEqual(result.action, .none)
        XCTAssertEqual(result.dialog, "I can't find an episode called Quantum Sandwiches on your phone.")
    }

    func testEpisodeTitleAmbiguousAcrossShows() {
        let result = plan(.playEpisode(title: "rush", show: nil))
        XCTAssertEqual(result.action, .none)
        XCTAssertEqual(result.dialog, "Did you mean The Gold Rush or Gold Rush Redux?")
    }

    func testEpisodeSameTitleTwiceTakesFirstLarderRow() {
        let snap = VoiceSnapshot(
            downloaded: [episode("a", "Rerun", "Show"), episode("b", "Rerun", "Show")],
            knownShowTitles: ["Show"], nowPlaying: nil
        )
        XCTAssertEqual(plan(.playEpisode(title: "Rerun", show: nil), snap).action, .play(item("a")))
    }

    func testEpisodeShowUnknownAmbiguousOrEmpty() {
        XCTAssertEqual(
            plan(.playEpisode(title: "Tide Pools", show: "Nonexistent Pod")).dialog,
            "I can't find a show called Nonexistent Pod."
        )
        XCTAssertEqual(
            plan(.playEpisode(title: "x", show: "Empty Show")).dialog,
            "No Empty Show episodes are on your phone."
        )
        let ambiguous = VoiceSnapshot(
            downloaded: [episode("a", "One", "The Daily"), episode("b", "Two", "Daily")],
            knownShowTitles: ["The Daily", "Daily"], nowPlaying: nil
        )
        XCTAssertEqual(
            plan(.playEpisode(title: "One", show: "daily,"), ambiguous).dialog,
            "Did you mean The Daily or Daily?"
        )
    }

    func testEpisodeNothingDownloaded() {
        let empty = VoiceSnapshot(downloaded: [], knownShowTitles: [], nowPlaying: nil)
        let result = plan(.playEpisode(title: "Tide Pools", show: nil), empty)
        XCTAssertEqual(result.action, .none)
        XCTAssertEqual(result.dialog, "No episodes are on your phone.")
    }

    func testEpisodePlayingOneStillPlansPlay() {
        let playing = VoiceNowPlaying(episode: episode("2", "Why Chips Are Scarce", "Planet Money"), isPlaying: true, canMarkCompleted: true)
        let snap = VoiceSnapshot(downloaded: snapshot.downloaded, knownShowTitles: snapshot.knownShowTitles, nowPlaying: playing)
        XCTAssertEqual(plan(.playEpisode(title: "Why Chips Are Scarce", show: nil), snap).action, .play(item("2")))
    }

    func testEpisodeByIDPlaysThatExactEpisodeEvenWithEqualTitles() {
        let snap = VoiceSnapshot(
            downloaded: [episode("a", "Rerun", "Show"), episode("b", "Rerun", "Show")],
            knownShowTitles: ["Show"], nowPlaying: nil
        )
        XCTAssertEqual(plan(.playEpisodeByID(item("b")), snap).action, .play(item("b")))
        let missing = plan(.playEpisodeByID(item("zzz")), snap)
        XCTAssertEqual(missing.action, .none)
        XCTAssertEqual(missing.dialog, "That episode isn't on your phone.")
    }

    // MARK: playLatest

    func testLatestOverallIsNewestPublished() {
        let result = plan(.playLatest(show: nil))
        XCTAssertEqual(result.action, .play(item("2")))
        XCTAssertEqual(result.dialog, "Playing Why Chips Are Scarce.")
    }

    func testLatestOfShow() {
        XCTAssertEqual(plan(.playLatest(show: "short wave")).action, .play(item("3")), "tie keeps the earlier Larder row")
        XCTAssertEqual(plan(.playLatest(show: "Planet Money")).action, .play(item("2")))
    }

    func testLatestShowUnknownAmbiguousOrEmpty() {
        XCTAssertEqual(plan(.playLatest(show: "Nonexistent Pod")).dialog, "I can't find a show called Nonexistent Pod.")
        XCTAssertEqual(plan(.playLatest(show: "Empty Show")).dialog, "No Empty Show episodes are on your phone.")
        let empty = VoiceSnapshot(downloaded: [], knownShowTitles: [], nowPlaying: nil)
        let result = plan(.playLatest(show: nil), empty)
        XCTAssertEqual(result.action, .none)
        XCTAssertEqual(result.dialog, "No episodes are on your phone.")
    }

    func testLatestWithUnknownDatesFallsBackToFirstRow() {
        let snap = VoiceSnapshot(
            downloaded: [
                VoiceEpisode(id: item("a"), title: "A", showTitle: "S"),
                VoiceEpisode(id: item("b"), title: "B", showTitle: "S"),
            ],
            knownShowTitles: ["S"], nowPlaying: nil
        )
        XCTAssertEqual(plan(.playLatest(show: nil), snap).action, .play(item("a")))
    }

    // MARK: playFirst (the app's play order, never `publishedAt`)

    func testPlayFirstTakesTheFirstCandidateInPlayOrderNotTheNewest() {
        let overall = plan(.playFirst(show: nil))
        let newest = plan(.playLatest(show: nil))
        XCTAssertNotEqual(overall.action, newest.action, "the fixture's newest is not its first row")
        XCTAssertEqual(overall.action, .play(item("1")))
        XCTAssertEqual(plan(.playFirst(show: "Planet Money")).action, .play(item("1")))
        XCTAssertEqual(plan(.playFirst(show: "short wave")).action, .play(item("3")))
    }

    func testPlayFirstShowUnknownAmbiguousOrEmpty() {
        XCTAssertEqual(plan(.playFirst(show: "Nonexistent Pod")).dialog, "I can't find a show called Nonexistent Pod.")
        XCTAssertEqual(plan(.playFirst(show: "Empty Show")).dialog, "No Empty Show episodes are on your phone.")
        let empty = VoiceSnapshot(downloaded: [], knownShowTitles: [], nowPlaying: nil)
        let result = plan(.playFirst(show: nil), empty)
        XCTAssertEqual(result.action, .none)
        XCTAssertEqual(result.dialog, "No episodes are on your phone.")
    }
}
