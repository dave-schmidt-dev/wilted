import CloudKit
import WiltedCloudKit
import WiltedDomain
import WiltedLibrary
import XCTest
@testable import WiltedCloudKitLibrary

/// A record with a fixed server modification date, which `CKRecord` only sets for fetched records.
/// It is built by unarchiving so no `CKRecord` initializer has to be called from the subclass.
final class StampedRecord: CKRecord, @unchecked Sendable {
    var stamp: Date?
    required init?(coder: NSCoder) { super.init(coder: coder) }
    override var modificationDate: Date? { stamp }
}

func stamped(_ record: CKRecord, _ seconds: TimeInterval) -> CKRecord {
    do {
        let data = try NSKeyedArchiver.archivedData(withRootObject: record, requiringSecureCoding: true)
        let unarchiver = try NSKeyedUnarchiver(forReadingFrom: data)
        unarchiver.requiresSecureCoding = false
        unarchiver.setClass(StampedRecord.self, forClassName: "CKRecord")
        let copy = unarchiver.decodeObject(forKey: NSKeyedArchiveRootObjectKey) as? StampedRecord
        copy?.stamp = Date(timeIntervalSince1970: seconds)
        return copy ?? record
    } catch { return record }
}

func item(_ raw: String) throws -> ItemID { try ItemID(rawValue: raw) }

func makeEntry(_ id: String = "ep-1", kind: LibraryKind = .podcastEpisode, removal: LibraryRemoval = .none,
               payload: Data = Data("{}".utf8)) throws -> LibraryEntry {
    try LibraryEntry(id: item(id), kind: kind, sourceID: item("feed-1"), title: "Title", summary: "Summary",
                     publishedAt: Date(timeIntervalSince1970: 1_700_000_000), durationSeconds: 1800,
                     artworkRef: "art", removal: removal, payload: payload)
}

func makePosition(device: String = "phone", entry: String = "ep-1", epoch: Int = 2) throws -> DevicePlaybackPosition {
    try DevicePlaybackPosition(deviceID: device, entryID: item(entry), revision: RevisionID(rawValue: "rev-1"),
                               positionSeconds: 61.5, rate: 1.25, isPlaying: true, epoch: epoch)
}

final class LibraryRecordMapperTests: XCTestCase {
    private let mapper = LibraryRecordMapper()

    private func saved(_ change: LibraryChange, existing: CKRecord? = nil) throws -> CKRecord {
        guard case let .save(record) = try mapper.operation(for: change, existing: existing) else {
            throw XCTSkip("expected a save")
        }
        return record
    }

    private func assertShape(_ record: CKRecord, type: LibraryRecordType, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(record.recordType, type.rawValue, file: file, line: line)
        XCTAssertEqual(record.allKeys(), [LibraryRecordMapper.payloadField], "single field", file: file, line: line)
        XCTAssertTrue(record[LibraryRecordMapper.payloadField] is Data, "Bytes field", file: file, line: line)
        XCTAssertEqual(record.recordID.zoneID.zoneName, "WiltedLibraryZone", file: file, line: line)
    }

    func testLibraryChangesRoundTripForEveryRecordType() throws {
        let cases: [(LibraryChange, LibraryRecordType)] = [
            (.source(LibrarySource(id: try item("feed-1"), kind: .podcastFeed, title: "Feed", locator: "https://example.com/rss")), .source),
            (.entry(try makeEntry()), .entry),
            (.slot(try QueueSlot(entryID: item("ep-1"), sortKey: 2.5)), .slot),
            (.listening(ListeningRecord(itemID: try item("ep-1"), completedAt: Date(timeIntervalSince1970: 1_700_000_100),
                                        updatedAt: Date(timeIntervalSince1970: 1_700_000_200), deviceID: "mac")), .listening),
        ]
        for (change, type) in cases {
            let record = try saved(change)
            assertShape(record, type: type)
            XCTAssertEqual(try mapper.decode(record), .library(change))
            XCTAssertEqual(mapper.key(forRecordName: record.recordID.recordName), change.key)
        }
    }

