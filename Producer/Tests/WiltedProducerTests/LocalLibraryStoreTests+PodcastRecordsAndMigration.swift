import CryptoKit
import Foundation
import SwiftData
import XCTest
import WiltedDomain
import WiltedSync
@testable import WiltedProducer

extension LocalLibraryStoreTests {
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
        XCTAssertEqual(queue.map(\.position), [0, 1])

        try await store.save(playbackSpeed: try PodcastPlaybackSpeed(itemID: episode.itemID, speed: 1, updatedAt: feed.createdAt))
        let updatedSpeed = try PodcastPlaybackSpeed(itemID: episode.itemID, speed: 1.75, updatedAt: feed.createdAt)
        try await store.save(playbackSpeed: updatedSpeed)
        let loadedSpeed = try await store.playbackSpeed(for: episode.itemID)
        XCTAssertEqual(loadedSpeed, updatedSpeed)
    }

    func testPodcastRevisionResolutionPrefersNamespacedRowsPreservesLegacyAndAvoidsDuplicates() async throws {
        let url = makeURL(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = try LocalLibraryStore(url: url)
        let (feed, firstEpisode) = try podcastValues()
        let secondEnclosureURL = URL(string: "https://podcasts.example.test/audio/episode-2.mp3")!
        let secondID = try ItemID.derivePodcastEpisode(
            feedURL: feed.canonicalURL,
            rssGUID: "episode-2",
            enclosureURL: secondEnclosureURL
        )
        let secondEpisode = try PodcastEpisode(
            itemID: secondID, feedID: feed.itemID, feedURL: feed.canonicalURL, rssGUID: "episode-2",
            title: "Episode Two", enclosureURL: secondEnclosureURL, enclosureMediaType: "audio/mpeg",
            createdAt: firstEpisode.createdAt
        )
        try await store.save(feed: feed)
        try await store.save(episode: firstEpisode)
        try await store.save(episode: secondEpisode)

        let hash = "sha256:" + String(repeating: "c", count: 64)
        let legacyID = try RevisionID.derive(downloadedAudioContentHash: hash)
        let firstNamespacedID = try RevisionID.derive(
            podcastDownloadedAudioItemID: firstEpisode.itemID,
            contentHash: hash
        )
        let secondNamespacedID = try RevisionID.derive(
            podcastDownloadedAudioItemID: secondEpisode.itemID,
            contentHash: hash
        )
        XCTAssertNotEqual(firstNamespacedID, secondNamespacedID)

        func revision(_ itemID: ItemID, _ revisionID: RevisionID) throws -> AudioRevision {
            try AudioRevision(
                itemID: itemID, revisionID: revisionID, durationSeconds: 60, byteCount: 100,
                contentHash: hash, mediaType: "audio/mpeg", createdAt: firstEpisode.createdAt, schemaVersion: 3
            )
        }

        try await store.saveReadyRevision(
            revision(firstEpisode.itemID, legacyID),
            mediaURL: URL(fileURLWithPath: "/tmp/legacy-podcast.mp3")
        )
        let resolvedLegacy = try await store.resolvePodcastRevision(
            itemID: firstEpisode.itemID,
            contentHash: hash
        )
        XCTAssertEqual(resolvedLegacy, legacyID)

        try await store.saveReadyRevision(
            revision(firstEpisode.itemID, firstNamespacedID),
            mediaURL: URL(fileURLWithPath: "/tmp/namespaced-podcast.mp3")
        )
        let resolvedNamespaced = try await store.resolvePodcastRevision(
            itemID: firstEpisode.itemID,
            contentHash: hash
        )
        XCTAssertEqual(resolvedNamespaced, firstNamespacedID)

        let secondRevision = try revision(secondEpisode.itemID, secondNamespacedID)
        let secondURL = URL(fileURLWithPath: "/tmp/second-podcast.mp3")
        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<8 {
                group.addTask { try await store.saveReadyRevision(secondRevision, mediaURL: secondURL) }
            }
            try await group.waitForAll()
        }
        let resolvedSecond = try await store.resolvePodcastRevision(
            itemID: secondEpisode.itemID,
            contentHash: hash
        )
        let secondRevisions = try await store.revisions(for: secondEpisode.itemID)
        let inspection = try await store.inspect()
        XCTAssertEqual(resolvedSecond, secondNamespacedID)
        XCTAssertEqual(secondRevisions.count, 1)
        XCTAssertEqual(inspection.revisionCount, 3)
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
        XCTAssertEqual(try LocalLibraryStore.diskSchemaVersion(at: preflight.retainedURL), .known(5),
                       "the retained copy must stay at the source schema")
        // A store that needs a migration is refused, not migrated, without `migrate`.
        XCTAssertThrowsError(try LocalLibraryStore(url: preflight.retainedURL, migrate: false)) { error in
            XCTAssertEqual(error as? LocalLibraryStoreError, .migrationRequired(fromVersion: 5))
        }
        let retained = try LocalLibraryStore(url: preflight.retainedURL)
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
        XCTAssertEqual(inspection.schemaVersion, .v15)
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
        // Still schema version one and still untimed after the version-seven
        // migration: adding columns must not restate what an older row claimed.
        let expectedTranscript = try Transcript(itemID: item.itemID, revisionID: rev.revisionID,
                                                 availability: .available, text: "V5 transcript",
                                                 updatedAt: expectedUpdatedAt, schemaVersion: 1)
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

}
