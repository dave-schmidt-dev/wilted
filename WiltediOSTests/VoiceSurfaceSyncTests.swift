import AppIntents
import Foundation
import WiltedDomain
import WiltedLibrary
import XCTest
@testable import WiltediOS

@MainActor
private final class RecordingIndex: EntityIndex {
    enum Call: Equatable {
        case reset
        case index(episodes: [String], shows: [String])
        case delete(episodes: [String], shows: [String])
    }

    private(set) var calls: [Call] = []

    /// Set to make every call report failure, like a Spotlight that rejects the work.
    var fails = false

    func index(episodes: [EpisodeEntity], shows: [ShowEntity]) async -> Bool {
        calls.append(.index(episodes: episodes.map(\.id).sorted(), shows: shows.map(\.id).sorted()))
        return !fails
    }
    func delete(episodeIDs: [String], showIDs: [String]) async -> Bool {
        calls.append(.delete(episodes: episodeIDs.sorted(), shows: showIDs.sorted()))
        return !fails
    }
    func deleteAll() async -> Bool { calls.append(.reset); return !fails }
}

@MainActor
private final class RecordingDonor: IntentDonating {
    private(set) var played: [String] = []
    private(set) var marks = 0
    func donatePlay(of episode: EpisodeEntity) { played.append(episode.id) }
    func donateMarkCompleted() { marks += 1 }
}

/// What reaches Spotlight and the donation manager, with the system calls replaced by recorders.
@MainActor
final class VoiceSurfaceSyncTests: XCTestCase {
    private func episode(_ id: String, _ title: String = "T", show: String = "Show") -> VoiceEpisode {
        VoiceEpisode(id: try! ItemID(rawValue: id), title: title, showTitle: show)
    }

    // MARK: Spotlight

    func testAnEmptyFirstStateDoesNothing() async {
        let index = RecordingIndex()
        let indexer = SpotlightIndexer(index: index)
        indexer.sync([])
        await indexer.settle()
        XCTAssertTrue(index.calls.isEmpty, "the model not having loaded yet is not 'nothing downloaded'")
    }

    func testASecondEmptyStateMeansLoadedEmptyAndResetsTheIndex() async {
        let index = RecordingIndex()
        let indexer = SpotlightIndexer(index: index)
        indexer.sync([])
        indexer.sync([])
        await indexer.settle()
        XCTAssertEqual(index.calls, [.reset, .index(episodes: [], shows: [])], "entries left by an earlier run are removed")
    }

    func testAFailedStepIsRepairedByAFullResetAtTheNextSync() async {
        let index = RecordingIndex()
        let indexer = SpotlightIndexer(index: index)
        indexer.sync([episode("a"), episode("b")])
        await indexer.settle()
        index.fails = true
        indexer.sync([episode("a")])
        await indexer.settle()
        index.fails = false
        let before = index.calls.count
        indexer.sync([episode("a")])
        await indexer.settle()
        XCTAssertEqual(Array(index.calls[before...]), [.reset, .index(episodes: ["a"], shows: ["Show"])],
                       "an unchanged state still repairs: the failed delete would otherwise linger")
    }

    func testTheFirstNonEmptyStateResetsThenIndexesEverythingIncludingShows() async {
        let index = RecordingIndex()
        let indexer = SpotlightIndexer(index: index)
        indexer.sync([])
        indexer.sync([episode("a", show: "Short Wave"), episode("b", show: "Planet Money"), episode("c", show: "Short Wave")])
        await indexer.settle()
        XCTAssertEqual(index.calls, [.reset, .index(episodes: ["a", "b", "c"], shows: ["Planet Money", "Short Wave"])])
    }

    func testADownloadIndexesOnlyTheNewEpisodeAndAShowOnlyOnce() async {
        let index = RecordingIndex()
        let indexer = SpotlightIndexer(index: index)
        indexer.sync([episode("a", show: "Short Wave")])
        indexer.sync([episode("a", show: "Short Wave"), episode("b", show: "Short Wave"), episode("c", show: "Planet Money")])
        await indexer.settle()
        XCTAssertEqual(index.calls.suffix(2), [
            .delete(episodes: [], shows: []),
            .index(episodes: ["b", "c"], shows: ["Planet Money"]),
        ])
    }

    func testARemovalDeletesTheEpisodeAndAShowWithNothingLeft() async {
        let index = RecordingIndex()
        let indexer = SpotlightIndexer(index: index)
        indexer.sync([episode("a", show: "Short Wave"), episode("b", show: "Planet Money")])
        indexer.sync([episode("a", show: "Short Wave")])
        await indexer.settle()
        XCTAssertEqual(index.calls.last.map { $0 }, .index(episodes: [], shows: []))
        XCTAssertTrue(index.calls.contains(.delete(episodes: ["b"], shows: ["Planet Money"])))
    }

