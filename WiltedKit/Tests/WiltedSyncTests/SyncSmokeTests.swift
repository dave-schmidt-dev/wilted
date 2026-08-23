import Testing
import CryptoKit
import Foundation
import WiltedDomain
@testable import WiltedSync
@testable import WiltedSyncTesting

@Test("sync targets are linked")
func syncTargetsAreLinked() {
    #expect(SyncOwnershipPolicy().allows(role: .mac, operation: .create, recordType: .item))
    #expect(!SyncOwnershipPolicy().allows(role: .iphone, operation: .create, recordType: .item))
}

@Test("iPhone fake transport rejects article and revision writes")
func iPhoneOwnershipIsEnforced() async throws {
    let (article, revisionID, _) = try fixtureArticle()
    let articleRecord = try WiltedRecordCodec().encode(article: article, currentRevisionID: revisionID)
    let transport = FakeSyncTransport(batch: try SyncFetchBatch(generationID: "g", records: []))
    do {
        let change = try SyncPendingChange(operation: .update, recordID: articleRecord.id, record: articleRecord)
        _ = try await transport.save(changes: [change], role: .iphone)
        Issue.record("expected iPhone ownership rejection")
    } catch let error as WiltedSyncError {
        #expect(error == .ownershipViolation(role: .iphone, operation: .update, recordType: .item))
    }
}

@Test("engine serialization is optional only for true no-op outcomes")
func engineSerializationNoOpContract() throws {
    let noOpFetch = try SyncFetchBatch(generationID: "no-op", records: [])
    let noOpSend = try SyncSendResult()
    #expect(noOpFetch.engineState == nil)
    #expect(noOpSend.engineState == nil)

    let (article, revisionID, _) = try fixtureArticle()
    let record = try WiltedRecordCodec().encode(article: article, currentRevisionID: revisionID)
    #expect(throws: WiltedSyncError.invalidValue(field: "engineState")) {
        try SyncFetchBatch(generationID: "remote", records: [record])
    }
    #expect(throws: WiltedSyncError.invalidValue(field: "engineState")) {
        try SyncFetchBatch(generationID: "snapshot", records: [], kind: .fullSnapshot)
    }
    #expect(throws: WiltedSyncError.invalidValue(field: "engineState")) {
        try SyncSendResult(acknowledgedRecordIDs: [record.id], serverEnvelopes: [record])
    }
}

private func fixtureArticle() throws -> (Article, RevisionID, WiltedAsset) {
    let url = URL(string: "https://example.test/articles/alpha")!
    let item = try ItemID.derive(from: url)
    let revisionID = try RevisionID(rawValue: "rev-alpha-v1")
    let hash = "sha256:" + String(repeating: "0", count: 63) + "1"
    let article = try Article(itemID: item, canonicalURL: url, title: "Alpha", source: "Example",
                              author: nil, createdAt: Timestamp(iso8601: "2026-08-17T12:00:00Z"))
    return (article, revisionID, try WiltedAsset(assetID: "asset-alpha", contentHash: hash))
}

private func chunkPublicationChanges() throws -> [SyncPendingChange] {
    let (article, revisionID, _) = try fixtureArticle()
    let bytes = Data("two-phase-audio".utf8)
    let chunked = try AudioChunking.chunk(bytes, chunkSize: 4)
    let hash = "sha256:" + SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    let revision = try AudioRevision(itemID: article.itemID, revisionID: revisionID,
                                     durationSeconds: 4, byteCount: Int64(bytes.count),
                                     contentHash: hash, mediaType: "audio/mp4",
                                     createdAt: Timestamp(Date(timeIntervalSince1970: 1_700_000_000)),
                                     schemaVersion: 1)
    let codec = WiltedRecordCodec()
    let item = try codec.encode(article: article, currentRevisionID: revisionID)
    let manifest = try codec.encode(revision: revision, manifest: chunked.manifest)
    let chunks = try chunked.manifest.chunks.map { descriptor in
        try codec.encode(revisionChunk: article.itemID, revisionID: revisionID,
                         descriptor: descriptor,
                         chunkAsset: WiltedAsset(assetID: descriptor.identity,
                                                 contentHash: "sha256:\(descriptor.sha256)"))
    }
    // Deliberately put visibility records first. The coordinator must not rely on
    // caller ordering to keep a partial upload undiscoverable.
    return try ([item, manifest] + chunks).map {
        try SyncPendingChange(operation: .create, recordID: $0.id, record: $0)
    }
}

private actor EpochGuardTransport: SyncTransport {
    nonisolated let statuses: AsyncStream<SyncStatus>
    nonisolated let saveStarted: AsyncStream<Void>
    private let saveStartedContinuation: AsyncStream<Void>.Continuation
    private let saveReleaseStream: AsyncStream<Void>
    private let saveReleaseContinuation: AsyncStream<Void>.Continuation
    private let batch: SyncFetchBatch
    private let sendResult: SyncSendResult
    private var generation: UInt64 = 0

    init(batch: SyncFetchBatch, sendResult: SyncSendResult = try! SyncSendResult()) {
        self.batch = batch
        self.sendResult = sendResult
        let (statuses, _) = AsyncStream<SyncStatus>.makeStream()
        self.statuses = statuses
        let (saveStarted, saveStartedContinuation) = AsyncStream<Void>.makeStream()
        self.saveStarted = saveStarted
        self.saveStartedContinuation = saveStartedContinuation
        let (saveReleaseStream, saveReleaseContinuation) = AsyncStream<Void>.makeStream()
        self.saveReleaseStream = saveReleaseStream
        self.saveReleaseContinuation = saveReleaseContinuation
    }

    func operationGeneration() async -> UInt64 { generation }

    func invalidateAccountOperation() { generation &+= 1 }

    func fetchChanges() async throws -> SyncFetchBatch { batch }

    func save(changes: [SyncPendingChange], role: SyncDeviceRole) async throws -> SyncSendResult {
        saveStartedContinuation.yield(())
        for await _ in saveReleaseStream { break }
        return sendResult
    }

    func releaseSave() { saveReleaseContinuation.yield(()) }
}

