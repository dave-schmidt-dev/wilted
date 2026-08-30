import XCTest
import WiltedDomain
import WiltedSync
@testable import WiltedProducer

final class LocalLibraryStoreTests: XCTestCase {
    private struct ForcedMigrationFailure: Error {}

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

    private func podcastValues() throws -> (PodcastFeed, PodcastEpisode) {
        let feedURL = URL(string: "https://podcasts.example.test/feed.xml")!
        let enclosureURL = URL(string: "https://podcasts.example.test/audio/episode-1.mp3")!
        let feedID = try ItemID.derivePodcastFeed(from: feedURL)
        let feed = try PodcastFeed(itemID: feedID, canonicalURL: feedURL, title: "The Wilted Show",
                                   author: "Wilted", artworkURL: URL(string: "https://podcasts.example.test/art.jpg"),
                                   createdAt: Timestamp(Date(timeIntervalSince1970: 1_700_000_100)))
        let episodeID = try ItemID.derivePodcastEpisode(feedURL: feedURL, rssGUID: "episode-1", enclosureURL: enclosureURL)
        let episode = try PodcastEpisode(itemID: episodeID, feedID: feedID, feedURL: feedURL, rssGUID: "episode-1",
                                         title: "Episode One", author: "Wilted", publishedTime: feed.createdAt,
                                         enclosureURL: enclosureURL, enclosureMediaType: "audio/mpeg", enclosureByteCount: 1000,
                                         durationSeconds: 120, artworkURL: feed.artworkURL, createdAt: feed.createdAt)
        return (feed, episode)
    }

    /// Marking an article deleted has to survive a round trip. Nothing covered
    /// this, and the producer's Remove action depends on it entirely.
    func testDeletingAnArticleSurvivesAReadBack() async throws {
        let url = makeURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let article = try article()
        let store = try LocalLibraryStore(url: url)
        try await store.save(article: article)
        var flags = try await store.articles().map(\.isDeleted)
        XCTAssertEqual(flags, [false])

        let deleted = try Article(
            itemID: article.itemID, canonicalURL: article.canonicalURL, title: article.title,
            source: article.source, author: article.author, publishedTime: article.publishedTime,
            createdAt: article.createdAt, isDeleted: true
        )
        try await store.save(article: deleted)
        flags = try await store.articles().map(\.isDeleted)
        XCTAssertEqual(flags, [true], "in-process read back")
        let single = try await store.article(for: article.itemID)?.isDeleted
        XCTAssertEqual(single, true, "single-item read back")

        let reopened = try LocalLibraryStore(url: url)
        flags = try await reopened.articles().map(\.isDeleted)
        XCTAssertEqual(flags, [true], "read back after reopen")
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
        XCTAssertEqual(migratedInspection.schemaVersion, .v6)
    }

