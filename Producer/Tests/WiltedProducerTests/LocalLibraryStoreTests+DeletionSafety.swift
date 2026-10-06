import Foundation
import SwiftData
import XCTest
import WiltedDomain
@testable import WiltedProducer

/// Confirmed destructive removals (Task 4.1): each commits in one save or
/// not at all, a failure at any staged step leaves the durable library
/// exactly as it was, and a duplicate confirm writes once.
extension LocalLibraryStoreTests {
    // MARK: - Article removal

    func testArticleRemovalCommitsFlagAndTombstoneInOneSave() async throws {
        let url = makeURL(); defer { removeStore(url) }
        let article = try article()
        try await saveArticle(article, at: url)
        let requestedAt = Timestamp(Date(timeIntervalSince1970: 1_700_000_500))

        let recorder = RemovalStageRecorder()
        let removed = try await recorder.observing {
            try await LocalLibraryStore(url: url).removeArticle(itemID: article.itemID, at: requestedAt)
        }
        XCTAssertTrue(removed)
        XCTAssertEqual(recorder.stages, LocalLibraryRemovalStage.articleRemoval)
        XCTAssertEqual(recorder.count(of: .save), 1, "flag and tombstone share one commit")

        let reopened = try LocalLibraryStore(url: url)
        let stored = try await reopened.article(for: article.itemID)
        let tombstone = try await reopened.tombstone(for: article.itemID.rawValue)
        XCTAssertEqual(stored?.isDeleted, true)
        XCTAssertEqual(tombstone?.itemID, article.itemID)
        XCTAssertEqual(tombstone?.requestedAt, requestedAt)
        XCTAssertEqual(tombstone?.remoteAcknowledged, false)
    }

    func testArticleRemovalFailureAtEachStageLeavesFlagAndTombstoneUnchangedOnReopen() async throws {
        for stage in LocalLibraryRemovalStage.articleRemoval {
            let url = makeURL("articleFailure-\(stage.rawValue)"); defer { removeStore(url) }
            let article = try article()
            try await saveArticle(article, at: url)

            do {
                _ = try await RemovalStageRecorder(failingAt: stage).observing {
                    try await LocalLibraryStore(url: url).removeArticle(itemID: article.itemID)
                }
                XCTFail("an injected failure at \(stage) must throw")
            } catch let error as LocalLibraryRemovalError {
                XCTAssertEqual(error.operation, .removeArticle)
                XCTAssertEqual(error.stage, stage, "the seam fired at the stage it was set for")
            }

            let reopened = try LocalLibraryStore(url: url)
            let stored = try await reopened.article(for: article.itemID)
            let tombstones = try await reopened.tombstones()
            XCTAssertEqual(stored?.isDeleted, false, "\(stage): the flag never committed alone")
            XCTAssertTrue(tombstones.isEmpty, "\(stage): the tombstone never committed alone")

            let retried = try await reopened.removeArticle(itemID: article.itemID)
            XCTAssertTrue(retried, "\(stage): a retry after the failure succeeds")
        }
    }

    func testDuplicateArticleRemovalWritesOnceAndRepairsAHalfRemovedArticle() async throws {
        let url = makeURL(); defer { removeStore(url) }
        let article = try article()
        try await saveArticle(article, at: url)
        let store = try LocalLibraryStore(url: url)

        let recorder = RemovalStageRecorder()
        let results = try await recorder.observing { () async throws -> [Bool] in
            async let first = store.removeArticle(itemID: article.itemID)
            async let second = store.removeArticle(itemID: article.itemID)
            let concurrent = try await [first, second]
            let repeated = try await store.removeArticle(itemID: article.itemID)
            let unknown = try await store.removeArticle(itemID: ItemID(rawValue: "article-never-stored"))
            return concurrent + [repeated, unknown]
        }
        XCTAssertEqual(results.filter { $0 }.count, 1, "concurrent confirms coalesce: \(results)")
        XCTAssertEqual(results.suffix(2), [false, false])
        XCTAssertEqual(recorder.count(of: .save), 1, "four confirms, one write")
        let tombstones = try await store.tombstones()
        XCTAssertEqual(tombstones.count, 1)

        // The old two-save path could commit the flag and lose the tombstone.
        let halfURL = makeURL("halfRemoved"); defer { removeStore(halfURL) }
        let half = try Article(itemID: article.itemID, canonicalURL: article.canonicalURL, title: article.title,
                               source: article.source, createdAt: article.createdAt, isDeleted: true)
        try await saveArticle(half, at: halfURL)
        let halfStore = try LocalLibraryStore(url: halfURL)
        let repaired = try await halfStore.removeArticle(itemID: article.itemID)
        let again = try await halfStore.removeArticle(itemID: article.itemID)
        let repairedTombstone = try await halfStore.tombstone(for: article.itemID.rawValue)
        XCTAssertTrue(repaired, "a flagged article without its tombstone gets one")
        XCTAssertFalse(again)
        XCTAssertNotNil(repairedTombstone)
    }