private actor EpochGuardRepository: SyncRepository {
    nonisolated let statuses: AsyncStream<SyncStatus>
    nonisolated let stageStarted: AsyncStream<Void>
    private var storedState: SyncRepositoryState
    private let stageStartedContinuation: AsyncStream<Void>.Continuation
    private let stageReleaseStream: AsyncStream<Void>
    private let stageReleaseContinuation: AsyncStream<Void>.Continuation
    private(set) var commitCalls = 0
    private(set) var acknowledgeCalls = 0

    init(state: SyncRepositoryState = .init()) {
        storedState = state
        let (statuses, _) = AsyncStream<SyncStatus>.makeStream()
        self.statuses = statuses
        let (stageStarted, stageStartedContinuation) = AsyncStream<Void>.makeStream()
        self.stageStarted = stageStarted
        self.stageStartedContinuation = stageStartedContinuation
        let (stageReleaseStream, stageReleaseContinuation) = AsyncStream<Void>.makeStream()
        self.stageReleaseStream = stageReleaseStream
        self.stageReleaseContinuation = stageReleaseContinuation
    }

    func state() async -> SyncRepositoryState { storedState }

    func stage(_ batch: SyncFetchBatch) async throws -> StagedSyncBatch {
        stageStartedContinuation.yield(())
        for await _ in stageReleaseStream { break }
        return StagedSyncBatch(batch: batch, priorState: storedState)
    }

    func releaseStage() { stageReleaseContinuation.yield(()) }

    func commit(_ staged: StagedSyncBatch) async throws {
        commitCalls += 1
        storedState = SyncRepositoryState(records: staged.batch.records,
                                          engineState: staged.batch.engineState,
                                          pendingChanges: storedState.pendingChanges)
    }

    func enqueue(_ change: SyncPendingChange) async throws {
        storedState = SyncRepositoryState(records: storedState.records, engineState: storedState.engineState,
                                          pendingChanges: storedState.pendingChanges + [change])
    }

    func acknowledge(_ result: SyncSendResult) async throws { acknowledgeCalls += 1 }
}

@Test("codec round trips validated records and rejects identity mismatch")
func codecRoundTripAndIdentity() throws {
    let (article, revisionID, _) = try fixtureArticle()
    let codec = WiltedRecordCodec()
    let encoded = try codec.encode(article: article, currentRevisionID: revisionID,
                                   opaqueFields: ["legacyEditorialLabel": .string("kept-opaque")])
    let decoded = try codec.decodeArticleRecord(encoded)
    #expect(decoded.value == article)
    #expect(decoded.opaqueFields["legacyEditorialLabel"] == .string("kept-opaque"))
    var fields = encoded.fields
    fields["itemID"] = .string("item-other")
    let bad = try WiltedRecordEnvelope(id: encoded.id, fields: fields)
    #expect(throws: WiltedSyncError.invalidRecordIdentity) { try codec.decodeArticle(bad) }
}

@Test("codec rejects malformed optional, required, schema, and boolean fields")
func codecRejectsMalformedFields() throws {
    let (article, revisionID, _) = try fixtureArticle()
    let codec = WiltedRecordCodec()
    let encoded = try codec.encode(article: article, currentRevisionID: revisionID)

    var optionalType = encoded.fields
    optionalType["author"] = .int64(7)
    #expect(throws: WiltedSyncError.invalidFieldType("author")) {
        try codec.decodeArticle(try WiltedRecordEnvelope(id: encoded.id, fields: optionalType))
    }

    var requiredType = encoded.fields
    requiredType["currentRevisionID"] = .int64(7)
    #expect(throws: WiltedSyncError.invalidFieldType("currentRevisionID")) {
        try codec.decodeArticle(try WiltedRecordEnvelope(id: encoded.id, fields: requiredType))
    }

    var schemaType = encoded.fields
    schemaType["schemaVersion"] = .string("1")
    #expect(throws: WiltedSyncError.invalidFieldType("schemaVersion")) {
        try codec.decodeArticle(try WiltedRecordEnvelope(id: encoded.id, fields: schemaType))
    }

    var invalidBoolean = encoded.fields
    invalidBoolean["isDeleted"] = .int64(2)
    #expect(throws: WiltedSyncError.invalidValue(field: "isDeleted")) {
        try codec.decodeArticle(try WiltedRecordEnvelope(id: encoded.id, fields: invalidBoolean))
    }
}

private struct PublishFixture: Decodable {
    let records: [WiltedRecordEnvelope]
    let sidecars: [String: FixtureSidecar]
}

private struct FixtureSidecar: Decodable {
    let encodedSystemFieldsBase64: String
    let changeTag: String
}

