import Foundation
import SwiftData
import SQLite3
import XCTest
import WiltedDomain
@testable import WiltedProducer

/// V22 adds the first-deferral time and deferral count to the work ticket.
/// Every ticket written at V21 must open unchanged, with both new fields nil.
final class LocalLibraryV22MigrationTests: XCTestCase {
    private let origin = Date(timeIntervalSince1970: 1_700_000_000)
    private let newColumns: Set<String> = ["ZFIRSTDEFERREDAT", "ZDEFERRALCOUNT"]

    private func makeURL(_ name: String = #function) -> URL {
        OwnedTestTemp.root.appendingPathComponent("wilted-v22-\(name)-\(UUID().uuidString)")
            .appendingPathComponent("library.sqlite")
    }

    private func at(_ seconds: TimeInterval) -> Timestamp { Timestamp(origin.addingTimeInterval(seconds)) }

    /// Tickets in every state and kind, with each optional field both set and
    /// absent somewhere, so a dropped or shifted column cannot pass unseen.
    private func fixtureTickets() -> [WorkTicket] {
        [
            WorkTicket(kind: .podcastPreparation, subjectID: "pending", requestSequence: 1, state: .pending,
                       policySnapshot: Data("snapshot-a".utf8), requestedAt: at(1), updatedAt: at(1)),
            WorkTicket(kind: .podcastPreparation, subjectID: "deferred", requestSequence: 2, state: .deferred,
                       nextEligibleAt: at(7_200), policySnapshot: Data("snapshot-b".utf8),
                       processingPolicy: Data("off-peak".utf8), requestedAt: at(2), updatedAt: at(3)),
            WorkTicket(kind: .podcastPreparation, subjectID: "running", requestSequence: 3, state: .running,
                       attemptCount: 2, failureKind: "retryable", policySnapshot: Data([0x00, 0xFF, 0x7F]),
                       requestedAt: at(4), updatedAt: at(5)),
            WorkTicket(kind: .podcastDownload, subjectID: "succeeded", resolvedItemID: "resolved-item",
                       requestSequence: 4, state: .succeeded, attemptCount: 1, runID: "run-4",
                       requestedAt: at(6), updatedAt: at(7)),
            WorkTicket(kind: .podcastDownload, subjectID: "failed", requestSequence: 5, state: .failed,
                       attemptCount: 3, failureKind: "interrupted", lastFailureMessage: "Download interrupted by quit.",
                       requestedAt: at(8), updatedAt: at(9)),
            WorkTicket(kind: .articlePreparation, subjectID: "cancelled", requestSequence: 6, state: .cancelled,
                       attemptCount: 1, requestedAt: at(10), updatedAt: at(11)),
        ]
    }

    /// Writes released V21 bytes directly.
    private func writeV21Fixture(at url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try autoreleasepool {
            let schema = Schema(versionedSchema: LocalLibrarySchemaV21.self)
            let container = try ModelContainer(for: schema, configurations: [
                ModelConfiguration(schema: schema, url: url, cloudKitDatabase: .none),
            ])
            let context = ModelContext(container)
            context.insert(LocalLibrarySchemaV14Models.LifetimeStatisticsTrackingRecord(startedAt: origin, schemaVersion: 21))
            context.insert(LocalLibrarySchemaV14Models.LifetimeStatisticsSummaryRecord(state: .ready, updatedAt: origin))
            for ticket in fixtureTickets() { context.insert(LocalLibrarySchemaV12Models.WorkTicketRecord(ticket)) }
            try context.save()
        }
        try checkpoint(url)
    }