    // MARK: - Unsubscribe cascade

    func testUnsubscribeFailureAtEachStageLeavesRowsListeningQueueAndMediaUnchanged() async throws {
        let fixture = try await makeCascadeFixture(); defer { removeStore(fixture.url) }
        let before = try fingerprint(fixture.store)

        for stage in LocalLibraryRemovalStage.unsubscribe {
            do {
                _ = try await RemovalStageRecorder(failingAt: stage).observing {
                    try await fixture.store.unsubscribeFromPodcast(feedID: fixture.target)
                }
                XCTFail("an injected failure at \(stage) must throw")
            } catch let error as LocalLibraryRemovalError {
                XCTAssertEqual(error.operation, .unsubscribe)
                XCTAssertEqual(error.stage, stage, "the seam fired at the stage it was set for")
            }
            let after = try fingerprint(fixture.store)
            XCTAssertEqual(after, before, "\(stage): nothing staged before the failure committed")
        }

        let reopened = try LocalLibraryStore(url: fixture.url)
        let durable = try fingerprint(reopened)
        let queue = try await reopened.podcastQueueState()
        XCTAssertEqual(durable, before)
        XCTAssertEqual(queue.currentEpisodeID, fixture.targetEpisodes[0])
        for media in fixture.media { XCTAssertTrue(FileManager.default.fileExists(atPath: media.path)) }
    }

    func testUnsubscribeRemovesPreciselyTheTargetFeedsRecords() async throws {
        let fixture = try await makeCascadeFixture(); defer { removeStore(fixture.url) }
        let before = try fingerprint(fixture.store)

        let recorder = RemovalStageRecorder()
        let removed = try await recorder.observing {
            try await fixture.store.unsubscribeFromPodcast(feedID: fixture.target)
        }
        XCTAssertEqual(removed, fixture.targetEpisodes.count)
        XCTAssertEqual(recorder.stages, LocalLibraryRemovalStage.unsubscribe)

        let owners = ([fixture.target] + fixture.targetEpisodes).map(\.rawValue)
        let after = try fingerprint(LocalLibraryStore(url: fixture.url))
        for (table, rows) in before.tables {
            if Self.survivingTables.contains(table) {
                XCTAssertEqual(after.tables[table], rows, "\(table) is not part of the cascade")
            } else {
                let expected = rows.filter { row in !owners.contains { row.contains($0) } }
                XCTAssertLessThan(expected.count, rows.count, "\(table) held a target record to remove")
                XCTAssertFalse(expected.isEmpty, "\(table) held a sibling record to keep")
                XCTAssertEqual(after.tables[table], expected, "\(table) lost exactly the target's records")
            }
        }
        let queue = try await fixture.store.podcastQueueState()
        XCTAssertEqual(queue.episodeIDs, [fixture.siblingEpisodes[0]])
        let targetMedia = fixture.media.prefix(fixture.targetEpisodes.count)
        for media in targetMedia { XCTAssertFalse(FileManager.default.fileExists(atPath: media.path), "target media goes with its records") }
        for media in fixture.media.dropFirst(targetMedia.count) {
            XCTAssertTrue(FileManager.default.fileExists(atPath: media.path), "sibling media stays on disk")
        }
    }

    func testDuplicateUnsubscribeWritesOnce() async throws {
        let fixture = try await makeCascadeFixture(); defer { removeStore(fixture.url) }
        let recorder = RemovalStageRecorder()
        let counts = try await recorder.observing { () async throws -> [Int] in
            async let first = fixture.store.unsubscribeFromPodcast(feedID: fixture.target)
            async let second = fixture.store.unsubscribeFromPodcast(feedID: fixture.target)
            let concurrent = try await [first, second]
            return concurrent + [try await fixture.store.unsubscribeFromPodcast(feedID: fixture.target)]
        }
        XCTAssertEqual(counts.sorted(), [0, 0, fixture.targetEpisodes.count])
        XCTAssertEqual(recorder.count(of: .save), 1, "three confirms, one write")
    }