@Test("authoritative publish fixture decodes all records and round trips exactly")
func authoritativePublishFixture() throws {
    let url = try #require(Bundle.module.url(forResource: "01-valid-publish-decode", withExtension: "json", subdirectory: "Fixtures"))
    let source = try Data(contentsOf: url)
    let fixture = try JSONDecoder().decode(PublishFixture.self, from: source)
    let root = try #require(JSONSerialization.jsonObject(with: source) as? [String: Any])
    let originalRecords = try #require(root["records"] as? [[String: Any]])
    let codec = WiltedRecordCodec()
    let encoder = JSONEncoder()
    for record in fixture.records {
        let sidecar = try #require(fixture.sidecars[record.id.recordName])
        let systemFields = try #require(Data(base64Encoded: sidecar.encodedSystemFieldsBase64))
        let withSidecar = try WiltedRecordEnvelope(id: record.id, fields: record.fields,
                                                   sidecar: WiltedOpaqueSidecar(changeTag: sidecar.changeTag,
                                                                                encodedSystemFields: systemFields))
        switch record.id.recordType {
        case .item: _ = try codec.decodeArticle(withSidecar)
        case .revision: _ = try codec.decodeRevision(withSidecar)
        case .revisionChunk: _ = try codec.decodeRevisionChunkRecord(withSidecar)
        case .playbackState: _ = try codec.decodePlayback(withSidecar)
        }
        let roundTrip = try #require(JSONSerialization.jsonObject(with: encoder.encode(record)) as? [String: Any])
        let original = try #require(originalRecords.first { ($0["recordName"] as? String) == record.id.recordName })
        #expect(NSDictionary(dictionary: roundTrip).isEqual(to: original))
    }
}

@Test("revision chunks remain transport-only records")
func revisionChunkIsTransportOnly() throws {
    let (article, revisionID, _) = try fixtureArticle()
    let chunked = try AudioChunking.chunk(Data("chunk payload".utf8), chunkSize: 6)
    let descriptor = try #require(chunked.manifest.chunks.first)
    let codec = WiltedRecordCodec()
    let record = try codec.encode(revisionChunk: article.itemID, revisionID: revisionID,
                                  descriptor: descriptor,
                                  chunkAsset: try WiltedAsset(assetID: descriptor.identity,
                                                             contentHash: "sha256:\(descriptor.sha256)"))

    #expect(record.id.recordType == .revisionChunk)
    #expect(try codec.decodeRevisionChunkRecord(record).value == descriptor)
    #expect(throws: WiltedSyncError.invalidRecordIdentity) {
        try codec.decodeRevision(record)
    }
}

@Test("revision and playback codec enforce readiness, references, booleans, and intent")
func revisionPlaybackStrictness() throws {
    let (article, revisionID, asset) = try fixtureArticle()
    let codec = WiltedRecordCodec()
    let revision = try AudioRevision(itemID: article.itemID, revisionID: revisionID, durationSeconds: 420.5,
                                     byteCount: 2_048_000, contentHash: asset.contentHash, mediaType: "audio/mp4",
                                     createdAt: Timestamp(iso8601: "2026-08-17T12:05:00Z"), schemaVersion: 1)
    let revisionRecord = try codec.encode(revision: revision, audioAsset: asset)
    #expect(try codec.decodeRevision(revisionRecord) == revision)
    var notReady = revisionRecord.fields; notReady["readiness"] = .string("pending")
    #expect(throws: WiltedSyncError.invalidValue(field: "readiness")) {
        try codec.decodeRevision(try WiltedRecordEnvelope(id: revisionRecord.id, fields: notReady))
    }

    let playback = try PlaybackState(itemID: article.itemID, revisionID: revisionID, sessionID: "session-alpha-1",
                                     sequence: 2, positionSeconds: 12, durationSeconds: 420.5, completed: false,
                                     intent: .rewind, deviceID: "device-iphone", updatedAt: Timestamp(iso8601: "2026-08-17T12:06:00Z"))
    let playbackRecord = try codec.encode(playback: playback)
    #expect(try codec.decodePlayback(playbackRecord) == playback)
    var badBoolean = playbackRecord.fields; badBoolean["completed"] = .int64(8)
    #expect(throws: WiltedSyncError.invalidValue(field: "completed")) {
        try codec.decodePlayback(try WiltedRecordEnvelope(id: playbackRecord.id, fields: badBoolean))
    }
    var badIntent = playbackRecord.fields; badIntent["intent"] = .string("unknown")
    #expect(throws: WiltedSyncError.invalidValue(field: "intent")) {
        try codec.decodePlayback(try WiltedRecordEnvelope(id: playbackRecord.id, fields: badIntent))
    }
    var badReference = playbackRecord.fields
    badReference["revisionReference"] = .reference(try WiltedRecordReference(recordID: .item(article.itemID)))
    #expect(throws: WiltedSyncError.invalidRecordIdentity) {
        try codec.decodePlayback(try WiltedRecordEnvelope(id: playbackRecord.id, fields: badReference))
    }

    let restart = try PlaybackState(itemID: article.itemID, revisionID: revisionID, sessionID: "session-alpha-2",
                                    sequence: 1, positionSeconds: 0, durationSeconds: 420.5, completed: false,
                                    intent: .restart, deviceID: "device-iphone", updatedAt: try Timestamp(iso8601: "2026-08-17T12:07:00Z"))
    #expect(try codec.decodePlayback(codec.encode(playback: restart)) == restart)
    let otherRevision = try RevisionID(rawValue: "rev-other")
    #expect(throws: WiltedSyncError.invalidRecordIdentity) {
        try codec.decodeRevision(try WiltedRecordEnvelope(id: try .revision(article.itemID, otherRevision), fields: revisionRecord.fields))
    }
    #expect(throws: WiltedSyncError.invalidRecordIdentity) {
        try codec.decodePlayback(try WiltedRecordEnvelope(id: try .playback(article.itemID, otherRevision), fields: playbackRecord.fields))
    }

    var badDate = try codec.encode(article: article, currentRevisionID: revisionID).fields
    badDate["author"] = .string("Author")
    badDate["publishedTime"] = .string("not-a-date")
    #expect(throws: WiltedSyncError.invalidFieldType("publishedTime")) {
        try codec.decodeArticle(try WiltedRecordEnvelope(id: try .item(article.itemID), fields: badDate))
    }
    let wrongZone = #"{"recordType":"WiltedItem","recordName":"item:item-x","zoneName":"_defaultZone","action":"none"}"#.data(using: .utf8)!
    #expect(throws: WiltedSyncError.invalidZone("_defaultZone")) {
        try JSONDecoder().decode(WiltedRecordReference.self, from: wrongZone)
    }
    var unsupported = revisionRecord.fields; unsupported["schemaVersion"] = .int64(2)
    #expect(throws: WiltedSyncError.unsupportedSchemaVersion(2)) {
        try codec.decodeRevision(try WiltedRecordEnvelope(id: revisionRecord.id, fields: unsupported))
    }
}