    func testDeletingTheLastEpisodeAfterIndexingStillDeletes() async {
        let index = RecordingIndex()
        let indexer = SpotlightIndexer(index: index)
        indexer.sync([episode("a")])
        indexer.sync([])
        await indexer.settle()
        XCTAssertTrue(index.calls.contains(.delete(episodes: ["a"], shows: ["Show"])))
    }

    func testAChangedTitleIsIndexedAgainAndAnUnchangedStateIsSilent() async {
        let index = RecordingIndex()
        let indexer = SpotlightIndexer(index: index)
        indexer.sync([episode("a", "Old")])
        indexer.sync([episode("a", "Old")])
        indexer.sync([episode("a", "New")])
        await indexer.settle()
        XCTAssertEqual(index.calls, [
            .reset, .index(episodes: ["a"], shows: ["Show"]),
            .delete(episodes: [], shows: []), .index(episodes: ["a"], shows: []),
        ])
    }

    func testARenamedShowIsDeletedAndAddedUnderItsNewId() async {
        let index = RecordingIndex()
        let indexer = SpotlightIndexer(index: index)
        indexer.sync([episode("a", show: "Old Name")])
        indexer.sync([episode("a", show: "New Name")])
        await indexer.settle()
        XCTAssertTrue(index.calls.contains(.delete(episodes: [], shows: ["Old Name"])))
        XCTAssertTrue(index.calls.contains(.index(episodes: ["a"], shows: ["New Name"])))
    }

    func testEntitiesAreIndexedEntitiesWithAttributes() {
        let entity = EpisodeEntity(episode("a", "Tide Pools", show: "Short Wave"))
        XCTAssertEqual(entity.attributeSet.keywords ?? [], ["Short Wave"])
        XCTAssertEqual(entity.attributeSet.displayName, "Tide Pools")
        _ = ShowEntity(id: "Short Wave").attributeSet
    }

    // MARK: donations

    private func item(_ id: String) -> LibraryPlayer.Item {
        LibraryPlayer.Item(entryID: try! ItemID(rawValue: id), title: "T", showTitle: "S", fileURL: URL(fileURLWithPath: "/dev/null"))
    }

    func testAnEpisodeStartingIsDonatedOnceUntilAnotherPlays() {
        let donor = RecordingDonor()
        let donations = IntentDonor(donor: donor)
        donations.played(item("a"))
        donations.played(item("a"))
        donations.played(item("b"))
        donations.played(item("a"))
        XCTAssertEqual(donor.played, ["a", "b", "a"])
    }

    func testAPlaySiriRanItselfIsNotDonatedAgain() async {
        let donor = RecordingDonor()
        let donations = IntentDonor(donor: donor)
        await donations.withoutDonatingPlay(of: try! ItemID(rawValue: "a")) { donations.played(item("a")) }
        XCTAssertTrue(donor.played.isEmpty)
        donations.played(item("b"))
        XCTAssertEqual(donor.played, ["b"])
    }

    func testMarkCompletedOnTheLoadedEpisodeIsDonatedOncePerDecision() {
        let donor = RecordingDonor()
        let donations = IntentDonor(donor: donor)
        let a = try! ItemID(rawValue: "a")
        donations.decisions([("d1", a)], loaded: a)
        donations.decisions([("d1", a)], loaded: a)
        XCTAssertEqual(donor.marks, 1)
        donations.decisions([("d1", a), ("d2", a)], loaded: a)
        XCTAssertEqual(donor.marks, 2)
    }

    func testRestoredOrUnrelatedDecisionsAreNotDonated() {
        let donor = RecordingDonor()
        let donations = IntentDonor(donor: donor)
        let a = try! ItemID(rawValue: "a")
        let b = try! ItemID(rawValue: "b")
        donations.decisions([("restored", a)], loaded: nil)
        donations.decisions([("restored", a), ("other", b)], loaded: a)
        donations.decisions([("restored", a), ("other", b), ("keep", nil)], loaded: a)
        XCTAssertEqual(donor.marks, 0)
    }

    func testAMarkSiriRanItselfIsNotDonatedAgain() async {
        let donor = RecordingDonor()
        let donations = IntentDonor(donor: donor)
        let a = try! ItemID(rawValue: "a")
        await donations.withoutDonatingMark(of: a) { donations.decisions([("d1", a)], loaded: a) }
        XCTAssertEqual(donor.marks, 0)
    }
}
