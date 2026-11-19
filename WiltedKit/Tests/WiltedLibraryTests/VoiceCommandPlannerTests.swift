import Foundation
import WiltedDomain
import XCTest
@testable import WiltedLibrary

final class VoiceCommandPlannerTests: XCTestCase {
    private func item(_ id: String) -> ItemID {
        try! ItemID(rawValue: "item-\(id)")
    }

    private func makeEpisode(id: String, title: String, showTitle: String) -> VoiceEpisode {
        VoiceEpisode(id: item(id), title: title, showTitle: showTitle)
    }

    // MARK: - Row 1: playNext(show) - show given, no title matches

    func testPlayNextShowNoMatch() {
        let snapshot = VoiceSnapshot(
            downloaded: [makeEpisode(id: "1", title: "Ep 1", showTitle: "Planet Money")],
            knownShowTitles: ["Planet Money"],
            nowPlaying: nil
        )
        let plan = VoiceCommandPlanner.plan(.playNext(show: "Unknown Show"), snapshot: snapshot)
        XCTAssertEqual(plan.action, .none)
        XCTAssertEqual(plan.dialog, "I can't find a show called Unknown Show.")
    }

    // MARK: - Row 2: playNext(show) - show given, ambiguous

    func testPlayNextShowAmbiguous() {
        let snapshot = VoiceSnapshot(
            downloaded: [],
            knownShowTitles: ["TechCrunch Daily", "TechCrunch Weekly"],
            nowPlaying: nil
        )
        let plan = VoiceCommandPlanner.plan(.playNext(show: "techcrunch"), snapshot: snapshot)
        XCTAssertEqual(plan.action, .none)
        XCTAssertEqual(plan.dialog, "Did you mean TechCrunch Daily or TechCrunch Weekly?")
    }

    // MARK: - Row 3: playNext(show) - show matched, none downloaded

    func testPlayNextShowMatchedNoneDownloaded() {
        let snapshot = VoiceSnapshot(
            downloaded: [makeEpisode(id: "1", title: "Ep 1", showTitle: "Other Show")],
            knownShowTitles: ["TechCrunch Daily", "Other Show"],
            nowPlaying: nil
        )
        let plan = VoiceCommandPlanner.plan(.playNext(show: "tech crunch daily"), snapshot: snapshot)
        XCTAssertEqual(plan.action, .none)
        XCTAssertEqual(plan.dialog, "No TechCrunch Daily episodes are downloaded.")
    }

    // MARK: - Row 4: playNext(show) - show matched, playing episode is of that show (not last)

    func testPlayNextShowMatchedPlayingEpisodeIsOfThatShow() {
        let ep1 = makeEpisode(id: "1", title: "Show Ep 1", showTitle: "The Daily")
        let ep2 = makeEpisode(id: "2", title: "Show Ep 2", showTitle: "The Daily")
        let snapshot = VoiceSnapshot(
            downloaded: [ep1, ep2],
            knownShowTitles: ["The Daily"],
            nowPlaying: VoiceNowPlaying(episode: ep1, isPlaying: true, canMarkCompleted: false)
        )
        let plan = VoiceCommandPlanner.plan(.playNext(show: "daily"), snapshot: snapshot)
        XCTAssertEqual(plan.action, .play(ep2.id))
        XCTAssertEqual(plan.dialog, "Playing Show Ep 2.")
    }

    // MARK: - Row 5: playNext(show) - show matched, playing episode is the last one of that show

    func testPlayNextShowMatchedPlayingEpisodeIsLastOne() {
        let ep1 = makeEpisode(id: "1", title: "Show Ep 1", showTitle: "The Daily")
        let ep2 = makeEpisode(id: "2", title: "Show Ep 2", showTitle: "The Daily")
        let snapshot = VoiceSnapshot(
            downloaded: [ep1, ep2],
            knownShowTitles: ["The Daily"],
            nowPlaying: VoiceNowPlaying(episode: ep2, isPlaying: true, canMarkCompleted: false)
        )
        let plan = VoiceCommandPlanner.plan(.playNext(show: "daily"), snapshot: snapshot)
        XCTAssertEqual(plan.action, .none)
        XCTAssertEqual(plan.dialog, "That was the last downloaded episode of The Daily.")
    }

