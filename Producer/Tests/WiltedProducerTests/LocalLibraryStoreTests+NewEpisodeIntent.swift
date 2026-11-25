import Foundation
import XCTest
import WiltedDomain
import WiltedLibrary
@testable import WiltedProducer

extension LocalLibraryStoreTests {
    private func prepareNewEpisode(at url: URL, origin: Date) async throws -> (LocalLibraryStore, PodcastEpisode) {
        let feedURL = URL(string: "https://podcasts.example.test/new-episode/feed.xml")!
        let (feed, episodes) = try episodes(feedURL: feedURL, origin: origin, daysAgo: [1])
        let store = try LocalLibraryStore(url: url)
        try await store.save(feed: feed)
        try await store.save(subscription: PodcastSubscription(feedID: feed.itemID, subscribedAt: Timestamp(origin)))
        try await store.savePodcastEpisodes(episodes, admission: .backfill)
        return (store, try XCTUnwrap(episodes.first))
    }

    private func newEpisodeIntent(
        _ episode: PodcastEpisode, decision: LibraryNewEpisodeDecision, id: String, at date: Date
    ) throws -> LibraryIntent {
        try .decideNewEpisode(entryID: episode.itemID, decision: decision, deviceID: "phone", createdAt: date, id: id)
    }

    func testConditionalKeepAndReceiptCommitTogetherAndReplayAfterReopen() async throws {
        let url = makeURL(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let origin = Date(timeIntervalSince1970: 1_700_000_000)
        let (store, episode) = try await prepareNewEpisode(at: url, origin: origin)
        let intent = try newEpisodeIntent(episode, decision: .keep, id: "new-keep", at: origin)

        let committed = try await store.commitNewEpisodeIntent(
            intent, macCurrentlyProjectsNew: true, decidedAt: origin, downloadAfterKeep: true)
        XCTAssertTrue(committed.outcome.isApplied)
        XCTAssertFalse(committed.wasReplay)
        let committedQueue = try await store.podcastQueueState()
        let committedDecision = try await store.episodeDecision(for: episode.itemID)
        let ticket = try await store.workTicket(kind: .podcastDownload, subjectID: episode.itemID.rawValue)
        XCTAssertEqual(committedQueue.episodeIDs, [episode.itemID])
        XCTAssertEqual(committedDecision?.decision, .keep)
        XCTAssertNotNil(ticket)

        let reopened = try LocalLibraryStore(url: url)
        let replay = try await reopened.commitNewEpisodeIntent(
            intent, macCurrentlyProjectsNew: false, decidedAt: origin.addingTimeInterval(20))
        XCTAssertTrue(replay.wasReplay)
        XCTAssertEqual(replay.outcome, committed.outcome, "the transaction receipt wins over later state")
        let replayQueue = try await reopened.podcastQueueState()
        XCTAssertEqual(replayQueue.episodeIDs, [episode.itemID], "replay never duplicates Keep")
        let delayedReplay = try await reopened.commitNewEpisodeIntent(
            intent, macCurrentlyProjectsNew: false,
            decidedAt: origin.addingTimeInterval(31 * 24 * 60 * 60))
        XCTAssertTrue(delayedReplay.wasReplay)
        XCTAssertEqual(delayedReplay.outcome, committed.outcome, "a saved commit receipt outlives ordinary intent expiry")

        let reusedID = try newEpisodeIntent(episode, decision: .skip, id: intent.id, at: origin)
        do {
            _ = try await reopened.commitNewEpisodeIntent(reusedID, macCurrentlyProjectsNew: true, decidedAt: origin)
            XCTFail("An intent ID cannot be rebound to a different conditional choice")
        } catch { }
    }

    func testStaleConditionalChoiceReturnsAndDurablyReplaysCurrentState() async throws {
        let url = makeURL(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let origin = Date(timeIntervalSince1970: 1_700_000_000)
        let (store, episode) = try await prepareNewEpisode(at: url, origin: origin)
        let keep = EpisodeDecisionRecord(episodeID: episode.itemID, decision: .keep, source: .manual, decidedAt: Timestamp(origin))
        let wroteKeep = try await store.save(episodeDecision: keep)
        XCTAssertEqual(wroteKeep, .applied)
        try await store.addPodcastQueueEpisode(episode.itemID)

        let intent = try newEpisodeIntent(episode, decision: .skip, id: "stale-new-skip", at: origin.addingTimeInterval(1))
        let conflict = try await store.commitNewEpisodeIntent(
            intent, macCurrentlyProjectsNew: false, decidedAt: origin.addingTimeInterval(2))
        XCTAssertEqual(conflict.outcome.reason, IntentOutcome.reasonNewEpisodeConflict)
        XCTAssertEqual(conflict.outcome.currentNewEpisodeState, .kept)
        let removal = try await store.removalKind(for: episode.itemID)
        let decision = try await store.episodeDecision(for: episode.itemID)
        XCTAssertNil(removal)
        XCTAssertEqual(decision?.decision, .keep)

        let reopened = try LocalLibraryStore(url: url)
        let replay = try await reopened.commitNewEpisodeIntent(
            intent, macCurrentlyProjectsNew: true, decidedAt: origin.addingTimeInterval(3))
        XCTAssertTrue(replay.wasReplay)
        XCTAssertEqual(replay.outcome, conflict.outcome)
        XCTAssertEqual(replay.outcome.currentNewEpisodeState, .kept)
    }

    func testConditionalKeepDoesNotBlockALaterNormalMacSkipReversal() async throws {
        let url = makeURL(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let origin = Date(timeIntervalSince1970: 1_700_000_000)
        let (store, episode) = try await prepareNewEpisode(at: url, origin: origin)
        let intent = try newEpisodeIntent(episode, decision: .keep, id: "keep-before-skip", at: origin)
        let kept = try await store.commitNewEpisodeIntent(intent, macCurrentlyProjectsNew: true, decidedAt: origin)
        XCTAssertTrue(kept.outcome.isApplied)

        let reversedAt = Timestamp(origin.addingTimeInterval(1))
        let result = try await store.retireEpisodes([episode.itemID], at: reversedAt, asOwnerChoice: true)
        XCTAssertEqual(result.committed, [episode.itemID])
        let decision = try await store.episodeDecision(for: episode.itemID)
        let removal = try await store.removalKind(for: episode.itemID)
        XCTAssertEqual(decision?.decision, .skip)
        XCTAssertEqual(removal, .retired)
    }

    func testExpiredConditionalIntentGetsDurableReceiptBeforeRetry() async throws {
        let url = makeURL(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let origin = Date(timeIntervalSince1970: 1_700_000_000)
        let (store, episode) = try await prepareNewEpisode(at: url, origin: origin)
        let intent = try newEpisodeIntent(episode, decision: .keep, id: "expired-new-keep", at: origin)

        let expiredAt = origin.addingTimeInterval(8 * 24 * 60 * 60)
        let expired = try await store.commitNewEpisodeIntent(
            intent, macCurrentlyProjectsNew: true, decidedAt: expiredAt)
        XCTAssertEqual(expired.outcome.reason, IntentOutcome.reasonExpired)
        let untouchedDecision = try await store.episodeDecision(for: episode.itemID)
        XCTAssertNil(untouchedDecision)

        let reopened = try LocalLibraryStore(url: url)
        let replay = try await reopened.commitNewEpisodeIntent(
            intent, macCurrentlyProjectsNew: false,
            decidedAt: origin.addingTimeInterval(40 * 24 * 60 * 60))
        XCTAssertTrue(replay.wasReplay)
        XCTAssertEqual(replay.outcome, expired.outcome)
        XCTAssertEqual(replay.outcome.reason, IntentOutcome.reasonExpired)
    }
}
