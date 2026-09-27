import CryptoKit
import Foundation
import SwiftData
import XCTest
import WiltedDomain
import WiltedSync
@testable import WiltedProducer

extension LocalLibraryStoreTests {
    func testSyncStateTombstoneAndPlaybackSidecarsReopen() async throws {
        let url = makeURL(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let item = try article(); let rev = try revision(for: item, id: "rev-sidecar")
        let store = try LocalLibraryStore(url: url)
        try await store.save(article: item)
        try await store.save(playback: playback(for: item, revision: rev, position: 8))
        let fetched = Timestamp(Date(timeIntervalSince1970: 1_700_000_100))
        let sent = Timestamp(Date(timeIntervalSince1970: 1_700_000_101))
        try await store.save(syncState: LocalLibrarySyncState(key: "private-zone", engineState: Data([1, 2, 3]), lastFetchAt: fetched, lastSendAt: sent))
        try await store.save(playbackSidecar: PlaybackSystemFieldsSidecar(encodedSystemFields: Data([4, 5]), changeTag: "change-tag-1"), for: item.itemID, revisionID: rev.revisionID)
        try await store.record(tombstone: LocalLibraryTombstone(id: "delete-1", itemID: item.itemID, requestedAt: fetched))
        let firstAcknowledgement = try await store.acknowledgeTombstone(id: "delete-1")
        let secondAcknowledgement = try await store.acknowledgeTombstone(id: "delete-1")
        XCTAssertTrue(firstAcknowledgement)
        XCTAssertFalse(secondAcknowledgement)

        let reopened = try LocalLibraryStore(url: url)
        let reopenedSync = try await reopened.syncState(for: "private-zone")
        let reopenedSidecar = try await reopened.playbackSidecar(for: item.itemID, revisionID: rev.revisionID)
        let reopenedTombstone = try await reopened.tombstone(for: "delete-1")
        XCTAssertEqual(reopenedSync?.engineState, Data([1, 2, 3]))
        XCTAssertEqual(reopenedSync?.lastFetchAt, fetched)
        XCTAssertEqual(reopenedSidecar, PlaybackSystemFieldsSidecar(encodedSystemFields: Data([4, 5]), changeTag: "change-tag-1"))
        XCTAssertEqual(reopenedTombstone?.remoteAcknowledged, true)
    }

    func testSyncCommitRefreshesPlaybackSidecarWhenLocalStateWins() async throws {
        let url = makeURL(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let item = try article(); let rev = try revision(for: item, id: "rev-sidecar-refresh")
        let current = try PlaybackState(
            itemID: item.itemID, revisionID: rev.revisionID, sessionID: "shared-session", sequence: 2,
            positionSeconds: 20, durationSeconds: rev.durationSeconds, completed: false, intent: .progress,
            deviceID: "device-local", updatedAt: Timestamp(Date(timeIntervalSince1970: 1_700_000_020)))
        let staleIncoming = try PlaybackState(
            itemID: item.itemID, revisionID: rev.revisionID, sessionID: "shared-session", sequence: 1,
            positionSeconds: 10, durationSeconds: rev.durationSeconds, completed: false, intent: .progress,
            deviceID: "device-remote", updatedAt: Timestamp(Date(timeIntervalSince1970: 1_700_000_030)))
        let incomingSidecar = PlaybackSystemFieldsSidecar(
            encodedSystemFields: Data([8, 9]), changeTag: "change-tag-new")
        let store = try LocalLibraryStore(url: url)
        try await store.save(playback: current)
        try await store.save(
            playbackSidecar: PlaybackSystemFieldsSidecar(encodedSystemFields: Data([4, 5]), changeTag: "change-tag-old"),
            for: item.itemID, revisionID: rev.revisionID)

        try await store.applySyncCommit(LocalLibrarySyncCommit(
            state: SyncRepositoryState(), playbacks: [.init(state: staleIncoming, sidecar: incomingSidecar)]))

        let saved = try await store.playbackState(for: item.itemID, revisionID: rev.revisionID)
        let sidecar = try await store.playbackSidecar(for: item.itemID, revisionID: rev.revisionID)
        XCTAssertEqual(saved?.sequence, current.sequence)
        XCTAssertEqual(saved?.positionSeconds, current.positionSeconds)
        XCTAssertEqual(saved?.deviceID, current.deviceID)
        XCTAssertEqual(sidecar, incomingSidecar)
    }

    func testSyncCommitAcceptsForwardProgressWithDifferingStoredChangeTag() async throws {
        let url = makeURL(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let item = try article(); let rev = try revision(for: item, id: "rev-forward-progress")
        let current = try PlaybackState(
            itemID: item.itemID, revisionID: rev.revisionID, sessionID: "shared-session", sequence: 1,
            positionSeconds: 10, durationSeconds: rev.durationSeconds, completed: false, intent: .progress,
            deviceID: "device-local", updatedAt: Timestamp(Date(timeIntervalSince1970: 1_700_000_020)))
        let incoming = try PlaybackState(
            itemID: item.itemID, revisionID: rev.revisionID, sessionID: "shared-session", sequence: 2,
            positionSeconds: 20, durationSeconds: rev.durationSeconds, completed: false, intent: .progress,
            deviceID: "device-remote", updatedAt: Timestamp(Date(timeIntervalSince1970: 1_700_000_030)))
        let incomingSidecar = PlaybackSystemFieldsSidecar(
            encodedSystemFields: Data([8, 9]), changeTag: "change-tag-new")
        let store = try LocalLibraryStore(url: url)
        try await store.save(playback: current)
        try await store.save(
            playbackSidecar: PlaybackSystemFieldsSidecar(encodedSystemFields: Data([4, 5]), changeTag: "change-tag-old"),
            for: item.itemID, revisionID: rev.revisionID)

        try await store.applySyncCommit(LocalLibrarySyncCommit(
            state: SyncRepositoryState(), playbacks: [.init(state: incoming, sidecar: incomingSidecar)]))

        let saved = try await store.playbackState(for: item.itemID, revisionID: rev.revisionID)
        let sidecar = try await store.playbackSidecar(for: item.itemID, revisionID: rev.revisionID)
        XCTAssertEqual(saved?.sequence, incoming.sequence)
        XCTAssertEqual(saved?.positionSeconds, incoming.positionSeconds)
        XCTAssertEqual(saved?.deviceID, incoming.deviceID)
        XCTAssertEqual(sidecar, incomingSidecar)
    }

    func testSyncCommitPreservesPendingLocalPlaybackAndSidecarAgainstStaleCrossSessionFetch() async throws {
        let url = makeURL(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let item = try article(); let rev = try revision(for: item, id: "rev-pending-playback")
        let pendingLocal = try PlaybackState(
            itemID: item.itemID, revisionID: rev.revisionID, sessionID: "local-session", sequence: 3,
            positionSeconds: 24, durationSeconds: rev.durationSeconds, completed: false, intent: .progress,
            deviceID: "device-local", updatedAt: Timestamp(Date(timeIntervalSince1970: 1_700_000_030)))
        let staleIncoming = try PlaybackState(
            itemID: item.itemID, revisionID: rev.revisionID, sessionID: "remote-session", sequence: 1,
            positionSeconds: 0, durationSeconds: rev.durationSeconds, completed: false, intent: .restart,
            deviceID: "device-remote", updatedAt: Timestamp(Date(timeIntervalSince1970: 1_700_000_020)))
        let localSidecar = PlaybackSystemFieldsSidecar(
            encodedSystemFields: Data([4, 5]), changeTag: "change-tag-local")
        let incomingSidecar = PlaybackSystemFieldsSidecar(
            encodedSystemFields: Data([8, 9]), changeTag: "change-tag-stale")
        let pendingEnvelope = try WiltedRecordCodec().encode(playback: pendingLocal)
        let pendingChange = try SyncPendingChange(
            operation: .update, recordID: pendingEnvelope.id, record: pendingEnvelope)
        let store = try LocalLibraryStore(url: url)
        try await store.save(playback: pendingLocal)
        try await store.save(
            playbackSidecar: localSidecar, for: item.itemID, revisionID: rev.revisionID)

        try await store.applySyncCommit(LocalLibrarySyncCommit(
            state: SyncRepositoryState(pendingChanges: [pendingChange]),
            playbacks: [.init(state: staleIncoming, sidecar: incomingSidecar)]))

        let saved = try await store.playbackState(for: item.itemID, revisionID: rev.revisionID)
        let sidecar = try await store.playbackSidecar(for: item.itemID, revisionID: rev.revisionID)
        XCTAssertEqual(saved?.sessionID, pendingLocal.sessionID)
        XCTAssertEqual(saved?.sequence, pendingLocal.sequence)
        XCTAssertEqual(saved?.positionSeconds, pendingLocal.positionSeconds)
        XCTAssertEqual(saved?.intent, pendingLocal.intent)
        XCTAssertEqual(saved?.deviceID, pendingLocal.deviceID)
        XCTAssertEqual(sidecar, localSidecar)
    }

    func testCorruptRepositoryStateDoesNotSilentlyReset() async throws {
        let url = makeURL(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try LocalLibraryStore.corruptRepositoryStateFixture(at: url, data: Data("corrupt-state".utf8))
        let store = try LocalLibraryStore(url: url)
        do {
            _ = try await store.syncRepositoryState()
            XCTFail("Expected corrupt repository state to throw")
        } catch {
            XCTAssertTrue(error is DecodingError)
        }
    }

    func testPartialSnapshotRetainsEveryLocalState() async throws {
        let url = makeURL(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = try LocalLibraryStore(url: url)
        let statuses: [LocalLibrarySyncStatus] = [.remoteAcknowledged, .localOnly, .pendingUpload, .conflicted, .failedUpload]
        var items: [ItemID] = []
        for (index, status) in statuses.enumerated() {
            let value = try Article(itemID: ItemID.derive(from: URL(string: "https://example.test/article-\(index)")!), canonicalURL: URL(string: "https://example.test/article-\(index)")!, title: "Article \(index)", source: "example.test", createdAt: Timestamp(Date(timeIntervalSince1970: Double(index))))
            items.append(value.itemID); try await store.save(article: value); try await store.setSyncStatus(status, for: value.itemID)
        }
        let result = try await store.finalizeSnapshot(generationID: "generation-partial", fetchComplete: false, seenRemoteItemIDs: [items[0]])
        XCTAssertFalse(result.mutated)
        let articleCount = try await store.articles().count
        XCTAssertEqual(articleCount, statuses.count)
    }

    func testCompleteSnapshotDeletesOnlyUnseenRemoteAcknowledgedItems() async throws {
        let url = makeURL(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = try LocalLibraryStore(url: url)
        let remote = try article()
        let localURL = URL(string: "https://example.test/local")!
        let local = try Article(itemID: ItemID.derive(from: localURL), canonicalURL: localURL, title: "Local", source: "example.test", createdAt: Timestamp(Date(timeIntervalSince1970: 1_700_000_004)))
        try await store.save(article: remote); try await store.save(article: local)
        try await store.setSyncStatus(.remoteAcknowledged, for: remote.itemID)
        try await store.setSyncStatus(.localOnly, for: local.itemID)
        let result = try await store.finalizeSnapshot(generationID: "generation-complete", fetchComplete: true, seenRemoteItemIDs: Set<ItemID>())
        XCTAssertEqual(result.deletedItemIDs, [remote.itemID])
        let deletedArticle = try await store.article(for: remote.itemID)
        let retainedArticle = try await store.article(for: local.itemID)
        XCTAssertNil(deletedArticle)
        XCTAssertNotNil(retainedArticle)
    }

}
