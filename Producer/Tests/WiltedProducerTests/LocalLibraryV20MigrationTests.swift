import Foundation
import SwiftData
import SQLite3
import XCTest
import WiltedDomain
@testable import WiltedProducer

extension LocalLibraryStoreTests {
    /// Writes released V19 bytes directly, including a genuine receipt shape
    /// whose undo can be exercised after the additive V20 migration.
    private func writeV19CompletionFixture(at url: URL) throws -> (PodcastEpisode, UUID, Date, Data) {
        let (_, episode) = try podcastValues()
        let finished = episode.createdAt.date.addingTimeInterval(10)
        let operation = UUID()
        let member: [String: Any] = [
            "episodeID": episode.itemID.rawValue, "generation": episode.createdAt.date.timeIntervalSinceReferenceDate,
            "feedID": episode.feedID.rawValue,
            "priorListening": ["updatedAt": episode.createdAt.date.timeIntervalSinceReferenceDate],
            "postListening": ["completedAt": finished.timeIntervalSinceReferenceDate,
                              "updatedAt": finished.timeIntervalSinceReferenceDate],
            "postDecision": ["decision": "skip", "source": "manual", "decidedAt": finished.timeIntervalSinceReferenceDate],
            "wasCurrent": false, "capacityReservation": 0, "restored": false,
        ]
        let bytes = try JSONSerialization.data(withJSONObject: [member], options: [.sortedKeys])
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try autoreleasepool {
            let schema = Schema(versionedSchema: LocalLibrarySchemaV19.self)
            let container = try ModelContainer(for: schema, configurations: [
                ModelConfiguration(schema: schema, url: url, cloudKitDatabase: .none),
            ])
            let context = ModelContext(container)
            context.insert(LocalLibrarySchemaV14Models.LifetimeStatisticsTrackingRecord(
                startedAt: episode.createdAt.date, schemaVersion: 19))
            context.insert(LocalLibrarySchemaV14Models.LifetimeStatisticsSummaryRecord(
                state: .ready, updatedAt: episode.createdAt.date))
            let row = try LocalLibrarySchemaV13Models.PodcastEpisodeRecord(episode)
            row.retiredAt = finished
            row.removalKind = PodcastEpisodeRemovalKind.retired.rawValue
            context.insert(row)
            context.insert(LocalLibrarySchemaV10Models.PodcastListeningRecord(PodcastListeningState(
                episodeID: episode.itemID, completedAt: Timestamp(finished), lastRevisionID: nil,
                updatedAt: Timestamp(finished))))
            context.insert(LocalLibrarySchemaV16Models.EpisodeDecisionRecord(
                episodeID: episode.itemID.rawValue, decision: "skip", source: "manual", ruleID: nil, decidedAt: finished))
            context.insert(LocalLibrarySchemaV19Models.ManualCompletionReceiptRecord(
                operationID: operation, createdAt: finished, undoAvailableUntil: finished.addingTimeInterval(100), members: bytes))
            try context.save()
        }
        return (episode, operation, finished, bytes)
    }

