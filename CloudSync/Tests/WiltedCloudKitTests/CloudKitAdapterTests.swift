import CloudKit
import CryptoKit
import Foundation
import Testing
import WiltedCloudKit
import WiltedDomain
import WiltedSync

private let hash = "sha256:" + String(repeating: "a", count: 64)

private func article(_ suffix: String = "alpha") throws -> (Article, RevisionID) {
    let url = URL(string: "https://example.test/articles/\(suffix)")!
    let item = try ItemID.derive(from: url)
    return (try Article(itemID: item, canonicalURL: url, title: "Title \(suffix)", source: "Example",
                        createdAt: Timestamp(iso8601: "2026-08-17T12:00:00Z")), try RevisionID(rawValue: "rev-\(suffix)"))
}

private func validEnvelope(_ suffix: String = "alpha", opaque: [String: WiltedFieldValue] = [:]) throws -> WiltedRecordEnvelope {
    let (value, revision) = try article(suffix)
    return try WiltedRecordCodec().encode(article: value, currentRevisionID: revision, opaqueFields: opaque)
}

private func mapper(stager: CloudKitAssetStaging? = nil) throws -> CloudKitRecordMapper { try CloudKitRecordMapper(stager: stager) }

private actor SaveGate {
    private(set) var calls = 0
    var released = false

    func save() async throws {
        calls += 1
        while !released { await Task.yield() }
    }

    func release() { released = true }

    func waitForCalls(_ expected: Int, maxYields: Int = 2_000) async -> Bool {
        for _ in 0..<maxYields {
            if calls >= expected { return true }
            await Task.yield()
        }
        return calls >= expected
    }
}

private actor FakeEngineDriver: CloudKitEngineDriver {
    let events: AsyncStream<CloudKitEngineEvent>
    private let continuation: AsyncStream<CloudKitEngineEvent>.Continuation
    private(set) var fetchCalls = 0
    private(set) var sendCalls = 0
    private(set) var ensureCalls = 0
    private(set) var ensureCallsAtFetch = 0
    private(set) var ensureCallsAtSend = 0
    private(set) var zoneBootstrapResets = 0
    private(set) var pendingAddCalls = 0
    private(set) var pendingChangeCounts: [Int] = []
    let holdSecondPendingAdd: Bool
    let pendingRelease: AsyncStream<Void>.Continuation
    let pendingReleaseStream: AsyncStream<Void>
    private(set) var cancelled = false
    let zoneFailure: CloudKitSyncError?
    var zoneNotFoundFetchesRemaining: Int
    var zoneNotFoundSendRemaining: Int
    let holdZoneBootstrap: Bool
    let zoneRelease: AsyncStream<Void>.Continuation
    let zoneReleaseStream: AsyncStream<Void>

    init(zoneFailure: CloudKitSyncError? = nil, zoneNotFoundFetches: Int = 0, zoneNotFoundSends: Int = 0,
         holdZoneBootstrap: Bool = false, holdSecondPendingAdd: Bool = false) {
        let (events, continuation) = AsyncStream<CloudKitEngineEvent>.makeStream()
        let (zoneReleaseStream, zoneRelease) = AsyncStream<Void>.makeStream()
        let (pendingReleaseStream, pendingRelease) = AsyncStream<Void>.makeStream()
        self.events = events
        self.continuation = continuation
        self.zoneFailure = zoneFailure
        self.zoneNotFoundFetchesRemaining = zoneNotFoundFetches
        self.zoneNotFoundSendRemaining = zoneNotFoundSends
        self.holdZoneBootstrap = holdZoneBootstrap
        self.zoneRelease = zoneRelease
        self.zoneReleaseStream = zoneReleaseStream
        self.holdSecondPendingAdd = holdSecondPendingAdd
        self.pendingRelease = pendingRelease
        self.pendingReleaseStream = pendingReleaseStream
    }

    func ensureZone() async throws {
        ensureCalls += 1
        if let zoneFailure { throw zoneFailure }
        if holdZoneBootstrap {
            for await _ in zoneReleaseStream { break }
        }
    }
    func fetchChanges() async throws {
        ensureCallsAtFetch = ensureCalls; fetchCalls += 1
        if zoneNotFoundFetchesRemaining > 0 { zoneNotFoundFetchesRemaining -= 1; throw CKError(.zoneNotFound) }
    }
    func sendChanges() async throws {
        ensureCallsAtSend = ensureCalls; sendCalls += 1
        if zoneNotFoundSendRemaining > 0 { zoneNotFoundSendRemaining -= 1; throw CKError(.zoneNotFound) }
    }
    func cancelOperations() async { cancelled = true }
    func resetZoneBootstrap() async { zoneBootstrapResets += 1 }
    func addPendingRecordZoneChanges(_ changes: [CKSyncEngine.PendingRecordZoneChange]) async {
        pendingAddCalls += 1
        pendingChangeCounts.append(changes.count)
        if holdSecondPendingAdd, pendingAddCalls == 2 {
            for await _ in pendingReleaseStream { break }
        }
    }
    nonisolated func isValidStateData(_ data: Data) -> Bool {
        data == Data("{}".utf8) || data == Data("{\"state\":1}".utf8)
    }
    func emit(_ event: CloudKitEngineEvent) { continuation.yield(event) }
    func releaseZoneBootstrap() { zoneRelease.yield(()) }
    func releasePendingAdd() { pendingRelease.yield(()) }
    func waitForEnsureCall(maxYields: Int = 2_000) async -> Bool {
        for _ in 0..<maxYields {
            if ensureCalls > 0 { return true }
            await Task.yield()
        }
        return ensureCalls > 0
    }
    func waitForFetchCall(maxYields: Int = 2_000) async -> Bool {
        for _ in 0..<maxYields {
            if fetchCalls > 0 { return true }
            await Task.yield()
        }
        return fetchCalls > 0
    }
    func waitForSendCall(maxYields: Int = 2_000) async -> Bool {
        for _ in 0..<maxYields {
            if sendCalls > 0 { return true }
            await Task.yield()
        }
        return sendCalls > 0
    }
    func waitForSendCalls(_ expected: Int, maxYields: Int = 2_000) async -> Bool {
        for _ in 0..<maxYields {
            if sendCalls >= expected { return true }
            await Task.yield()
        }
        return sendCalls >= expected
    }
    func waitForFetchCalls(_ expected: Int, maxYields: Int = 2_000) async -> Bool {
        for _ in 0..<maxYields {
            if fetchCalls >= expected { return true }
            await Task.yield()
        }
        return fetchCalls >= expected
    }
    func waitForPendingAdd(_ expected: Int, maxYields: Int = 2_000) async -> Bool {
        for _ in 0..<maxYields {
            if pendingAddCalls >= expected { return true }
            await Task.yield()
        }
        return pendingAddCalls >= expected
    }
}