@Test("failed fetch preserves repository state")
func failedFetchPreservesState() async throws {
    let (article, revisionID, _) = try fixtureArticle()
    let record = try WiltedRecordCodec().encode(article: article, currentRevisionID: revisionID)
    let pending = try SyncPendingChange(operation: .create, recordID: record.id, record: record)
    let initial = SyncRepositoryState(records: [record], engineState: Data([1, 2]), pendingChanges: [pending])
    let batch = try SyncFetchBatch(generationID: "generation-1", records: [], engineState: Data([3]))
    let transport = FakeSyncTransport(batch: batch, failure: WiltedSyncError.transport("offline"))
    let repository = FakeSyncRepository(state: initial)
    let result = await SyncCoordinator(transport: transport, repository: repository).synchronize()
    guard case .failure = result else { Issue.record("expected failed fetch"); return }
    #expect(await repository.state() == initial)
}

@Test("account change between fetch return and commit invalidates the staged generation")
func accountChangeBeforeCommitCannotPublishStaleFetch() async throws {
    let (article, revisionID, _) = try fixtureArticle()
    let record = try WiltedRecordCodec().encode(article: article, currentRevisionID: revisionID)
    let batch = try SyncFetchBatch(generationID: "account-race-fetch", records: [record], engineState: Data([7]))
    let transport = EpochGuardTransport(batch: batch)
    let repository = EpochGuardRepository()
    let coordinator = SyncCoordinator(transport: transport, repository: repository)
    let run = Task { await coordinator.synchronize() }
    var staged = repository.stageStarted.makeAsyncIterator()
    #expect(await staged.next() != nil)

    await transport.invalidateAccountOperation()
    await repository.releaseStage()
    let result = await run.value
    guard case .failure = result else { Issue.record("expected stale fetch rejection"); return }
    let commitCalls = await repository.commitCalls
    #expect(commitCalls == 0)
}

@Test("account change between send return and acknowledgement preserves pending work")
func accountChangeBeforeAcknowledgementCannotPublishStaleSend() async throws {
    let (article, revisionID, _) = try fixtureArticle()
    let record = try WiltedRecordCodec().encode(article: article, currentRevisionID: revisionID)
    let change = try SyncPendingChange(operation: .update, recordID: record.id, record: record)
    let initial = SyncRepositoryState(pendingChanges: [change])
    let result = try SyncSendResult(engineState: Data([8]), acknowledgedRecordIDs: [record.id], serverEnvelopes: [record])
    let transport = EpochGuardTransport(batch: try SyncFetchBatch(generationID: "account-race-send", records: []), sendResult: result)
    let repository = EpochGuardRepository(state: initial)
    let coordinator = SyncCoordinator(transport: transport, repository: repository)
    let run = Task { await coordinator.sendPending(role: .mac) }
    var saving = transport.saveStarted.makeAsyncIterator()
    #expect(await saving.next() != nil)

    await transport.invalidateAccountOperation()
    await transport.releaseSave()
    let outcome = await run.value
    guard case .failure = outcome else { Issue.record("expected stale send rejection"); return }
    let acknowledgeCalls = await repository.acknowledgeCalls
    #expect(acknowledgeCalls == 0)
    #expect(await repository.state() == initial)
}

@Test("successful commit preserves queued pending changes")
func successfulCommitPreservesPending() async throws {
    let (article, revisionID, _) = try fixtureArticle()
    let record = try WiltedRecordCodec().encode(article: article, currentRevisionID: revisionID)
    let pending = try SyncPendingChange(operation: .create, recordID: record.id, record: record)
    let initial = SyncRepositoryState(records: [], engineState: Data([1]), pendingChanges: [pending])
    let batch = try SyncFetchBatch(generationID: "generation-1", records: [record], engineState: Data([9]))
    let repository = FakeSyncRepository(state: initial)
    let result = await SyncCoordinator(transport: FakeSyncTransport(batch: batch), repository: repository).synchronize()
    guard case .success = result else { Issue.record("expected successful fetch"); return }
    let state = await repository.state()
    #expect(state.records == [record])
    #expect(state.engineState == Data([9]))
    #expect(state.pendingChanges == [pending])
}

