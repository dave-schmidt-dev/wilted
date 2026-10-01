import Foundation
import WiltedDomain
import XCTest
@testable import WiltedLibrary

final class InProgressOrderingTests: XCTestCase {
    private func id(_ raw: String) -> ItemID { try! ItemID(rawValue: raw) }

    private func observed(_ raw: String, device: String, position: Double, at seconds: Double) -> ObservedPlayback {
        ObservedPlayback(
            record: try! DevicePlaybackPosition(
                deviceID: device, entryID: id(raw), revision: try! RevisionID(rawValue: "rev"), positionSeconds: position,
                isPlaying: false, epoch: 1),
            serverModifiedAt: Date(timeIntervalSince1970: seconds))
    }

    func testMacAndPhonePositionsBothCountAndTheNewestPlayWinsTheTop() {
        let progress = InProgressOrdering.progress(
            checkpoints: [id("a"): observed("a", device: "mac", position: 30, at: 100), id("c"): observed("c", device: "mac", position: 5, at: 300)],
            ownPositions: [id("b"): observed("b", device: "phone", position: 50, at: 200)])
        let ordered = InProgressOrdering.ordered(["a", "b", "c", "d", "e"], progress: progress, id: { self.id($0) })
        XCTAssertEqual(ordered, ["c", "b", "a", "d", "e"], "in progress first, newest play first, the rest in their order")
    }

    func testCompletedAndUnstartedAndFinishedNeverCount() {
        let progress = InProgressOrdering.progress(
            checkpoints: [
                id("done"): observed("done", device: "mac", position: 90, at: 500),
                id("zero"): observed("zero", device: "mac", position: 0, at: 500),
                id("end"): observed("end", device: "mac", position: 599.5, at: 500),
                id("mid"): observed("mid", device: "mac", position: 120, at: 100),
            ],
            ownPositions: [:], completed: [id("done")], durations: [id("end"): 600, id("mid"): 600])
        XCTAssertEqual(Set(progress.keys), [id("mid")])
    }

    func testTheNewestRecordForAnEntryDecidesItsPositionAndTime() {
        let progress = InProgressOrdering.progress(
            checkpoints: [id("a"): observed("a", device: "mac", position: 400, at: 900)],
            ownPositions: [id("a"): observed("a", device: "phone", position: 100, at: 500)])
        XCTAssertEqual(progress[id("a")], EpisodeProgress(positionSeconds: 400, lastPlayedAt: Date(timeIntervalSince1970: 900)))
        let reversed = InProgressOrdering.progress(
            checkpoints: [id("a"): observed("a", device: "mac", position: 400, at: 400)],
            ownPositions: [id("a"): observed("a", device: "phone", position: 100, at: 500)])
        XCTAssertEqual(reversed[id("a")]?.positionSeconds, 100)
    }

    func testTheEpisodeLoadedInThePlayerRanksFirstEvenWithNoRecordYet() {
        let now = Date(timeIntervalSince1970: 1_000)
        let progress = InProgressOrdering.progress(
            checkpoints: [id("a"): observed("a", device: "mac", position: 30, at: 900)], ownPositions: [:],
            nowPlaying: (id("b"), 0, true), now: now)
        XCTAssertEqual(InProgressOrdering.ordered(["a", "b", "c"], progress: progress, id: { self.id($0) }), ["b", "a", "c"])
        XCTAssertNil(InProgressOrdering.progress(
            checkpoints: [:], ownPositions: [:], completed: [id("b")], nowPlaying: (id("b"), 10, true))[id("b")], "a completed episode is never pinned")
    }

    func testANewerFinishedOrRestartedRecordClearsAnOlderPartialOne() {
        let finished = InProgressOrdering.progress(
            checkpoints: [id("a"): observed("a", device: "mac", position: 30, at: 100)],
            ownPositions: [id("a"): observed("a", device: "phone", position: 600, at: 200)], durations: [id("a"): 600])
        XCTAssertNil(finished[id("a")], "played to the end on the phone after the Mac's old checkpoint")
        let restarted = InProgressOrdering.progress(
            checkpoints: [id("a"): observed("a", device: "mac", position: 30, at: 100)],
            ownPositions: [id("a"): observed("a", device: "phone", position: 0, at: 200)])
        XCTAssertNil(restarted[id("a")])
    }

