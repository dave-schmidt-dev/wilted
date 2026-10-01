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
        XCTAssertFalse(plan.needsConfirmation)
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
        XCTAssertFalse(plan.needsConfirmation)
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
        XCTAssertEqual(plan.dialog, "No TechCrunch Daily episodes are on your phone.")
        XCTAssertFalse(plan.needsConfirmation)
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
        XCTAssertFalse(plan.needsConfirmation)
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
        XCTAssertEqual(plan.dialog, "That was the last The Daily episode on your phone.")
        XCTAssertFalse(plan.needsConfirmation)
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
        XCTAssertFalse(plan.needsConfirmation)
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
        XCTAssertFalse(plan.needsConfirmation)
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
        XCTAssertEqual(plan.dialog, "No episodes are on your phone.")
        XCTAssertFalse(plan.needsConfirmation)
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
        XCTAssertFalse(plan.needsConfirmation)
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
        XCTAssertEqual(plan.dialog, "That was the last episode on your phone.")
        XCTAssertFalse(plan.needsConfirmation)
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
        XCTAssertFalse(plan.needsConfirmation)
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
        XCTAssertFalse(plan.needsConfirmation)
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
        XCTAssertFalse(plan.needsConfirmation)
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
        XCTAssertFalse(plan.needsConfirmation)
    }

    func testPauseWhenNothingLoaded() {
        let snapshot = VoiceSnapshot(downloaded: [], knownShowTitles: [], nowPlaying: nil)
        let plan = VoiceCommandPlanner.plan(.pause, snapshot: snapshot)
        XCTAssertEqual(plan.action, .none)
        XCTAssertEqual(plan.dialog, "Nothing is playing.")
        XCTAssertFalse(plan.needsConfirmation)
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
        XCTAssertFalse(plan.needsConfirmation)
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
        XCTAssertFalse(plan.needsConfirmation)
    }

    func testResumeWhenNothingLoaded() {
        let snapshot = VoiceSnapshot(downloaded: [], knownShowTitles: [], nowPlaying: nil)
        let plan = VoiceCommandPlanner.plan(.resume, snapshot: snapshot)
        XCTAssertEqual(plan.action, .none)
        XCTAssertEqual(plan.dialog, "Nothing to resume.")
        XCTAssertFalse(plan.needsConfirmation)
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
        XCTAssertFalse(plan.needsConfirmation)
    }

    func testSkipForwardWhenNothingLoaded() {
        let snapshot = VoiceSnapshot(downloaded: [], knownShowTitles: [], nowPlaying: nil)
        let plan = VoiceCommandPlanner.plan(.skipForward, snapshot: snapshot)
        XCTAssertEqual(plan.action, .none)
        XCTAssertEqual(plan.dialog, "Nothing is playing.")
        XCTAssertFalse(plan.needsConfirmation)
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
        XCTAssertFalse(plan.needsConfirmation)
    }

    func testSkipBackWhenNothingLoaded() {
        let snapshot = VoiceSnapshot(downloaded: [], knownShowTitles: [], nowPlaying: nil)
        let plan = VoiceCommandPlanner.plan(.skipBack, snapshot: snapshot)
        XCTAssertEqual(plan.action, .none)
        XCTAssertEqual(plan.dialog, "Nothing is playing.")
        XCTAssertFalse(plan.needsConfirmation)
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
        XCTAssertFalse(plan.needsConfirmation)
    }

    func testRestartWhenNothingLoaded() {
        let snapshot = VoiceSnapshot(downloaded: [], knownShowTitles: [], nowPlaying: nil)
        let plan = VoiceCommandPlanner.plan(.restart, snapshot: snapshot)
        XCTAssertEqual(plan.action, .none)
        XCTAssertEqual(plan.dialog, "Nothing is playing.")
        XCTAssertFalse(plan.needsConfirmation)
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
        XCTAssertEqual(plan.dialog, "Mark Episode One completed?")
        XCTAssertTrue(plan.needsConfirmation)
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
        XCTAssertFalse(plan.needsConfirmation)
    }

    func testMarkCompletedWhenNothingLoaded() {
        let snapshot = VoiceSnapshot(downloaded: [], knownShowTitles: [], nowPlaying: nil)
        let plan = VoiceCommandPlanner.plan(.markCompleted, snapshot: snapshot)
        XCTAssertEqual(plan.action, .none)
        XCTAssertEqual(plan.dialog, "Nothing is playing.")
        XCTAssertFalse(plan.needsConfirmation)
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
        XCTAssertFalse(plan.needsConfirmation)
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
        XCTAssertFalse(plan.needsConfirmation)
    }

    func testWhatsPlayingWhenNothingLoaded() {
        let snapshot = VoiceSnapshot(downloaded: [], knownShowTitles: [], nowPlaying: nil)
        let plan = VoiceCommandPlanner.plan(.whatsPlaying, snapshot: snapshot)
        XCTAssertEqual(plan.action, .none)
        XCTAssertEqual(plan.dialog, "Nothing is playing.")
        XCTAssertFalse(plan.needsConfirmation)
    }

    // MARK: - Row 23 & 24: listDownloaded

    func testListDownloadedWhenEmpty() {
        let snapshot = VoiceSnapshot(downloaded: [], knownShowTitles: [], nowPlaying: nil)
        let plan = VoiceCommandPlanner.plan(.listDownloaded, snapshot: snapshot)
        XCTAssertEqual(plan.action, .none)
        XCTAssertEqual(plan.dialog, "No episodes are on your phone.")
        XCTAssertFalse(plan.needsConfirmation)
    }

    func testListDownloadedWithOneEpisode() {
        let ep1 = makeEpisode(id: "1", title: "Ep 1", showTitle: "Show")
        let snapshot = VoiceSnapshot(downloaded: [ep1], knownShowTitles: [], nowPlaying: nil)
        let plan = VoiceCommandPlanner.plan(.listDownloaded, snapshot: snapshot)
        XCTAssertEqual(plan.action, .none)
        XCTAssertEqual(plan.dialog, "1 episode on your phone: Ep 1.")
        XCTAssertFalse(plan.needsConfirmation)
    }

    func testListDownloadedWithTwoEpisodes() {
        let ep1 = makeEpisode(id: "1", title: "Ep 1", showTitle: "Show")
        let ep2 = makeEpisode(id: "2", title: "Ep 2", showTitle: "Show")
        let snapshot = VoiceSnapshot(downloaded: [ep1, ep2], knownShowTitles: [], nowPlaying: nil)
        let plan = VoiceCommandPlanner.plan(.listDownloaded, snapshot: snapshot)
        XCTAssertEqual(plan.action, .none)
        XCTAssertEqual(plan.dialog, "2 episodes on your phone: Ep 1, Ep 2.")
        XCTAssertFalse(plan.needsConfirmation)
    }

    func testListDownloadedWithThreeEpisodes() {
        let ep1 = makeEpisode(id: "1", title: "Ep 1", showTitle: "Show")
        let ep2 = makeEpisode(id: "2", title: "Ep 2", showTitle: "Show")
        let ep3 = makeEpisode(id: "3", title: "Ep 3", showTitle: "Show")
        let snapshot = VoiceSnapshot(downloaded: [ep1, ep2, ep3], knownShowTitles: [], nowPlaying: nil)
        let plan = VoiceCommandPlanner.plan(.listDownloaded, snapshot: snapshot)
        XCTAssertEqual(plan.action, .none)
        XCTAssertEqual(plan.dialog, "3 episodes on your phone: Ep 1, Ep 2, Ep 3.")
        XCTAssertFalse(plan.needsConfirmation)
    }

    func testListDownloadedWithFourEpisodes() {
        let ep1 = makeEpisode(id: "1", title: "Ep 1", showTitle: "Show")
        let ep2 = makeEpisode(id: "2", title: "Ep 2", showTitle: "Show")
        let ep3 = makeEpisode(id: "3", title: "Ep 3", showTitle: "Show")
        let ep4 = makeEpisode(id: "4", title: "Ep 4", showTitle: "Show")
        let snapshot = VoiceSnapshot(downloaded: [ep1, ep2, ep3, ep4], knownShowTitles: [], nowPlaying: nil)
        let plan = VoiceCommandPlanner.plan(.listDownloaded, snapshot: snapshot)
        XCTAssertEqual(plan.action, .none)
        XCTAssertEqual(plan.dialog, "4 episodes on your phone: Ep 1, Ep 2, Ep 3, and 1 more.")
        XCTAssertFalse(plan.needsConfirmation)
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
        XCTAssertEqual(plan.dialog, "5 episodes on your phone: Ep 1, Ep 2, Ep 3, and 2 more.")
        XCTAssertFalse(plan.needsConfirmation)
    }
}