    func testLateCheckpointForAnUnsubscribedEpisodeWritesNothing() async throws {
        let fixture = try await makeCascadeFixture(); defer { removeStore(fixture.url) }
        let episode = fixture.targetEpisodes[0]
        let revision = try RevisionID(rawValue: "rev-\(episode.rawValue)")
        try await fixture.store.unsubscribeFromPodcast(feedID: fixture.target)
        let late = try PlaybackState(
            itemID: episode, revisionID: revision, sessionID: "session-late", sequence: 2,
            positionSeconds: 95, durationSeconds: 180, completed: true, intent: .progress,
            deviceID: "device-mac", updatedAt: Timestamp(Date()))
        let paused = try await fixture.store.save(playback: late)
        let finished = try await fixture.store.save(playback: late, listening: PodcastListeningState(
            episodeID: episode, completedAt: Timestamp(Date()), lastRevisionID: revision, updatedAt: Timestamp(Date())))
        XCTAssertEqual([paused, finished], [.skippedMissingItem, .skippedMissingItem])
        let position = try await fixture.store.playbackState(for: episode, revisionID: revision)
        XCTAssertNil(position, "a pause after the cascade must not re-create the deleted position")
        let listening = try await fixture.store.listeningState(for: episode)
        XCTAssertNil(listening, "nor its listening fact")
    }

    // MARK: - Fixture

    /// Tables a cascade must leave whole: history, articles and their tombstones.
    private static let survivingTables: Set<String> = ["preparations", "articles", "tombstones"]

    private struct CascadeFixture {
        let url: URL
        let store: LocalLibraryStore
        let target: ItemID
        let targetEpisodes: [ItemID]
        let siblingEpisodes: [ItemID]
        let media: [URL]
    }

    /// Two subscribed feeds with two episodes each. Every episode has a
    /// download, speed, artwork, revision, transcript, playback position,
    /// preparation run and media file on disk; each feed has artwork; the
    /// queue mixes both feeds with a target episode current; one article.
    private func makeCascadeFixture(_ name: String = #function) async throws -> CascadeFixture {
        let url = makeURL(name)
        let origin = Date(timeIntervalSince1970: 1_700_000_000)
        let store = try LocalLibraryStore(url: url)
        try await store.save(article: try article())
        var feeds: [(feed: ItemID, episodes: [ItemID])] = []
        var media: [URL] = []
        for show in ["doomed", "kept"] {
            let feedURL = URL(string: "https://podcasts.example.test/\(show)/feed.xml")!
            let (feed, all) = try episodes(feedURL: feedURL, origin: origin, daysAgo: [1, 2])
            try await store.save(feed: feed)
            try await store.save(subscription: PodcastSubscription(feedID: feed.itemID, subscribedAt: Timestamp(origin)))
            try await store.savePodcastEpisodes(all, admission: .backfill)
            try await store.save(artwork: PodcastArtwork(id: "art-feed-\(feed.itemID.rawValue)", ownerID: feed.itemID,
                                                         updatedAt: Timestamp(origin)))
            for (index, episode) in all.enumerated() {
                let id = episode.itemID
                let hash = "sha256:" + String(repeating: show == "doomed" ? "d" : "e", count: 63) + String(index)
                let mediaURL = url.deletingLastPathComponent().appendingPathComponent("\(show)-\(index).mp3")
                try Data([UInt8(index)]).write(to: mediaURL)
                media.append(mediaURL)
                let revision = try AudioRevision(
                    itemID: id, revisionID: RevisionID(rawValue: "rev-\(id.rawValue)"), durationSeconds: 180,
                    byteCount: 1, contentHash: hash, mediaType: "audio/mpeg", createdAt: Timestamp(origin), schemaVersion: 1)
                try await store.saveReadyRevision(revision, mediaURL: mediaURL, transcript: try Transcript(
                    itemID: id, revisionID: revision.revisionID, availability: .available,
                    text: "Transcript \(show) \(index).", updatedAt: Timestamp(origin)))
                try await store.save(download: PodcastDownload(
                    episodeID: id, status: .completed, bytesReceived: 1, expectedByteCount: 1,
                    localURL: mediaURL, contentHash: hash, updatedAt: Timestamp(origin)))
                try await store.save(playbackSpeed: PodcastPlaybackSpeed(itemID: id, speed: 1.5, updatedAt: Timestamp(origin)))
                try await store.save(artwork: PodcastArtwork(id: "art-\(id.rawValue)", ownerID: id, updatedAt: Timestamp(origin)))
                try await store.save(playback: try PlaybackState(
                    itemID: id, revisionID: revision.revisionID, sessionID: "session-\(show)-\(index)", sequence: 1,
                    positionSeconds: 30 + Double(index), durationSeconds: 180, completed: false, intent: .progress,
                    deviceID: "device-mac", updatedAt: Timestamp(origin)))
                try await store.record(preparation: PreparationJournalEntry(
                    id: "prep-\(id.rawValue)", itemID: id, requestID: "request-\(show)-\(index)",
                    status: try PreparationStatus(
                        stage: .completed, detail: "ready", fraction: 1, cancellable: false,
                        terminalResult: try PreparationTerminalResult(outcome: .succeeded, revisionID: revision.revisionID),
                        emittedAt: Timestamp(origin))))
            }
            feeds.append((feed.itemID, all.map(\.itemID)))
        }
        let (target, sibling) = (feeds[0], feeds[1])
        try await store.replacePodcastQueue(try PodcastQueueState(
            episodeIDs: [target.episodes[0], sibling.episodes[0], target.episodes[1]],
            currentEpisodeID: target.episodes[0]))
        return CascadeFixture(url: url, store: store, target: target.feed, targetEpisodes: target.episodes,
                              siblingEpisodes: sibling.episodes, media: media)
    }