    /// The V4 -> V5 stage renames the deletion column. A read-back inside one
    /// schema version cannot catch a rename that drops its values, so this
    /// walks a deleted article from a frozen V2 store all the way to V5.
    func testDeletionFlagSurvivesMigrationFromV2() async throws {
        let url = makeURL(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let live = try article()
        let removed = try Article(
            itemID: live.itemID, canonicalURL: live.canonicalURL, title: live.title,
            source: live.source, author: live.author, publishedTime: live.publishedTime,
            createdAt: live.createdAt, isDeleted: true
        )
        let rev = try revision(for: removed, id: "rev-deleted-migration")
        try LocalLibraryStore.createV2MigrationFixture(
            at: url, article: removed, playback: try playback(for: removed, revision: rev, position: 3)
        )

        let migrated = try LocalLibraryStore(url: url)
        let flags = try await migrated.articles().map(\.isDeleted)
        XCTAssertEqual(flags, [true], "the deletion flag must survive the column rename")
        let single = try await migrated.article(for: removed.itemID)?.isDeleted
        XCTAssertEqual(single, true)
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

    func testV6PodcastStateRoundTripsWithoutTouchingArticleState() async throws {
        let url = makeURL(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let article = try article(); let revision = try revision(for: article, id: "v6-revision")
        let store = try LocalLibraryStore(url: url)
        try await store.save(article: article)
        try await store.saveReadyRevision(revision, mediaURL: URL(fileURLWithPath: "/tmp/v6.m4a"))
        try await store.save(playback: playback(for: article, revision: revision, position: 9))
        let (feed, episode) = try podcastValues()
        try await store.save(feed: feed); try await store.save(episode: episode)
        try await store.save(subscription: PodcastSubscription(feedID: feed.itemID, subscribedAt: feed.createdAt))
        try await store.save(download: try PodcastDownload(episodeID: episode.itemID, status: .completed,
                                                            bytesReceived: 1000, expectedByteCount: 1000,
                                                            localURL: URL(fileURLWithPath: "/tmp/episode.mp3"),
                                                            contentHash: "sha256:" + String(repeating: "a", count: 64), updatedAt: feed.createdAt))
        try await store.save(artwork: try PodcastArtwork(id: "art-1", ownerID: feed.itemID,
                                                          remoteURL: feed.artworkURL, localURL: URL(fileURLWithPath: "/tmp/art.jpg"),
                                                          byteCount: 10, updatedAt: feed.createdAt))
        try await store.save(queueEntry: try PodcastQueueEntry(episodeID: episode.itemID, position: 0, addedAt: feed.createdAt))
        try await store.save(playbackSpeed: try PodcastPlaybackSpeed(itemID: episode.itemID, speed: 1.5, updatedAt: feed.createdAt))
        let reopened = try LocalLibraryStore(url: url)
        let reopenedFeed = try await reopened.podcastFeed(for: feed.itemID)
        let reopenedEpisode = try await reopened.podcastEpisode(for: episode.itemID)
        let reopenedSubscription = try await reopened.subscription(for: feed.itemID)
        let reopenedDownload = try await reopened.download(for: episode.itemID)
        let reopenedArtwork = try await reopened.artwork(for: "art-1")
        let reopenedQueue = try await reopened.upNext()
        let reopenedSpeed = try await reopened.playbackSpeed(for: episode.itemID)
        let reopenedArticle = try await reopened.article(for: article.itemID)
        let reopenedRevision = try await reopened.readyRevision(for: article.itemID)
        let reopenedPlayback = try await reopened.playbackState(for: article.itemID, revisionID: revision.revisionID)
        XCTAssertEqual(reopenedFeed, feed)
        XCTAssertEqual(reopenedEpisode, episode)
        XCTAssertEqual(reopenedSubscription?.enabled, true)
        XCTAssertEqual(reopenedDownload?.status, .completed)
        XCTAssertEqual(reopenedArtwork?.ownerID, feed.itemID)
        XCTAssertEqual(reopenedQueue.map(\.episodeID), [episode.itemID])
        XCTAssertEqual(reopenedSpeed?.speed, 1.5)
        XCTAssertEqual(reopenedArticle, article)
        XCTAssertEqual(reopenedRevision?.revision.itemID, revision.itemID)
        XCTAssertEqual(reopenedRevision?.revision.revisionID, revision.revisionID)
        XCTAssertEqual(reopenedRevision?.revision.contentHash, revision.contentHash)
        XCTAssertEqual(reopenedPlayback?.positionSeconds, 9)
    }

    func testPodcastRecordsUpsertAndQueriesReflectLatestState() async throws {
        let url = makeURL(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = try LocalLibraryStore(url: url)
        let (feed, episode) = try podcastValues()
        let secondEpisodeURL = URL(string: "https://podcasts.example.test/audio/episode-2.mp3")!
        let secondEpisodeID = try ItemID.derivePodcastEpisode(feedURL: feed.canonicalURL, rssGUID: "episode-2", enclosureURL: secondEpisodeURL)
        let secondEpisode = try PodcastEpisode(itemID: secondEpisodeID, feedID: feed.itemID, feedURL: feed.canonicalURL,
                                                rssGUID: "episode-2", title: "Episode Two", publishedTime: feed.createdAt,
                                                enclosureURL: secondEpisodeURL, enclosureMediaType: "audio/mpeg", durationSeconds: 90,
                                                createdAt: feed.createdAt)
        let otherFeedURL = URL(string: "https://other.example.test/feed.xml")!
        let otherFeedID = try ItemID.derivePodcastFeed(from: otherFeedURL)
        let otherFeed = try PodcastFeed(itemID: otherFeedID, canonicalURL: otherFeedURL, title: "Other Show",
                                        createdAt: Timestamp(Date(timeIntervalSince1970: 1_700_000_200)))
        let otherEpisodeURL = URL(string: "https://other.example.test/audio/episode.mp3")!
        let otherEpisodeID = try ItemID.derivePodcastEpisode(feedURL: otherFeedURL, rssGUID: "other-episode", enclosureURL: otherEpisodeURL)
        let otherEpisode = try PodcastEpisode(itemID: otherEpisodeID, feedID: otherFeedID, feedURL: otherFeedURL,
                                              rssGUID: "other-episode", title: "Other Episode", publishedTime: otherFeed.createdAt,
                                              enclosureURL: otherEpisodeURL, enclosureMediaType: "audio/mpeg", durationSeconds: 60,
                                              createdAt: otherFeed.createdAt)

        try await store.save(feed: feed); try await store.save(feed: otherFeed)
        try await store.save(episode: episode); try await store.save(episode: secondEpisode); try await store.save(episode: otherEpisode)

        let updatedFeed = try PodcastFeed(itemID: feed.itemID, canonicalURL: feed.canonicalURL, title: "Updated Wilted Show",
                                          author: "Updated Author", createdAt: feed.createdAt)
        let updatedEpisodeURL = URL(string: "https://podcasts.example.test/audio/episode-1-remastered.mp3")!
        let updatedEpisode = try PodcastEpisode(itemID: episode.itemID, feedID: feed.itemID, feedURL: feed.canonicalURL,
                                                rssGUID: episode.rssGUID, title: "Episode One Remastered",
                                                publishedTime: Timestamp(Date(timeIntervalSince1970: 1_700_000_101)),
                                                enclosureURL: updatedEpisodeURL, enclosureMediaType: "audio/mpeg",
                                                durationSeconds: 121, createdAt: episode.createdAt)
        try await store.save(feed: updatedFeed); try await store.save(episode: updatedEpisode)

        let loadedFeed = try await store.podcastFeed(for: feed.itemID)
        let loadedFeeds = try await store.podcastFeeds()
        let loadedEpisode = try await store.podcastEpisode(for: episode.itemID)
        let feedEpisodes = try await store.podcastEpisodes(for: feed.itemID)
        let allEpisodes = try await store.podcastEpisodes()
        XCTAssertEqual(loadedFeed, updatedFeed)
        XCTAssertEqual(loadedFeeds.map(\.itemID), [otherFeed.itemID, feed.itemID])
        XCTAssertEqual(loadedEpisode, updatedEpisode)
        XCTAssertEqual(feedEpisodes.map(\.itemID), [episode.itemID, secondEpisode.itemID])
        XCTAssertEqual(allEpisodes.count, 3)

        try await store.save(subscription: PodcastSubscription(feedID: feed.itemID, subscribedAt: feed.createdAt))
        try await store.save(subscription: PodcastSubscription(feedID: feed.itemID, subscribedAt: feed.createdAt, enabled: false))
        let loadedSubscription = try await store.subscription(for: feed.itemID)
        let subscriptions = try await store.subscriptions()
        XCTAssertEqual(loadedSubscription?.enabled, false)
        XCTAssertEqual(subscriptions.count, 1)

        let queued = try PodcastDownload(episodeID: episode.itemID, updatedAt: feed.createdAt)
        let completed = try PodcastDownload(episodeID: episode.itemID, status: .completed, bytesReceived: 100,
                                             expectedByteCount: 100, localURL: URL(fileURLWithPath: "/tmp/episode.mp3"),
                                             contentHash: "sha256:" + String(repeating: "b", count: 64), updatedAt: feed.createdAt)
        try await store.save(download: queued); try await store.save(download: completed)
        let loadedDownload = try await store.download(for: episode.itemID)
        let downloads = try await store.downloads()
        XCTAssertEqual(loadedDownload, completed)
        XCTAssertEqual(downloads.count, 1)

        let artwork = try PodcastArtwork(id: "art-upsert", ownerID: feed.itemID, byteCount: 10, updatedAt: feed.createdAt)
        let updatedArtwork = try PodcastArtwork(id: artwork.id, ownerID: feed.itemID,
                                                localURL: URL(fileURLWithPath: "/tmp/art-updated.jpg"), byteCount: 20,
                                                updatedAt: feed.createdAt)
        try await store.save(artwork: artwork); try await store.save(artwork: updatedArtwork)
        let loadedArtwork = try await store.artwork(for: artwork.id)
        XCTAssertEqual(loadedArtwork, updatedArtwork)

        try await store.save(queueEntry: try PodcastQueueEntry(episodeID: episode.itemID, position: 1, addedAt: feed.createdAt))
        try await store.save(queueEntry: try PodcastQueueEntry(episodeID: secondEpisode.itemID, position: 0, addedAt: feed.createdAt))
        try await store.save(queueEntry: try PodcastQueueEntry(episodeID: episode.itemID, position: 2, addedAt: feed.createdAt))
        let queue = try await store.queue()
        XCTAssertEqual(queue.map(\.episodeID), [secondEpisode.itemID, episode.itemID])
        XCTAssertEqual(queue.map(\.position), [0, 2])

        try await store.save(playbackSpeed: try PodcastPlaybackSpeed(itemID: episode.itemID, speed: 1, updatedAt: feed.createdAt))
        let updatedSpeed = try PodcastPlaybackSpeed(itemID: episode.itemID, speed: 1.75, updatedAt: feed.createdAt)
        try await store.save(playbackSpeed: updatedSpeed)
        let loadedSpeed = try await store.playbackSpeed(for: episode.itemID)
        XCTAssertEqual(loadedSpeed, updatedSpeed)
    }

    func testPodcastDownloadValidationRequiresCompleteLocalMediaOnlyForCompleted() throws {
        let item = try ItemID(rawValue: "item-download-validation")
        let timestamp = Timestamp(Date(timeIntervalSince1970: 1_700_000_000))
        let hash = "sha256:" + String(repeating: "c", count: 64)
        XCTAssertThrowsError(try PodcastDownload(episodeID: item, status: .completed, bytesReceived: 10,
                                                 expectedByteCount: 10, updatedAt: timestamp))
        XCTAssertThrowsError(try PodcastDownload(episodeID: item, status: .completed, bytesReceived: 10,
                                                 expectedByteCount: 10, localURL: URL(fileURLWithPath: "/tmp/audio.mp3"),
                                                 updatedAt: timestamp))
        XCTAssertThrowsError(try PodcastDownload(episodeID: item, status: .completed, bytesReceived: 11,
                                                 expectedByteCount: 10, localURL: URL(fileURLWithPath: "/tmp/audio.mp3"),
                                                 contentHash: hash, updatedAt: timestamp))
        XCTAssertNoThrow(try PodcastDownload(episodeID: item, status: .queued, updatedAt: timestamp))
        XCTAssertNoThrow(try PodcastDownload(episodeID: item, status: .downloading, bytesReceived: 10,
                                             expectedByteCount: 100, updatedAt: timestamp))
        XCTAssertNoThrow(try PodcastDownload(episodeID: item, status: .failed, bytesReceived: 10,
                                             expectedByteCount: 10, updatedAt: timestamp))
        XCTAssertThrowsError(try PodcastArtwork(id: "art-invalid-hash", ownerID: item,
                                                 contentHash: "sha256:" + String(repeating: "A", count: 64), updatedAt: timestamp))
        XCTAssertNoThrow(try PodcastArtwork(id: "art-valid-hash", ownerID: item,
                                            contentHash: hash, updatedAt: timestamp))
    }

    func testWALCheckpointOutputRejectsBusyIncompleteOrUntruncatedResults() throws {
        XCTAssertNoThrow(try LocalLibraryStore.validateWALCheckpointOutputForTesting("0|0|0\n"))
        XCTAssertNoThrow(try LocalLibraryStore.validateWALCheckpointOutputForTesting("0|3|3\n", walByteCount: 0))
        XCTAssertThrowsError(try LocalLibraryStore.validateWALCheckpointOutputForTesting("1|3|3\n", walByteCount: 0))
        XCTAssertThrowsError(try LocalLibraryStore.validateWALCheckpointOutputForTesting("0|3|2\n", walByteCount: 0))
        XCTAssertThrowsError(try LocalLibraryStore.validateWALCheckpointOutputForTesting("0|3|3\n", walByteCount: 512))
        XCTAssertThrowsError(try LocalLibraryStore.validateWALCheckpointOutputForTesting("0|3\n", walByteCount: 0))
    }

    func testMigrationPreflightRetainsUsableV5FilesBeforeV6Migration() async throws {
        let url = makeURL(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let item = try article(); let rev = try revision(for: item, id: "v5-forward")
        try LocalLibraryStore.createV5MigrationFixture(at: url, article: item, playback: try playback(for: item, revision: rev, position: 21))
        let preflight = try LocalLibraryStore.migrationPreflight(at: url)
        XCTAssertTrue(preflight.retainedFiles.contains(where: { $0.lastPathComponent == url.lastPathComponent }))
        let retained = try LocalLibraryStore(url: preflight.retainedURL, migrate: false)
        let retainedArticle = try await retained.article(for: item.itemID)
        XCTAssertEqual(retainedArticle, item)
        let migrated = try LocalLibraryStore(url: url)
        let migratedArticle = try await migrated.article(for: item.itemID)
        let migratedPlayback = try await migrated.playbackState(for: item.itemID, revisionID: rev.revisionID)
        XCTAssertEqual(migratedArticle, item)
        XCTAssertEqual(migratedPlayback?.positionSeconds, 21)
    }

    func testMigrationPreflightRenamesRetainedSidecarsAndRejectsSourceDirectoryDestination() throws {
        let url = makeURL(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let item = try article(); let rev = try revision(for: item, id: "v5-custom-retention")
        try LocalLibraryStore.createV5MigrationFixture(at: url, article: item,
                                                       playback: try playback(for: item, revision: rev, position: 4))
        let customURL = url.deletingLastPathComponent().appendingPathComponent("retained/backup.sqlite")
        let preflight = try LocalLibraryStore.migrationPreflight(at: url, retainingAt: customURL)
        XCTAssertEqual(preflight.retainedURL, customURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: customURL.path))
        XCTAssertTrue(preflight.retainedFiles.allSatisfy { $0.lastPathComponent == "backup.sqlite" || $0.lastPathComponent.hasPrefix("backup.sqlite-") })

        let unsafeURL = url.deletingLastPathComponent().appendingPathComponent("unsafe.sqlite")
        XCTAssertThrowsError(try LocalLibraryStore.migrationPreflight(at: url, retainingAt: unsafeURL))
        XCTAssertFalse(FileManager.default.fileExists(atPath: unsafeURL.path))
    }

    func testV5RowsRemainReadableAfterAdditiveV6Migration() async throws {
        let url = makeURL(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let item = try article(); let rev = try revision(for: item, id: "v5-all-rows")
        try LocalLibraryStore.createV5MigrationFixture(at: url, article: item,
                                                       playback: try playback(for: item, revision: rev, position: 23))
        let migrated = try LocalLibraryStore(url: url)
        let inspection = try await migrated.inspect()
        XCTAssertEqual(inspection.schemaVersion, .v6)
        XCTAssertEqual(inspection.articleCount, 1)
        XCTAssertEqual(inspection.revisionCount, 1)
        XCTAssertEqual(inspection.transcriptCount, 1)
        XCTAssertEqual(inspection.preparationCount, 1)
        XCTAssertEqual(inspection.playbackCount, 1)
        let syncState = try await migrated.syncState(for: "private-zone")
        let tombstone = try await migrated.tombstone(for: "v5-tombstone")
        let transcript = try await migrated.transcript(for: item.itemID, revisionID: rev.revisionID)
        let journal = try await migrated.preparationJournal(for: "v5-request")
        let loadedPlayback = try await migrated.playbackState(for: item.itemID, revisionID: rev.revisionID)
        let repositoryState = try await migrated.syncRepositoryState()
        let expectedUpdatedAt = Timestamp(Date(timeIntervalSince1970: 1_700_000_010))
        let expectedRevision = try AudioRevision(itemID: item.itemID, revisionID: rev.revisionID, durationSeconds: 42,
                                                  byteCount: 1, contentHash: "sha256:" + String(repeating: "5", count: 64),
                                                  mediaType: "audio/mp4", createdAt: expectedUpdatedAt, schemaVersion: 3)
        let expectedPlayback = try playback(for: item, revision: rev, position: 23)
        let expectedTranscript = try Transcript(itemID: item.itemID, revisionID: rev.revisionID,
                                                 availability: .available, text: "V5 transcript", updatedAt: expectedUpdatedAt)
        let expectedStatus = try PreparationStatus(stage: .completed, detail: "V5 ready", fraction: 1,
                                                    cancellable: false,
                                                    terminalResult: try PreparationTerminalResult(outcome: .succeeded, revisionID: rev.revisionID),
                                                    emittedAt: expectedUpdatedAt)
        let expectedJournal = PreparationJournalEntry(id: "v5-prep", itemID: item.itemID, requestID: "v5-request", status: expectedStatus)
        let expectedTombstone = LocalLibraryTombstone(id: "v5-tombstone", itemID: item.itemID,
                                                      generationID: "v5-generation", requestedAt: expectedUpdatedAt)
        let migratedArticle = try await migrated.article(for: item.itemID)
        let migratedRevision = try await migrated.readyRevision(for: item.itemID)
        XCTAssertEqual(migratedArticle, item)
        XCTAssertEqual(migratedRevision?.revision, expectedRevision)
        XCTAssertEqual(migratedRevision?.mediaURL, URL(fileURLWithPath: "/tmp/v5.m4a"))
        XCTAssertEqual(loadedPlayback, expectedPlayback)
        XCTAssertEqual(transcript, expectedTranscript)
        XCTAssertEqual(journal, [expectedJournal])
        XCTAssertEqual(tombstone, expectedTombstone)
        XCTAssertEqual(syncState, LocalLibrarySyncState(key: "private-zone", engineState: Data([5]),
                                                         lastFetchAt: expectedUpdatedAt, lastSendAt: expectedUpdatedAt))
        XCTAssertEqual(repositoryState, SyncRepositoryState(engineState: Data([5])))
    }

    func testForcedMigrationFailureLeavesEveryCheckpointedStoreFileIdentical() async throws {
        let url = makeURL(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let item = try article(); let rev = try revision(for: item, id: "v5-forced-failure")
        try LocalLibraryStore.createV5MigrationFixture(at: url, article: item,
                                                       playback: try playback(for: item, revision: rev, position: 27))

        let failedURL = url.deletingLastPathComponent().appendingPathComponent("failed/library.sqlite")
        final class SnapshotCheck: @unchecked Sendable {
            var matched = false
            var retainedSidecar = false
        }
        let check = SnapshotCheck()
        XCTAssertThrowsError(try LocalLibraryStore(url: url, migrate: true,
                                                   migrationFailure: {
                                                       do {
                                                           let manager = FileManager.default
                                                           let sourceDirectory = url.deletingLastPathComponent()
                                                           let sourceFiles = try manager.contentsOfDirectory(at: sourceDirectory, includingPropertiesForKeys: nil)
                                                               .filter { $0.lastPathComponent == url.lastPathComponent || $0.lastPathComponent.hasPrefix("\(url.lastPathComponent)-") }
                                                           let retainedFiles = try manager.contentsOfDirectory(at: failedURL.deletingLastPathComponent(), includingPropertiesForKeys: nil)
                                                               .filter { $0.lastPathComponent == failedURL.lastPathComponent || $0.lastPathComponent.hasPrefix("\(failedURL.lastPathComponent)-") }
                                                           guard Set(sourceFiles.map(\.lastPathComponent)) == Set(retainedFiles.map(\.lastPathComponent)) else { throw ForcedMigrationFailure() }
                                                           check.retainedSidecar = sourceFiles.contains { $0.lastPathComponent.hasSuffix("-wal") || $0.lastPathComponent.hasSuffix("-shm") }
                                                           for sourceFile in sourceFiles {
                                                               let retainedFile = failedURL.deletingLastPathComponent().appendingPathComponent(sourceFile.lastPathComponent)
                                                               guard try Data(contentsOf: sourceFile) == Data(contentsOf: retainedFile) else { throw ForcedMigrationFailure() }
                                                           }
                                                           check.matched = true
                                                       } catch {
                                                           throw ForcedMigrationFailure()
                                                       }
                                                       throw ForcedMigrationFailure()
                                                   }, retainingAt: failedURL))
        XCTAssertTrue(check.retainedSidecar, "preflight must retain SQLite sidecars when the store provides them")
        XCTAssertTrue(check.matched, "retained post-checkpoint files must match the source before migration")
        let retainedFiles = try FileManager.default.contentsOfDirectory(
            at: failedURL.deletingLastPathComponent(), includingPropertiesForKeys: nil
        ).filter { $0.lastPathComponent == failedURL.lastPathComponent || $0.lastPathComponent.hasPrefix("\(failedURL.lastPathComponent)-") }
        XCTAssertFalse(retainedFiles.isEmpty)
    }
}