@Test("all CloudKit field types map round trip through a valid article")
func allFieldTypesRoundTrip() throws {
    let mapper = try mapper()
    let original = try validEnvelope(opaque: [
        "text": .string("hello"), "count": .int64(7), "ratio": .double(1.25),
        "date": .date(Timestamp(iso8601: "2026-08-17T12:00:00Z")), "bytes": .bytes(Data([1, 2, 3])),
    ])
    let decoded = try mapper.decode(try mapper.encode(original)).envelope
    #expect(decoded.fields == original.fields)
    #expect(decoded.id == original.id)
}

@Test("record identity, type, and both zone fields are rejected")
func identityAndZoneAreRejected() throws {
    let mapper = try mapper()
    let badType = CKRecord(recordType: "Unknown", recordID: CKRecord.ID(recordName: "item:item-x", zoneID: mapper.zoneID))
    #expect(throws: CloudKitSyncError.unsupportedRecordType("Unknown")) { try mapper.decode(badType) }
    let otherZone = CKRecordZone.ID(zoneName: "OtherZone", ownerName: CKCurrentUserDefaultName)
    let wrongZone = CKRecord(recordType: WiltedRecordType.item.rawValue, recordID: CKRecord.ID(recordName: "item:item-x", zoneID: otherZone))
    #expect(throws: CloudKitSyncError.invalidZone("OtherZone")) { try mapper.decode(wrongZone) }
    let wrongOwner = CKRecordZone.ID(zoneName: mapper.zoneID.zoneName, ownerName: "other-owner")
    let wrongOwnerRecord = CKRecord(recordType: WiltedRecordType.item.rawValue, recordID: CKRecord.ID(recordName: "item:item-x", zoneID: wrongOwner))
    #expect(throws: CloudKitSyncError.invalidZone(mapper.zoneID.zoneName)) { try mapper.decode(wrongOwnerRecord) }
    let wrongName = CKRecord(recordType: WiltedRecordType.item.rawValue, recordID: CKRecord.ID(recordName: "revision:item-x:rev-a", zoneID: mapper.zoneID))
    #expect(throws: CloudKitSyncError.invalidRecordIdentity) { try mapper.decode(wrongName) }
}

@Test("system fields round trip and corruption fails closed")
func systemFieldsRoundTrip() async throws {
    let mapper = try mapper()
    let record = try mapper.encode(validEnvelope())
    let data = try mapper.encodeSystemFields(record)
    let restored = try mapper.decodeSystemFields(data)
    #expect(restored.recordID == record.recordID)
    #expect(throws: CloudKitSyncError.systemFieldsCorrupt) { try mapper.decodeSystemFields(Data("corrupt".utf8)) }
    #expect(throws: CloudKitSyncError.stateCorrupt) { try CloudKitSyncTransport(driver: FakeEngineDriver(), role: .mac, mapper: mapper, stateData: Data([1])) }
    #expect(throws: CloudKitSyncError.stateCorrupt) { try CloudKitSyncTransport(driver: FakeEngineDriver(), role: .mac, mapper: mapper, stateData: Data()) }
    #expect(throws: CloudKitSyncError.stateCorrupt) {
        try CloudKitSyncTransport(driver: FakeEngineDriver(), role: .mac, mapper: mapper,
                                  stateData: Data("{\"not-state\":true}".utf8))
    }
}

@Test("first-run empty fetch completes without an engine state update")
func initialEmptyFetchWithoutStateUpdate() async throws {
    let driver = FakeEngineDriver()
    let transport = try CloudKitSyncTransport(driver: driver, role: .mac, mapper: mapper())
    let fetch = Task { try await transport.fetchChanges() }
    guard await driver.waitForFetchCall() else {
        await transport.cancel()
        Issue.record("fake driver did not receive fetchChanges")
        return
    }
    await driver.emit(.fetchCompleted)
    let batch = try await fetch.value
    #expect(batch.records.isEmpty)
    #expect(batch.deletedRecordIDs.isEmpty)
    #expect(batch.engineState == nil)
}

@Test("first-run empty send completes without an engine state update")
func initialEmptySendWithoutStateUpdate() async throws {
    let driver = FakeEngineDriver()
    let transport = try CloudKitSyncTransport(driver: driver, role: .mac, mapper: mapper())
    let result = try await transport.save(changes: [], role: .mac)
    #expect(result.engineState == nil)
    #expect(await driver.sendCalls == 0)
}

private final class TestStager: CloudKitAssetStaging {
    let root: URL
    init() throws { root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString); try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true) }
    func stage(asset: CKAsset, assetID: String, contentHash: String) throws -> URL {
        guard let source = asset.fileURL else { throw CloudKitSyncError.assetUnavailable(assetID) }
        let destination = root.appendingPathComponent("incoming-\(UUID().uuidString)")
        try FileManager.default.copyItem(at: source, to: destination)
        return destination
    }
    func commit(stagedURL: URL, assetID: String) throws -> CloudKitAssetCommit { CloudKitAssetCommit(url: stagedURL, created: true) }
    func removeStagedAsset(at url: URL) { try? FileManager.default.removeItem(at: url) }
    func resolve(assetID: String) -> URL? { nil }
    deinit { try? FileManager.default.removeItem(at: root) }
}