    func testFrozenV19MigratesToV20WithRetainedReceiptAndCompatibleUndo() async throws {
        let url = makeURL(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let (episode, operation, finished, bytes) = try writeV19CompletionFixture(at: url)
        XCTAssertEqual(try LocalLibraryStore.diskSchemaVersion(at: url), .known(19))
        let before = try LocalLibraryStore.tableRowCounts(at: url)
        let store = try LocalLibraryStore(url: url)
        let version = await store.schemaVersion
        let backup = await store.migrationBackupURL
        XCTAssertEqual(version, .current)
        let retained = try XCTUnwrap(backup)
        XCTAssertEqual(try LocalLibraryStore.diskSchemaVersion(at: retained), .known(19))
        XCTAssertEqual(try LocalLibraryStore.diskSchemaVersion(at: url), .known(LocalLibrarySchemaVersion.current.rawValue))
        let after = try LocalLibraryStore.tableRowCounts(at: url)
        for (table, count) in before where !LocalLibraryStore.retiredTables.contains(table) {
            XCTAssertEqual(after[table], count, table)
        }
        try autoreleasepool {
            let schema = Schema(versionedSchema: LocalLibraryCurrentSchema.self)
            let container = try ModelContainer(for: schema,
                configurations: [ModelConfiguration(schema: schema, url: url, cloudKitDatabase: .none)])
            let context = ModelContext(container)
            let receipts = try context.fetch(FetchDescriptor<LocalLibrarySchemaV19Models.ManualCompletionReceiptRecord>())
            XCTAssertEqual(receipts.first?.operationID, operation)
            XCTAssertEqual(receipts.first?.members, bytes)
            XCTAssertEqual(receipts.first?.admissionEffectIDs, Data("[]".utf8))
            XCTAssertTrue(try context.fetch(FetchDescriptor<LocalLibrarySchemaV20Models.EpisodeAssociationRecord>()).isEmpty)
        }
        let undone = try await store.undoManualCompletion(operation, at: finished.addingTimeInterval(1))
        XCTAssertEqual(undone.committed, [episode.itemID])
        let listening = try await store.listeningState(for: episode.itemID)
        let decision = try await store.episodeDecision(for: episode.itemID)
        let removal = try await store.removalKind(for: episode.itemID)
        XCTAssertEqual(listening?.updatedAt, episode.createdAt)
        XCTAssertNil(listening?.completedAt)
        XCTAssertNil(decision)
        XCTAssertNil(removal)
        let reopened = try LocalLibraryStore(url: url)
        let secondBackup = await reopened.migrationBackupURL
        XCTAssertNil(secondBackup)
    }

    /// A SwiftData fixture may still hold committed changes in its WAL when
    /// its container leaves the autorelease pool. Freeze the same checkpointed
    /// source that migration retains before capturing exact rollback bytes.
    private func checkpointSyntheticV19Fixture(_ source: URL) throws {
        var database: OpaquePointer?
        guard sqlite3_open_v2(source.path, &database, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK, let database else {
            if let database { sqlite3_close(database) }
            throw LocalLibraryStoreError.migrationPreflightFailed("Synthetic V19 fixture checkpoint could not open")
        }
        defer { sqlite3_close(database) }
        sqlite3_busy_timeout(database, 5_000)
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, "PRAGMA wal_checkpoint(TRUNCATE);", -1, &statement, nil) == SQLITE_OK,
              let statement else {
            throw LocalLibraryStoreError.migrationPreflightFailed("Synthetic V19 fixture checkpoint could not prepare")
        }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else {
            throw LocalLibraryStoreError.migrationPreflightFailed("Synthetic V19 fixture checkpoint could not finish")
        }
        let fields = (0..<3).map { String(sqlite3_column_int(statement, Int32($0))) }.joined(separator: "|")
        let wal = URL(fileURLWithPath: source.path + "-wal")
        let walSize = FileManager.default.fileExists(atPath: wal.path)
            ? (try FileManager.default.attributesOfItem(atPath: wal.path)[.size] as? NSNumber)?.int64Value : nil
        try LocalLibraryStore.validateWALCheckpointOutputForTesting(fields, walByteCount: walSize)
    }

    func testV20MigrationFailureRestoresExactV19SourceAndRetainsBackup() async throws {
        let url = makeURL(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        _ = try writeV19CompletionFixture(at: url)
        let counts = try LocalLibraryStore.tableRowCounts(at: url)
        try checkpointSyntheticV19Fixture(url)
        let original = try Data(contentsOf: url)
        let hooks = LocalLibraryOpenHooks(afterMigration: {
            XCTAssertEqual(try LocalLibraryStore.diskSchemaVersion(at: url), .known(LocalLibrarySchemaVersion.current.rawValue))
            throw InjectedMigrationFailure()
        })
        var retained: URL?
        XCTAssertThrowsError(try LocalLibraryStore(url: url, migrate: true, hooks: hooks)) { error in
            guard case .migrationFailedRestored(let backup, _)? = error as? LocalLibraryStoreError else {
                return XCTFail("Expected retained-backup restoration, got \(error)")
            }
            retained = backup
        }
        XCTAssertEqual(try LocalLibraryStore.diskSchemaVersion(at: url), .known(19))
        XCTAssertEqual(try Data(contentsOf: url), original)
        XCTAssertEqual(try LocalLibraryStore.tableRowCounts(at: url), counts)
        let retainedURL = try XCTUnwrap(retained)
        XCTAssertEqual(try Data(contentsOf: retainedURL), original, "The exact checkpointed backup stays retained")
        XCTAssertEqual(try LocalLibraryStore.tableRowCounts(at: retainedURL), counts)
        XCTAssertEqual(try LocalLibraryStore.diskSchemaVersion(at: retainedURL), .known(19))
        let recovered = try LocalLibraryStore(url: url)
        let version = await recovered.schemaVersion
        XCTAssertEqual(version, .current)
    }
}
