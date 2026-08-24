import XCTest
import WiltedDomain
@testable import WiltedProducer

final class LocalLibraryStoreTests: XCTestCase {
    private func makeURL(_ name: String = #function) -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("wilted-store-\(name)-\(UUID().uuidString)").appendingPathComponent("library.sqlite")
    }

    private func article() throws -> Article {
        let url = URL(string: "https://example.test/library/article")!
        return try Article(itemID: ItemID.derive(from: url), canonicalURL: url, title: "A durable article", source: "example.test", createdAt: Timestamp(Date(timeIntervalSince1970: 1_700_000_000)))
    }

    private func revision(for article: Article, id: String, at time: TimeInterval = 1_700_000_001) throws -> AudioRevision {
        try AudioRevision(itemID: article.itemID, revisionID: RevisionID(rawValue: id), durationSeconds: 42, byteCount: 128,
                          contentHash: "sha256\(String(repeating: ":", count: 0)):\(String(repeating: "a", count: 64))",
                          mediaType: "audio/mp4", createdAt: Timestamp(Date(timeIntervalSince1970: time)), schemaVersion: 1)
    }

    private func playback(for article: Article, revision: AudioRevision, position: Double) throws -> PlaybackState {
        try PlaybackState(itemID: article.itemID, revisionID: revision.revisionID, sessionID: "session-1", sequence: 1,
                          positionSeconds: position, durationSeconds: revision.durationSeconds, completed: false, intent: .progress,
                          deviceID: "device-mac", updatedAt: Timestamp(Date(timeIntervalSince1970: 1_700_000_010)))
    }

    func testInterruptedStoreReopensWithArticleRevisionPreparationAndPlayback() async throws {
        let url = makeURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let article = try article()
        let revision = try revision(for: article, id: "rev-v1")
        let status = try PreparationStatus(stage: .completed, detail: "ready", fraction: 1, cancellable: false,
                                            terminalResult: try PreparationTerminalResult(outcome: .succeeded, revisionID: revision.revisionID),
                                            emittedAt: Timestamp(Date(timeIntervalSince1970: 1_700_000_002)))
        do {
            let store = try LocalLibraryStore(url: url)
            try await store.save(article: article)
            try await store.saveReadyRevision(revision, mediaURL: URL(fileURLWithPath: "/tmp/rev-v1.m4a"))
            try await store.record(preparation: PreparationJournalEntry(id: "prep-1", itemID: article.itemID, requestID: "request-1", status: status))
            try await store.save(playback: playback(for: article, revision: revision, position: 12))
        }
        let reopened = try LocalLibraryStore(url: url)
        let reopenedArticle = try await reopened.article(for: article.itemID)
        let reopenedRevision = try await reopened.readyRevision(for: article.itemID)
        let reopenedJournal = try await reopened.preparationJournal(for: "request-1")
        let reopenedPlayback = try await reopened.playbackState(for: article.itemID, revisionID: revision.revisionID)
        XCTAssertEqual(reopenedArticle, article)
        XCTAssertEqual(reopenedRevision?.revisionID, revision.revisionID)
        XCTAssertEqual(reopenedJournal.count, 1)
        XCTAssertEqual(reopenedPlayback?.positionSeconds, 12)
    }

