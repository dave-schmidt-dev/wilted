import Foundation
import SwiftData
import SQLite3
import XCTest
import WiltedDomain
@testable import WiltedProducer

/// V21 drops the retired legacy sync storage: the tombstone and repository-state
/// entities and the playback system-fields column. Every live row must survive.
final class LocalLibraryV21MigrationTests: XCTestCase {
    private let origin = Date(timeIntervalSince1970: 1_700_000_000)
    private let systemFieldsColumn = "ZENCODEDCLOUDKITRECORDSYSTEMFIELDS"

    private struct Fixture {
        let article: Article
        let revision: AudioRevision
        let mediaURL: URL
        let feed: PodcastFeed
        let subscription: PodcastSubscription
        let episode: PodcastEpisode
        let articlePlayback: PlaybackState
        let episodePlayback: PlaybackState
        let syncState: LocalLibrarySyncState
        let binding: LocalLibraryAccountBinding
        let listening: PodcastListeningState
        let decision: EpisodeDecisionRecord
        let receiptID: UUID
        let associationID: UUID
    }

    private func makeURL(_ name: String = #function) -> URL {
        OwnedTestTemp.root.appendingPathComponent("wilted-v21-\(name)-\(UUID().uuidString)")
            .appendingPathComponent("library.sqlite")
    }

    private func at(_ seconds: TimeInterval) -> Timestamp { Timestamp(origin.addingTimeInterval(seconds)) }

