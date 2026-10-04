import Foundation
import CryptoKit
import SwiftData
import XCTest
import WiltedDomain
import WiltedSync
@testable import WiltedProducer

final class LocalLibraryStoreCompatibilityTests: XCTestCase {
    /// SHA-256 of the checked-in V13 fixture. The fixture is frozen: this
    /// build writes V16 stores, so it can no longer be regenerated, and every
    /// test below works on a copy.
    static let v13FixtureSHA256 = "3be8dc8875963cdc840443bf310dcdca0fd78c7ade5c04d55d42e605b2a8aeb3"

    func testV13FixtureBytesAreFrozen() throws {
        XCTAssertEqual(try Self.sha256(of: fixtureURL), Self.v13FixtureSHA256)
        XCTAssertEqual(try LocalLibraryStore.diskSchemaVersion(at: fixtureURL), .known(13))
    }

    func testV13FixtureMigratesToV16WithRetainedBackupAndReopens() async throws {
        let copied = try copiedFixture()
        defer { try? FileManager.default.removeItem(at: copied.deletingLastPathComponent()) }

        let backupURL: URL
        do {
            let store = try LocalLibraryStore(url: copied)
            try await assertFixtureValues(in: store)
            let retained = await store.migrationBackupURL
            backupURL = try XCTUnwrap(retained, "a V13 store must be backed up before it opens as V16")
            let summary = try await store.lifetimeStatisticsSummary()
            XCTAssertEqual(summary.state, .rebuildRequired, "opening must not rebuild the summary")
            XCTAssertNotNil(summary.trackingStartedAt)
            XCTAssertEqual(summary.measured, LifetimeMeasuredTotals())
        }
        XCTAssertEqual(try Self.sha256(of: backupURL), Self.v13FixtureSHA256, "the backup is the untouched V13 store")
        XCTAssertEqual(try LocalLibraryStore.diskSchemaVersion(at: backupURL), .known(13))
        XCTAssertEqual(try LocalLibraryStore.diskSchemaVersion(at: copied), .known(16))

        let reopened = try LocalLibraryStore(url: copied)
        let secondBackup = await reopened.migrationBackupURL
        XCTAssertNil(secondBackup, "a current store is not backed up again")
        try await assertFixtureValues(in: reopened)
        let rebuilt = try await reopened.rebuildLifetimeStatisticsSummary()
        XCTAssertEqual(rebuilt.state, .ready)
        XCTAssertEqual(rebuilt.legacy, LifetimeStatistics(audioProcessedSeconds: 12.5))
        XCTAssertEqual(rebuilt.measured, LifetimeMeasuredTotals(), "no history is fabricated for the new totals")
        XCTAssertEqual(try Self.sha256(of: fixtureURL), Self.v13FixtureSHA256)
    }

    func testV13FixtureIsRefusedUnmodifiedWithoutMigration() throws {
        let copied = try copiedFixture()
        defer { try? FileManager.default.removeItem(at: copied.deletingLastPathComponent()) }
        let before = try Self.directorySnapshot(copied.deletingLastPathComponent())

        XCTAssertThrowsError(try LocalLibraryStore(url: copied, migrate: false)) { error in
            XCTAssertEqual(error as? LocalLibraryStoreError, .migrationRequired(fromVersion: 13))
        }
        XCTAssertEqual(try Self.directorySnapshot(copied.deletingLastPathComponent()), before)
    }