    private struct LibraryFingerprint: Equatable {
        /// Sorted row keys per table. Rows that carry listening state include
        /// the values, so "unchanged" covers position and queue order too.
        var tables: [String: [String]]
    }

    private func fingerprint(_ store: LocalLibraryStore) throws -> LibraryFingerprint {
        let context = ModelContext(store.container)
        func rows<Model: PersistentModel>(_: Model.Type, _ key: (Model) -> String) throws -> [String] {
            try context.fetch(FetchDescriptor<Model>()).map(key).sorted()
        }
        return LibraryFingerprint(tables: [
            "subscriptions": try rows(LocalLibrarySchemaV6Models.PodcastSubscriptionRecord.self) { $0.feedID },
            "feeds": try rows(LocalLibrarySchemaV6Models.PodcastFeedRecord.self) { $0.id },
            "episodes": try rows(LocalLibrarySchemaV13Models.PodcastEpisodeRecord.self) { "\($0.id)|\($0.removalKind ?? "-")" },
            "queue": try rows(LocalLibrarySchemaV6Models.PodcastQueueRecord.self) { "\($0.episodeID)|\($0.position)" },
            "downloads": try rows(LocalLibrarySchemaV10Models.PodcastDownloadRecord.self) { "\($0.episodeID)|\($0.status)" },
            "speeds": try rows(LocalLibrarySchemaV6Models.PodcastPlaybackSpeedRecord.self) { "\($0.itemID)|\($0.speed)" },
            "artwork": try rows(LocalLibrarySchemaV6Models.PodcastArtworkRecord.self) { $0.id },
            "revisions": try rows(LocalLibrarySchemaV3Models.RevisionRecord.self) { "\($0.itemID)|\($0.id)" },
            "transcripts": try rows(LocalLibrarySchemaV7Models.TranscriptRecord.self) { "\($0.itemID)|\($0.id)" },
            "playback": try rows(LocalLibrarySchemaV3Models.PlaybackRecord.self) { "\($0.id)|\($0.positionSeconds)" },
            "preparations": try rows(LocalLibrarySchemaV3Models.PreparationRecord.self) { $0.id },
            "articles": try rows(LocalLibrarySchemaV5Models.ArticleRecord.self) { "\($0.id)|\($0.isRemoved)" },
            "tombstones": try rows(LocalLibrarySchemaV3Models.TombstoneRecord.self) { $0.id },
        ])
    }

    private func saveArticle(_ article: Article, at url: URL) async throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try await LocalLibraryStore(url: url).save(article: article)
    }

    private func removeStore(_ url: URL) { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
}

/// Binds the store's removal seam for one awaited operation: records every
/// stage reached and, if asked, fails at one of them.
private final class RemovalStageRecorder: @unchecked Sendable {
    struct InjectedFailure: Error {}

    private let lock = NSLock()
    private var reached: [LocalLibraryRemovalStage] = []
    private let failingStage: LocalLibraryRemovalStage?

    init(failingAt stage: LocalLibraryRemovalStage? = nil) { failingStage = stage }

    var stages: [LocalLibraryRemovalStage] { lock.withLock { reached } }
    func count(of stage: LocalLibraryRemovalStage) -> Int { stages.filter { $0 == stage }.count }

    func observing<Result: Sendable>(_ operation: @Sendable () async throws -> Result) async throws -> Result {
        try await LocalLibraryStore.$removalStageObserver.withValue({ [self] stage in
            lock.withLock { reached.append(stage) }
            if stage == failingStage { throw InjectedFailure() }
        }, operation: operation)
    }
}