    func testDeviceRecordsRoundTripAndNamesEmbedTheDeviceID() throws {
        let position = try makePosition()
        let now = try mapper.record(playback: position, channel: .nowPlaying)
        let progress = try mapper.record(playback: position, channel: .progress)
        assertShape(now, type: .nowPlaying)
        assertShape(progress, type: .progress)
        XCTAssertEqual(try mapper.decode(now), .playback(.nowPlaying, position))
        XCTAssertEqual(try mapper.decode(progress), .playback(.progress, position))
        XCTAssertTrue(now.recordID.recordName.contains("phone"))
        XCTAssertTrue(progress.recordID.recordName.contains("phone"))
        let other = try mapper.record(playback: makePosition(device: "ipad"), channel: .nowPlaying)
        XCTAssertNotEqual(now.recordID, other.recordID, "each device is the single writer of its record")

        let intent = try LibraryIntent.requestMedia(entryID: item("ep-1"), deviceID: "phone",
                                                    createdAt: Date(timeIntervalSince1970: 1_700_000_300), id: "intent-1")
        let record = try mapper.record(intent: intent)
        assertShape(record, type: .intent)
        XCTAssertEqual(try mapper.decode(record), .intent(intent))
        XCTAssertTrue(record.recordID.recordName.contains("phone"))

        let removal = try LibraryIntent.removeFromLarder(entryID: item("ep-1"), deviceID: "phone",
                                                         createdAt: Date(timeIntervalSince1970: 1_700_000_301), id: "intent-2")
        let removalRecord = try mapper.record(intent: removal)
        assertShape(removalRecord, type: .intent)
        XCTAssertEqual(try mapper.decode(removalRecord), .intent(removal))
    }

