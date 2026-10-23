import SwiftUI
import WiltedDomain
import XCTest
@testable import WiltedMac

/// The Larder row's listening progress: a started, unfinished episode shows how
/// much is left on its date line, measured on the ready revision's timeline.
@MainActor
final class WiltedMacListeningProgressTests: XCTestCase {
    private func episode(
        playback: TimeInterval, playable: TimeInterval? = 4_286, isPlayed: Bool = false
    ) -> WiltedMacEpisode {
        var episode = WiltedMacEpisode(
            id: "listening-episode", title: "Michael Douglas", feedTitle: "SmartLess", summary: "",
            artworkURL: nil, releasedAt: Date(timeIntervalSince1970: 1_900_000_000),
            publishedAt: Date(timeIntervalSince1970: 1_700_000_000),
            sourceDurationSeconds: 4_620, playableDurationSeconds: playable,
            durationSeconds: playable, playbackSeconds: playback, downloadState: .completed,
            preparationState: .prepared(summary: "Ready"))
        episode.isPlayed = isPlayed
        return episode
    }

    func testAStartedEpisodeShowsTimeLeftOnThePlayableTimeline() {
        let started = episode(playback: 2_240)
        XCTAssertEqual(try XCTUnwrap(WiltedMacListeningProgress.fraction(for: started)), 2_240.0 / 4_286.0, accuracy: 1e-9)
        // 4286 - 2240 = 2046 s, measured against the cut, not the feed's 4620 s.
        XCTAssertEqual(WiltedMacListeningProgress.remainingLabel(for: started), "34m 06s left")
    }

    func testUnstartedFinishedOrUnmeasurableEpisodesShowNothing() {
        for hidden in [
            episode(playback: 0),
            episode(playback: 2_240, isPlayed: true),
            episode(playback: 2_240, playable: nil),
            episode(playback: 2_240, playable: 0),
            episode(playback: .nan),
        ] {
            XCTAssertNil(WiltedMacListeningProgress.fraction(for: hidden))
            XCTAssertNil(WiltedMacListeningProgress.remainingLabel(for: hidden))
        }
    }

    func testAPositionPastTheEndReadsFullAndNothingLeft() {
        let past = episode(playback: 5_000)
        XCTAssertEqual(WiltedMacListeningProgress.fraction(for: past), 1)
        XCTAssertEqual(WiltedMacListeningProgress.remainingLabel(for: past), "0s left")
    }

    func testTheLarderRowDrawsTimeLeftBesideTheDate() throws {
        let model = WiltedMacModel(
            arguments: ["--wilted-ui-fixture-ready"],
            stateDirectoryOverride: wiltedTemporaryDirectory("larder-listening-progress"),
            preferences: WiltedMacTestPreferences.ephemeral())
        let started = episode(playback: 2_240)
        model.installEpisodeForTesting(started)
        model.podcastQueueIDs.append(started.id)
        let row = try XCTUnwrap(model.episodes.first { $0.id == started.id })
        let shown = try WiltedMacHeadless.recognizedText(
            WiltedMacLarderView(model: model, paneMode: .side).larderRow(row, position: 1, count: 1, showsGroupName: false),
            size: CGSize(width: 760, height: 110)).joined(separator: " ")
        XCTAssertTrue(shown.contains("34m 06s left"), shown)
        XCTAssertTrue(shown.contains(row.presentation.publicationLabel), shown)
    }
}