@Test("coordinator excludes conflicted records from automatic sends")
func coordinatorDoesNotReuploadConflicts() async throws {
    let (article, revisionID, _) = try fixtureArticle()
    let eligible = try WiltedRecordCodec().encode(article: article, currentRevisionID: revisionID)
    var conflictFields = eligible.fields
    conflictFields["itemID"] = .string("item-conflicted")
    let conflicted = try WiltedRecordEnvelope(
        id: .item(try ItemID(rawValue: "item-conflicted")),
        fields: conflictFields)
    let eligibleChange = try SyncPendingChange(operation: .update, recordID: eligible.id, record: eligible)
    let conflictedChange = try SyncPendingChange(operation: .update, recordID: conflicted.id, record: conflicted)
    let repository = FakeSyncRepository(state: SyncRepositoryState(
        records: [eligible, conflicted],
        engineState: Data([1]),
        pendingChanges: [eligibleChange, conflictedChange],
        conflictedRecordIDs: [conflicted.id]))
    let transport = FakeSyncTransport(batch: try SyncFetchBatch(generationID: "no-op", records: []))

    let result = await SyncCoordinator(transport: transport, repository: repository).sendPending(role: .mac)
    guard case let .success(outcome) = result else {
        Issue.record("expected eligible pending change to send")
        return
    }
    #expect(outcome.acknowledgedRecordIDs == [eligible.id])
    let state = await repository.state()
    #expect(state.pendingChanges == [conflictedChange])
    #expect(state.conflictedRecordIDs == [conflicted.id])
}

@Test("chunk publications are acknowledged before their ready records become sendable")
func coordinatorPublishesChunksBeforeReadyPointers() async throws {
    let changes = try chunkPublicationChanges()
    let repository = FakeSyncRepository(state: SyncRepositoryState(pendingChanges: changes))
    let transport = FakeSyncTransport(batch: try SyncFetchBatch(generationID: "no-op", records: []))

    let result = await SyncCoordinator(transport: transport, repository: repository).sendPending(role: .mac)
    guard case let .success(outcome) = result else {
        Issue.record("expected two-phase publication to complete")
        return
    }

    let batches = await transport.savedBatches
    #expect(batches.count == 2)
    #expect(!batches[0].isEmpty)
    #expect(batches[0].allSatisfy { $0.recordType == .revisionChunk })
    #expect(batches[1].allSatisfy { $0.recordType != .revisionChunk })
    #expect(Set(batches[1].map(\.recordType)) == Set([.item, .revision]))
    #expect(outcome.failures.isEmpty)
    #expect((await repository.state()).pendingChanges.isEmpty)
}

@Test("a partial chunk upload withholds the manifest and item pointer")
func coordinatorWithholdsReadyPointersAfterChunkFailure() async throws {
    let changes = try chunkPublicationChanges()
    let failedChunk = try #require(changes.first { $0.recordID.recordType == .revisionChunk })
    let partial = try SyncSendResult(
        engineState: Data([9]),
        failures: [SyncSendFailure(recordID: failedChunk.recordID, disposition: .retryable)]
    )
    let repository = FakeSyncRepository(state: SyncRepositoryState(pendingChanges: changes))
    let transport = FakeSyncTransport(batch: try SyncFetchBatch(generationID: "no-op", records: []),
                                      sendResult: partial)

    let result = await SyncCoordinator(transport: transport, repository: repository).sendPending(role: .mac)
    guard case let .success(outcome) = result else {
        Issue.record("partial send should remain retryable state")
        return
    }

    let batches = await transport.savedBatches
    #expect(batches.count == 1)
    #expect(batches[0].allSatisfy { $0.recordType == .revisionChunk })
    #expect(outcome.failures.map(\.recordID) == [failedChunk.recordID])
    let pending = await repository.state().pendingChanges
    #expect(pending.contains { $0.recordID.recordType == .revision })
    #expect(pending.contains { $0.recordID.recordType == .item })
}

@Test("a conflicted chunk withholds ready records even when sibling chunks upload")
func coordinatorWithholdsReadyPointersForMixedChunkConflict() async throws {
    let changes = try chunkPublicationChanges()
    let blockedChunk = try #require(changes.first { $0.recordID.recordType == .revisionChunk })
    let repository = FakeSyncRepository(state: SyncRepositoryState(
        pendingChanges: changes,
        conflictedRecordIDs: [blockedChunk.recordID]
    ))
    let transport = FakeSyncTransport(batch: try SyncFetchBatch(generationID: "no-op", records: []))

    let result = await SyncCoordinator(transport: transport, repository: repository).sendPending(role: .mac)
    guard case let .failure(error) = result else {
        Issue.record("a blocked chunk must prevent ready publication")
        return
    }

    #expect(error as? WiltedSyncError == .transport(
        "chunk publication incomplete; ready records were withheld"
    ))
    let batches = await transport.savedBatches
    #expect(batches.count == 1)
    #expect(batches[0].allSatisfy { $0.recordType == .revisionChunk })
    let pending = await repository.state().pendingChanges
    #expect(pending.contains { $0.recordID.recordType == .revision })
    #expect(pending.contains { $0.recordID.recordType == .item })
    #expect(pending.contains { $0.recordID == blockedChunk.recordID })
}

