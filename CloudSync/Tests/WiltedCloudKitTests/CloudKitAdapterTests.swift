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

private actor FakeEngineDriver: CloudKitEngineDriver {
    let events: AsyncStream<CloudKitEngineEvent>
    private let continuation: AsyncStream<CloudKitEngineEvent>.Continuation
    private(set) var fetchCalls = 0
    private(set) var sendCalls = 0
    private(set) var cancelled = false

    init() {
        let (events, continuation) = AsyncStream<CloudKitEngineEvent>.makeStream()
        self.events = events
        self.continuation = continuation
    }

    func fetchChanges() async throws { fetchCalls += 1 }
    func sendChanges() async throws { sendCalls += 1 }
    func cancelOperations() async { cancelled = true }
    func addPendingRecordZoneChanges(_ changes: [CKSyncEngine.PendingRecordZoneChange]) async {}
    nonisolated func isValidStateData(_ data: Data) -> Bool {
        data == Data("{}".utf8) || data == Data("{\"state\":1}".utf8)
    }
    func emit(_ event: CloudKitEngineEvent) { continuation.yield(event) }
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
    await driver.emit(.accountChanged)
    for _ in 0..<100 {
        if await transport.isQuarantined() { break }
        try? await Task.sleep(for: .milliseconds(5))
    }
    #expect(await transport.isQuarantined())
    do { _ = try await transport.save(changes: [], role: .mac); Issue.record("expected quarantine") }
    catch let error as CloudKitSyncError { #expect(error == .quarantined) }
    await transport.resetAfterAccountChange()
    #expect(await transport.isQuarantined() == false)
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