    func testV21StoreMigratesToV22KeepingEveryTicketWithNilDeferralFields() async throws {
        let url = makeURL(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try writeV21Fixture(at: url)
        XCTAssertEqual(try LocalLibraryStore.diskSchemaVersion(at: url), .known(21))
        let oldColumns = try columns(of: "ZWORKTICKETRECORD", at: url)
        XCTAssertTrue(oldColumns.isDisjoint(with: newColumns))
        let ticketColumns = oldColumns.subtracting(["Z_PK", "Z_ENT", "Z_OPT"]).sorted()
        let rowsBefore = try quotedRows(of: "ZWORKTICKETRECORD", columns: ticketColumns, at: url)
        XCTAssertEqual(rowsBefore.count, 6)
        let original = try Data(contentsOf: url)
        let before = try LocalLibraryStore.tableRowCounts(at: url)

        let store = try LocalLibraryStore(url: url)
        let version = await store.schemaVersion
        let backupValue = await store.migrationBackupURL
        XCTAssertEqual(version, .v22)
        XCTAssertEqual(try LocalLibraryStore.diskSchemaVersion(at: url), .known(22))
        let backup = try XCTUnwrap(backupValue, "a V21 store is backed up before it migrates")
        XCTAssertEqual(try Data(contentsOf: backup), original, "the retained backup is the checkpointed V21 source")
        XCTAssertEqual(try LocalLibraryStore.diskSchemaVersion(at: backup), .known(21))
        XCTAssertEqual(try LocalLibraryStore.tableRowCounts(at: url), before, "every table keeps its exact row count")

        XCTAssertTrue(try columns(of: "ZWORKTICKETRECORD", at: url).isSuperset(of: newColumns))
        XCTAssertEqual(try quotedRows(of: "ZWORKTICKETRECORD", columns: ticketColumns, at: url), rowsBefore,
                       "every V21 ticket column keeps its exact stored value")
        XCTAssertEqual(try scalar("SELECT count(*) FROM ZWORKTICKETRECORD WHERE ZFIRSTDEFERREDAT IS NOT NULL "
                                  + "OR ZDEFERRALCOUNT IS NOT NULL", at: url), 0)
        let tickets = try await store.workTickets().sorted { $0.requestSequence < $1.requestSequence }
        XCTAssertEqual(tickets, fixtureTickets())
        XCTAssertTrue(tickets.allSatisfy { $0.firstDeferredAt == nil && $0.deferralCount == nil })
    }

    func testOpeningAV22StoreAgainIsANoOp() async throws {
        let url = makeURL(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try writeV21Fixture(at: url)
        _ = try LocalLibraryStore(url: url)
        let counts = try LocalLibraryStore.tableRowCounts(at: url)
        let siblings = try siblingDirectories(of: url)
        XCTAssertEqual(siblings.count, 1, "the first open retained exactly one backup")

        let reopened = try LocalLibraryStore(url: url)
        let backup = await reopened.migrationBackupURL
        XCTAssertNil(backup, "a current store opens without another backup")
        XCTAssertEqual(try LocalLibraryStore.diskSchemaVersion(at: url), .known(LocalLibrarySchemaVersion.current.rawValue))
        XCTAssertEqual(try LocalLibraryStore.tableRowCounts(at: url), counts)
        XCTAssertEqual(try siblingDirectories(of: url), siblings)
        let tickets = try await reopened.workTickets().sorted { $0.requestSequence < $1.requestSequence }
        XCTAssertEqual(tickets, fixtureTickets())
    }

    func testV22MigrationFailureRestoresTheV21Source() throws {
        let url = makeURL(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try writeV21Fixture(at: url)
        let original = try Data(contentsOf: url)
        let counts = try LocalLibraryStore.tableRowCounts(at: url)
        let hooks = LocalLibraryOpenHooks(afterMigration: {
            XCTAssertEqual(try LocalLibraryStore.diskSchemaVersion(at: url), .known(22))
            throw InjectedMigrationFailure()
        })
        var retained: URL?
        XCTAssertThrowsError(try LocalLibraryStore(url: url, migrate: true, hooks: hooks)) { error in
            guard case .migrationFailedRestored(let backup, _)? = error as? LocalLibraryStoreError else {
                return XCTFail("Expected retained-backup restoration, got \(error)")
            }
            retained = backup
        }
        XCTAssertEqual(try LocalLibraryStore.diskSchemaVersion(at: url), .known(21))
        XCTAssertEqual(try Data(contentsOf: url), original)
        XCTAssertEqual(try LocalLibraryStore.tableRowCounts(at: url), counts)
        XCTAssertTrue(try columns(of: "ZWORKTICKETRECORD", at: url).isDisjoint(with: newColumns))
        XCTAssertEqual(try Data(contentsOf: try XCTUnwrap(retained)), original)
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

    /// Each row as SQLite's own literal for every named column (blobs as hex),
    /// ordered by the unique ticket key, so equality is equality of stored values.
    private func quotedRows(of table: String, columns: [String], at url: URL) throws -> [String] {
        let select = columns.map { "quote(\($0))" }.joined(separator: " || '|' || ")
        return try withDatabase(url, flags: SQLITE_OPEN_READONLY) { database in
            try rows(database, "SELECT \(select) FROM \(table) ORDER BY ZID;") { statement in
                String(cString: sqlite3_column_text(statement, 0))
            }
        }
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