    func testV2StoreMigratesArticlePlaybackAndSafeNewDefaults() async throws {
        let url = makeURL(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let item = try article()
        let rev = try revision(for: item, id: "rev-migration")
        let state = try playback(for: item, revision: rev, position: 17)
        try LocalLibraryStore.createV2MigrationFixture(at: url, article: item, playback: state)

        let migrated = try LocalLibraryStore(url: url)
        let migratedArticle = try await migrated.article(for: item.itemID)
        let migratedPlayback = try await migrated.playbackState(for: item.itemID, revisionID: rev.revisionID)
        XCTAssertEqual(migratedArticle, item)
        XCTAssertEqual(migratedPlayback?.positionSeconds, 17)
        let migratedStatus = try await migrated.syncStatus(for: item.itemID)
        let migratedSidecar = try await migrated.playbackSidecar(for: item.itemID, revisionID: rev.revisionID)
        XCTAssertEqual(migratedStatus, .localOnly)
        XCTAssertNil(migratedSidecar?.changeTag)
        let migratedTranscript = try await migrated.transcript(for: item.itemID, revisionID: rev.revisionID)
        let migratedInspection = try await migrated.inspect()
        XCTAssertNil(migratedTranscript)
        XCTAssertEqual(migratedInspection.schemaVersion, .v4)
    }

    func testPriorRevisionIsPreservedAndImmutableWhenNewRevisionIsSaved() async throws {
        let url = makeURL(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let article = try article(); let old = try revision(for: article, id: "rev-old", at: 1_700_000_001); let new = try revision(for: article, id: "rev-new", at: 1_700_000_002)
        let store = try LocalLibraryStore(url: url)
        try await store.saveReadyRevision(old, mediaURL: URL(fileURLWithPath: "/tmp/old.m4a"))
        try await store.saveReadyRevision(new, mediaURL: URL(fileURLWithPath: "/tmp/new.m4a"))
        let revisions = try await store.revisions(for: article.itemID)
        XCTAssertEqual(Set(revisions.map(\.revisionID)), [old.revisionID, new.revisionID])
        do {
            try await store.saveReadyRevision(old, mediaURL: URL(fileURLWithPath: "/tmp/changed.m4a"))
            XCTFail("Expected immutable revision error")
        } catch {
            XCTAssertEqual(error as? LocalLibraryStoreError, .immutableRevision(old.revisionID))
        }
    }

    func testTranscriptPersistsWithRevisionAndSurvivesRelaunch() async throws {
        let url = makeURL(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let item = try article()
        let rev = try revision(for: item, id: "rev-transcript")
        let transcript = try Transcript(itemID: item.itemID, revisionID: rev.revisionID,
                                        availability: .available, text: "Persisted article text.",
                                        languageCode: "en", updatedAt: rev.createdAt)
        do {
            let store = try LocalLibraryStore(url: url)
            try await store.saveReadyRevision(rev, mediaURL: URL(fileURLWithPath: "/tmp/transcript.m4a"),
                                              transcript: transcript)
            let inspection = try await store.inspect()
            XCTAssertEqual(inspection.transcriptCount, 1)
        }
        let reopened = try LocalLibraryStore(url: url)
        let reopenedTranscript = try await reopened.transcript(for: item.itemID, revisionID: rev.revisionID)
        XCTAssertEqual(reopenedTranscript, transcript)
    }

    func testTranscriptAndRevisionIdentityMustMatchBeforeAtomicSave() async throws {
        let url = makeURL(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let item = try article()
        let rev = try revision(for: item, id: "rev-a")
        let transcript = try Transcript(itemID: item.itemID, revisionID: RevisionID(rawValue: "rev-b"),
                                        availability: .available, text: "Text", updatedAt: rev.createdAt)
        let store = try LocalLibraryStore(url: url)
        do {
            try await store.saveReadyRevision(rev, mediaURL: URL(fileURLWithPath: "/tmp/rev-a.m4a"),
                                              transcript: transcript)
            XCTFail("Expected identity mismatch")
        } catch {
            XCTAssertEqual(error as? LocalLibraryStoreError, .revisionBelongsToDifferentItem)
        }
        let savedRevision = try await store.readyRevision(for: item.itemID)
        XCTAssertNil(savedRevision)
    }

    func testPlaybackRequiresMatchingStableItemAndRevision() async throws {
        let url = makeURL(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let article = try article(); let first = try revision(for: article, id: "rev-first"); let second = try revision(for: article, id: "rev-second")
        let store = try LocalLibraryStore(url: url)
        try await store.save(playback: playback(for: article, revision: first, position: 30))
        let mismatchedRevision = try await store.playbackState(for: article.itemID, revisionID: second.revisionID)
        XCTAssertNil(mismatchedRevision)
        let otherItem = try ItemID(rawValue: "item-other")
        let mismatchedItem = try await store.playbackState(for: otherItem, revisionID: first.revisionID)
        XCTAssertNil(mismatchedItem)
    }

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