    func testALoadedEpisodeFollowsTheSameRulesAndOnlyAPlayingOneIsFreshlyPlayed() {
        let now = Date(timeIntervalSince1970: 1_000)
        let atEnd = InProgressOrdering.progress(
            checkpoints: [:], ownPositions: [:], durations: [id("a"): 600], nowPlaying: (id("a"), 600, false), now: now)
        XCTAssertNil(atEnd[id("a")], "a finished episode that is still loaded is not in progress")
        let idle = InProgressOrdering.progress(checkpoints: [:], ownPositions: [:], nowPlaying: (id("a"), 0, false), now: now)
        XCTAssertNil(idle[id("a")], "loaded but untouched")
        let paused = InProgressOrdering.progress(
            checkpoints: [id("a"): observed("a", device: "mac", position: 30, at: 100)], ownPositions: [:],
            nowPlaying: (id("a"), 75, false), now: now)
        XCTAssertEqual(paused[id("a")], EpisodeProgress(positionSeconds: 75, lastPlayedAt: Date(timeIntervalSince1970: 100)), "keeping it loaded does not refresh its play time")
    }

    func testOrderingIsStableAndLeavesEverythingAloneWithNoProgress() {
        XCTAssertEqual(InProgressOrdering.ordered(["x", "y", "z"], progress: [:], id: { self.id($0) }), ["x", "y", "z"])
        let tie = Date(timeIntervalSince1970: 50)
        let progress = [id("z"): EpisodeProgress(positionSeconds: 1, lastPlayedAt: tie), id("y"): EpisodeProgress(positionSeconds: 1, lastPlayedAt: tie)]
        XCTAssertEqual(InProgressOrdering.ordered(["x", "y", "z"], progress: progress, id: { self.id($0) }), ["y", "z", "x"], "ties keep the given order")
    }

    func testShowsWithAnInProgressEpisodeComeFirst() {
        let ordered = InProgressOrdering.orderedShows(
            ["Alpha", "Beta", "Gamma", "Delta"],
            progressByShow: ["Delta": Date(timeIntervalSince1970: 10), "Beta": Date(timeIntervalSince1970: 20)])
        XCTAssertEqual(ordered, ["Beta", "Delta", "Alpha", "Gamma"])
    }

    // MARK: play order, finished and auto-continue

    private struct Item { let name: String; let published: Double; let completed: Double? }

    private func playOrder(_ items: [Item], progress: [ItemID: EpisodeProgress] = [:]) -> [String] {
        InProgressOrdering.playOrder(
            items, progress: progress, id: { self.id($0.name) },
            publishedAt: { Date(timeIntervalSince1970: $0.published) },
            completedAt: { $0.completed.map { Date(timeIntervalSince1970: $0) } }).map(\.name)
    }

    func testPlayOrderIsInProgressThenOldestNotStartedThenCompletedMostRecentFirst() {
        let items = [
            Item(name: "new", published: 400, completed: nil), Item(name: "old", published: 100, completed: nil),
            Item(name: "done1", published: 50, completed: 900), Item(name: "mid", published: 200, completed: nil),
            Item(name: "done2", published: 60, completed: 950), Item(name: "partA", published: 300, completed: nil),
            Item(name: "partB", published: 10, completed: nil),
        ]
        let progress = [
            id("partA"): EpisodeProgress(positionSeconds: 5, lastPlayedAt: Date(timeIntervalSince1970: 700)),
            id("partB"): EpisodeProgress(positionSeconds: 5, lastPlayedAt: Date(timeIntervalSince1970: 800)),
        ]
        XCTAssertEqual(playOrder(items, progress: progress), ["partB", "partA", "old", "mid", "new", "done2", "done1"])
    }

