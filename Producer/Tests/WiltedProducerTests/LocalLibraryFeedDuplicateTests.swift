import Foundation
import XCTest
import WiltedDomain
@testable import WiltedProducer

extension LocalLibraryStoreTests {
    private func twitEpisode(
        _ guid: String, show: String = "twit", seconds: Double? = 0, length: Double? = 7_200,
        fetched: Double = 0, title: String = "This Week in Tech 1098"
    ) throws -> PodcastEpisode {
        let epoch = Date(timeIntervalSince1970: 1_700_000_000)
        let feed = URL(string: "https://feeds.example.test/\(show).xml")!
        let enclosure = URL(string: "https://cdn.example.test/\(guid).mp3")!
        return try PodcastEpisode(
            itemID: ItemID.derivePodcastEpisode(feedURL: feed, rssGUID: guid, enclosureURL: enclosure),
            feedID: ItemID.derivePodcastFeed(from: feed), feedURL: feed, rssGUID: guid, title: title,
            publishedTime: seconds.map { Timestamp(epoch.addingTimeInterval($0)) }, enclosureURL: enclosure,
            enclosureMediaType: "audio/mpeg", durationSeconds: length, createdAt: Timestamp(epoch.addingTimeInterval(fetched))
        )
    }

    func testReissuedGUIDPreservesOriginalPlayheadCompletionAndRemovalWithoutWork() async throws {
        let url = makeURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        var store = try LocalLibraryStore(url: url)
        let original = try twitEpisode("twit1098-audio")
        let reissue = try twitEpisode("twit1098-republished", seconds: 60, length: 7_195, fetched: 86_400)
        try await store.save(episode: original)
        let checkpoint = try PlaybackState(
            itemID: original.itemID, revisionID: RevisionID(rawValue: "revision-twit"), sessionID: "saved-position",
            sequence: 1, positionSeconds: 754, durationSeconds: 7_200, completed: false,
            intent: .progress, deviceID: "test-mac", updatedAt: original.createdAt)
        try await store.save(playback: checkpoint)
        _ = try await store.manuallyCompleteEpisodes([original.itemID])
        try await store.save(subscription: PodcastSubscription(feedID: original.feedID, subscribedAt: reissue.createdAt))
        let before = try await store.podcastLibrarySnapshot()
        let first = try await store.admitPodcastEpisodes([reissue], admission: .incremental, claimingNewest: 5)
        XCTAssertTrue(first.claimed.isEmpty)
        XCTAssertTrue(first.admission.newlyAdmitted.isEmpty)
        store = try LocalLibraryStore(url: url)
        let groups = try await store.episodeAssociations()
        let group = try XCTUnwrap(groups.first)
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(group.representativeID, original.itemID)
        XCTAssertEqual(group.confirmation.source, .feedMatch)
        XCTAssertEqual(Set(group.memberIDs), [original.itemID, reissue.itemID])
        let state = try await store.podcastEpisodeLogicalState(for: reissue.itemID)
        XCTAssertEqual(state?.isTerminal, true)
        let replay = try await store.admitPodcastEpisodes([original, reissue], admission: .incremental, claimingNewest: 5)
        XCTAssertTrue(replay.claimed.isEmpty)
        try await assertDuplicateCannotEnqueue(reissue, in: store)
        let after = try await store.podcastLibrarySnapshot()
        XCTAssertEqual(after.playbackStates, before.playbackStates)
        XCTAssertEqual(after.listeningStates, before.listeningStates)
        XCTAssertEqual(after.removalKindByEpisode, before.removalKindByEpisode)
        XCTAssertEqual(after.episodeDecisions, before.episodeDecisions)
        XCTAssertEqual(after.podcastQueue, before.podcastQueue)
    }

