import CloudKit
import WiltedCloudKit
import WiltedDomain
import WiltedLibrary
import XCTest
@testable import WiltedCloudKitLibrary

final class NotebookCloudKitSyncTests: XCTestCase {
    private let mapper = LibraryRecordMapper()
    private let instant = Date(timeIntervalSince1970: 1_700_000_000)

    private func notebook(_ id: String = "notebook-clip-1", note: String? = nil, deletedAt: Date? = nil) throws -> LibraryNotebookEntry {
        try LibraryNotebookEntry(
            id: item(id), createdAt: instant, sourceItemID: item("episode-1"),
            sourceRevision: RevisionID(rawValue: "ready-r1"), sourceTitle: "Episode One",
            sourceURL: URL(string: "https://podcasts.example.test/episode-1")!, sourceName: "Example Show",
            startSeconds: 30, endSeconds: 60, textExcerpt: "A clipped sentence.", note: note,
            tags: ["idea"], capturedOn: .iphone, reviewed: false, updatedAt: instant, deletedAt: deletedAt)
    }

    private func notebookRecord(_ entry: LibraryNotebookEntry, at seconds: TimeInterval, existing: CKRecord? = nil) throws -> CKRecord {
        guard case let .save(record) = try mapper.operation(for: .notebookEntry(entry), existing: existing) else {
            throw XCTSkip("Notebook entries are versioned records, never hard deletions")
        }
        return stamped(record, seconds)
    }

    private func transport(
        _ driver: ScriptedDriver, mode: NotebookCloudWriteMode, counters: CloudKitOperationCounters = CloudKitOperationCounters(startLoggingTask: false)
    ) throws -> CloudKitLibraryTransport {
        try CloudKitLibraryTransport(
            deviceID: "mac", isLibraryWriter: true, driver: driver, driverFactory: { _ in driver },
            outbox: CloudKitLibraryOutbox(), counters: counters, notebookCloudWriteMode: mode)
    }

    func testNotebookEntryRoundTripsOnStableRecordAndTombstoneSavesInPlace() throws {
        let live = try notebook()
        let liveRecord = try notebookRecord(live, at: 1_700_000_001)

        XCTAssertEqual(liveRecord.recordType, LibraryRecordType.notebookEntry.rawValue)
        XCTAssertEqual(liveRecord.recordID.recordName, "notebook:notebook-clip-1")
        XCTAssertEqual(liveRecord.recordID.zoneID, mapper.zoneID)
        let key = LibraryChange.notebookEntry(live).key
        XCTAssertEqual(mapper.recordID(for: key), liveRecord.recordID)
        XCTAssertEqual(mapper.key(forRecordName: liveRecord.recordID.recordName), key)
        XCTAssertEqual(try mapper.decode(liveRecord), .library(.notebookEntry(live)))
        XCTAssertLessThanOrEqual((liveRecord[LibraryRecordMapper.payloadField] as? Data)?.count ?? .max,
                                 LibraryRecordMapper.maximumPayloadBytes)

        let deleted = try notebook(deletedAt: instant.addingTimeInterval(100))
        let tombstoneRecord = try notebookRecord(deleted, at: 1_700_000_101, existing: liveRecord)
        XCTAssertEqual(tombstoneRecord.recordID, liveRecord.recordID)
        XCTAssertEqual(try mapper.decode(tombstoneRecord), .library(.notebookEntry(deleted)))
        XCTAssertNil(mapper.deletion(recordID: liveRecord.recordID, recordType: LibraryRecordType.notebookEntry.rawValue),
                     "Notebook deletes travel as a value carrying deletedAt")
    }

    func testMalformedNotebookRecordFailsTheLibraryFetch() async throws {
        let id = try item("notebook-clip-bad")
        let recordID = mapper.recordID(for: LibraryRecordKey(kind: .notebookEntry, id: id))
        let malformed = CKRecord(recordType: LibraryRecordType.notebookEntry.rawValue, recordID: recordID)
        malformed[LibraryRecordMapper.payloadField] = Data("{broken".utf8) as CKRecordValue
        let driver = ScriptedDriver(fetch: {
            [.willFetch, .fetched(modifications: [malformed], deletions: []),
             .stateUpdated(Data("bad-notebook".utf8)), .fetchCompleted]
        })
        let transport = try transport(driver, mode: .localOnly)

        do {
            _ = try await transport.fetchChanges(since: nil)
            XCTFail("a known Notebook record with invalid data cannot be silently skipped")
        } catch {
            guard case .malformedPayload = error as? LibraryRecordMapperError else {
                return XCTFail("unexpected error: \(error)")
            }
        }
    }

    func testLocalOnlyModeRefusesNotebookIntentAndPushBeforeAnyCloudKitRequest() async throws {
        let driver = ScriptedDriver()
        let counters = CloudKitOperationCounters(startLoggingTask: false)
        let transport = try transport(driver, mode: .localOnly, counters: counters)
        let entry = try notebook()
        let intent = try LibraryIntent.setNotebookEntry(
            entry: entry, basedOnVersion: 0, deviceID: "mac", createdAt: instant, id: "notebook-intent-1")

        do {
            try await transport.send(intent: intent)
            XCTFail("local-only mode admitted a Notebook intent")
        } catch {
            XCTAssertEqual(error as? LibraryTransportError, .transport("Notebook CloudKit writes are disabled in this build"))
        }
        let result = try await transport.push(changes: [
            PendingLibraryChange(localSeq: 1, change: .notebookEntry(entry), baseVersion: 0)
        ])
        XCTAssertEqual(result.failures.count, 1)
        XCTAssertEqual(result.failures.first?.key, LibraryChange.notebookEntry(entry).key)
        XCTAssertEqual(result.failures.first?.disposition, .terminal)
        let localOnlyPending = await driver.pending
        let summary = await transport.operationSummary()
        XCTAssertTrue(localOnlyPending.isEmpty, "the driver was not given an outbound CloudKit operation")
        XCTAssertEqual(summary.totalRequests, 0)
    }