    // MARK: - Row 6: playNext(show) - show matched, playing episode is another show (or nothing)

    func testPlayNextShowMatchedPlayingEpisodeIsAnotherShow() {
        let epOther = makeEpisode(id: "1", title: "Other Ep", showTitle: "Other Show")
        let epDaily1 = makeEpisode(id: "2", title: "Daily Ep 1", showTitle: "The Daily")
        let epDaily2 = makeEpisode(id: "3", title: "Daily Ep 2", showTitle: "The Daily")
        let snapshot = VoiceSnapshot(
            downloaded: [epOther, epDaily1, epDaily2],
            knownShowTitles: ["The Daily", "Other Show"],
            nowPlaying: VoiceNowPlaying(episode: epOther, isPlaying: true, canMarkCompleted: false)
        )
        let plan = VoiceCommandPlanner.plan(.playNext(show: "daily"), snapshot: snapshot)
        XCTAssertEqual(plan.action, .play(epDaily1.id))
        XCTAssertEqual(plan.dialog, "Playing Daily Ep 1.")
    }

    func testPlayNextShowMatchedNothingPlaying() {
        let epDaily1 = makeEpisode(id: "1", title: "Daily Ep 1", showTitle: "The Daily")
        let snapshot = VoiceSnapshot(
            downloaded: [epDaily1],
            knownShowTitles: ["The Daily"],
            nowPlaying: nil
        )
        let plan = VoiceCommandPlanner.plan(.playNext(show: "daily"), snapshot: snapshot)
        XCTAssertEqual(plan.action, .play(epDaily1.id))
        XCTAssertEqual(plan.dialog, "Playing Daily Ep 1.")
    }

    // MARK: - Row 7: playNext(nil) - nothing downloaded

    func testPlayNextNilNothingDownloaded() {
        let snapshot = VoiceSnapshot(
            downloaded: [],
            knownShowTitles: [],
            nowPlaying: nil
        )
        let plan = VoiceCommandPlanner.plan(.playNext(show: nil), snapshot: snapshot)
        XCTAssertEqual(plan.action, .none)
        XCTAssertEqual(plan.dialog, "No episodes are downloaded.")
    }

    // MARK: - Row 8: playNext(nil) - otherwise

    func testPlayNextNilPlayingEpisodeHasNext() {
        let ep1 = makeEpisode(id: "1", title: "Episode One", showTitle: "Show A")
        let ep2 = makeEpisode(id: "2", title: "Episode Two", showTitle: "Show B")
        let snapshot = VoiceSnapshot(
            downloaded: [ep1, ep2],
            knownShowTitles: ["Show A", "Show B"],
            nowPlaying: VoiceNowPlaying(episode: ep1, isPlaying: true, canMarkCompleted: false)
        )
        let plan = VoiceCommandPlanner.plan(.playNext(show: nil), snapshot: snapshot)
        XCTAssertEqual(plan.action, .play(ep2.id))
        XCTAssertEqual(plan.dialog, "Playing Episode Two.")
    }

    func testPlayNextNilPlayingEpisodeIsLastOne() {
        let ep1 = makeEpisode(id: "1", title: "Episode One", showTitle: "Show A")
        let ep2 = makeEpisode(id: "2", title: "Episode Two", showTitle: "Show B")
        let snapshot = VoiceSnapshot(
            downloaded: [ep1, ep2],
            knownShowTitles: ["Show A", "Show B"],
            nowPlaying: VoiceNowPlaying(episode: ep2, isPlaying: true, canMarkCompleted: false)
        )
        let plan = VoiceCommandPlanner.plan(.playNext(show: nil), snapshot: snapshot)
        XCTAssertEqual(plan.action, .none)
        XCTAssertEqual(plan.dialog, "That was the last downloaded episode.")
    }