@Test("an unreported chunk outcome withholds ready records")
func coordinatorWithholdsReadyPointersForOmittedChunkOutcome() async throws {
    let changes = try chunkPublicationChanges()
    let firstChunk = try #require(changes.first { $0.recordID.recordType == .revisionChunk })
    let omitted = try SyncSendResult(engineState: Data([9]),
                                     acknowledgedRecordIDs: [firstChunk.recordID])
    let repository = FakeSyncRepository(state: SyncRepositoryState(pendingChanges: changes))
    let transport = FakeSyncTransport(batch: try SyncFetchBatch(generationID: "no-op", records: []),
                                      sendResult: omitted)

    let result = await SyncCoordinator(transport: transport, repository: repository).sendPending(role: .mac)
    guard case let .failure(error) = result else {
        Issue.record("an omitted chunk outcome must prevent ready publication")
        return
    }

    #expect(error as? WiltedSyncError == .transport(
        "chunk publication incomplete; ready records were withheld"
    ))
    let batches = await transport.savedBatches
    #expect(batches.count == 1)
    #expect(batches[0].allSatisfy { $0.recordType == .revisionChunk })
    let pending = await repository.state().pendingChanges
    #expect(pending.contains { $0.recordID.recordType == .revision })
    #expect(pending.contains { $0.recordID.recordType == .item })
    #expect(pending.contains { $0.recordID.recordType == .revisionChunk })
}

@Test("a fully conflicted queue reports a blocked send instead of a clean upload")
func coordinatorReportsBlockedSendWhenEveryChangeIsConflicted() async throws {
    let (article, revisionID, _) = try fixtureArticle()
    let record = try WiltedRecordCodec().encode(article: article, currentRevisionID: revisionID)
    let change = try SyncPendingChange(operation: .update, recordID: record.id, record: record)
    let initial = SyncRepositoryState(records: [record], engineState: Data([1]),
                                      pendingChanges: [change], conflictedRecordIDs: [record.id])
    let repository = FakeSyncRepository(state: initial)
    let transport = FakeSyncTransport(batch: try SyncFetchBatch(generationID: "no-op", records: []))

    let result = await SyncCoordinator(transport: transport, repository: repository).sendPending(role: .mac)
    guard case let .failure(error) = result else {
        Issue.record("a send that moved nothing must not report success")
        return
    }
    #expect(error as? WiltedSyncError == .sendBlockedByConflicts(count: 1, accountReviewRequired: true))
    // Nothing was eligible, so the service is never contacted and state is untouched.
    let saveCalls = await transport.saveCalls
    #expect(saveCalls == 0)
    #expect(await repository.state() == initial)
}

@Test("commit failure leaves staged state untouched and restart preserves deletes")
func commitFailureAndRestartPreserveState() async throws {
    let (article, revisionID, _) = try fixtureArticle()
    let record = try WiltedRecordCodec().encode(article: article, currentRevisionID: revisionID)
    let tombstone = SyncTombstone(itemID: article.itemID, generationID: "delete-generation",
                                  requestedAt: try Timestamp(iso8601: "2026-08-17T12:07:00Z"))
    let deletion = try SyncPendingChange(operation: .delete, recordID: record.id, tombstone: tombstone)
    let initial = SyncRepositoryState(records: [record], engineState: Data([4, 5]), pendingChanges: [deletion], tombstones: [tombstone])
    let batch = try SyncFetchBatch(generationID: "generation-2", records: [], engineState: Data([9]), kind: .fullSnapshot)
    let repository = FakeSyncRepository(state: initial, commitFailure: .injectedFailure("commit"))
    let result = await SyncCoordinator(transport: FakeSyncTransport(batch: batch), repository: repository).synchronize()
    guard case .failure = result else { Issue.record("expected commit failure"); return }
    #expect(await repository.state() == initial)
    let restarted = FakeSyncRepository(state: await repository.state())
    #expect(await restarted.state() == initial)
}

@Test("incremental fetch retains absent records while full snapshot replaces atomically")
func incrementalAndFullFetchSemantics() async throws {
    let (article, revisionID, _) = try fixtureArticle()
    let record = try WiltedRecordCodec().encode(article: article, currentRevisionID: revisionID)
    var otherFields = record.fields; otherFields["itemID"] = .string("item-other")
    let other = try WiltedRecordEnvelope(id: try .item(try ItemID(rawValue: "item-other")), fields: otherFields)
    var localFields = record.fields; localFields["itemID"] = .string("item-local")
    let local = try WiltedRecordEnvelope(id: try .item(try ItemID(rawValue: "item-local")), fields: localFields)
    var protectedFields = record.fields; protectedFields["itemID"] = .string("item-protected")
    let protected = try WiltedRecordEnvelope(id: try .item(try ItemID(rawValue: "item-protected")), fields: protectedFields)
    let localPending = try SyncPendingChange(operation: .create, recordID: local.id, record: local)
    let initial = SyncRepositoryState(records: [record, other, local, protected], engineState: Data([1]), pendingChanges: [localPending],
                                      remoteAcknowledgedRecordIDs: [record.id, other.id, local.id, protected.id], protectedRecordIDs: [protected.id])
    let repository = FakeSyncRepository(state: initial)
    let incremental = try SyncFetchBatch(generationID: "incremental", records: [record], engineState: Data([2]), kind: .incremental)
    let incrementalStaged = try await repository.stage(incremental)
    try await repository.commit(incrementalStaged)
    #expect((await repository.state()).records.count == 4)
    var updatedFields = record.fields; updatedFields["title"] = .string("Updated")
    let updated = try WiltedRecordEnvelope(id: record.id, fields: updatedFields)
    let newRecord = try WiltedRecordEnvelope(id: try .item(try ItemID(rawValue: "item-new")), fields: localFields)
    let full = try SyncFetchBatch(generationID: "full", records: [updated, newRecord], engineState: Data([3]), kind: .fullSnapshot)
    let staged = try await repository.stage(full)
    try await repository.commit(staged)
    #expect(Set((await repository.state()).records.map(\.id)) == Set([record.id, newRecord.id, local.id, protected.id]))
    #expect((await repository.state()).records.first(where: { $0.id == record.id })?.fields["title"] == .string("Updated"))
    #expect((await repository.state()).tombstones.isEmpty)
}