    func testCreateCannotOverwriteAnExistingRecordAtBaseZero() async throws {
        let original = try notebook()
        let server = try notebookRecord(original, at: 1_700_000_010)
        let driver = ScriptedDriver(namedRecords: [server])
        let transport = try transport(driver, mode: .development)
        let duplicate = try notebook(note: "offline replacement")

        let result = try await transport.push(changes: [
            PendingLibraryChange(localSeq: 1, change: .notebookEntry(duplicate), baseVersion: 0)
        ])

        XCTAssertEqual(result.failures.count, 1)
        XCTAssertEqual(result.failures.first?.disposition, .conflict)
        guard case let .notebookEntry(serverEntry)? = result.failures.first?.server?.change else {
            return XCTFail("the conflict returns the current server Notebook value")
        }
        XCTAssertEqual(serverEntry, original)
        let pending = await driver.pending
        XCTAssertTrue(pending.isEmpty, "base zero must not overwrite an existing id")
    }

    func testOfflineLiveEditCannotResurrectServerTombstone() async throws {
        let original = try notebook(note: "before delete")
        let originalRecord = try notebookRecord(original, at: 1_700_000_020)
        let observedVersion = try XCTUnwrap(LibraryRecordMapper.version(of: originalRecord))
        let tombstone = try notebook(note: "before delete", deletedAt: instant.addingTimeInterval(200))
        let serverTombstone = try notebookRecord(tombstone, at: 1_700_000_220)
        let driver = ScriptedDriver(namedRecords: [serverTombstone])
        let transport = try transport(driver, mode: .development)
        let offlineEdit = try notebook(note: "stale phone edit")

        let result = try await transport.push(changes: [
            PendingLibraryChange(localSeq: 2, change: .notebookEntry(offlineEdit), baseVersion: observedVersion)
        ])

        XCTAssertEqual(result.failures.count, 1)
        XCTAssertEqual(result.failures.first?.disposition, .conflict)
        guard case let .notebookEntry(serverEntry)? = result.failures.first?.server?.change else {
            return XCTFail("the conflict returns the current tombstone")
        }
        XCTAssertEqual(serverEntry.deletedAt, tombstone.deletedAt)
        XCTAssertEqual(serverEntry.note, "before delete")
        let pending = await driver.pending
        XCTAssertTrue(pending.isEmpty, "stale offline content never reaches CloudKit send")
    }

    func testFetchPublishesNotebookTombstoneThroughTheVersionedChangeStream() async throws {
        let tombstone = try notebook(deletedAt: instant.addingTimeInterval(300))
        let record = try notebookRecord(tombstone, at: 1_700_000_300)
        let token = Data("notebook-fetch".utf8)
        let driver = ScriptedDriver(fetch: {
            [.willFetch, .fetched(modifications: [record], deletions: []), .stateUpdated(token), .fetchCompleted]
        })
        let transport = try transport(driver, mode: .localOnly)

        let batch = try await transport.fetchChanges(since: nil)

        XCTAssertEqual(batch.changes.count, 1)
        XCTAssertEqual(batch.changes.first?.change, .notebookEntry(tombstone))
        XCTAssertEqual(batch.changes.first?.version, 1_700_000_300_000_000)
        XCTAssertEqual(batch.token, LibraryChangeToken(rawValue: token.base64EncodedString()))
    }

    func testMissingKnownRecordCannotBeRecreatedFromAnOfflineReplay() async throws {
        let original = try notebook()
        let oldRecord = try notebookRecord(original, at: 1_700_000_025)
        let oldVersion = try XCTUnwrap(LibraryRecordMapper.version(of: oldRecord))
        let driver = ScriptedDriver()
        let transport = try transport(driver, mode: .development)
        let staleEdit = try notebook(note: "replay")

        let result = try await transport.push(changes: [
            PendingLibraryChange(localSeq: 2, change: .notebookEntry(staleEdit), baseVersion: oldVersion)
        ])

        XCTAssertEqual(result.failures.first?.disposition, .terminal)
        XCTAssertNil(result.failures.first?.server)
        let pending = await driver.pending
        XCTAssertTrue(pending.isEmpty, "a previously versioned id is never silently recreated")
    }

    func testExactBaseVersionAllowsADevelopmentUpdate() async throws {
        let original = try notebook(note: "old")
        let server = try notebookRecord(original, at: 1_700_000_030)
        let version = try XCTUnwrap(LibraryRecordMapper.version(of: server))
        let updated = try notebook(note: "new")
        let saved = try notebookRecord(updated, at: 1_700_000_031, existing: server)
        let driver = ScriptedDriver(send: {
            [.willSend, .sent(saved: [saved], failed: [], deleted: [], failedDeletes: [:]),
             .stateUpdated(Data("notebook-sent".utf8)), .sendCompleted]
        }, namedRecords: [server])
        let transport = try transport(driver, mode: .development)

        let result = try await transport.push(changes: [
            PendingLibraryChange(localSeq: 3, change: .notebookEntry(updated), baseVersion: version)
        ])

        XCTAssertEqual(result.acknowledged.first?.key, LibraryChange.notebookEntry(updated).key)
        XCTAssertGreaterThan(result.acknowledged.first?.version ?? 0, 0)
        XCTAssertTrue(result.failures.isEmpty)
        XCTAssertEqual(try mapper.decode(saved), .library(.notebookEntry(updated)))
    }
}