    func testUnknownKindEntryRoundTripsUnchanged() throws {
        let payload = Data(#"{"future":{"field":[1,2,3]}}"#.utf8)
        let entry = try makeEntry("art-1", kind: "article.rss", removal: .dismissed, payload: payload)
        let record = try saved(.entry(entry))
        guard case let .library(.entry(decoded)) = try mapper.decode(record) else { return XCTFail("expected an entry") }
        XCTAssertEqual(decoded, entry)
        XCTAssertEqual(decoded.kind.rawValue, "article.rss")
        XCTAssertEqual(decoded.payload, payload)
    }

    func testForeignRecordTypeIsSkippedWithoutError() throws {
        let foreign = CKRecord(recordType: "SomethingElse", recordID: CKRecord.ID(recordName: "x", zoneID: mapper.zoneID))
        foreign["payload"] = Data("not ours".utf8) as CKRecordValue
        XCTAssertEqual(try mapper.decode(foreign), .skipped(recordType: "SomethingElse"))
        XCTAssertNil(mapper.deletion(recordID: foreign.recordID, recordType: "SomethingElse"))
    }

    func testMalformedRecordsAreRejected() throws {
        let good = try saved(.entry(makeEntry()))
        let garbage = CKRecord(recordType: good.recordType, recordID: good.recordID)
        garbage["payload"] = Data("{".utf8) as CKRecordValue
        XCTAssertThrowsError(try mapper.decode(garbage)) {
            guard case .malformedPayload = $0 as? LibraryRecordMapperError else { return XCTFail("\($0)") }
        }
        let empty = CKRecord(recordType: good.recordType, recordID: good.recordID)
        XCTAssertThrowsError(try mapper.decode(empty)) { XCTAssertEqual($0 as? LibraryRecordMapperError, .missingPayload(good.recordID.recordName)) }
        let forged = CKRecord(recordType: good.recordType, recordID: CKRecord.ID(recordName: "entry:other", zoneID: mapper.zoneID))
        forged["payload"] = good["payload"]
        XCTAssertThrowsError(try mapper.decode(forged)) { XCTAssertEqual($0 as? LibraryRecordMapperError, .identityMismatch("entry:other")) }
        let wrongZone = CKRecord(recordType: good.recordType, recordID: CKRecord.ID(recordName: good.recordID.recordName,
                                 zoneID: CKRecordZone.ID(zoneName: "WiltedZone", ownerName: CKCurrentUserDefaultName)))
        wrongZone["payload"] = good["payload"]
        XCTAssertThrowsError(try mapper.decode(wrongZone))
        let mismatchedDevice = try mapper.record(playback: makePosition(), channel: .nowPlaying)
        let stolen = CKRecord(recordType: mismatchedDevice.recordType,
                              recordID: CKRecord.ID(recordName: "nowplaying:ipad", zoneID: mapper.zoneID))
        stolen["payload"] = mismatchedDevice["payload"]
        XCTAssertThrowsError(try mapper.decode(stolen), "a device record must live under its own device's name")
    }

    func testRemovalDeletionAndLimits() throws {
        let base = try saved(.entry(makeEntry()))
        let retired = try saved(.removal(entryID: item("ep-1"), state: .retired), existing: base)
        guard case let .library(.entry(entry)) = try mapper.decode(retired) else { return XCTFail("expected an entry") }
        XCTAssertEqual(entry.removal, .retired)
        XCTAssertNil(entry.removedAt)
        XCTAssertEqual(entry.title, "Title")
        XCTAssertEqual(base.recordID, retired.recordID)
        XCTAssertThrowsError(try mapper.operation(for: .removal(entryID: item("ep-1"), state: .retired), existing: nil)) {
            XCTAssertEqual($0 as? LibraryRecordMapperError, .missingBaseEntry("ep-1"))
        }

        guard case let .delete(id) = try mapper.operation(for: .slotRemoved(entryID: item("ep-1")), existing: nil) else {
            return XCTFail("expected a delete")
        }
        XCTAssertEqual(mapper.deletion(recordID: id, recordType: LibraryRecordType.slot.rawValue), .slotRemoved(entryID: try item("ep-1")))
        XCTAssertNil(mapper.deletion(recordID: base.recordID, recordType: LibraryRecordType.entry.rawValue))

        let huge = Data(repeating: 0x61, count: LibraryRecordMapper.maximumPayloadBytes)
        let source = LibrarySource(id: try item("feed-1"), kind: .podcastFeed, title: String(decoding: huge, as: UTF8.self))
        XCTAssertThrowsError(try mapper.operation(for: .source(source), existing: nil))
    }

    func testVersionIsServerModificationTimeInMicroseconds() throws {
        let record = stamped(try saved(.entry(makeEntry())), 1_700_000_000.25)
        XCTAssertEqual(LibraryRecordMapper.version(of: record), 1_700_000_000_250_000)
        XCTAssertNil(LibraryRecordMapper.version(of: try saved(.entry(makeEntry()))))
    }
}

// MARK: - Transport over a scripted engine

actor ScriptedDriver: CloudKitEngineDriver {
    typealias Script = @Sendable () throws -> [CloudKitEngineEvent]
    nonisolated let stream: AsyncStream<CloudKitEngineEvent>
    private let continuation: AsyncStream<CloudKitEngineEvent>.Continuation
    private let onFetch: Script
    private let onSend: Script
    private let identity: @Sendable () async throws -> CloudKitAccountIdentity?
    private let zone: @Sendable () async throws -> Void
    private(set) var pending: [CKSyncEngine.PendingRecordZoneChange] = []
    private var fetched = false
    private var fetchWaiters: [CheckedContinuation<Void, Never>] = []

    init(fetch: @escaping Script = { [.fetchCompleted] }, send: @escaping Script = { [.sendCompleted] },
         identity: @escaping @Sendable () async throws -> CloudKitAccountIdentity? = { nil },
         zone: @escaping @Sendable () async throws -> Void = {}) {
        (stream, continuation) = AsyncStream<CloudKitEngineEvent>.makeStream()
        onFetch = fetch
        onSend = send
        self.identity = identity
        self.zone = zone
    }

    var events: AsyncStream<CloudKitEngineEvent> { get async { stream } }
    func currentAccountIdentity() async throws -> CloudKitAccountIdentity? { try await identity() }
    func ensureZone() async throws { try await zone() }
    func fetchChanges() async throws {
        fetched = true
        fetchWaiters.forEach { $0.resume() }
        fetchWaiters.removeAll()
        for event in try onFetch() { continuation.yield(event) }
    }
    func waitForFetch() async {
        if !fetched { await withCheckedContinuation { fetchWaiters.append($0) } }
    }
    func sendChanges() async throws { for event in try onSend() { continuation.yield(event) } }
    func cancelOperations() async {}
    func emit(_ event: CloudKitEngineEvent) { continuation.yield(event) }
    func addPendingRecordZoneChanges(_ changes: [CKSyncEngine.PendingRecordZoneChange]) async { pending += changes }
    nonisolated func isValidStateData(_ data: Data) -> Bool { true }
}

final class FactoryLog: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [Data?] = []
    var states: [Data?] { lock.withLock { recorded } }
    func record(_ state: Data?) -> Int { lock.withLock { recorded.append(state); return recorded.count } }
}