@Test("assets use deterministic record-unique IDs and are validated before publication")
func assetsAreStagedAndValidated() throws {
    let stager = try TestStager()
    let source = stager.root.appendingPathComponent("source.m4a")
    let bytes = Data("audio".utf8)
    try bytes.write(to: source)
    let contentHash = "sha256:" + SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    let mapper = try mapper(stager: stager)
    let item = try article().0.itemID
    let revision = try AudioRevision(itemID: item, revisionID: RevisionID(rawValue: "rev-alpha"), durationSeconds: 1,
                                     byteCount: Int64(bytes.count), contentHash: contentHash, mediaType: "audio/mp4",
                                     createdAt: Timestamp(iso8601: "2026-08-17T12:00:00Z"), schemaVersion: 1)
    let envelope = try WiltedRecordCodec().encode(revision: revision, audioAsset: WiltedAsset(assetID: "audioAsset", contentHash: contentHash))
    let record = try mapper.encode(envelope, assetURLs: ["audioAsset": source])
    let decoded = try mapper.decode(record)
    #expect(decoded.envelope.fields["audioAsset"] == .asset(try WiltedAsset(assetID: "\(record.recordID.recordName)#audioAsset", contentHash: contentHash)))
    #expect(decoded.stagedAssets["audioAsset"].flatMap { try? Data(contentsOf: $0) } == bytes)
}