    func testPlayNextNilNothingPlaying() {
        let ep1 = makeEpisode(id: "1", title: "Episode One", showTitle: "Show A")
        let snapshot = VoiceSnapshot(
            downloaded: [ep1],
            knownShowTitles: ["Show A"],
            nowPlaying: nil
        )
        let plan = VoiceCommandPlanner.plan(.playNext(show: nil), snapshot: snapshot)
        XCTAssertEqual(plan.action, .play(ep1.id))
        XCTAssertEqual(plan.dialog, "Playing Episode One.")
    }

    func testPlayNextNilPlayingNotListed() {
        let unlisted = makeEpisode(id: "99", title: "Streamed Ep", showTitle: "Show A")
        let ep1 = makeEpisode(id: "1", title: "Episode One", showTitle: "Show A")
        let snapshot = VoiceSnapshot(
            downloaded: [ep1],
            knownShowTitles: ["Show A"],
            nowPlaying: VoiceNowPlaying(episode: unlisted, isPlaying: true, canMarkCompleted: false)
        )
        let plan = VoiceCommandPlanner.plan(.playNext(show: nil), snapshot: snapshot)
        XCTAssertEqual(plan.action, .play(ep1.id))
        XCTAssertEqual(plan.dialog, "Playing Episode One.")
    }

    // MARK: - Row 9 & 10: pause

    func testPauseWhenPlaying() {
        let ep = makeEpisode(id: "1", title: "Episode One", showTitle: "Show A")
        let snapshot = VoiceSnapshot(
            downloaded: [ep],
            knownShowTitles: ["Show A"],
            nowPlaying: VoiceNowPlaying(episode: ep, isPlaying: true, canMarkCompleted: false)
        )
        let plan = VoiceCommandPlanner.plan(.pause, snapshot: snapshot)
        XCTAssertEqual(plan.action, .pause)
        XCTAssertEqual(plan.dialog, "Paused.")
    }

    func testPauseWhenPaused() {
        let ep = makeEpisode(id: "1", title: "Episode One", showTitle: "Show A")
        let snapshot = VoiceSnapshot(
            downloaded: [ep],
            knownShowTitles: ["Show A"],
            nowPlaying: VoiceNowPlaying(episode: ep, isPlaying: false, canMarkCompleted: false)
        )
        let plan = VoiceCommandPlanner.plan(.pause, snapshot: snapshot)
        XCTAssertEqual(plan.action, .none)
        XCTAssertEqual(plan.dialog, "Nothing is playing.")
    }

    func testPauseWhenNothingLoaded() {
        let snapshot = VoiceSnapshot(downloaded: [], knownShowTitles: [], nowPlaying: nil)
        let plan = VoiceCommandPlanner.plan(.pause, snapshot: snapshot)
        XCTAssertEqual(plan.action, .none)
        XCTAssertEqual(plan.dialog, "Nothing is playing.")
    }

    // MARK: - Row 11, 12, 13: resume

    func testResumeWhenPausedEpisodeLoaded() {
        let ep = makeEpisode(id: "1", title: "Episode One", showTitle: "Show A")
        let snapshot = VoiceSnapshot(
            downloaded: [ep],
            knownShowTitles: ["Show A"],
            nowPlaying: VoiceNowPlaying(episode: ep, isPlaying: false, canMarkCompleted: false)
        )
        let plan = VoiceCommandPlanner.plan(.resume, snapshot: snapshot)
        XCTAssertEqual(plan.action, .resume)
        XCTAssertEqual(plan.dialog, "Resuming Episode One.")
    }