    /// Writes released V20 bytes directly: one playback row carrying encoded
    /// system fields and one without, retired tombstone and repository-state
    /// rows, and live sync, podcast, receipt and association rows.
    private func writeV20Fixture(at url: URL) throws -> Fixture {
        let articleURL = URL(string: "https://example.test/v21/article")!
        let article = try Article(itemID: ItemID.derive(from: articleURL), canonicalURL: articleURL,
                                  title: "Retained article", source: "example.test", createdAt: at(0))
        let revision = try AudioRevision(itemID: article.itemID, revisionID: RevisionID(rawValue: "v21-article-rev"),
                                         durationSeconds: 42, byteCount: 128,
                                         contentHash: "sha256:" + String(repeating: "a", count: 64),
                                         mediaType: "audio/mp4", createdAt: at(1), schemaVersion: 3)
        let feedURL = URL(string: "https://podcasts.example.test/v21/feed.xml")!
        let enclosure = URL(string: "https://podcasts.example.test/v21/episode.mp3")!
        let feed = try PodcastFeed(itemID: ItemID.derivePodcastFeed(from: feedURL), canonicalURL: feedURL,
                                   title: "V21 Show", author: "Wilted", artworkURL: nil, createdAt: at(2))
        let episode = try PodcastEpisode(
            itemID: ItemID.derivePodcastEpisode(feedURL: feedURL, rssGUID: "v21", enclosureURL: enclosure),
            feedID: feed.itemID, feedURL: feedURL, rssGUID: "v21", title: "Episode", author: "Wilted",
            publishedTime: at(2), enclosureURL: enclosure, enclosureMediaType: "audio/mpeg",
            enclosureByteCount: 1_000, durationSeconds: 120, artworkURL: nil, createdAt: at(2))
        let fixture = Fixture(
            article: article, revision: revision, mediaURL: URL(fileURLWithPath: "/tmp/v21-article.m4a"),
            feed: feed, subscription: PodcastSubscription(feedID: feed.itemID, subscribedAt: at(3)), episode: episode,
            articlePlayback: try PlaybackState(
                itemID: article.itemID, revisionID: revision.revisionID, sessionID: "session-mac", sequence: 7,
                positionSeconds: 31.5, durationSeconds: 42, completed: false, intent: .rewind,
                deviceID: "device-mac", updatedAt: at(10)),
            episodePlayback: try PlaybackState(
                itemID: episode.itemID, revisionID: RevisionID(rawValue: "v21-episode-rev"), sessionID: "session-phone",
                sequence: 3, positionSeconds: 120, durationSeconds: 120, completed: true, intent: .progress,
                deviceID: "device-phone", updatedAt: at(11)),
            syncState: LocalLibrarySyncState(key: "private-zone", engineState: Data([1, 2, 3]),
                                             lastFetchAt: at(12), lastSendAt: at(13)),
            binding: try LocalLibraryAccountBinding(state: .bound, ownerToken: "sha256:" + String(repeating: "b", count: 64),
                                                    updatedAt: at(14)),
            listening: PodcastListeningState(episodeID: episode.itemID, completedAt: at(15), lastRevisionID: nil,
                                             updatedAt: at(15)),
            decision: EpisodeDecisionRecord(episodeID: episode.itemID, decision: .skip, source: .manual, decidedAt: at(16)),
            receiptID: UUID(), associationID: UUID())
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try autoreleasepool {
            let schema = Schema(versionedSchema: LocalLibrarySchemaV20.self)
            let container = try ModelContainer(for: schema, configurations: [
                ModelConfiguration(schema: schema, url: url, cloudKitDatabase: .none),
            ])
            let context = ModelContext(container)
            context.insert(LocalLibrarySchemaV14Models.LifetimeStatisticsTrackingRecord(startedAt: origin, schemaVersion: 20))
            context.insert(LocalLibrarySchemaV14Models.LifetimeStatisticsSummaryRecord(state: .ready, updatedAt: origin))
            context.insert(LocalLibrarySchemaV17Models.ArticleRecord(article))
            context.insert(LocalLibrarySchemaV3Models.RevisionRecord(revision, mediaURL: fixture.mediaURL))
            let withSystemFields = LocalLibrarySchemaV3Models.PlaybackRecord(fixture.articlePlayback)
            withSystemFields.encodedCloudKitRecordSystemFields = Data([0xCA, 0xFE, 0xBA, 0xBE])
            context.insert(withSystemFields)
            context.insert(LocalLibrarySchemaV3Models.PlaybackRecord(fixture.episodePlayback))
            context.insert(LocalLibrarySchemaV3Models.SyncStateRecord(fixture.syncState))
            context.insert(LocalLibrarySchemaV3Models.SyncStateRecord(LocalLibrarySyncState(
                key: LocalLibraryAccountBinding.storageKey, engineState: try JSONEncoder().encode(fixture.binding))))
            context.insert(LocalLibrarySchemaV3Models.TombstoneRecord(LocalLibraryTombstone(
                id: "v20-tombstone", itemID: article.itemID, generationID: "v20-generation", requestedAt: at(4))))
            context.insert(LocalLibrarySchemaV3Models.RepositoryStateRecord(stateData: Data("{}".utf8)))
            context.insert(LocalLibrarySchemaV17Models.PodcastFeedRecord(feed))
            context.insert(LocalLibrarySchemaV18Models.PodcastSubscriptionRecord(fixture.subscription))
            context.insert(try LocalLibrarySchemaV13Models.PodcastEpisodeRecord(episode))
            context.insert(LocalLibrarySchemaV10Models.PodcastListeningRecord(fixture.listening))
            context.insert(LocalLibrarySchemaV16Models.EpisodeDecisionRecord(
                episodeID: episode.itemID.rawValue, decision: "skip", source: "manual", ruleID: nil,
                decidedAt: at(16).date))
            context.insert(LocalLibrarySchemaV19Models.ManualCompletionReceiptRecord(
                operationID: fixture.receiptID, createdAt: at(17).date, undoAvailableUntil: at(27).date,
                members: Data("[]".utf8)))
            context.insert(LocalLibrarySchemaV20Models.EpisodeAssociationRecord(
                associationID: fixture.associationID, feedID: feed.itemID.rawValue,
                representativeID: episode.itemID.rawValue, members: Data("[\"m\"]".utf8),
                evidence: Data("{}".utf8), createdAt: at(18).date, capturedMemberState: Data("[]".utf8)))
            try context.save()
        }
        try checkpoint(url)
        return fixture
    }