    func testPlayOrderTiesOnPublishDateKeepTheGivenLarderOrder() {
        let items = [Item(name: "x", published: 5, completed: nil), Item(name: "y", published: 5, completed: nil), Item(name: "w", published: 1, completed: nil)]
        XCTAssertEqual(playOrder(items), ["w", "x", "y"])
    }

    func testAutoContinuePicksTheFirstNotCompletedOtherThanTheEndedOne() {
        let items = [
            Item(name: "a", published: 1, completed: nil), Item(name: "b", published: 2, completed: 10),
            Item(name: "c", published: 3, completed: nil),
        ]
        let order = InProgressOrdering.playOrder(
            items, progress: [:], id: { self.id($0.name) }, publishedAt: { Date(timeIntervalSince1970: $0.published) },
            completedAt: { $0.completed.map { Date(timeIntervalSince1970: $0) } })
        func next(after ended: String) -> String? {
            InProgressOrdering.next(in: order, after: id(ended), id: { self.id($0.name) }, isCompleted: { $0.completed != nil })?.name
        }
        XCTAssertEqual(next(after: "a"), "c", "b is completed")
        XCTAssertEqual(next(after: "c"), "a")
        XCTAssertNil(InProgressOrdering.next(in: [items[1]], after: id("a"), id: { self.id($0.name) }, isCompleted: { $0.completed != nil }))
        XCTAssertNil(InProgressOrdering.next(in: [items[0]], after: id("a"), id: { self.id($0.name) }, isCompleted: { _ in false }), "never the one that just ended")
    }

    func testFinishedFindsEpisodesPlayedToTheEndButNotMarkedCompleted() {
        let finished = InProgressOrdering.finished(
            checkpoints: [
                id("end"): observed("end", device: "mac", position: 599.5, at: 100),
                id("mid"): observed("mid", device: "mac", position: 100, at: 100),
                id("marked"): observed("marked", device: "mac", position: 600, at: 100),
                id("restarted"): observed("restarted", device: "mac", position: 3, at: 300),
            ],
            ownPositions: [id("restarted"): observed("restarted", device: "phone", position: 600, at: 200)],
            completed: [id("marked")],
            durations: [id("end"): 600, id("mid"): 600, id("marked"): 600, id("restarted"): 600, id("loaded"): 600],
            nowPlaying: (id("loaded"), 600, false), now: Date(timeIntervalSince1970: 1_000))
        XCTAssertEqual(Set(finished.keys), [id("end"), id("loaded")], "a newer restart clears an older finish; marked ones are not repeated")
        XCTAssertEqual(finished[id("end")], Date(timeIntervalSince1970: 100))
        XCTAssertEqual(finished[id("loaded")], Date(timeIntervalSince1970: 1_000), "the loaded episode at its end finishes now")
    }

    /// The loaded episode decides over its saved record: replaying "end" from near the start clears its
    /// older finish, and a loaded episode whose length is unknown is never judged finished.
    func testTheLoadedEpisodeDecidesOverItsSavedRecordAndNeedsAKnownLength() {
        let replay = InProgressOrdering.finished(
            checkpoints: [id("end"): observed("end", device: "mac", position: 599.5, at: 100)], ownPositions: [:],
            durations: [id("end"): 600], nowPlaying: (id("end"), 3, true), now: Date(timeIntervalSince1970: 1_000))
        XCTAssertTrue(replay.isEmpty, "a replay from the start is not finished")
        let unknown = InProgressOrdering.finished(
            checkpoints: [:], ownPositions: [:], durations: [:],
            nowPlaying: (id("loaded"), 600, false), now: Date(timeIntervalSince1970: 1_000))
        XCTAssertTrue(unknown.isEmpty, "no feed length, no judgement; the app's played-out set covers this")
    }

    func testCompletedItemsGoLastInTheSortedPhoneListToo() {
        let items = ["a", "b", "c"]
        let ordered = InProgressOrdering.ordered(
            items, progress: [:], id: { self.id($0) }, completedAt: { $0 == "a" ? Date(timeIntervalSince1970: 1) : nil })
        XCTAssertEqual(ordered, ["b", "c", "a"])
    }
}
