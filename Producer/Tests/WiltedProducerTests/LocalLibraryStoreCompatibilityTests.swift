import Foundation
import SQLite3
import XCTest
import WiltedDomain
import WiltedSync
@testable import WiltedProducer

final class LocalLibraryStoreCompatibilityTests: XCTestCase {
    /// This V8-era table remains in the V13 schema for migration, but the V13
    /// public API represents dismissals on the episode row instead of writing
    /// the legacy tombstone table.
    private let unseededEntities = ["PodcastEpisodeDismissalRecord"]

    func testWriteV13Fixture() async throws {
        guard let output = ProcessInfo.processInfo.environment["WILTED_WRITE_V13_FIXTURE"], !output.isEmpty else {
            throw XCTSkip("Set WILTED_WRITE_V13_FIXTURE to write the checked-in V13 fixture.")
        }

        try await writeFixture(to: URL(fileURLWithPath: output))
    }

    func testV13FixtureOpensWithMigration() async throws {
        try await assertFixtureReads(migrate: true)
    }

    func testV13FixtureOpensWithoutMigration() async throws {
        try await assertFixtureReads(migrate: false)
    }

    private func assertFixtureReads(migrate: Bool) async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("wilted-v13-fixture-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let copiedFixture = directory.appendingPathComponent("library-v13.store")
        try FileManager.default.copyItem(at: fixtureURL, to: copiedFixture)

        let store = try LocalLibraryStore(url: copiedFixture, migrate: migrate)
        try await assertFixtureValues(in: store)
    }