    func testLegacyGhostIsFoundEvenWhenBothCopiesHaveLeftTheFeedAndReversalSticks() async throws {
        let url = makeURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = try LocalLibraryStore(url: url)
        let original = try twitEpisode("twit-original")
        let ghost = try twitEpisode("twit-ghost", seconds: 12, length: 7_201, fetched: 86_400)
        for episode in [original, ghost] { try await store.save(episode: episode) }
        try await store.addPodcastQueueEpisode(original.itemID)
        try await store.setCurrentPodcastQueueEpisode(original.itemID)
        let queue = try await store.podcastQueueState()
        let next = try twitEpisode("twit1099", seconds: 604_800, title: "This Week in Tech 1099")
        let result = try await store.admitPodcastEpisodes([next], admission: .incremental, claimingNewest: 1)
        XCTAssertEqual(result.claimed, [next.itemID])
        let groups = try await store.episodeAssociations()
        let group = try XCTUnwrap(groups.first)
        XCTAssertEqual(group.representativeID, original.itemID)
        try await assertDuplicateCannotEnqueue(ghost, in: store)

        // An active feed match must survive a later RSS parser fetch timestamp.
        _ = try await store.savePodcastEpisodes([twitEpisode("twit-original", fetched: 172_800)], admission: .incremental)
        let refreshed = try await store.episodeAssociations()
        XCTAssertEqual(refreshed, groups)
        let preview = try await store.previewEpisodeAssociationReversal(group.associationID, expectedVersion: group.version)
        _ = try await store.reverseEpisodeAssociation(preview)
        _ = try await store.savePodcastEpisodes([ghost], admission: .incremental)
        let active = try await store.episodeAssociations()
        XCTAssertTrue(active.isEmpty)
        let queueAfter = try await store.podcastQueueState()
        XCTAssertEqual(queueAfter, queue)
    }

    func testTwoPossibleOriginalsAndMissingLengthHoldAcrossReopenWhileOtherShowsProceed() async throws {
        let url = makeURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        var store = try LocalLibraryStore(url: url)
        // The two old episodes are 100 seconds apart. The incoming item is
        // within a minute of each, even though neither matches the other.
        let older = try twitEpisode("old-a", seconds: -50)
        let newer = try twitEpisode("old-b", seconds: 50)
        let reissue = try twitEpisode("uncertain", fetched: 3_600)
        let otherShow = try twitEpisode("other-show", show: "other")
        for episode in [older, newer] { try await store.save(episode: episode) }
        let result = try await store.admitPodcastEpisodes([reissue, otherShow], admission: .incremental, claimingNewest: 5)
        XCTAssertEqual(result.claimed, [otherShow.itemID])
        XCTAssertEqual(result.admission.newlyAdmitted, [otherShow.itemID])
        store = try LocalLibraryStore(url: url)
        try await assertDuplicateCannotEnqueue(reissue, in: store)
        let review = try await store.episodeReviewPairs(for: reissue.itemID)
        XCTAssertEqual(Set(review.held.map(\.representativeID)), [older.itemID, newer.itemID])
        for other in [older, newer] {
            let pair = try await store.podcastEpisodeAssociationComparison(first: reissue.itemID, second: other.itemID)
            _ = try await store.keepEpisodesSeparate(pair, at: reissue.createdAt)
            if other == older { try await assertDuplicateCannotEnqueue(reissue, in: store) }
        }
        let released = try await store.admitPodcastEpisodes([reissue], admission: .incremental, claimingNewest: 5)
        XCTAssertEqual(released.admission.releasedFromReview, [reissue.itemID])
        XCTAssertEqual(released.claimed, [reissue.itemID])
        let missing = try twitEpisode("missing-duration", length: nil, fetched: 7_200)
        let uncertain = try await store.admitPodcastEpisodes([missing], admission: .incremental, claimingNewest: 5)
        XCTAssertTrue(uncertain.claimed.isEmpty)
        try await assertDuplicateCannotEnqueue(missing, in: store)
        let groups = try await store.episodeAssociations()
        XCTAssertTrue(groups.isEmpty)
    }

    private func assertDuplicateCannotEnqueue(
        _ episode: PodcastEpisode, in store: LocalLibraryStore, file: StaticString = #filePath, line: UInt = #line
    ) async throws {
        let claimed = try await store.claimPodcastDownload(episodeID: episode.itemID)
        XCTAssertFalse(claimed, file: file, line: line)
        do {
            _ = try await store.admitEpisode(.init(episodeID: episode.itemID, decision: .keep,
                source: .policy, decidedAt: episode.createdAt), workTicketKinds: [.podcastDownload, .podcastPreparation])
            XCTFail("Duplicate admitted to the work queue", file: file, line: line)
        } catch let error as AutomaticEpisodeAdmissionError {
            XCTAssertEqual(error, .episodeUnavailable, file: file, line: line)
        }
        for kind in [WorkTicketKind.podcastDownload, .podcastPreparation] {
            do {
                _ = try await store.issueWorkTicket(kind: kind, subjectID: episode.itemID.rawValue, requestedAt: episode.createdAt)
                XCTFail("An independent ticket writer admitted a duplicate", file: file, line: line)
            } catch let error as AutomaticEpisodeAdmissionError {
                XCTAssertEqual(error, .episodeUnavailable, file: file, line: line)
            }
        }
        let tickets = try await store.workTickets()
        XCTAssertFalse(tickets.contains { $0.subjectID == episode.itemID.rawValue }, file: file, line: line)
    }
}