    func testFailureAfterInPlaceMigrationRestoresTheV13Original() async throws {
        let copied = try copiedFixture()
        defer { try? FileManager.default.removeItem(at: copied.deletingLastPathComponent()) }

        let hooks = LocalLibraryOpenHooks(afterMigration: {
            // The source really was migrated before this failure.
            XCTAssertEqual(try LocalLibraryStore.diskSchemaVersion(at: copied), .known(16))
            throw InjectedMigrationFailure()
        })
        var backupURL: URL?
        XCTAssertThrowsError(try LocalLibraryStore(url: copied, migrate: true, hooks: hooks)) { error in
            guard case .migrationFailedRestored(let url, _)? = error as? LocalLibraryStoreError else {
                return XCTFail("expected a restored migration failure, got \(error)")
            }
            backupURL = url
        }
        XCTAssertEqual(try Self.sha256(of: copied), Self.v13FixtureSHA256, "the original bytes are restored")
        XCTAssertEqual(try LocalLibraryStore.diskSchemaVersion(at: copied), .known(13))
        XCTAssertEqual(try Self.sha256(of: XCTUnwrap(backupURL)), Self.v13FixtureSHA256, "the backup is retained")

        let recovered = try LocalLibraryStore(url: copied)
        try await assertFixtureValues(in: recovered)
    }

    func testRetainedBackupRestoreProcedureReturnsTheV13Store() async throws {
        let copied = try copiedFixture()
        defer { try? FileManager.default.removeItem(at: copied.deletingLastPathComponent()) }
        let backupURL: URL
        do {
            let store = try LocalLibraryStore(url: copied)
            _ = try await store.recordLifetimeMeasure(
                id: "after-migration", try XCTUnwrap(.time(.playedTime, seconds: 5)), at: Date()
            )
            let retained = await store.migrationBackupURL
            backupURL = try XCTUnwrap(retained)
        }
        try LocalLibraryStore.restoreMigrationBackup(LocalLibraryMigrationPreflight(
            sourceURL: copied, retainedURL: backupURL, retainedFiles: []
        ))
        XCTAssertEqual(try Self.sha256(of: copied), Self.v13FixtureSHA256)
        XCTAssertEqual(try LocalLibraryStore.diskSchemaVersion(at: copied), .known(13))
        let reopened = try LocalLibraryStore(url: copied)
        try await assertFixtureValues(in: reopened)
        let restoredEvent = try await reopened.lifetimeMeasureEventExists(id: "after-migration")
        XCTAssertFalse(restoredEvent, "restoring returns exactly the pre-migration store")
    }

    func testV13StoreWithLiveWALIsCheckpointedIntoACompleteBackup() async throws {
        let copied = try copiedFixture()
        defer { try? FileManager.default.removeItem(at: copied.deletingLastPathComponent()) }
        // Keep the V13 writer's connection open so its commit stays in the WAL.
        let v13Writer = try Self.appendV13LegacyStatistic(at: copied, id: "wal|speech", seconds: 2)
        defer { withExtendedLifetime(v13Writer) {} }
        let walURL = URL(fileURLWithPath: copied.path + "-wal")
        let walBytes = try FileManager.default.attributesOfItem(atPath: walURL.path)[.size] as? NSNumber
        XCTAssertGreaterThan(walBytes?.intValue ?? 0, 0, "the source must carry committed rows only in its WAL")

        let store = try LocalLibraryStore(url: copied)
        let retained = await store.migrationBackupURL
        let backupURL = try XCTUnwrap(retained)
        let totals = try await store.lifetimeStatistics()
        XCTAssertEqual(totals, LifetimeStatistics(audioProcessedSeconds: 12.5, speechGeneratedSeconds: 2))
        XCTAssertEqual(try LocalLibraryStore.tableRowCounts(at: backupURL)["ZLIFETIMESTATISTICEVENTRECORD"], 2,
                       "the backup holds the WAL's committed rows")
        XCTAssertEqual(try LocalLibraryStore.diskSchemaVersion(at: backupURL), .known(13))
        let backupFiles = try FileManager.default.contentsOfDirectory(atPath: backupURL.deletingLastPathComponent().path)
        XCTAssertTrue(backupFiles.contains(backupURL.lastPathComponent + "-wal"), "the backup keeps the WAL sidecar")
    }