    func testResumeWhenAlreadyPlaying() {
        let ep = makeEpisode(id: "1", title: "Episode One", showTitle: "Show A")
        let snapshot = VoiceSnapshot(
            downloaded: [ep],
            knownShowTitles: ["Show A"],
            nowPlaying: VoiceNowPlaying(episode: ep, isPlaying: true, canMarkCompleted: false)
        )
        let plan = VoiceCommandPlanner.plan(.resume, snapshot: snapshot)
        XCTAssertEqual(plan.action, .none)
        XCTAssertEqual(plan.dialog, "Already playing.")
    }

    func testResumeWhenNothingLoaded() {
        let snapshot = VoiceSnapshot(downloaded: [], knownShowTitles: [], nowPlaying: nil)
        let plan = VoiceCommandPlanner.plan(.resume, snapshot: snapshot)
        XCTAssertEqual(plan.action, .none)
        XCTAssertEqual(plan.dialog, "Nothing to resume.")
    }

    // MARK: - Row 14 & 15: skipForward / skipBack

    func testSkipForwardWhenEpisodeLoaded() {
        let ep = makeEpisode(id: "1", title: "Episode One", showTitle: "Show A")
        let snapshot = VoiceSnapshot(
            downloaded: [ep],
            knownShowTitles: ["Show A"],
            nowPlaying: VoiceNowPlaying(episode: ep, isPlaying: false, canMarkCompleted: false)
        )
        let plan = VoiceCommandPlanner.plan(.skipForward, snapshot: snapshot)
        XCTAssertEqual(plan.action, .skipForward)
        XCTAssertEqual(plan.dialog, "Skipped forward.")
    }

    func testSkipForwardWhenNothingLoaded() {
        let snapshot = VoiceSnapshot(downloaded: [], knownShowTitles: [], nowPlaying: nil)
        let plan = VoiceCommandPlanner.plan(.skipForward, snapshot: snapshot)
        XCTAssertEqual(plan.action, .none)
        XCTAssertEqual(plan.dialog, "Nothing is playing.")
    }

    func testSkipBackWhenEpisodeLoaded() {
        let ep = makeEpisode(id: "1", title: "Episode One", showTitle: "Show A")
        let snapshot = VoiceSnapshot(
            downloaded: [ep],
            knownShowTitles: ["Show A"],
            nowPlaying: VoiceNowPlaying(episode: ep, isPlaying: true, canMarkCompleted: false)
        )
        let plan = VoiceCommandPlanner.plan(.skipBack, snapshot: snapshot)
        XCTAssertEqual(plan.action, .skipBack)
        XCTAssertEqual(plan.dialog, "Skipped back.")
    }

    func testSkipBackWhenNothingLoaded() {
        let snapshot = VoiceSnapshot(downloaded: [], knownShowTitles: [], nowPlaying: nil)
        let plan = VoiceCommandPlanner.plan(.skipBack, snapshot: snapshot)
        XCTAssertEqual(plan.action, .none)
        XCTAssertEqual(plan.dialog, "Nothing is playing.")
    }

    // MARK: - Row 16 & 17: restart

    func testRestartWhenEpisodeLoaded() {
        let ep = makeEpisode(id: "1", title: "Episode One", showTitle: "Show A")
        let snapshot = VoiceSnapshot(
            downloaded: [ep],
            knownShowTitles: ["Show A"],
            nowPlaying: VoiceNowPlaying(episode: ep, isPlaying: false, canMarkCompleted: false)
        )
        let plan = VoiceCommandPlanner.plan(.restart, snapshot: snapshot)
        XCTAssertEqual(plan.action, .restart)
        XCTAssertEqual(plan.dialog, "Starting over.")
    }

    func testRestartWhenNothingLoaded() {
        let snapshot = VoiceSnapshot(downloaded: [], knownShowTitles: [], nowPlaying: nil)
        let plan = VoiceCommandPlanner.plan(.restart, snapshot: snapshot)
        XCTAssertEqual(plan.action, .none)
        XCTAssertEqual(plan.dialog, "Nothing is playing.")
    }

