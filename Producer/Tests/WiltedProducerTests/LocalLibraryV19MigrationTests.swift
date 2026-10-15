import Foundation
import SwiftData
import SQLite3
import XCTest
import WiltedDomain
@testable import WiltedProducer

extension LocalLibraryStoreTests {
    func testV18CloneMigratesAdditiveReceiptsWithoutChangingEpisodeOrListening() async throws {
        let url = makeURL(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let (_, episode) = try podcastValues()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try autoreleasepool {
            let schema = Schema(versionedSchema: LocalLibrarySchemaV18.self)
            let configuration = ModelConfiguration(schema: schema, url: url, cloudKitDatabase: .none)
            let container = try ModelContainer(for: schema, configurations: [configuration])
            let context = ModelContext(container)
            context.insert(try LocalLibrarySchemaV13Models.PodcastEpisodeRecord(episode))
            context.insert(LocalLibrarySchemaV10Models.PodcastListeningRecord(PodcastListeningState(
                episodeID: episode.itemID, completedAt: nil, lastRevisionID: nil, updatedAt: episode.createdAt)))
            try context.save()
        }
        let before = try LocalLibraryStore.diskSchemaVersion(at: url)
        XCTAssertEqual(before, .known(18))
        let store = try LocalLibraryStore(url: url)
        let version = await store.schemaVersion
        let backup = await store.migrationBackupURL
        XCTAssertEqual(version, .current)
        XCTAssertNotNil(backup)
        let listening = try await store.listeningState(for: episode.itemID)
        XCTAssertEqual(listening?.updatedAt, episode.createdAt)
        let finish = try await store.manuallyCompleteEpisodes([episode.itemID])
        XCTAssertEqual(finish.committed, [episode.itemID])
        let undo = try await store.undoManualCompletion(XCTUnwrap(finish.operationID))
        XCTAssertEqual(undo.committed, [episode.itemID])
    }

    private func checkpointSyntheticV18Fixture(_ source: URL) throws {
        var database: OpaquePointer?
        guard sqlite3_open_v2(source.path, &database, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK, let database else {
            if let database { sqlite3_close(database) }
            throw LocalLibraryStoreError.migrationPreflightFailed("Synthetic V18 fixture checkpoint could not open")
        }
        defer { sqlite3_close(database) }
        sqlite3_busy_timeout(database, 5_000)
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, "PRAGMA wal_checkpoint(TRUNCATE);", -1, &statement, nil) == SQLITE_OK,
              let statement else {
            throw LocalLibraryStoreError.migrationPreflightFailed("Synthetic V18 fixture checkpoint could not prepare")
        }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else {
            throw LocalLibraryStoreError.migrationPreflightFailed("Synthetic V18 fixture checkpoint could not finish")
        }
        let fields = (0..<3).map { String(sqlite3_column_int(statement, Int32($0))) }.joined(separator: "|")
        let wal = URL(fileURLWithPath: source.path + "-wal")
        let walSize = FileManager.default.fileExists(atPath: wal.path)
            ? (try FileManager.default.attributesOfItem(atPath: wal.path)[.size] as? NSNumber)?.int64Value : nil
        try LocalLibraryStore.validateWALCheckpointOutputForTesting(fields, walByteCount: walSize)
    }

    func testFrozenV18CopyMigratesDirectlyToExactV19AndStoresReceipts() throws {
        let source = makeURL()
        defer { try? FileManager.default.removeItem(at: source.deletingLastPathComponent()) }
        let (_, episode) = try podcastValues()
        try FileManager.default.createDirectory(at: source.deletingLastPathComponent(), withIntermediateDirectories: true)
        try autoreleasepool {
            let schema = Schema(versionedSchema: LocalLibrarySchemaV18.self)
            let container = try ModelContainer(for: schema, configurations: [
                ModelConfiguration(schema: schema, url: source, cloudKitDatabase: .none),
            ])
            let context = ModelContext(container)
            context.insert(try LocalLibrarySchemaV13Models.PodcastEpisodeRecord(episode))
            context.insert(LocalLibrarySchemaV10Models.PodcastListeningRecord(PodcastListeningState(
                episodeID: episode.itemID, completedAt: nil, lastRevisionID: nil, updatedAt: episode.createdAt)))
            try context.save()
        }
        // Saving the synthetic SwiftData fixture can leave a closing WAL checkpoint
        // writing the main file. Freeze committed bytes before capturing the baseline
        // or copying the main-file-only clone; the exact source assertion stays strict.
        try checkpointSyntheticV18Fixture(source)
        let original = try Data(contentsOf: source)
        let counts = try LocalLibraryStore.tableRowCounts(at: source)
        let clone = source.deletingLastPathComponent().appendingPathComponent("direct-v19.sqlite")
        try FileManager.default.copyItem(at: source, to: clone)
        let operationID = UUID()
        let receiptBytes = Data("[]".utf8)
        try autoreleasepool {
            let schema = Schema(versionedSchema: LocalLibrarySchemaV19.self)
            let container = try ModelContainer(for: schema, migrationPlan: LocalLibraryV19MigrationPlan.self,
                configurations: [ModelConfiguration(schema: schema, url: clone, cloudKitDatabase: .none)])
            let context = ModelContext(container)
            let episodes = try context.fetch(FetchDescriptor<LocalLibrarySchemaV13Models.PodcastEpisodeRecord>())
            XCTAssertEqual(episodes.map(\.id), [episode.itemID.rawValue])
            XCTAssertEqual(episodes.first?.rssGUID, episode.rssGUID)
            let listening = try context.fetch(FetchDescriptor<LocalLibrarySchemaV10Models.PodcastListeningRecord>())
            XCTAssertEqual(listening.first?.updatedAt, episode.createdAt.date)
            context.insert(LocalLibrarySchemaV19Models.ManualCompletionReceiptRecord(
                operationID: operationID, createdAt: episode.createdAt.date,
                undoAvailableUntil: episode.createdAt.date.addingTimeInterval(10), members: receiptBytes))
            try context.save()
        }
        XCTAssertEqual(try LocalLibraryStore.diskSchemaVersion(at: clone), .known(19))
        let after = try LocalLibraryStore.tableRowCounts(at: clone)
        for (table, count) in counts { XCTAssertEqual(after[table], count, table) }
        try autoreleasepool {
            let schema = Schema(versionedSchema: LocalLibrarySchemaV19.self)
            let container = try ModelContainer(for: schema,
                configurations: [ModelConfiguration(schema: schema, url: clone, cloudKitDatabase: .none)])
            let receipts = try ModelContext(container).fetch(
                FetchDescriptor<LocalLibrarySchemaV19Models.ManualCompletionReceiptRecord>())
            XCTAssertEqual(receipts.first?.operationID, operationID)
            XCTAssertEqual(receipts.first?.members, receiptBytes)
            XCTAssertEqual(receipts.first?.admissionEffectIDs, Data("[]".utf8))
        }
        XCTAssertEqual(try LocalLibraryStore.diskSchemaVersion(at: source), .known(18))
        XCTAssertEqual(try Data(contentsOf: source), original, "Direct qualification only migrates the clone")
    }
}