@Test("failed asset validation preserves the prior valid cached file")
func assetFailurePreservesPrior() throws {
    let stager = try FileCloudKitAssetStager(rootURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
    let mapper = try mapper(stager: stager)
    let bytes = Data("audio".utf8)
    let source = stager.rootURL.appendingPathComponent("source")
    try bytes.write(to: source)
    let contentHash = "sha256:" + SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    let item = try article().0.itemID
    let revision = try AudioRevision(itemID: item, revisionID: RevisionID(rawValue: "rev-alpha"), durationSeconds: 1, byteCount: 5, contentHash: contentHash, mediaType: "audio/mp4", createdAt: Timestamp(iso8601: "2026-08-17T12:00:00Z"), schemaVersion: 1)
    let good = try mapper.encode(try WiltedRecordCodec().encode(revision: revision, audioAsset: WiltedAsset(assetID: "audioAsset", contentHash: contentHash)), assetURLs: ["audioAsset": source])
    let decodedGood = try mapper.decode(good)
    _ = try mapper.publish(decodedGood)
    let badSource = stager.rootURL.appendingPathComponent("bad")
    try Data("wrong".utf8).write(to: badSource)
    let bad = CKRecord(recordType: good.recordType, recordID: good.recordID)
    for key in good.allKeys() { bad[key] = good[key] }
    bad["audioAsset"] = CKAsset(fileURL: badSource)
    #expect(throws: CloudKitSyncError.invalidField("audioAsset.contentHash")) { try mapper.decode(bad) }
    let asset = try WiltedAsset(assetID: "\(good.recordID.recordName)#audioAsset", contentHash: contentHash)
    guard let resolved = mapper.resolvedAssetURL(for: asset) else {
        Issue.record("asset resolver returned no committed URL")
        return
    }
    #expect(try Data(contentsOf: resolved) == bytes)
}

@Test("pending scope filtering validates outgoing records")
func pendingScopeFiltering() throws {
    let mapper = try mapper()
    let record = try validEnvelope()
    let change = try SyncPendingChange(operation: .update, recordID: record.id, record: record)
    let id = CKRecord.ID(recordName: record.id.recordName, zoneID: mapper.zoneID)
    let pending = CloudKitPendingMapper(mapper: mapper)
    #expect(try pending.pendingRecordZoneChanges([change], scope: .recordIDs([id]), role: .mac).count == 1)
    #expect(try pending.pendingRecordZoneChanges([change], scope: .recordIDs([CKRecord.ID(recordName: "item:item-other", zoneID: mapper.zoneID)]), role: .mac).isEmpty)
}

@Test("transport fetch waits for state, modifications, deletion, and completion")
func transportFetch() async throws {
    let mapper = try mapper()
    let driver = FakeEngineDriver()
    let transport = try CloudKitSyncTransport(driver: driver, role: .mac, mapper: mapper, stateData: Data("{}".utf8))
    let record = try mapper.encode(validEnvelope())
    let fetch = Task { try await transport.fetchChanges() }
    guard await driver.waitForFetchCall() else {
        await transport.cancel()
        Issue.record("fake driver did not receive fetchChanges")
        return
    }
    await driver.emit(.fetched(modifications: [record], deletions: [CloudKitRecordDeletion(recordID: CKRecord.ID(recordName: "item:item-deleted", zoneID: mapper.zoneID), recordType: WiltedRecordType.item.rawValue)]))
    await driver.emit(.stateUpdated(Data("{\"state\":1}".utf8)))
    await driver.emit(.fetchCompleted)
    let batch = try await fetch.value
    #expect(batch.records.count == 1)
    #expect(batch.deletedRecordIDs.count == 1)
    #expect(await driver.fetchCalls == 1)
    #expect(await driver.ensureCalls == 1)
    #expect(await driver.ensureCallsAtFetch == 1)
}

@Test("transport send returns partial acknowledgement and server conflict envelope")
func transportSendPartialConflict() async throws {
    let mapper = try mapper()
    let driver = FakeEngineDriver()
    let transport = try CloudKitSyncTransport(driver: driver, role: .mac, mapper: mapper)
    let local = try validEnvelope("alpha")
    let server = try validEnvelope("alpha", opaque: ["server": .string("new")])
    let other = try validEnvelope("beta")
    let otherRecord = try mapper.encode(other)
    let localRecord = try mapper.encode(local)
    let serverRecord = try mapper.encode(server)
    let change = try SyncPendingChange(operation: .update, recordID: local.id, record: local)
    let otherChange = try SyncPendingChange(operation: .update, recordID: other.id, record: other)
    let send = Task { try await transport.save(changes: [change, otherChange], role: .mac) }
    guard await driver.waitForSendCall() else {
        await transport.cancel()
        Issue.record("fake driver did not receive sendChanges")
        return
    }
    await driver.emit(.sent(saved: [otherRecord], failed: [], deleted: [], failedDeletes: [:]))
    await driver.emit(.sent(saved: [], failed: [CloudKitRecordFailure(record: localRecord, error: CKError(.serverRecordChanged, userInfo: [CKRecordChangedErrorServerRecordKey: serverRecord]))], deleted: [], failedDeletes: [:]))
    await driver.emit(.stateUpdated(Data("{\"state\":1}".utf8)))
    await driver.emit(.sendCompleted)
    let result = try await send.value
    #expect(result.acknowledgedRecordIDs == [other.id])
    #expect(result.failures.first?.disposition == .conflict)
    #expect(result.failures.first?.serverRecord?.fields["server"] == .string("new"))
    #expect(result.engineState == Data("{\"state\":1}".utf8))
    #expect(await driver.ensureCalls == 1)
    #expect(await driver.ensureCallsAtSend == 1)
}

@Test("zone bootstrap failure prevents record-zone saves and reports failure")
func zoneBootstrapFailure() async throws {
    let mapper = try mapper()
    let driver = FakeEngineDriver(zoneFailure: CloudKitSyncError.cloudKit(code: 7, message: "zone unavailable"))
    let transport = try CloudKitSyncTransport(driver: driver, role: .mac, mapper: mapper)
    let envelope = try validEnvelope("zone-failure")
    let change = try SyncPendingChange(operation: .update, recordID: envelope.id, record: envelope)
    do { _ = try await transport.save(changes: [change], role: .mac); Issue.record("expected zone bootstrap failure") }
    catch let error as CloudKitSyncError { #expect(error == .cloudKit(code: 7, message: "zone unavailable")) }
    #expect(await driver.ensureCalls == 1)
    #expect(await driver.sendCalls == 0)
}

@Test("zone-not-found send recreates the zone and requeues pending changes once")
func zoneNotFoundSendRecovery() async throws {
    let mapper = try mapper()
    let driver = FakeEngineDriver(zoneNotFoundSends: 1)
    let transport = try CloudKitSyncTransport(driver: driver, role: .mac, mapper: mapper)
    let envelope = try validEnvelope("zone-retry-send")
    let record = try mapper.encode(envelope)
    let change = try SyncPendingChange(operation: .update, recordID: envelope.id, record: envelope)
    let send = Task { try await transport.save(changes: [change], role: .mac) }
    guard await driver.waitForSendCalls(2) else {
        await transport.cancel()
        Issue.record("zone-not-found send was not retried")
        return
    }
    await driver.emit(.sent(saved: [record], failed: [], deleted: [], failedDeletes: [:]))
    await driver.emit(.stateUpdated(Data("{\"state\":1}".utf8)))
    await driver.emit(.sendCompleted)
    let result = try await send.value
    #expect(result.acknowledgedRecordIDs == [envelope.id])
    #expect(await driver.zoneBootstrapResets == 1)
    #expect(await driver.ensureCalls == 2)
    #expect(await driver.pendingAddCalls == 2)
}

@Test("per-record zone-not-found save waits for completion before retrying")
func eventZoneNotFoundSaveRecovery() async throws {
    let mapper = try mapper()
    let driver = FakeEngineDriver()
    let transport = try CloudKitSyncTransport(driver: driver, role: .mac, mapper: mapper)
    let envelope = try validEnvelope("event-zone-save")
    let record = try mapper.encode(envelope)
    let change = try SyncPendingChange(operation: .update, recordID: envelope.id, record: envelope)
    let send = Task { try await transport.save(changes: [change], role: .mac) }
    #expect(await driver.waitForSendCalls(1))

    await driver.emit(.sent(saved: [], failed: [CloudKitRecordFailure(record: record, error: CKError(.zoneNotFound))], deleted: [], failedDeletes: [:]))
    await Task.yield()
    #expect(await driver.sendCalls == 1)
    #expect(await driver.pendingAddCalls == 1)
    await driver.emit(.sendCompleted)
    #expect(await driver.waitForSendCalls(2))
    await driver.emit(.sent(saved: [record], failed: [], deleted: [], failedDeletes: [:]))
    await driver.emit(.stateUpdated(Data("{\"state\":1}".utf8)))
    await driver.emit(.sendCompleted)

    let result = try await send.value
    #expect(result.acknowledgedRecordIDs == [envelope.id])
    #expect(result.failures.isEmpty)
    #expect(await driver.zoneBootstrapResets == 1)
    #expect(await driver.pendingAddCalls == 2)
}

@Test("multiple sent events before completion coalesce all zone failures")
func multipleEventZoneFailuresCoalesce() async throws {
    let mapper = try mapper()
    let driver = FakeEngineDriver()
    let transport = try CloudKitSyncTransport(driver: driver, role: .mac, mapper: mapper)
    let first = try validEnvelope("event-zone-first")
    let second = try validEnvelope("event-zone-second")
    let firstRecord = try mapper.encode(first)
    let secondRecord = try mapper.encode(second)
    let changes = [
        try SyncPendingChange(operation: .update, recordID: first.id, record: first),
        try SyncPendingChange(operation: .update, recordID: second.id, record: second),
    ]
    let send = Task { try await transport.save(changes: changes, role: .mac) }
    #expect(await driver.waitForSendCalls(1))
    await driver.emit(.sent(saved: [], failed: [CloudKitRecordFailure(record: firstRecord, error: CKError(.zoneNotFound))], deleted: [], failedDeletes: [:]))
    await driver.emit(.sent(saved: [], failed: [CloudKitRecordFailure(record: secondRecord, error: CKError(.zoneNotFound))], deleted: [], failedDeletes: [:]))
    await driver.emit(.sendCompleted)
    #expect(await driver.waitForSendCalls(2))
    #expect(await driver.pendingChangeCounts == [2, 2])
    await driver.emit(.sent(saved: [firstRecord, secondRecord], failed: [], deleted: [], failedDeletes: [:]))
    await driver.emit(.stateUpdated(Data("{\"state\":1}".utf8)))
    await driver.emit(.sendCompleted)

    let result = try await send.value
    #expect(Set(result.acknowledgedRecordIDs) == Set([first.id, second.id]))
    #expect(result.failures.isEmpty)
}

@Test("per-record zone-not-found delete waits for completion before retrying")
func eventZoneNotFoundDeleteRecovery() async throws {
    let mapper = try mapper()
    let driver = FakeEngineDriver()
    let transport = try CloudKitSyncTransport(driver: driver, role: .mac, mapper: mapper)
    let (value, _) = try article("event-zone-delete")
    let recordID = try WiltedRecordID(recordType: .item, recordName: "item:\(value.itemID.rawValue)", zoneName: mapper.zoneID.zoneName)
    let tombstone = SyncTombstone(itemID: value.itemID, generationID: "generation-delete", requestedAt: try Timestamp(iso8601: "2026-08-17T12:00:00Z"))
    let change = try SyncPendingChange(operation: .delete, recordID: recordID, tombstone: tombstone)
    let cloudID = CKRecord.ID(recordName: recordID.recordName, zoneID: mapper.zoneID)
    let send = Task { try await transport.save(changes: [change], role: .mac) }
    #expect(await driver.waitForSendCalls(1))

    await driver.emit(.sent(saved: [], failed: [], deleted: [], failedDeletes: [cloudID: CKError(.zoneNotFound)]))
    await driver.emit(.sendCompleted)
    #expect(await driver.waitForSendCalls(2))
    await driver.emit(.sent(saved: [], failed: [], deleted: [cloudID], failedDeletes: [:]))
    await driver.emit(.stateUpdated(Data("{\"state\":1}".utf8)))
    await driver.emit(.sendCompleted)

    let result = try await send.value
    #expect(result.acknowledgedRecordIDs == [recordID])
    #expect(result.failures.isEmpty)
    #expect(await driver.zoneBootstrapResets == 1)
    #expect(await driver.pendingAddCalls == 2)
}

@Test("persistent thrown zone-not-found stops after one retry")
func persistentThrownZoneNotFoundStopsAfterOneRetry() async throws {
    let mapper = try mapper()
    let driver = FakeEngineDriver(zoneNotFoundSends: 2)
    let transport = try CloudKitSyncTransport(driver: driver, role: .mac, mapper: mapper)
    let envelope = try validEnvelope("persistent-zone-throw")
    let change = try SyncPendingChange(operation: .update, recordID: envelope.id, record: envelope)
    let send = Task { try await transport.save(changes: [change], role: .mac) }
    #expect(await driver.waitForSendCalls(2))
    do { _ = try await send.value; Issue.record("expected persistent zone failure") }
    catch let error as CloudKitSyncError {
        if case let .cloudKit(code, _) = error { #expect(code == CKError.Code.zoneNotFound.rawValue) }
        else { Issue.record("unexpected error: \(error)") }
    }
    #expect(await driver.sendCalls == 2)
    #expect(await driver.zoneBootstrapResets == 1)
    #expect(await driver.ensureCalls == 2)
}

@Test("persistent per-record zone-not-found stops after one retry")
func persistentEventZoneNotFoundStopsAfterOneRetry() async throws {
    let mapper = try mapper()
    let driver = FakeEngineDriver()
    let transport = try CloudKitSyncTransport(driver: driver, role: .mac, mapper: mapper)
    let envelope = try validEnvelope("persistent-zone-event")
    let record = try mapper.encode(envelope)
    let change = try SyncPendingChange(operation: .update, recordID: envelope.id, record: envelope)
    let send = Task { try await transport.save(changes: [change], role: .mac) }
    #expect(await driver.waitForSendCalls(1))
    let failure = CloudKitRecordFailure(record: record, error: CKError(.zoneNotFound))
    await driver.emit(.sent(saved: [], failed: [failure], deleted: [], failedDeletes: [:]))
    await driver.emit(.sendCompleted)
    #expect(await driver.waitForSendCalls(2))
    await driver.emit(.sent(saved: [], failed: [failure], deleted: [], failedDeletes: [:]))
    await driver.emit(.stateUpdated(Data("{\"state\":1}".utf8)))
    await driver.emit(.sendCompleted)

    let result = try await send.value
    #expect(result.acknowledgedRecordIDs.isEmpty)
    #expect(result.failures.count == 1)
    #expect(result.failures[0].recordID == envelope.id)
    #expect(await driver.sendCalls == 2)
    #expect(await driver.zoneBootstrapResets == 1)
}

@Test("cancellation during retry requeue prevents the second send")
func cancellationDuringRetryRequeue() async throws {
    let mapper = try mapper()
    let driver = FakeEngineDriver(holdSecondPendingAdd: true)
    let transport = try CloudKitSyncTransport(driver: driver, role: .mac, mapper: mapper)
    let envelope = try validEnvelope("cancel-requeue")
    let record = try mapper.encode(envelope)
    let change = try SyncPendingChange(operation: .update, recordID: envelope.id, record: envelope)
    let send = Task { try await transport.save(changes: [change], role: .mac) }
    #expect(await driver.waitForSendCalls(1))
    await driver.emit(.sent(saved: [], failed: [CloudKitRecordFailure(record: record, error: CKError(.zoneNotFound))], deleted: [], failedDeletes: [:]))
    await driver.emit(.sendCompleted)
    #expect(await driver.waitForPendingAdd(2))
    await transport.cancel()
    await driver.releasePendingAdd()
    do { _ = try await send.value; Issue.record("expected cancellation") }
    catch let error as CloudKitSyncError { #expect(error == .cancelled) }
    #expect(await driver.sendCalls == 1)
}

@Test("account change during retry requeue prevents the second send")
func accountChangeDuringRetryRequeue() async throws {
    let mapper = try mapper()
    let driver = FakeEngineDriver(holdSecondPendingAdd: true)
    let transport = try CloudKitSyncTransport(driver: driver, role: .mac, mapper: mapper)
    let envelope = try validEnvelope("account-requeue")
    let record = try mapper.encode(envelope)
    let change = try SyncPendingChange(operation: .update, recordID: envelope.id, record: envelope)
    let send = Task { try await transport.save(changes: [change], role: .mac) }
    #expect(await driver.waitForSendCalls(1))
    await driver.emit(.sent(saved: [], failed: [CloudKitRecordFailure(record: record, error: CKError(.zoneNotFound))], deleted: [], failedDeletes: [:]))
    await driver.emit(.sendCompleted)
    #expect(await driver.waitForPendingAdd(2))
    await driver.emit(.accountChanged(.switchAccounts))
    for _ in 0..<100 {
        if await transport.isQuarantined() { break }
        await Task.yield()
    }
    await driver.releasePendingAdd()
    do { _ = try await send.value; Issue.record("expected account-change failure") }
    catch let error as CloudKitSyncError { #expect(error == .accountChanged) }
    #expect(await driver.sendCalls == 1)
}

@Test("zone-not-found fetch recreates the zone before returning deletions")
func zoneNotFoundFetchRecovery() async throws {
    let mapper = try mapper()
    let driver = FakeEngineDriver(zoneNotFoundFetches: 1)
    let transport = try CloudKitSyncTransport(driver: driver, role: .mac, mapper: mapper, stateData: Data("{}".utf8))
    let fetch = Task { try await transport.fetchChanges() }
    guard await driver.waitForFetchCalls(2) else {
        await transport.cancel()
        Issue.record("zone-not-found fetch was not retried")
        return
    }
    let deleted = CloudKitRecordDeletion(recordID: CKRecord.ID(recordName: "item:item-zone-fetch-delete", zoneID: mapper.zoneID), recordType: WiltedRecordType.item.rawValue)
    await driver.emit(.fetched(modifications: [], deletions: [deleted]))
    await driver.emit(.stateUpdated(Data("{\"state\":1}".utf8)))
    await driver.emit(.fetchCompleted)
    let batch = try await fetch.value
    #expect(batch.deletedRecordIDs.count == 1)
    #expect(await driver.zoneBootstrapResets == 1)
    #expect(await driver.ensureCalls == 2)
}

@Test("zone bootstrap cancellation cannot publish a stale save generation")
func zoneBootstrapCancellationGeneration() async throws {
    let gate = SaveGate()
    let state = CloudKitZoneBootstrapState { try await gate.save() }
    let first = Task { try await state.ensureZone() }
    #expect(await gate.waitForCalls(1))

    await state.cancel()
    await gate.release()
    try await first.value

    // The canceled generation completed, but it was not allowed to mark the
    // zone ensured. A retry creates the replacement save; subsequent ensures
    // are still idempotent.
    try await state.ensureZone()
    #expect(await gate.calls == 2)
    await state.cancel()
    try await state.ensureZone()
    #expect(await gate.calls == 2)

    await state.invalidate()
    try await state.ensureZone()
    #expect(await gate.calls == 3)
}

@Test("account change during suspended zone bootstrap becomes accountChanged")
func accountChangeDuringZoneBootstrap() async throws {
    let mapper = try mapper()
    let driver = FakeEngineDriver(holdZoneBootstrap: true)
    let transport = try CloudKitSyncTransport(driver: driver, role: .mac, mapper: mapper)
    let fetch = Task { try await transport.fetchChanges() }
    guard await driver.waitForEnsureCall() else {
        await transport.cancel()
        Issue.record("zone bootstrap did not start")
        return
    }
    await driver.emit(.accountChanged(.switchAccounts))
    for _ in 0..<100 {
        if await transport.isQuarantined() { break }
        try? await Task.sleep(for: .milliseconds(5))
    }
    await driver.releaseZoneBootstrap()
    do { _ = try await fetch.value; Issue.record("expected account-change failure") }
    catch let error as CloudKitSyncError { #expect(error == .accountChanged) }
    #expect(await driver.zoneBootstrapResets == 1)
}

@Test("send acknowledgements require a fresh engine state update")
func sendAcknowledgementRequiresFreshState() async throws {
    let mapper = try mapper()
    let driver = FakeEngineDriver()
    let transport = try CloudKitSyncTransport(driver: driver, role: .mac, mapper: mapper, stateData: Data("{}".utf8))
    let envelope = try validEnvelope("stale-ack")
    let record = try mapper.encode(envelope)
    let change = try SyncPendingChange(operation: .update, recordID: envelope.id, record: envelope)
    let send = Task { try await transport.save(changes: [change], role: .mac) }
    guard await driver.waitForSendCall() else {
        await transport.cancel()
        Issue.record("fake driver did not receive sendChanges")
        return
    }
    await driver.emit(.sent(saved: [record], failed: [], deleted: [], failedDeletes: [:]))
    await driver.emit(.sendCompleted)
    do { _ = try await send.value; Issue.record("expected stale state rejection") }
    catch let error as CloudKitSyncError { #expect(error == .stateCorrupt) }
}

@Test("transport cancellation wakes a fetch waiter")
func transportCancellation() async throws {
    let mapper = try mapper()
    let driver = FakeEngineDriver()
    let transport = try CloudKitSyncTransport(driver: driver, role: .mac, mapper: mapper)
    let fetch = Task { try await transport.fetchChanges() }
    guard await driver.waitForFetchCall() else {
        await transport.cancel()
        Issue.record("fake driver did not receive fetchChanges")
        return
    }
    await transport.cancel()
    do { _ = try await fetch.value; Issue.record("expected cancellation") }
    catch let error as CloudKitSyncError { #expect(error == .cancelled) }
}

@Test("account change quarantines sends until explicit reset and emits status")
func transportAccountQuarantine() async throws {
    let mapper = try mapper()
    let driver = FakeEngineDriver()
    let transport = try CloudKitSyncTransport(driver: driver, role: .mac, mapper: mapper)
    await driver.emit(.accountChanged(.switchAccounts))
    for _ in 0..<100 {
        if await transport.isQuarantined() { break }
        try? await Task.sleep(for: .milliseconds(5))
    }
    #expect(await transport.isQuarantined())
    #expect(await transport.operationGeneration() == 1)
    #expect(await driver.zoneBootstrapResets == 1)
    do { _ = try await transport.save(changes: [], role: .mac); Issue.record("expected quarantine") }
    catch let error as CloudKitSyncError { #expect(error == .quarantined) }
    await transport.resetAfterAccountChange()
    #expect(await transport.isQuarantined() == false)
    #expect(await driver.zoneBootstrapResets == 2)
}

@Test("account reset permits a fresh fetch after quarantine")
func accountResetAllowsFreshFetch() async throws {
    let mapper = try mapper()
    let driver = FakeEngineDriver()
    let transport = try CloudKitSyncTransport(driver: driver, role: .mac, mapper: mapper)
    await driver.emit(.accountChanged(.signOut))
    for _ in 0..<100 {
        if await transport.isQuarantined() { break }
        await Task.yield()
    }
    #expect(await transport.isQuarantined())

    await transport.resetAfterAccountChange()
    #expect(await transport.isQuarantined() == false)
    let fetch = Task { try await transport.fetchChanges() }
    guard await driver.waitForFetchCall() else {
        await transport.cancel()
        Issue.record("reset transport did not start a fresh fetch")
        return
    }
    await driver.emit(.stateUpdated(Data("{\"state\":1}".utf8)))
    await driver.emit(.fetchCompleted)
    let batch = try await fetch.value
    #expect(batch.records.isEmpty)
    #expect(await driver.zoneBootstrapResets == 2)
}

@Test("account change type crosses the CloudKit transport without account identifiers")
func typedAccountChangeSignal() async throws {
    let mapper = try mapper()
    for type in [CloudKitAccountChangeType.signIn, .signOut, .switchAccounts] {
        let driver = FakeEngineDriver()
        let transport = try CloudKitSyncTransport(driver: driver, role: .mac, mapper: mapper)
        var changes = transport.accountChanges.makeAsyncIterator()
        await driver.emit(.accountChanged(type))
        #expect(await changes.next() == .quarantineRequired(type))
        #expect(await transport.isQuarantined())
    }
}

@Test("a first sign-in adopts ownership instead of deadlocking the first sync")
func firstSignInAdoptsOwnership() async throws {
    let mapper = try mapper()
    let driver = FakeEngineDriver()
    // No recorded owner is what every install starts with, and a sync engine built without
    // persisted serialization always reports a first sign-in. Quarantining it meant the
    // first sync could never send, so state was never persisted, so the next engine
    // reported a first sign-in again.
    let transport = try CloudKitSyncTransport(driver: driver, role: .mac, mapper: mapper)
    var changes = transport.accountChanges.makeAsyncIterator()
    let token = CloudKitAccountIdentity.token(for: "_owner-one")
    await driver.emit(.accountChanged(.signIn, identity: .init(currentOwnerToken: token, hadPreviousOwner: false)))

    #expect(await changes.next() == .ownershipAdopted(token: token))
    #expect(await transport.isQuarantined() == false)

    let fetch = Task { try await transport.fetchChanges() }
    guard await driver.waitForFetchCall() else {
        await transport.cancel()
        Issue.record("an adopted account did not permit a fetch")
        return
    }
    await driver.emit(.stateUpdated(Data("{\"state\":1}".utf8)))
    await driver.emit(.fetchCompleted)
    let batch = try await fetch.value
    #expect(batch.records.isEmpty)
}

@Test("the recorded owner signing in again resumes without review")
func recordedOwnerSignInResumes() async throws {
    let mapper = try mapper()
    let driver = FakeEngineDriver()
    let token = CloudKitAccountIdentity.token(for: "_owner-one")
    // Losing engine state does not change who owns the work, so this must not read as an
    // account change the owner has to review.
    let transport = try CloudKitSyncTransport(driver: driver, role: .mac, mapper: mapper, knownOwnerToken: token)
    var changes = transport.accountChanges.makeAsyncIterator()
    await driver.emit(.accountChanged(.signIn, identity: .init(currentOwnerToken: token, hadPreviousOwner: false)))

    #expect(await changes.next() == .ownershipConfirmed)
    #expect(await transport.isQuarantined() == false)
}

@Test("a different account signing in still quarantines for review")
func differentAccountSignInQuarantines() async throws {
    let mapper = try mapper()
    let driver = FakeEngineDriver()
    let transport = try CloudKitSyncTransport(driver: driver, role: .mac, mapper: mapper,
                                              knownOwnerToken: CloudKitAccountIdentity.token(for: "_owner-one"))
    var changes = transport.accountChanges.makeAsyncIterator()
    let other = CloudKitAccountIdentity.token(for: "_owner-two")
    await driver.emit(.accountChanged(.signIn, identity: .init(currentOwnerToken: other, hadPreviousOwner: false)))

    #expect(await changes.next() == .quarantineRequired(.signIn))
    #expect(await transport.isQuarantined())
}

@Test("an account switch quarantines even when it lands on the recorded owner")
func accountSwitchAlwaysQuarantines() async throws {
    let mapper = try mapper()
    let driver = FakeEngineDriver()
    let token = CloudKitAccountIdentity.token(for: "_owner-one")
    let transport = try CloudKitSyncTransport(driver: driver, role: .mac, mapper: mapper, knownOwnerToken: token)
    var changes = transport.accountChanges.makeAsyncIterator()
    // A switch means another account was signed in on the way here, so local work may have
    // been produced under it. Matching tokens do not make that ambiguity go away.
    await driver.emit(.accountChanged(.switchAccounts, identity: .init(currentOwnerToken: token, hadPreviousOwner: true)))

    #expect(await changes.next() == .quarantineRequired(.switchAccounts))
    #expect(await transport.isQuarantined())
}

@Test("account ownership tokens are derived, stable, and not the account identifier")
func accountOwnershipTokens() {
    let token = CloudKitAccountIdentity.token(for: "_abc123")
    #expect(token == CloudKitAccountIdentity.token(for: "_abc123"))
    #expect(token != CloudKitAccountIdentity.token(for: "_abc124"))
    #expect(token.hasPrefix("sha256:"))
    #expect(!token.contains("abc123"))
}

@Test("transport status stream remains live through a fetch")
func transportStatusLiveness() async throws {
    let mapper = try mapper()
    let driver = FakeEngineDriver()
    let transport = try CloudKitSyncTransport(driver: driver, role: .mac, mapper: mapper, stateData: Data("{}".utf8))
    let statuses = transport.statuses
    let fetch = Task { try await transport.fetchChanges() }
    guard await driver.waitForFetchCall() else {
        await transport.cancel()
        Issue.record("fake driver did not receive fetchChanges")
        return
    }
    await driver.emit(.willFetch)
    await driver.emit(.fetched(modifications: [], deletions: []))
    await driver.emit(.stateUpdated(Data("{\"state\":1}".utf8)))
    await driver.emit(.fetchCompleted)
    _ = try await fetch.value
    #expect(await boundedStatusCount(statuses, minimum: 3) >= 3)
}

private func boundedStatusCount(_ stream: AsyncStream<SyncStatus>, minimum: Int) async -> Int {
    await withTaskGroup(of: Int.self) { group in
        group.addTask {
            var iterator = stream.makeAsyncIterator()
            var count = 0
            while count < minimum, await iterator.next() != nil { count += 1 }
            return count
        }
        group.addTask {
            try? await Task.sleep(for: .milliseconds(100))
            return 0
        }
        let result = await group.next() ?? 0
        group.cancelAll()
        return result
    }
}

@Test("asset resolver keeps committed paths inside its root")
func assetResolverRejectsTraversal() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let stager = try FileCloudKitAssetStager(rootURL: root)
    let staged = root.appendingPathComponent("incoming")
    try Data("safe".utf8).write(to: staged)
    let committed = try stager.commit(stagedURL: staged, assetID: "../../outside")
    #expect(committed.url.deletingLastPathComponent().standardizedFileURL == root.standardizedFileURL)
    #expect(stager.resolve(assetID: "../../outside") == committed.url)
}

@Test("transport rejects concurrent operations and cancellation releases waiters")
func transportRejectsConcurrentOperations() async throws {
    let mapper = try mapper()
    let driver = FakeEngineDriver()
    let transport = try CloudKitSyncTransport(driver: driver, role: .mac, mapper: mapper)
    let firstFetch = Task { try await transport.fetchChanges() }
    guard await driver.waitForFetchCall() else {
        await transport.cancel()
        Issue.record("fake driver did not receive fetchChanges")
        return
    }
    do { _ = try await transport.fetchChanges(); Issue.record("expected in-flight rejection") }
    catch let error as CloudKitSyncError { #expect(error == .operationInProgress) }
    await transport.cancel()
    do { _ = try await firstFetch.value; Issue.record("expected first fetch cancellation") }
    catch let error as CloudKitSyncError { #expect(error == .cancelled) }
}

@Test("fetch with remote changes requires a fresh engine state update")
func fetchRequiresFreshState() async throws {
    let mapper = try mapper()
    let driver = FakeEngineDriver()
    let transport = try CloudKitSyncTransport(driver: driver, role: .mac, mapper: mapper, stateData: Data("{}".utf8))
    let fetch = Task { try await transport.fetchChanges() }
    guard await driver.waitForFetchCall() else {
        await transport.cancel()
        Issue.record("fake driver did not receive fetchChanges")
        return
    }
    await driver.emit(.fetched(modifications: [try mapper.encode(validEnvelope())], deletions: []))
    await driver.emit(.fetchCompleted)
    do { _ = try await fetch.value; Issue.record("expected stale state rejection") }
    catch let error as CloudKitSyncError { #expect(error == .stateCorrupt) }
}

@Test("saved acknowledgements carry pending envelope fields and server system fields")
func savedAcknowledgementCarriesEnvelope() throws {
    let mapper = try mapper()
    let envelope = try validEnvelope("saved", opaque: ["custom": .string("kept")])
    let change = try SyncPendingChange(operation: .update, recordID: envelope.id, record: envelope)
    let record = try mapper.encode(envelope)
    let result = try CloudKitSendMapper(mapper: mapper).result(
        engineState: Data("{\"state\":1}".utf8), pendingChanges: [change], saved: [record], failed: [], deleted: [], failedDeletes: [:])
    #expect(result.acknowledgedRecordIDs == [envelope.id])
    #expect(result.serverEnvelopes.first?.fields["custom"] == .string("kept"))
    #expect(result.serverEnvelopes.first?.sidecar?.encodedSystemFields != nil)
}

@Test("unavailable conflict assets do not fail the entire conflict result")
func unavailableConflictAssetIsTolerated() throws {
    let mapper = try mapper()
    let envelope = try validEnvelope("conflict")
    let change = try SyncPendingChange(operation: .update, recordID: envelope.id, record: envelope)
    let record = try mapper.encode(envelope)
    let unavailable = CKRecord(recordType: record.recordType, recordID: record.recordID)
    for key in record.allKeys() { unavailable[key] = record[key] }
    unavailable["unavailableAsset"] = CKAsset(fileURL: URL(fileURLWithPath: "/tmp/wilted-no-such-asset"))
    let error = CKError(.serverRecordChanged, userInfo: [CKRecordChangedErrorServerRecordKey: unavailable])
    let result = try CloudKitSendMapper(mapper: mapper).result(
        engineState: Data("{\"state\":1}".utf8), pendingChanges: [change], saved: [], failed: [(record, error)], deleted: [], failedDeletes: [:])
    #expect(result.failures.first?.disposition == .conflict)
    #expect(result.failures.first?.serverRecord == nil)
}

@Test("CloudKit transient errors retry while permission errors terminate")
func sendDispositionClassification() throws {
    let mapper = try mapper()
    let envelope = try validEnvelope("disposition")
    let change = try SyncPendingChange(operation: .update, recordID: envelope.id, record: envelope)
    let record = try mapper.encode(envelope)
    let mapperUnderTest = CloudKitSendMapper(mapper: mapper)
    for code in [CKError.Code.networkFailure, .requestRateLimited, .serviceUnavailable, .zoneBusy] {
        let result = try mapperUnderTest.result(engineState: Data("{\"state\":1}".utf8), pendingChanges: [change], saved: [], failed: [(record, CKError(code))], deleted: [], failedDeletes: [:])
        #expect(result.failures.first?.disposition == .retryable)
    }
    let terminal = try mapperUnderTest.result(engineState: Data("{\"state\":1}".utf8), pendingChanges: [change], saved: [], failed: [(record, CKError(.permissionFailure))], deleted: [], failedDeletes: [:])
    #expect(terminal.failures.first?.disposition == .terminal)
}