    // MARK: - Row 18, 19, 20: markCompleted

    func testMarkCompletedWhenCanMarkCompleted() {
        let ep = makeEpisode(id: "1", title: "Episode One", showTitle: "Show A")
        let snapshot = VoiceSnapshot(
            downloaded: [ep],
            knownShowTitles: ["Show A"],
            nowPlaying: VoiceNowPlaying(episode: ep, isPlaying: true, canMarkCompleted: true)
        )
        let plan = VoiceCommandPlanner.plan(.markCompleted, snapshot: snapshot)
        XCTAssertEqual(plan.action, .markCompleted(ep.id))
        XCTAssertEqual(plan.dialog, "Marked Episode One completed.", "the line names the episode: no question guards it")
    }

    func testMarkCompletedWhenCannotYet() {
        let ep = makeEpisode(id: "1", title: "Episode One", showTitle: "Show A")
        let snapshot = VoiceSnapshot(
            downloaded: [ep],
            knownShowTitles: ["Show A"],
            nowPlaying: VoiceNowPlaying(episode: ep, isPlaying: true, canMarkCompleted: false)
        )
        let plan = VoiceCommandPlanner.plan(.markCompleted, snapshot: snapshot)
        XCTAssertEqual(plan.action, .none)
        XCTAssertEqual(plan.dialog, "I can't mark that completed yet.")
    }

    func testMarkCompletedWhenNothingLoaded() {
        let snapshot = VoiceSnapshot(downloaded: [], knownShowTitles: [], nowPlaying: nil)
        let plan = VoiceCommandPlanner.plan(.markCompleted, snapshot: snapshot)
        XCTAssertEqual(plan.action, .none)
        XCTAssertEqual(plan.dialog, "Nothing is playing.")
    }

    // MARK: - Row 21 & 22: whatsPlaying

    func testWhatsPlayingWhenEpisodeLoadedWithShow() {
        let ep = makeEpisode(id: "1", title: "Episode One", showTitle: "The Daily")
        let snapshot = VoiceSnapshot(
            downloaded: [ep],
            knownShowTitles: ["The Daily"],
            nowPlaying: VoiceNowPlaying(episode: ep, isPlaying: true, canMarkCompleted: false)
        )
        let plan = VoiceCommandPlanner.plan(.whatsPlaying, snapshot: snapshot)
        XCTAssertEqual(plan.action, .none)
        XCTAssertEqual(plan.dialog, "Episode One, from The Daily.")
    }

    func testWhatsPlayingWhenEpisodeLoadedWithoutShow() {
        let ep = makeEpisode(id: "1", title: "Standalone Episode", showTitle: "")
        let snapshot = VoiceSnapshot(
            downloaded: [ep],
            knownShowTitles: [],
            nowPlaying: VoiceNowPlaying(episode: ep, isPlaying: false, canMarkCompleted: false)
        )
        let plan = VoiceCommandPlanner.plan(.whatsPlaying, snapshot: snapshot)
        XCTAssertEqual(plan.action, .none)
        XCTAssertEqual(plan.dialog, "Standalone Episode.")
    }

    func testWhatsPlayingWhenNothingLoaded() {
        let snapshot = VoiceSnapshot(downloaded: [], knownShowTitles: [], nowPlaying: nil)
        let plan = VoiceCommandPlanner.plan(.whatsPlaying, snapshot: snapshot)
        XCTAssertEqual(plan.action, .none)
        XCTAssertEqual(plan.dialog, "Nothing is playing.")
    }

    // MARK: - Row 23 & 24: listDownloaded

    func testListDownloadedWhenEmpty() {
        let snapshot = VoiceSnapshot(downloaded: [], knownShowTitles: [], nowPlaying: nil)
        let plan = VoiceCommandPlanner.plan(.listDownloaded, snapshot: snapshot)
        XCTAssertEqual(plan.action, .none)
        XCTAssertEqual(plan.dialog, "No episodes are downloaded.")
    }

