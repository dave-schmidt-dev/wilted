import Foundation
import XCTest
import WiltedDomain
@testable import WiltedProducer

extension LocalLibraryStoreTests {
    func testBulkSkipAndReceiptRestoreReuseOneAssociationLookupPerTransaction() async throws {
        let url = makeURL(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = try LocalLibraryStore(url: url)
        let origin = Date(timeIntervalSince1970: 1_700_000_000)
        let (_, built) = try episodes(feedURL: URL(string: "https://podcasts.example.test/bulk-decisions/feed.xml")!,
            origin: origin, daysAgo: Array(1...12))
        for episode in built { try await store.save(episode: episode) }
        let ids = built.map(\.itemID)
        let skipReads = BulkDecisionReadCounter()
        let skipped = try await LocalLibraryStore.$associationReadObserver.withValue({ fetches, _ in skipReads.add(fetches) }) {
            try await store.retireEpisodes(ids, at: Timestamp(origin.addingTimeInterval(100)), asOwnerChoice: true)
        }
        XCTAssertEqual(Set(skipped.committed), Set(ids))
        XCTAssertEqual(skipReads.count, 4)
        let restoreReads = BulkDecisionReadCounter()
        let restored = try await LocalLibraryStore.$associationReadObserver.withValue({ fetches, _ in restoreReads.add(fetches) }) {
            try await store.restoreEpisodes(ids, at: origin.addingTimeInterval(200))
        }
        XCTAssertEqual(Set(restored.committed), Set(ids))
        XCTAssertEqual(restoreReads.count, 4)
        try await store.replacePodcastQueue(PodcastQueueState(episodeIDs: ids, currentEpisodeID: ids[0]))
        _ = try await store.manuallyCompleteEpisodes(ids, at: Timestamp(origin.addingTimeInterval(300)))
        let receiptReads = BulkDecisionReadCounter()
        let receiptRestored = try await LocalLibraryStore.$associationReadObserver.withValue({ fetches, _ in receiptReads.add(fetches) }) {
            try await store.restoreEpisodes(ids, at: origin.addingTimeInterval(400))
        }
        XCTAssertEqual(Set(receiptRestored.committed), Set(ids))
        XCTAssertEqual(receiptReads.count, 4)
        let queue = try await store.podcastQueueState()
        XCTAssertEqual(queue.episodeIDs, ids)
        XCTAssertEqual(queue.currentEpisodeID, ids[0])
    }

    func testExplicitDatedLiveRestoreRecordsGroupKeepWhileOrdinaryNoOpPreservesPolicy() async throws {
        let url = makeURL(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = try LocalLibraryStore(url: url)
        let origin = Date(timeIntervalSince1970: 1_700_000_000)
        let (_, built) = try episodes(feedURL: URL(string: "https://podcasts.example.test/live-restore/feed.xml")!,
            origin: origin, daysAgo: [1, 2])
        for episode in built {
            try await store.save(episode: episode)
            try await store.save(episodeDecision: EpisodeDecisionRecord(episodeID: episode.itemID,
                decision: .keep, source: .policy, decidedAt: Timestamp(origin)))
        }
        let ids = built.map(\.itemID)
        let confirmation = PodcastEpisodePairConfirmation(confirmationID: UUID(), feedID: built[0].feedID,
            first: ids[0], second: ids[1], confirmedAt: Timestamp(origin))
        let preview = try await store.previewEpisodeAssociation(confirming: confirmation, representativeID: ids[0])
        _ = try await store.applyEpisodeAssociation(preview)
        try await store.replacePodcastQueue(PodcastQueueState(episodeIDs: ids, currentEpisodeID: ids[1]))
        let noOp = try await store.restoreEpisodes(ids, at: origin.addingTimeInterval(10))
        XCTAssertEqual(Set(noOp.alreadyAtTarget), Set(ids))
        XCTAssertTrue(noOp.atomicOwnerDecisionIDs.isEmpty)
        for id in ids {
            let decision = try await store.episodeDecision(for: id)
            XCTAssertEqual(decision?.source, .policy)
            XCTAssertEqual(decision?.decidedAt.date, origin)
        }
        let choiceAt = origin.addingTimeInterval(20)
        let lifecycleChanged = try await store.restoreEpisode(ids[1], at: choiceAt, recordLiveOwnerChoice: true)
        XCTAssertFalse(lifecycleChanged, "A live Restore records intent without inventing a lifecycle change")
        for id in ids {
            let decision = try await store.episodeDecision(for: id)
            XCTAssertEqual(decision?.decision, .keep)
            XCTAssertEqual(decision?.source, .manual)
            XCTAssertEqual(decision?.decidedAt.date, choiceAt)
        }
        _ = try await store.restoreEpisode(ids[0], at: origin.addingTimeInterval(10), recordLiveOwnerChoice: true)
        let logical = try await store.podcastEpisodeLogicalState(for: ids[0])
        XCTAssertEqual(logical?.manualDecidedAt?.date, choiceAt, "An explicitly dated old Restore cannot advance chronology")
        let queue = try await store.podcastQueueState()
        XCTAssertEqual(queue.episodeIDs, ids)
        XCTAssertEqual(queue.currentEpisodeID, ids[1])
        let listening = try await store.listeningState(for: ids[0])
        XCTAssertNil(listening)
    }

    func testBatchNoOpRestoreAndAutomaticRollbackPreserveDecisionProvenance() async throws {
        let url = makeURL(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = try LocalLibraryStore(url: url)
        let (_, episode) = try podcastValues()
        try await store.save(episode: episode)
        let policy = EpisodeDecisionRecord(episodeID: episode.itemID, decision: .keep, source: .policy,
            decidedAt: episode.createdAt)
        try await store.save(episodeDecision: policy)
        let noOp = try await store.restoreEpisodes([episode.itemID], at: episode.createdAt.date.addingTimeInterval(10))
        XCTAssertEqual(noOp.alreadyAtTarget, [episode.itemID])
        let afterNoOp = try await store.episodeDecision(for: episode.itemID)
        XCTAssertEqual(afterNoOp, policy)
        XCTAssertTrue(noOp.atomicOwnerDecisionIDs.isEmpty)
        _ = try await store.retireEpisodeBySkipRule(episode.itemID, ruleID: UUID(),
            at: Timestamp(episode.createdAt.date.addingTimeInterval(20)))
        try await store.restoreEpisodeDecisions([episode.itemID: policy], queue: PodcastQueueState(episodeIDs: []),
            unretiring: [episode.itemID])
        let removal = try await store.removalKind(for: episode.itemID)
        let decision = try await store.episodeDecision(for: episode.itemID)
        XCTAssertNil(removal)
        XCTAssertEqual(decision, policy)
    }
}

private final class BulkDecisionReadCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func add(_ count: Int) { lock.lock(); defer { lock.unlock() }; value += count }
    var count: Int { lock.lock(); defer { lock.unlock() }; return value }
}