final class CloudKitLibraryTransportTests: XCTestCase {
    private let mapper = LibraryRecordMapper()
    private let stateA = Data("state-a".utf8)
    private let stateB = Data("state-b".utf8)

    private func entryRecord(_ id: String, at seconds: TimeInterval, removal: LibraryRemoval = .none) throws -> CKRecord {
        guard case let .save(record) = try mapper.operation(for: .entry(makeEntry(id, removal: removal)), existing: nil) else { throw XCTSkip("save") }
        return stamped(record, seconds)
    }

    private func makeTransport(writer: Bool = true, first: ScriptedDriver, later: @escaping @Sendable (Int) -> ScriptedDriver = { _ in ScriptedDriver() },
                               log: FactoryLog = FactoryLog(), state: LibraryChangeToken? = nil) throws -> CloudKitLibraryTransport {
        try CloudKitLibraryTransport(deviceID: writer ? "mac" : "phone", isLibraryWriter: writer, driver: first,
                                     driverFactory: { state in later(log.record(state)) }, outbox: CloudKitLibraryOutbox(), state: state)
    }

    func testFetchMapsRecordsSkipsForeignTypesAndReturnsTheEngineStateAsToken() async throws {
        let foreign = CKRecord(recordType: "LegacyItem", recordID: CKRecord.ID(recordName: "item:1", zoneID: mapper.zoneID))
        let slot = try QueueSlot(entryID: item("ep-1"), sortKey: 1)
        guard case let .save(slotRecord) = try mapper.operation(for: .slot(slot), existing: nil) else { return XCTFail() }
        let deviceRecord = try mapper.record(playback: makePosition(), channel: .nowPlaying)
        let entry = try entryRecord("ep-1", at: 1_700_000_000)
        let stateA = self.stateA
        let removedID = mapper.recordID(for: LibraryRecordKey(kind: .slot, id: try item("ep-2")))
        let driver = ScriptedDriver(fetch: {
            [.willFetch,
             .fetched(modifications: [foreign, entry, stamped(slotRecord, 1_700_000_001), stamped(deviceRecord, 1_700_000_002)],
                      deletions: [CloudKitRecordDeletion(recordID: removedID, recordType: LibraryRecordType.slot.rawValue),
                                  CloudKitRecordDeletion(recordID: CKRecord.ID(recordName: "revision:x", zoneID: removedID.zoneID), recordType: "Revision")]),
             .stateUpdated(stateA), .fetchCompleted]
        })
        let transport = try makeTransport(first: driver)
        let batch = try await transport.fetchChanges(since: nil)
        XCTAssertEqual(batch.changes.map(\.change.key.description), ["entry:ep-1", "slot:ep-1", "slot:ep-2"])
        XCTAssertEqual(batch.changes[0].version, 1_700_000_000_000_000)
        XCTAssertEqual(batch.changes[2].change, .slotRemoved(entryID: try item("ep-2")))
        XCTAssertGreaterThan(batch.changes[2].version, batch.changes[1].version)
        XCTAssertEqual(batch.token, LibraryChangeToken(rawValue: stateA.base64EncodedString()))
        try await transport.commitFetchedState(batch.token)
    }

    func testMissingZoneDiscardsEngineStateAndRefetchesFromNothing() async throws {
        let log = FactoryLog()
        let stateB = self.stateB
        let entry = try entryRecord("ep-1", at: 1_700_000_000)
        let broken = ScriptedDriver(fetch: { throw CKError(.zoneNotFound) })
        let rebuilt = ScriptedDriver(fetch: { [.fetched(modifications: [entry], deletions: []), .stateUpdated(stateB), .fetchCompleted] })
        let token = LibraryChangeToken(rawValue: stateA.base64EncodedString())
        let transport = try makeTransport(first: broken, later: { _ in rebuilt }, log: log, state: token)
        let batch = try await transport.fetchChanges(since: token)
        XCTAssertEqual(log.states.count, 1)
        XCTAssertNil(log.states[0], "the persisted engine state is dropped")
        XCTAssertEqual(batch.changes.count, 1)
        XCTAssertTrue(batch.generationID.hasSuffix(":1"), batch.generationID)
        XCTAssertEqual(batch.token, LibraryChangeToken(rawValue: stateB.base64EncodedString()))
    }

