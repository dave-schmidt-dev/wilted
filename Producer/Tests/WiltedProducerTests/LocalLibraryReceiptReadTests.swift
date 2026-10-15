import Foundation
import SwiftData
import XCTest
import WiltedDomain
@testable import WiltedProducer

extension LocalLibraryStoreTests {
    /// Corrupt unrelated sealed history cannot block recovery or explicit Restore.
    /// Undo of a genuine prior finish remains protected after the window is sealed.
    func testReceiptReadersSkipLargeUnrelatedMalformedSealedHistoryAndKeepRestoredFinishProof() async throws {
        let url = makeURL(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        var store = try LocalLibraryStore(url: url)
        let (feed, episode) = try podcastValues()
        try await store.save(feed: feed)
        try await store.save(episode: episode)
        let revision = try podcastRevision(itemID: episode.itemID, id: "receipt-read-finish", hashDigit: "a")
        let media = url.deletingLastPathComponent().appendingPathComponent("receipt-read.m4a")
        try Data([1, 2, 3]).write(to: media)
        try await store.finalizePodcastDownload(revision: revision, mediaURL: media,
            download: completedPodcastDownload(episodeID: episode.itemID, revision: revision, mediaURL: media))
        let genuine = PodcastListeningState(episodeID: episode.itemID, completedAt: episode.createdAt,
            lastRevisionID: revision.revisionID, updatedAt: episode.createdAt)
        try await store.saveListening(genuine)
        try await store.addPodcastQueueEpisode(episode.itemID)
        let now = episode.createdAt.date.addingTimeInterval(100)
        let completion = try await store.manuallyCompleteEpisodes([episode.itemID], at: Timestamp(now), localNow: now)
        let context = ModelContext(store.container)
        for index in 0..<2_000 {
            context.insert(LocalLibrarySchemaV19Models.ManualCompletionReceiptRecord(operationID: UUID(),
                createdAt: now.addingTimeInterval(Double(index)), undoAvailableUntil: .distantPast,
                members: Data("malformed unrelated sealed history \(index)".utf8)))
        }
        try context.save()
        store = try LocalLibraryStore(url: url)
        let recovery = try await store.manualCompletionRecoveryFeedIDs()
        let capacity = try await store.manualCompletionCapacityReservations(at: now)
        XCTAssertTrue(recovery.contains(feed.itemID))
        XCTAssertEqual(capacity[feed.itemID], 1)
        let undone = try await store.undoManualCompletion(XCTUnwrap(completion.operationID), at: now.addingTimeInterval(9))
        XCTAssertEqual(undone.committed, [episode.itemID])
        _ = try await store.sealExpiredManualCompletions(at: now.addingTimeInterval(10))
        store = try LocalLibraryStore(url: url)
        try await store.retireCompletedEpisodesMissingRetirement()
        let retained = try await store.removalKind(for: episode.itemID)
        let restoredListening = try await store.listeningState(for: episode.itemID)
        XCTAssertNil(retained, "Receipt proof protects an undone genuine finish after sealing and restart")
        XCTAssertEqual(restoredListening, genuine)
        // A second manual finish still supports explicit owner Restore after seal.
        _ = try await store.manuallyCompleteEpisodes([episode.itemID], at: Timestamp(now.addingTimeInterval(20)),
            localNow: now.addingTimeInterval(20))
        _ = try await store.sealExpiredManualCompletions(at: now.addingTimeInterval(30))
        store = try LocalLibraryStore(url: url)
        let postSealRecovery = try await store.manualCompletionRecoveryFeedIDs()
        XCTAssertTrue(postSealRecovery.contains(feed.itemID), "Seal-before-admission crash recovery uses sealed receipt feed metadata")
        let explicit = try await store.restoreManualCompletion(episode.itemID, at: now.addingTimeInterval(31))
        XCTAssertEqual(explicit, true)
        let preserved = try await store.listeningState(for: episode.itemID)
        XCTAssertEqual(preserved, genuine)
    }

    func testDatedPhoneCompletionRetainsChronologyButStartsUndoAtLocalActionTime() async throws {
        let url = makeURL(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = try LocalLibraryStore(url: url)
        let (_, episode) = try podcastValues()
        try await store.save(episode: episode)
        let intentAt = episode.createdAt.date.addingTimeInterval(100)
        let localNow = intentAt.addingTimeInterval(86_400)
        let result = try await store.manuallyCompleteEpisodes([episode.itemID], at: Timestamp(intentAt), localNow: localNow)
        XCTAssertEqual(result.undoAvailableUntil, localNow.addingTimeInterval(10))
        let choice = try await store.episodeDecision(for: episode.itemID)
        XCTAssertEqual(choice?.decidedAt, Timestamp(intentAt))
        let undone = try await store.undoManualCompletion(XCTUnwrap(result.operationID), at: localNow.addingTimeInterval(9))
        XCTAssertEqual(undone.committed, [episode.itemID])
        let second = try await store.manuallyCompleteEpisodes([episode.itemID], at: Timestamp(intentAt), localNow: localNow)
        let expired = try await store.undoManualCompletion(XCTUnwrap(second.operationID), at: localNow.addingTimeInterval(10))
        XCTAssertTrue(expired.committed.isEmpty)
    }

    func testRecoveryDoesNothingWithoutReceiptsAndRevisitsOnlyActualSealedReceiptFeeds() async throws {
        let url = makeURL(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        var store = try LocalLibraryStore(url: url)
        let (feed, episode) = try podcastValues()
        try await store.save(feed: feed)
        try await store.save(episode: episode)
        let unrelatedURL = URL(string: "https://podcasts.example.test/unrelated-live.xml")!
        let unrelatedID = try ItemID.derivePodcastFeed(from: unrelatedURL)
        try await store.save(feed: PodcastFeed(itemID: unrelatedID, canonicalURL: unrelatedURL,
            title: "Unrelated live feed", createdAt: feed.createdAt))
        let empty = try await store.manualCompletionRecoveryFeedIDs()
        XCTAssertTrue(empty.isEmpty, "Live feeds and episodes cannot trigger unrelated completion recovery")
        let now = episode.createdAt.date.addingTimeInterval(100)
        _ = try await store.manuallyCompleteEpisodes([episode.itemID], at: Timestamp(now), localNow: now)
        _ = try await store.sealExpiredManualCompletions(at: now.addingTimeInterval(10))
        store = try LocalLibraryStore(url: url)
        let recovered = try await store.manualCompletionRecoveryFeedIDs()
        XCTAssertEqual(recovered, [feed.itemID], "A seal-before-admission restart revisits only actual receipt feeds")
    }

    func testCorruptActiveReceiptStillBlocksRecoveryAndCapacityRelease() async throws {
        let url = makeURL(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = try LocalLibraryStore(url: url)
        let context = ModelContext(store.container)
        context.insert(LocalLibrarySchemaV19Models.ManualCompletionReceiptRecord(operationID: UUID(),
            createdAt: Date(), undoAvailableUntil: Date().addingTimeInterval(10), members: Data("corrupt active proof".utf8)))
        try context.save()
        do { _ = try await store.manualCompletionRecoveryFeedIDs(); XCTFail("Active proof cannot be silently discarded") } catch {}
        do { _ = try await store.manualCompletionCapacityReservations(); XCTFail("Active capacity cannot be silently discarded") } catch {}
    }
}