    func testListDownloadedWithOneEpisode() {
        let ep1 = makeEpisode(id: "1", title: "Ep 1", showTitle: "Show")
        let snapshot = VoiceSnapshot(downloaded: [ep1], knownShowTitles: [], nowPlaying: nil)
        let plan = VoiceCommandPlanner.plan(.listDownloaded, snapshot: snapshot)
        XCTAssertEqual(plan.action, .none)
        XCTAssertEqual(plan.dialog, "1 episode downloaded: Ep 1.")
    }

    func testListDownloadedWithTwoEpisodes() {
        let ep1 = makeEpisode(id: "1", title: "Ep 1", showTitle: "Show")
        let ep2 = makeEpisode(id: "2", title: "Ep 2", showTitle: "Show")
        let snapshot = VoiceSnapshot(downloaded: [ep1, ep2], knownShowTitles: [], nowPlaying: nil)
        let plan = VoiceCommandPlanner.plan(.listDownloaded, snapshot: snapshot)
        XCTAssertEqual(plan.action, .none)
        XCTAssertEqual(plan.dialog, "2 episodes downloaded: Ep 1, Ep 2.")
    }

    func testListDownloadedWithThreeEpisodes() {
        let ep1 = makeEpisode(id: "1", title: "Ep 1", showTitle: "Show")
        let ep2 = makeEpisode(id: "2", title: "Ep 2", showTitle: "Show")
        let ep3 = makeEpisode(id: "3", title: "Ep 3", showTitle: "Show")
        let snapshot = VoiceSnapshot(downloaded: [ep1, ep2, ep3], knownShowTitles: [], nowPlaying: nil)
        let plan = VoiceCommandPlanner.plan(.listDownloaded, snapshot: snapshot)
        XCTAssertEqual(plan.action, .none)
        XCTAssertEqual(plan.dialog, "3 episodes downloaded: Ep 1, Ep 2, Ep 3.")
    }

    func testListDownloadedWithFourEpisodes() {
        let ep1 = makeEpisode(id: "1", title: "Ep 1", showTitle: "Show")
        let ep2 = makeEpisode(id: "2", title: "Ep 2", showTitle: "Show")
        let ep3 = makeEpisode(id: "3", title: "Ep 3", showTitle: "Show")
        let ep4 = makeEpisode(id: "4", title: "Ep 4", showTitle: "Show")
        let snapshot = VoiceSnapshot(downloaded: [ep1, ep2, ep3, ep4], knownShowTitles: [], nowPlaying: nil)
        let plan = VoiceCommandPlanner.plan(.listDownloaded, snapshot: snapshot)
        XCTAssertEqual(plan.action, .none)
        XCTAssertEqual(plan.dialog, "4 episodes downloaded: Ep 1, Ep 2, Ep 3, and 1 more.")
    }

    func testListDownloadedWithFiveEpisodes() {
        let ep1 = makeEpisode(id: "1", title: "Ep 1", showTitle: "Show")
        let ep2 = makeEpisode(id: "2", title: "Ep 2", showTitle: "Show")
        let ep3 = makeEpisode(id: "3", title: "Ep 3", showTitle: "Show")
        let ep4 = makeEpisode(id: "4", title: "Ep 4", showTitle: "Show")
        let ep5 = makeEpisode(id: "5", title: "Ep 5", showTitle: "Show")
        let snapshot = VoiceSnapshot(downloaded: [ep1, ep2, ep3, ep4, ep5], knownShowTitles: [], nowPlaying: nil)
        let plan = VoiceCommandPlanner.plan(.listDownloaded, snapshot: snapshot)
        XCTAssertEqual(plan.action, .none)
        XCTAssertEqual(plan.dialog, "5 episodes downloaded: Ep 1, Ep 2, Ep 3, and 2 more.")
    }
}