    private func writeFixture(to output: URL) async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("wilted-v13-fixture-write-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let source = directory.appendingPathComponent("library-v13.store")
        let values = try fixtureValues()
        do {
            let store = try LocalLibraryStore(url: source)
            try await seed(values, in: store)
            try await assertFixtureValues(in: store)
        }

        try checkpointAndDisableWAL(at: source)
        try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: output.path) {
            try FileManager.default.removeItem(at: output)
        }
        try FileManager.default.copyItem(at: source, to: output)
    }

    private func seed(_ values: FixtureValues, in store: LocalLibraryStore) async throws {
        try await store.save(article: values.article)
        try await store.saveReadyRevision(values.articleRevision, mediaURL: values.articleMediaURL)
        try await store.save(transcript: values.transcript)
        try await store.save(playback: values.playback)
        try await store.record(preparation: values.preparation)
        try await store.save(syncState: values.syncState)
        try await store.record(tombstone: values.tombstone)
        try await store.applySyncCommit(LocalLibrarySyncCommit(state: SyncRepositoryState()))

        try await store.save(feed: values.feed)
        try await store.save(episode: values.episode)
        try await store.save(episode: values.dismissedEpisode)
        try await store.save(subscription: values.subscription)
        try await store.save(download: values.download)
        try await store.save(artwork: values.artwork)
        try await store.save(queueEntry: values.queueEntry)
        try await store.save(playbackSpeed: values.playbackSpeed)
        let dismissed = try await store.dismissPodcastEpisode(values.dismissedEpisode.itemID, at: values.timestamp)
        XCTAssertTrue(dismissed)

        try await store.saveReadyRevision(values.podcastRevision, mediaURL: values.podcastMediaURL)
        try await store.savePreparationOutcome(values.preparationOutcome)
        try await store.saveListening(values.listening)
        let statisticInserted = try await store.recordLifetimeStatistic(
            id: "fixture|audio-processed", kind: .audioProcessed, seconds: 12.5
        )
        XCTAssertTrue(statisticInserted)
        let checkpoint = try await store.recordPlaybackSpeedCheckpoint(
            revisionID: values.podcastRevision.revisionID, from: 0, to: 30, rate: 1
        )
        XCTAssertEqual(checkpoint, 0)
        _ = try await store.issueWorkTicket(
            kind: .podcastPreparation, subjectID: values.episode.itemID.rawValue,
            resolvedItemID: values.episode.itemID.rawValue,
            policySnapshot: Data([0x01, 0x02]), processingPolicy: Data([0x03]),
            requestedAt: values.timestamp, requestSequence: 7
        )
    }

    private func assertFixtureValues(in store: LocalLibraryStore) async throws {
        let values = try fixtureValues()

        let article = try await store.article(for: values.article.itemID)
        let articleRevision = try await store.readyRevision(for: values.article.itemID)
        let transcript = try await store.transcript(for: values.article.itemID, revisionID: values.articleRevision.revisionID)
        let playback = try await store.playbackState(for: values.article.itemID, revisionID: values.articleRevision.revisionID)
        let preparation = try await store.preparationJournal(for: values.preparation.requestID)
        let syncState = try await store.syncState(for: values.syncState.key)
        let tombstone = try await store.tombstone(for: values.tombstone.id)
        let repositoryState = try await store.syncRepositoryState()
        let feed = try await store.podcastFeed(for: values.feed.itemID)
        let episode = try await store.podcastEpisode(for: values.episode.itemID)
        let dismissedEpisode = try await store.podcastEpisode(for: values.dismissedEpisode.itemID)
        let subscription = try await store.subscription(for: values.feed.itemID)
        let download = try await store.download(for: values.episode.itemID)
        let artwork = try await store.artwork(for: values.artwork.id)
        let queue = try await store.queue()
        let playbackSpeed = try await store.playbackSpeed(for: values.episode.itemID)
        let removalKind = try await store.removalKind(for: values.dismissedEpisode.itemID)
        let dismissedEpisodes = try await store.dismissedPodcastEpisodes()
        let podcastRevision = try await store.readyRevision(for: values.episode.itemID)
        let preparationOutcome = try await store.preparationOutcome(
            for: values.episode.itemID, revisionID: values.podcastRevision.revisionID
        )
        let listening = try await store.listeningState(for: values.episode.itemID)
        let lifetimeStatistics = try await store.lifetimeStatistics()
        let checkpoint = try await store.recordPlaybackSpeedCheckpoint(
            revisionID: values.podcastRevision.revisionID, from: 0, to: 30, rate: 1
        )
        let ticket = try await store.workTicket(kind: .podcastPreparation, subjectID: values.episode.itemID.rawValue)
        let inspection = try await store.inspect()

        XCTAssertEqual(article, values.article)
        XCTAssertEqual(articleRevision?.revision, values.articleRevision)
        XCTAssertEqual(articleRevision?.mediaURL, values.articleMediaURL)
        XCTAssertEqual(transcript, values.transcript)
        XCTAssertEqual(playback, values.playback)
        XCTAssertEqual(preparation, [values.preparation])
        XCTAssertEqual(syncState, values.syncState)
        XCTAssertEqual(tombstone, values.tombstone)
        XCTAssertEqual(repositoryState, SyncRepositoryState())
        XCTAssertEqual(feed, values.feed)
        XCTAssertEqual(episode, values.episode)
        XCTAssertEqual(dismissedEpisode, values.dismissedEpisode)
        XCTAssertEqual(subscription, values.subscription)
        XCTAssertEqual(download, values.download)
        XCTAssertEqual(artwork, values.artwork)
        XCTAssertEqual(queue, [values.queueEntry])
        XCTAssertEqual(playbackSpeed, values.playbackSpeed)
        XCTAssertEqual(removalKind, .dismissed)
        XCTAssertEqual(dismissedEpisodes.map(\.episodeID), [values.dismissedEpisode.itemID])
        XCTAssertEqual(dismissedEpisodes.first?.feedID, values.feed.itemID)
        XCTAssertEqual(dismissedEpisodes.first?.title, values.dismissedEpisode.title)
        XCTAssertEqual(dismissedEpisodes.first?.dismissedAt, values.timestamp)
        XCTAssertEqual(podcastRevision?.revision, values.podcastRevision)
        XCTAssertEqual(podcastRevision?.mediaURL, values.podcastMediaURL)
        XCTAssertEqual(preparationOutcome, values.preparationOutcome)
        XCTAssertEqual(listening, values.listening)
        XCTAssertEqual(lifetimeStatistics, LifetimeStatistics(audioProcessedSeconds: 12.5))
        XCTAssertEqual(checkpoint, 0)
        XCTAssertEqual(ticket, WorkTicket(
            kind: .podcastPreparation, subjectID: values.episode.itemID.rawValue,
            resolvedItemID: values.episode.itemID.rawValue, requestSequence: 7,
            policySnapshot: Data([0x01, 0x02]), processingPolicy: Data([0x03]),
            requestedAt: values.timestamp, updatedAt: values.timestamp
        ))
        XCTAssertEqual(inspection, LocalLibraryInspection(
            schemaVersion: .v13, articleCount: 1, revisionCount: 2, preparationCount: 1,
            playbackCount: 1, transcriptCount: 1
        ))
    }

    private var fixtureURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/library-v13.store")
    }

    private func checkpointAndDisableWAL(at url: URL) throws {
        var handle: OpaquePointer?
        guard sqlite3_open_v2(url.path, &handle, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK, let database = handle else {
            throw FixtureError.sqlite("could not open fixture")
        }
        defer { sqlite3_close(database) }

        for statement in ["PRAGMA wal_checkpoint(TRUNCATE)", "PRAGMA journal_mode=DELETE"] {
            guard sqlite3_exec(database, statement, nil, nil, nil) == SQLITE_OK else {
                throw FixtureError.sqlite(String(cString: sqlite3_errmsg(database)))
            }
        }
    }

    private func fixtureValues() throws -> FixtureValues {
        let timestamp = Timestamp(Date(timeIntervalSince1970: 1_700_000_000))
        let articleURL = URL(string: "https://fixture.example.test/articles/v13")!
        let article = try Article(
            itemID: ItemID.derive(from: articleURL), canonicalURL: articleURL,
            title: "V13 fixture article", source: "fixture.example.test", author: "Fixture Author",
            publishedTime: timestamp, createdAt: timestamp
        )
        let articleRevision = try AudioRevision(
            itemID: article.itemID, revisionID: RevisionID(rawValue: "fixture-article-revision"),
            durationSeconds: 42, byteCount: 128,
            contentHash: "sha256:" + String(repeating: "a", count: 64), mediaType: "audio/mp4",
            createdAt: timestamp, schemaVersion: 3
        )
        let transcript = try Transcript(
            itemID: article.itemID, revisionID: articleRevision.revisionID, availability: .available,
            text: "V13 fixture transcript.", languageCode: "en", updatedAt: timestamp
        )
        let playback = try PlaybackState(
            itemID: article.itemID, revisionID: articleRevision.revisionID, sessionID: "fixture-session",
            sequence: 1, positionSeconds: 12, durationSeconds: 42, completed: false, intent: .progress,
            deviceID: "fixture-device", updatedAt: timestamp
        )
        let preparation = PreparationJournalEntry(
            id: "fixture-preparation", itemID: article.itemID, requestID: "fixture-request",
            status: try PreparationStatus(
                stage: .completed, detail: "fixture complete", fraction: 1, cancellable: false,
                terminalResult: try PreparationTerminalResult(
                    outcome: .succeeded, revisionID: articleRevision.revisionID
                ), emittedAt: timestamp
            )
        )
        let feedURL = URL(string: "https://fixture.example.test/podcast/feed.xml")!
        let feedID = try ItemID.derivePodcastFeed(from: feedURL)
        let feed = try PodcastFeed(
            itemID: feedID, canonicalURL: feedURL, title: "V13 fixture podcast", author: "Fixture Host",
            artworkURL: URL(string: "https://fixture.example.test/podcast/artwork.jpg"), createdAt: timestamp
        )
        func episode(guid: String) throws -> PodcastEpisode {
            let enclosureURL = URL(string: "https://fixture.example.test/podcast/\(guid).mp3")!
            return try PodcastEpisode(
                itemID: ItemID.derivePodcastEpisode(feedURL: feedURL, rssGUID: guid, enclosureURL: enclosureURL),
                feedID: feedID, feedURL: feedURL, rssGUID: guid, title: "Fixture \(guid)",
                author: "Fixture Host", publishedTime: timestamp, enclosureURL: enclosureURL,
                enclosureMediaType: "audio/mpeg", enclosureByteCount: 1_024, durationSeconds: 60,
                artworkURL: feed.artworkURL, transcriptSources: [], notes: "Fixture notes", createdAt: timestamp
            )
        }
        let activeEpisode = try episode(guid: "active")
        let dismissedEpisode = try episode(guid: "dismissed")
        let podcastRevision = try AudioRevision(
            itemID: activeEpisode.itemID, revisionID: RevisionID(rawValue: "fixture-podcast-revision"),
            durationSeconds: 60, byteCount: 1_024,
            contentHash: "sha256:" + String(repeating: "b", count: 64), mediaType: "audio/mpeg",
            createdAt: timestamp, schemaVersion: 3
        )

        return FixtureValues(
            timestamp: timestamp, article: article, articleRevision: articleRevision,
            articleMediaURL: URL(fileURLWithPath: "/tmp/fixture-article.m4a"), transcript: transcript,
            playback: playback, preparation: preparation,
            syncState: LocalLibrarySyncState(key: "fixture-zone", engineState: Data([0x11, 0x22]), lastFetchAt: timestamp, lastSendAt: timestamp),
            tombstone: LocalLibraryTombstone(id: "fixture-tombstone", itemID: article.itemID, generationID: "fixture-generation", requestedAt: timestamp),
            feed: feed, episode: activeEpisode, dismissedEpisode: dismissedEpisode,
            subscription: PodcastSubscription(feedID: feedID, subscribedAt: timestamp),
            download: try PodcastDownload(
                episodeID: activeEpisode.itemID, status: .completed, bytesReceived: 1_024,
                expectedByteCount: 1_024, localURL: URL(fileURLWithPath: "/tmp/fixture-podcast.mp3"),
                contentHash: "sha256:" + String(repeating: "c", count: 64), updatedAt: timestamp
            ),
            artwork: try PodcastArtwork(
                id: "fixture-artwork", ownerID: feedID, remoteURL: feed.artworkURL,
                localURL: URL(fileURLWithPath: "/tmp/fixture-artwork.jpg"),
                contentHash: "sha256:" + String(repeating: "d", count: 64), byteCount: 256, updatedAt: timestamp
            ),
            queueEntry: try PodcastQueueEntry(episodeID: activeEpisode.itemID, position: 0, addedAt: timestamp),
            playbackSpeed: try PodcastPlaybackSpeed(itemID: activeEpisode.itemID, speed: 1.25, updatedAt: timestamp),
            podcastRevision: podcastRevision, podcastMediaURL: URL(fileURLWithPath: "/tmp/fixture-podcast-ready.mp3"),
            preparationOutcome: PodcastPreparationOutcome(
                episodeID: activeEpisode.itemID, revisionID: podcastRevision.revisionID,
                policyDigest: "fixture-policy", pipelineFingerprint: "fixture-fingerprint",
                semanticVersion: "fixture-v13", producedAt: timestamp
            ),
            listening: PodcastListeningState(
                episodeID: activeEpisode.itemID, completedAt: timestamp,
                lastRevisionID: podcastRevision.revisionID, updatedAt: timestamp
            )
        )
    }
}

private struct FixtureValues {
    let timestamp: Timestamp
    let article: Article
    let articleRevision: AudioRevision
    let articleMediaURL: URL
    let transcript: Transcript
    let playback: PlaybackState
    let preparation: PreparationJournalEntry
    let syncState: LocalLibrarySyncState
    let tombstone: LocalLibraryTombstone
    let feed: PodcastFeed
    let episode: PodcastEpisode
    let dismissedEpisode: PodcastEpisode
    let subscription: PodcastSubscription
    let download: PodcastDownload
    let artwork: PodcastArtwork
    let queueEntry: PodcastQueueEntry
    let playbackSpeed: PodcastPlaybackSpeed
    let podcastRevision: AudioRevision
    let podcastMediaURL: URL
    let preparationOutcome: PodcastPreparationOutcome
    let listening: PodcastListeningState
}

private enum FixtureError: Error {
    case sqlite(String)
}