    func testDifferentSinceTokenRebuildsTheEngineFromThatToken() async throws {
        let log = FactoryLog()
        let transport = try makeTransport(first: ScriptedDriver(), log: log, state: LibraryChangeToken(rawValue: stateA.base64EncodedString()))
        _ = try await transport.fetchChanges(since: LibraryChangeToken(rawValue: stateA.base64EncodedString()))
        XCTAssertTrue(log.states.isEmpty, "matching token keeps the engine")
        _ = try await transport.fetchChanges(since: LibraryChangeToken(rawValue: stateB.base64EncodedString()))
        XCTAssertEqual(log.states, [stateB])
    }

    func testPushAcknowledgesWithServerVersionsAndReportsConflicts() async throws {
        let entry = try makeEntry()
        let slot = try QueueSlot(entryID: item("ep-2"), sortKey: 1)
        let savedEntry = try {
            guard case let .save(record) = try mapper.operation(for: .entry(entry), existing: nil) else { throw XCTSkip("save") }
            return stamped(record, 1_700_000_500)
        }()
        guard case let .save(slotRecord) = try mapper.operation(for: .slot(slot), existing: nil) else { return XCTFail() }
        let serverEntry = try entryRecord("ep-1", at: 1_700_000_900, removal: .dismissed)
        let conflictError = CKError(.serverRecordChanged, userInfo: [CKRecordChangedErrorServerRecordKey: serverEntry])
        let removedSlot = mapper.recordID(for: LibraryRecordKey(kind: .slot, id: try item("ep-3")))
        let driver = ScriptedDriver(send: {
            [.willSend,
             .sent(saved: [savedEntry], failed: [CloudKitRecordFailure(record: slotRecord, error: conflictError)],
                   deleted: [removedSlot], failedDeletes: [:]),
             .stateUpdated(Data("sent".utf8)), .sendCompleted]
        })
        let transport = try makeTransport(first: driver)
        let result = try await transport.push(changes: [
            PendingLibraryChange(localSeq: 1, change: .entry(entry), baseVersion: 0),
            PendingLibraryChange(localSeq: 2, change: .slot(slot), baseVersion: 0),
            PendingLibraryChange(localSeq: 3, change: .slotRemoved(entryID: item("ep-3")), baseVersion: 5),
        ])
        XCTAssertEqual(result.acknowledged.first { $0.key.kind == .entry }?.version, 1_700_000_500_000_000)
        XCTAssertGreaterThan(result.acknowledged.first { $0.key.kind == .slot }?.version ?? 0, 5)
        XCTAssertEqual(result.failures.count, 1)
        XCTAssertEqual(result.failures[0].disposition, .conflict)
        guard case let .entry(server)? = result.failures[0].server?.change else { return XCTFail("server entry") }
        XCTAssertEqual(server.removal, .dismissed)
        XCTAssertEqual(result.token, LibraryChangeToken(rawValue: Data("sent".utf8).base64EncodedString()))
        let pending = await driver.pending
        XCTAssertEqual(pending.count, 3)
    }

    func testOwnershipIsEnforcedBeforeAnythingIsSent() async throws {
        let follower = try makeTransport(writer: false, first: ScriptedDriver())
        await XCTAssertThrowsErrorAsync(try await follower.push(changes: [PendingLibraryChange(localSeq: 1, change: .slotRemoved(entryID: item("ep-1")), baseVersion: 0)])) {
            guard case .ownershipViolation? = $0 as? LibraryTransportError else { return XCTFail("\($0)") }
        }
        await XCTAssertThrowsErrorAsync(try await follower.publish(makePosition(device: "ipad"), as: .nowPlaying)) {
            guard case .ownershipViolation? = $0 as? LibraryTransportError else { return XCTFail("\($0)") }
        }
        let foreignIntent = try LibraryIntent.requestMedia(entryID: item("ep-1"), deviceID: "ipad")
        await XCTAssertThrowsErrorAsync(try await follower.send(intent: foreignIntent)) {
            guard case .ownershipViolation? = $0 as? LibraryTransportError else { return XCTFail("\($0)") }
        }
    }