    func testNewerStoreIsRefusedWithoutAnyWrite() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("wilted-future-store-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("library.sqlite")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // Keep the newer build's connection open so its sidecars are live.
        let schema = Schema(versionedSchema: LocalLibrarySchemaV17.self)
        let futureWriter = try ModelContainer(for: schema, configurations: [
            ModelConfiguration(schema: schema, url: url, cloudKitDatabase: .none),
        ])
        defer { withExtendedLifetime(futureWriter) {} }
        let context = ModelContext(futureWriter)
        context.insert(FutureSchemaRecord(id: "future"))
        try context.save()
        let walURL = URL(fileURLWithPath: url.path + "-wal")
        let walBytes = try FileManager.default.attributesOfItem(atPath: walURL.path)[.size] as? NSNumber
        XCTAssertGreaterThan(walBytes?.intValue ?? 0, 0, "the newer store's latest commit is still in its WAL")
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path + "-shm"))
        XCTAssertEqual(try LocalLibraryStore.diskSchemaVersion(at: url),
                       .unrecognized("store matches no schema from V1 through V16"))
        let before = try Self.directorySnapshot(directory)

        for migrate in [true, false] {
            XCTAssertThrowsError(try LocalLibraryStore(url: url, migrate: migrate)) { error in
                guard case .incompatibleStoreVersion? = error as? LocalLibraryStoreError else {
                    return XCTFail("expected a downgrade refusal, got \(error)")
                }
            }
        }
        XCTAssertThrowsError(try LocalLibraryStore.migrationPreflight(at: url))
        XCTAssertEqual(try Self.directorySnapshot(directory), before,
                       "a refused store keeps every file byte-identical and gains no backup")
    }

    func testV13FixtureOpensWithMigration() async throws {
        let copied = try copiedFixture()
        defer { try? FileManager.default.removeItem(at: copied.deletingLastPathComponent()) }
        let store = try LocalLibraryStore(url: copied, migrate: true)
        try await assertFixtureValues(in: store)
    }

    private func copiedFixture() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("wilted-v13-fixture-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let copied = directory.appendingPathComponent("library-v13.store")
        try FileManager.default.copyItem(at: fixtureURL, to: copied)
        return copied
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
            schemaVersion: .v16, articleCount: 1, revisionCount: 2, preparationCount: 1,
            playbackCount: 1, transcriptCount: 1
        ))
    }

    private var fixtureURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/library-v13.store")
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


extension LocalLibraryStoreCompatibilityTests {
    static func sha256(of url: URL) throws -> String {
        SHA256.hash(data: try Data(contentsOf: url)).map { String(format: "%02x", $0) }.joined()
    }

    /// Every file under `directory` (recursively) with its content hash, so a
    /// refused open can be shown to have written, removed and added nothing.
    static func directorySnapshot(_ directory: URL) throws -> [String: String] {
        var snapshot: [String: String] = [:]
        let enumerator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: [.isRegularFileKey])
        while let file = enumerator?.nextObject() as? URL {
            guard try file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else { continue }
            let relative = String(file.standardizedFileURL.path.dropFirst(directory.standardizedFileURL.path.count))
            snapshot[relative] = try sha256(of: file)
        }
        return snapshot
    }

    /// Writes one more legacy ledger row through the frozen V13 schema, the
    /// way a V13 build would. The returned container keeps its connection.
    @discardableResult
    static func appendV13LegacyStatistic(at url: URL, id: String, seconds: Double) throws -> ModelContainer {
        let schema = Schema(versionedSchema: LocalLibrarySchemaV13.self)
        let container = try ModelContainer(for: schema, configurations: [
            ModelConfiguration(schema: schema, url: url, cloudKitDatabase: .none),
        ])
        let context = ModelContext(container)
        context.insert(LocalLibrarySchemaV11Models.LifetimeStatisticEventRecord(
            id: id, kind: .speechGenerated, seconds: seconds
        ))
        try context.save()
        return container
    }
}

/// An entity no released schema has, standing in for a newer build's store.
@Model final class FutureSchemaRecord {
    @Attribute(.unique) var id: String
    init(id: String) { self.id = id }
}

enum LocalLibrarySchemaV17: VersionedSchema {
    static let versionIdentifier = Schema.Version(17, 0, 0)
    static var models: [any PersistentModel.Type] { LocalLibrarySchemaV16.models + [FutureSchemaRecord.self] }
}

struct InjectedMigrationFailure: Error {}