@Test("fake delay emits visible status before completion")
func fakeDelayStatusLiveness() async throws {
    let batch = try SyncFetchBatch(generationID: "delayed", records: [], engineState: Data([1]))
    let transport = FakeSyncTransport(batch: batch, delayNanoseconds: 50_000_000)
    let repository = FakeSyncRepository()
    let coordinator = SyncCoordinator(transport: transport, repository: repository)
    let run = Task { await coordinator.synchronize() }
    let first = await coordinator.statuses.first { $0.phase == .fetching }
    #expect(first != nil)
    _ = await run.value
}

@Test("partial send acknowledgement updates sidecars, deletes tombstones, and retains failures")
func partialSendAcknowledgement() async throws {
    let (article, revisionID, _) = try fixtureArticle()
    let codec = WiltedRecordCodec()
    let item = try codec.encode(article: article, currentRevisionID: revisionID)
    let otherItemID = try ItemID(rawValue: "item-other")
    let otherID = try WiltedRecordID.item(otherItemID)
    let other = try WiltedRecordEnvelope(id: otherID, fields: item.fields)
    let playbackID = try WiltedRecordID.playback(article.itemID, revisionID)
    let playback = try WiltedRecordEnvelope(id: playbackID, fields: item.fields)
    let conflictID = try WiltedRecordID.revision(article.itemID, revisionID)
    let conflict = try WiltedRecordEnvelope(id: conflictID, fields: item.fields)
    let itemChange = try SyncPendingChange(operation: .update, recordID: item.id, record: item)
    let deleteTombstone = SyncTombstone(itemID: otherItemID, generationID: "g", requestedAt: try Timestamp(iso8601: "2026-08-17T12:09:00Z"))
    let deleteChange = try SyncPendingChange(operation: .delete, recordID: otherID, tombstone: deleteTombstone)
    let retryChange = try SyncPendingChange(operation: .update, recordID: playbackID, record: playback)
    let conflictChange = try SyncPendingChange(operation: .update, recordID: conflictID, record: conflict)
    let serverItem = try WiltedRecordEnvelope(id: item.id, fields: item.fields.merging(["title": .string("Server")]) { _, incoming in incoming })
    let serverConflict = try WiltedRecordEnvelope(id: conflictID, fields: conflict.fields.merging(["title": .string("Remote")]) { _, incoming in incoming })
    let itemTombstone = SyncTombstone(itemID: article.itemID, generationID: "item-delete", requestedAt: try Timestamp(iso8601: "2026-08-17T12:09:01Z"))
    let result = try SyncSendResult(engineState: Data([8, 8]), acknowledgedRecordIDs: [item.id, otherID], serverEnvelopes: [serverItem], failures: [
        SyncSendFailure(recordID: playbackID, disposition: .retryable),
        SyncSendFailure(recordID: conflictID, disposition: .conflict, serverRecord: serverConflict),
    ])
    let initial = SyncRepositoryState(records: [item, other, playback, conflict], pendingChanges: [itemChange, deleteChange, retryChange, conflictChange], tombstones: [deleteTombstone, itemTombstone])
    let repository = FakeSyncRepository(state: initial)
    try await repository.acknowledge(result)
    let state = await repository.state()
    #expect(state.pendingChanges.map(\.recordID) == [playbackID, conflictID])
    #expect(state.tombstones.count == 2)
    #expect(state.tombstones.first(where: { $0.itemID == otherItemID })?.remoteAcknowledged == true)
    #expect(state.tombstones.first(where: { $0.itemID == article.itemID })?.remoteAcknowledged == false)
    #expect(state.records.first(where: { $0.id == item.id })?.fields["title"] == .string("Server"))
    #expect(state.conflictedRecordIDs == Set([conflictID]))
    #expect(state.conflictServerRecords[conflictID] == serverConflict)
    #expect(state.records.first(where: { $0.id == conflictID })?.fields["title"] == item.fields["title"])
    let reopened = try JSONDecoder().decode(SyncRepositoryState.self, from: JSONEncoder().encode(state))
    #expect(reopened == state)
    #expect(state.engineState == Data([8, 8]))
    do {
        try await repository.acknowledge(try SyncSendResult(engineState: Data([9]), acknowledgedRecordIDs: [try .item(try ItemID(rawValue: "item-unknown"))]))
        Issue.record("expected unknown acknowledgement rejection")
    } catch let error as WiltedSyncError {
        #expect(error == .invalidValue(field: "acknowledgement"))
    }
    #expect((await repository.state()).engineState == Data([8, 8]))
    #expect(throws: WiltedSyncError.invalidValue(field: "engineState")) {
        try SyncSendResult(engineState: Data())
    }
}