    func testV20StoreMigratesToV21DroppingRetiredSyncStorageAndKeepingLiveRows() async throws {
        let url = makeURL(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let fixture = try writeV20Fixture(at: url)
        XCTAssertEqual(try LocalLibraryStore.diskSchemaVersion(at: url), .known(20))
        XCTAssertTrue(try columns(of: "ZPLAYBACKRECORD", at: url).contains(systemFieldsColumn))
        XCTAssertEqual(try scalar("SELECT count(*) FROM ZPLAYBACKRECORD WHERE \(systemFieldsColumn) IS NOT NULL", at: url), 1)
        let original = try Data(contentsOf: url)
        let before = try LocalLibraryStore.tableRowCounts(at: url)
        XCTAssertEqual(before["ZTOMBSTONERECORD"], 1)
        XCTAssertEqual(before["ZREPOSITORYSTATERECORD"], 1)

        let store = try LocalLibraryStore(url: url)
        let version = await store.schemaVersion
        let backupValue = await store.migrationBackupURL
        XCTAssertEqual(version, .v21)
        XCTAssertEqual(try LocalLibraryStore.diskSchemaVersion(at: url), .known(21))
        let backup = try XCTUnwrap(backupValue, "a V20 store is backed up before it migrates")
        XCTAssertEqual(try Data(contentsOf: backup), original, "the retained backup is the checkpointed V20 source")
        XCTAssertEqual(try LocalLibraryStore.diskSchemaVersion(at: backup), .known(20))
        XCTAssertEqual(try LocalLibraryStore.tableRowCounts(at: backup), before)

        let after = try LocalLibraryStore.tableRowCounts(at: url)
        var expected = before
        for table in LocalLibraryStore.retiredTables {
            XCTAssertNil(after[table], "\(table) is dropped")
            expected.removeValue(forKey: table)
        }
        XCTAssertEqual(after, expected, "every live table keeps its exact row count")
        let playbackColumns = try columns(of: "ZPLAYBACKRECORD", at: url)
        XCTAssertFalse(playbackColumns.contains(systemFieldsColumn))
        XCTAssertTrue(playbackColumns.isSuperset(of: ["ZID", "ZSESSIONID", "ZSEQUENCE", "ZPOSITIONSECONDS", "ZCOMPLETED", "ZINTENT"]))

        let article = try await store.article(for: fixture.article.itemID)
        let revision = try await store.readyRevision(for: fixture.article.itemID)
        let articlePlayback = try await store.playbackState(for: fixture.article.itemID,
                                                            revisionID: fixture.articlePlayback.revisionID)
        let episodePlayback = try await store.playbackState(for: fixture.episode.itemID,
                                                            revisionID: fixture.episodePlayback.revisionID)
        let syncState = try await store.syncState(for: fixture.syncState.key)
        let binding = try await store.libraryAccountBinding()
        let feed = try await store.podcastFeed(for: fixture.feed.itemID)
        let subscription = try await store.subscription(for: fixture.feed.itemID)
        let episode = try await store.podcastEpisode(for: fixture.episode.itemID)
        let listening = try await store.listeningState(for: fixture.episode.itemID)
        let decision = try await store.episodeDecision(for: fixture.episode.itemID)
        XCTAssertEqual(article, fixture.article)
        XCTAssertEqual(revision?.revision, fixture.revision)
        XCTAssertEqual(revision?.mediaURL, fixture.mediaURL)
        XCTAssertEqual(articlePlayback, fixture.articlePlayback)
        XCTAssertEqual(episodePlayback, fixture.episodePlayback)
        XCTAssertEqual(syncState, fixture.syncState)
        XCTAssertEqual(binding, fixture.binding)
        XCTAssertEqual(feed, fixture.feed)
        XCTAssertEqual(subscription, fixture.subscription)
        XCTAssertEqual(episode, fixture.episode)
        XCTAssertEqual(listening, fixture.listening)
        XCTAssertEqual(decision, fixture.decision)

        let context = ModelContext(store.container)
        let receipts = try context.fetch(FetchDescriptor<LocalLibrarySchemaV19Models.ManualCompletionReceiptRecord>())
        XCTAssertEqual(receipts.map(\.operationID), [fixture.receiptID])
        let associations = try context.fetch(FetchDescriptor<LocalLibrarySchemaV20Models.EpisodeAssociationRecord>())
        XCTAssertEqual(associations.map(\.associationID), [fixture.associationID])
        XCTAssertEqual(associations.first?.members, Data("[\"m\"]".utf8))
        XCTAssertEqual(associations.first?.representativeID, fixture.episode.itemID.rawValue)
        let playbackRows = try context.fetch(FetchDescriptor<LocalLibrarySchemaV21Models.PlaybackRecord>())
        XCTAssertEqual(Set(playbackRows.map(\.sequence)), [7, 3])
        XCTAssertEqual(Set(playbackRows.map(\.completed)), [false, true])
    }

    func testOpeningAV21StoreAgainIsANoOp() async throws {
        let url = makeURL(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let fixture = try writeV20Fixture(at: url)
        _ = try LocalLibraryStore(url: url)
        let counts = try LocalLibraryStore.tableRowCounts(at: url)
        let siblings = try siblingDirectories(of: url)
        XCTAssertEqual(siblings.count, 1, "the first open retained exactly one backup")

        let reopened = try LocalLibraryStore(url: url)
        let backup = await reopened.migrationBackupURL
        XCTAssertNil(backup, "a current store opens without another backup")
        XCTAssertEqual(try LocalLibraryStore.diskSchemaVersion(at: url), .known(21))
        XCTAssertEqual(try LocalLibraryStore.tableRowCounts(at: url), counts)
        XCTAssertEqual(try siblingDirectories(of: url), siblings)
        let playback = try await reopened.playbackState(for: fixture.article.itemID,
                                                       revisionID: fixture.articlePlayback.revisionID)
        XCTAssertEqual(playback, fixture.articlePlayback)
    }

    func testV21MigrationFailureRestoresTheV20SourceWithItsRetiredRows() throws {
        let url = makeURL(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        _ = try writeV20Fixture(at: url)
        let original = try Data(contentsOf: url)
        let counts = try LocalLibraryStore.tableRowCounts(at: url)
        let hooks = LocalLibraryOpenHooks(afterMigration: {
            XCTAssertEqual(try LocalLibraryStore.diskSchemaVersion(at: url), .known(21))
            throw InjectedMigrationFailure()
        })
        var retained: URL?
        XCTAssertThrowsError(try LocalLibraryStore(url: url, migrate: true, hooks: hooks)) { error in
            guard case .migrationFailedRestored(let backup, _)? = error as? LocalLibraryStoreError else {
                return XCTFail("Expected retained-backup restoration, got \(error)")
            }
            retained = backup
        }
        XCTAssertEqual(try LocalLibraryStore.diskSchemaVersion(at: url), .known(20))
        XCTAssertEqual(try Data(contentsOf: url), original)
        XCTAssertEqual(try LocalLibraryStore.tableRowCounts(at: url), counts)
        XCTAssertEqual(counts["ZTOMBSTONERECORD"], 1, "the restored source still holds the retired rows")
        XCTAssertEqual(try Data(contentsOf: try XCTUnwrap(retained)), original)
    }

    /// Only the tables V21 retired may vanish while populated.
    func testRowCountVerificationAllowsOnlyRetiredTablesToVanishWithRows() throws {
        XCTAssertNoThrow(try LocalLibraryStore.verifyRowCounts(
            ["ZARTICLERECORD": 2, "ZTOMBSTONERECORD": 3, "ZREPOSITORYSTATERECORD": 1],
            preserved: ["ZARTICLERECORD": 2]))
        XCTAssertThrowsError(try LocalLibraryStore.verifyRowCounts(
            ["ZARTICLERECORD": 2, "ZTOMBSTONERECORD": 3], preserved: ["ZTOMBSTONERECORD": 3])) { error in
            guard case LocalLibraryStoreError.migrationPreflightFailed(let reason) = error else {
                return XCTFail("expected migrationPreflightFailed, got \(error)")
            }
            XCTAssertTrue(reason.contains("ZARTICLERECORD had 2 rows before migration and is missing after"), reason)
        }
        XCTAssertThrowsError(try LocalLibraryStore.verifyRowCounts(["ZTOMBSTONERECORD": 3], preserved: ["ZTOMBSTONERECORD": 2]))
    }

    // MARK: - SQLite helpers

    private func siblingDirectories(of url: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(at: url.deletingLastPathComponent(), includingPropertiesForKeys: nil)
            .filter { $0.hasDirectoryPath }.map(\.lastPathComponent).sorted()
    }

    /// Freezes the fixture's committed WAL into the main file so its bytes equal what migration retains.
    private func checkpoint(_ url: URL) throws {
        try withDatabase(url, flags: SQLITE_OPEN_READWRITE) { database in
            XCTAssertEqual(sqlite3_exec(database, "PRAGMA wal_checkpoint(TRUNCATE);", nil, nil, nil), SQLITE_OK)
        }
    }

    private func columns(of table: String, at url: URL) throws -> Set<String> {
        try withDatabase(url, flags: SQLITE_OPEN_READONLY) { database in
            try rows(database, "PRAGMA table_info(\(table));") { statement in
                String(cString: sqlite3_column_text(statement, 1))
            }
        }.reduce(into: Set<String>()) { $0.insert($1) }
    }

    private func scalar(_ sql: String, at url: URL) throws -> Int {
        try withDatabase(url, flags: SQLITE_OPEN_READONLY) { database in
            try rows(database, sql) { Int(sqlite3_column_int64($0, 0)) }.first ?? -1
        }
    }

    private func rows<T>(_ database: OpaquePointer, _ sql: String, _ read: (OpaquePointer) -> T) throws -> [T] {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw LocalLibraryStoreError.migrationPreflightFailed("could not prepare \(sql)")
        }
        defer { sqlite3_finalize(statement) }
        var values: [T] = []
        while sqlite3_step(statement) == SQLITE_ROW { values.append(read(statement)) }
        return values
    }

    private func withDatabase<T>(_ url: URL, flags: Int32, _ body: (OpaquePointer) throws -> T) throws -> T {
        var database: OpaquePointer?
        guard sqlite3_open_v2(url.path, &database, flags, nil) == SQLITE_OK, let database else {
            if let database { sqlite3_close(database) }
            throw LocalLibraryStoreError.migrationPreflightFailed("could not open \(url.lastPathComponent)")
        }
        defer { sqlite3_close(database) }
        sqlite3_busy_timeout(database, 5_000)
        return try body(database)
    }
}