    /// Polling reads named records (see `LibraryMediaRecordTests`); only `discoverPeers` scans the zone.
    func testPublishSendsOwnRecordAndDiscoverPeersScansTheZoneOnce() async throws {
        let position = try makePosition()
        let saved = stamped(try mapper.record(playback: position, channel: .nowPlaying), 1_700_000_000)
        let intent = try LibraryIntent.requestMedia(entryID: item("ep-1"), deviceID: "ipad", createdAt: Date(timeIntervalSince1970: 5), id: "i-1")
        let intentRecord = stamped(try mapper.record(intent: intent), 1_700_000_001)
        let main = ScriptedDriver(send: { [.sent(saved: [saved], failed: [], deleted: [], failedDeletes: [:]), .sendCompleted] })
        // A real factory builds a fresh engine per call, and a stream cannot be re-consumed after cancellation.
        let makeScan: @Sendable (Int) -> ScriptedDriver = { _ in
            ScriptedDriver(fetch: { [.fetched(modifications: [saved, intentRecord], deletions: []), .fetchCompleted] })
        }
        let log = FactoryLog()
        let transport = try makeTransport(writer: false, first: main, later: makeScan, log: log)
        try await transport.publish(position, as: .nowPlaying)
        XCTAssertTrue(log.states.isEmpty, "publishing creates no scan engine")
        let devices = try await transport.discoverPeers()
        XCTAssertEqual(devices, 2, "the phone and the ipad that sent the intent")
        XCTAssertEqual(log.states.count, 1, "discovery reads the whole zone through one stateless engine")
    }

    func testAccountChangeQuarantinesTheTransport() async throws {
        let driver = ScriptedDriver()
        let transport = try makeTransport(first: driver)
        let generation = await transport.operationGeneration()
        await driver.emit(.accountChanged(.signOut))
        for _ in 0..<100 where !(await transport.isQuarantined()) { try await Task.sleep(nanoseconds: 20_000_000) }
        let quarantined = await transport.isQuarantined()
        XCTAssertTrue(quarantined)
        let bumped = await transport.operationGeneration()
        XCTAssertNotEqual(generation, bumped)
        await XCTAssertThrowsErrorAsync(try await transport.fetchChanges(since: nil)) {
            XCTAssertEqual($0 as? CloudKitSyncError, .quarantined)
        }
    }

    func testMalformedKnownLibraryRecordFailsInsteadOfAdvancingCursor() async throws {
        let record = CKRecord(recordType: LibraryRecordType.entry.rawValue,
                              recordID: mapper.recordID(for: .init(kind: .entry, id: try item("broken"))))
        record[LibraryRecordMapper.payloadField] = Data("not-json".utf8) as CKRecordValue
        let state = self.stateB
        let driver = ScriptedDriver(fetch: { [.fetched(modifications: [record], deletions: []), .stateUpdated(state), .fetchCompleted] })
        let transport = try makeTransport(first: driver)
        await XCTAssertThrowsErrorAsync(try await transport.fetchChanges(since: nil)) { _ in }
        let provisional = await transport.provisionalFetchToken
        let committed = await transport.committedFetchToken
        XCTAssertNil(provisional)
        XCTAssertNil(committed)
    }

    func testKnownLibraryRecordWithoutVersionFailsTheFetch() async throws {
        guard case let .save(record) = try mapper.operation(for: .entry(makeEntry()), existing: nil) else { return XCTFail() }
        let state = self.stateB
        let driver = ScriptedDriver(fetch: { [.fetched(modifications: [record], deletions: []), .stateUpdated(state), .fetchCompleted] })
        let transport = try makeTransport(first: driver)
        await XCTAssertThrowsErrorAsync(try await transport.fetchChanges(since: nil)) { _ in }
        let provisional = await transport.provisionalFetchToken
        XCTAssertNil(provisional)
    }
}

func XCTAssertThrowsErrorAsync<T>(_ expression: @autoclosure () async throws -> T, _ check: (Error) -> Void,
                                  file: StaticString = #filePath, line: UInt = #line) async {
    do { _ = try await expression(); XCTFail("expected an error", file: file, line: line) } catch { check(error) }
}