@Test("internal record IDs cannot bypass validation and pending delete shape is strict")
func internalIdentityAndPendingShape() throws {
    let invalid = #"{"recordType":"WiltedItem","recordName":"bad name","zoneName":"WiltedZone"}"#.data(using: .utf8)!
    #expect(throws: WiltedSyncError.invalidRecordName("bad name")) {
        try JSONDecoder().decode(WiltedRecordID.self, from: invalid)
    }
    let wrongPrefix = #"{"recordType":"WiltedRevision","recordName":"item:item-x","zoneName":"WiltedZone"}"#.data(using: .utf8)!
    #expect(throws: WiltedSyncError.invalidRecordIdentity) {
        try JSONDecoder().decode(WiltedRecordID.self, from: wrongPrefix)
    }
    let (article, revisionID, _) = try fixtureArticle()
    let record = try WiltedRecordCodec().encode(article: article, currentRevisionID: revisionID)
    let tombstone = SyncTombstone(itemID: article.itemID, generationID: "g", requestedAt: try Timestamp(iso8601: "2026-08-17T12:08:00Z"))
    #expect(throws: WiltedSyncError.invalidValue(field: "delete shape")) {
        try SyncPendingChange(operation: .delete, recordID: record.id, record: record, tombstone: tombstone)
    }
    #expect(throws: WiltedSyncError.invalidRecordIdentity) {
        try SyncPendingChange(operation: .delete, recordID: record.id, tombstone: SyncTombstone(itemID: try ItemID(rawValue: "item-other"), generationID: "g", requestedAt: try Timestamp(iso8601: "2026-08-17T12:08:00Z")))
    }
}

@Test("remote deletions apply incrementally, cascade items, and preserve protected work")
func remoteDeletionSemantics() async throws {
    let (article, revisionID, asset) = try fixtureArticle()
    let codec = WiltedRecordCodec()
    let revision = try AudioRevision(itemID: article.itemID, revisionID: revisionID, durationSeconds: 420,
                                     byteCount: 100, contentHash: asset.contentHash, mediaType: "audio/mp4",
                                     createdAt: article.createdAt, schemaVersion: 1)
    let playback = try PlaybackState(itemID: article.itemID, revisionID: revisionID, sessionID: "s1", sequence: 1,
                                     positionSeconds: 0, durationSeconds: 420, completed: false, intent: .progress,
                                     deviceID: "d1", updatedAt: article.createdAt)
    let itemRecord = try codec.encode(article: article, currentRevisionID: revisionID)
    let revisionRecord = try codec.encode(revision: revision, audioAsset: asset)
    let playbackRecord = try codec.encode(playback: playback)
    let all = [itemRecord, revisionRecord, playbackRecord]
    let itemBatch = try SyncFetchBatch(generationID: "delete-item", records: [], engineState: Data([1]), kind: .fullSnapshot, deletedRecordIDs: [itemRecord.id])
    let itemRepository = FakeSyncRepository(state: SyncRepositoryState(records: all, remoteAcknowledgedRecordIDs: Set(all.map(\.id))))
    try await itemRepository.commit(try await itemRepository.stage(itemBatch))
    #expect((await itemRepository.state()).records.isEmpty)

    let revisionBatch = try SyncFetchBatch(generationID: "delete-revision", records: [], engineState: Data([2]), deletedRecordIDs: [revisionRecord.id])
    let revisionRepository = FakeSyncRepository(state: SyncRepositoryState(records: all, remoteAcknowledgedRecordIDs: Set(all.map(\.id))))
    try await revisionRepository.commit(try await revisionRepository.stage(revisionBatch))
    #expect(Set((await revisionRepository.state()).records.map(\.id)) == Set([itemRecord.id, playbackRecord.id]))

    let protected = SyncRepositoryState(records: [itemRecord], protectedRecordIDs: [itemRecord.id])
    let protectedRepository = FakeSyncRepository(state: protected)
    try await protectedRepository.commit(try await protectedRepository.stage(itemBatch))
    let protectedState = await protectedRepository.state()
    #expect(protectedState.records == [itemRecord])
    #expect(protectedState.conflictedRecordIDs == Set([itemRecord.id]))

    let protectedRevision = SyncRepositoryState(records: all, remoteAcknowledgedRecordIDs: Set(all.map(\.id)),
                                                protectedRecordIDs: [revisionRecord.id])
    let familyRepository = FakeSyncRepository(state: protectedRevision)
    try await familyRepository.commit(try await familyRepository.stage(itemBatch))
    let familyState = await familyRepository.state()
    #expect(Set(familyState.records.map { $0.id }) == Set(all.map { $0.id }))
    #expect(familyState.conflictedRecordIDs == Set(all.map { $0.id }))

    #expect(throws: WiltedSyncError.invalidValue(field: "deletedRecordIDs")) {
        _ = try SyncFetchBatch(generationID: "collision", records: [itemRecord], engineState: Data(), deletedRecordIDs: [itemRecord.id])
    }
    #expect(throws: WiltedSyncError.invalidValue(field: "deletedRecordIDs")) {
        _ = try SyncFetchBatch(generationID: "duplicate", records: [], engineState: Data(), deletedRecordIDs: [itemRecord.id, itemRecord.id])
    }
    let reopened = try JSONDecoder().decode(SyncRepositoryState.self, from: JSONEncoder().encode(protectedState))
    #expect(reopened == protectedState)
}
