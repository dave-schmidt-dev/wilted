import CryptoKit
import Foundation
import Testing
import WiltedDomain
import WiltedListener
import WiltedSync

private func ids() throws -> (ItemID, RevisionID) {
    let url = URL(string: "https://example.test/listener")!
    return (try ItemID.derive(from: url), try RevisionID(rawValue: "rev-listener"))
}

private func itemEnvelope() throws -> WiltedRecordEnvelope {
    let url = URL(string: "https://example.test/listener")!
    let item = try ItemID.derive(from: url)
    let article = try Article(itemID: item, canonicalURL: url, title: "Listener", source: "Test", createdAt: Timestamp(Date()))
    return try WiltedRecordCodec().encode(article: article, currentRevisionID: RevisionID(rawValue: "rev-listener"))
}

private func playbackState(sequence: Int64 = 1, intent: PlaybackIntent = .progress, position: Double = 5, sessionID: String = "session-a") throws -> PlaybackState {
    let (item, revision) = try ids()
    return try PlaybackState(itemID: item, revisionID: revision, sessionID: sessionID, sequence: sequence,
                             positionSeconds: position, durationSeconds: 30, completed: false, intent: intent,
                             deviceID: "iphone", updatedAt: Timestamp(Date()))
}

private func playbackEnvelope(_ state: PlaybackState) throws -> WiltedRecordEnvelope { try WiltedRecordCodec().encode(playback: state) }

private func revisionChunkEnvelope() throws -> WiltedRecordEnvelope {
    let (item, revision) = try ids()
    let chunk = try WiltedRecordID.revisionChunk(item, revision, index: 0)
    return try WiltedRecordEnvelope(id: chunk, fields: [
        "schemaVersion": .int64(1),
        "chunkIndex": .int64(0),
        "asset": .asset(try asset(Data("chunk".utf8)))
    ])
}

private func asset(_ data: Data) throws -> WiltedAsset {
    let hash = "sha256:" + SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    return try WiltedAsset(assetID: "revision-audio", contentHash: hash)
}

private final class MemoryEngine: ListenerAudioEngine, @unchecked Sendable {
    var duration: Double = 30
    var currentTime = 0.0
    var loadedURL: URL?
    var playing = false
    var isPlaying: Bool { playing }
    func load(url: URL) throws { loadedURL = url }
    func play() -> Bool { playing = true; return true }
    func pause() { playing = false }
}

private struct TestSession: ListenerAudioSession {
    let onActivate: @Sendable () -> Void
    func activate() throws { onActivate() }
    func deactivate() {}
}

private final class TestNowPlaying: ListenerNowPlaying, @unchecked Sendable {
    var updates = 0
    func update(title: String, duration: Double, position: Double, rate: Double) { updates += 1 }
    func clear() {}
}

private final class TestRemoteCommands: ListenerRemoteCommands, @unchecked Sendable {
    var handler: (@Sendable (ListenerRemoteCommand) async -> Void)?
    func install(handler: @escaping @Sendable (ListenerRemoteCommand) async -> Void) { self.handler = handler }
    func send(_ command: ListenerRemoteCommand) async { await handler?(command) }
}

@Test("repository commits a batch and reloads durable state")
func repositoryCommitAndRelaunch() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let repository = try ListenerRepository(directoryURL: directory)
    let envelope = try itemEnvelope()
    let batch = try SyncFetchBatch(generationID: "g1", records: [envelope], engineState: Data([1]))
    let staged = try await repository.stage(batch)
    try await repository.commit(staged)
    let reopened = try ListenerRepository(directoryURL: directory)
    #expect((await reopened.state()).records.first?.id == envelope.id)
    #expect((await reopened.state()).engineState == Data([1]))
}

@Test("revision chunk records remain transport-only")
func revisionChunksDoNotEnterListenerState() async throws {
    let repository = try ListenerRepository(directoryURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
    let article = try itemEnvelope()
    let chunk = try revisionChunkEnvelope()
    let batch = try SyncFetchBatch(generationID: "chunk-g1", records: [article, chunk], engineState: Data([1]))

    try await repository.commit(try await repository.stage(batch))

    let state = await repository.state()
    #expect(state.records.map(\.id) == [article.id])
    #expect(state.remoteAcknowledgedRecordIDs == [article.id])
}

@Test("optional engine state preserves prior state for no-op batches")
func optionalEngineStatePreservation() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let repository = try ListenerRepository(directoryURL: directory)
    let envelope = try itemEnvelope()
    let initial = try SyncFetchBatch(generationID: "g1", records: [envelope], engineState: Data([1]))
    try await repository.commit(try await repository.stage(initial))
    let noop = try SyncFetchBatch(generationID: "g2", records: [], engineState: nil)
    try await repository.commit(try await repository.stage(noop))
    #expect((await repository.state()).engineState == Data([1]))
    #expect(throws: WiltedSyncError.invalidValue(field: "engineState")) {
        try SyncFetchBatch(generationID: "g3", records: [envelope], engineState: nil)
    }
}

@Test("full snapshot removes only previously remote-acknowledged absence")
func fullSnapshotAbsenceDeletion() async throws {
    let repository = try ListenerRepository(directoryURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
    let envelope = try itemEnvelope()
    let incremental = try SyncFetchBatch(generationID: "g1", records: [envelope], engineState: Data([1]))
    try await repository.commit(try await repository.stage(incremental))
    #expect((await repository.state()).remoteAcknowledgedRecordIDs.contains(envelope.id))
    let snapshot = try SyncFetchBatch(generationID: "g2", records: [], engineState: Data([2]), kind: .fullSnapshot)
    try await repository.commit(try await repository.stage(snapshot))
    #expect((await repository.state()).records.isEmpty)
    #expect((await repository.state()).remoteAcknowledgedRecordIDs.contains(envelope.id))
}

@Test("full snapshot keeps an entire family when one member is protected")
func fullSnapshotFamilyProtection() async throws {
    let repository = try ListenerRepository(directoryURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
    let item = try itemEnvelope()
    let playback = try playbackEnvelope(try playbackState())
    try await repository.commit(try await repository.stage(try SyncFetchBatch(generationID: "g1", records: [item, playback], engineState: Data([1]))))
    let change = try SyncPendingChange(operation: .update, recordID: playback.id, record: playback)
    try await repository.enqueue(change)
    let snapshot = try SyncFetchBatch(generationID: "g2", records: [], engineState: Data([2]), kind: .fullSnapshot)
    try await repository.commit(try await repository.stage(snapshot))
    #expect(Set((await repository.state()).records.map(\.id)) == Set([item.id, playback.id]))
}

@Test("repository applies remote deletion and quarantines pending playback")
func repositoryDeletionAndPending() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let repository = try ListenerRepository(directoryURL: directory)
    let envelope = try itemEnvelope()
    try await repository.commit(try await repository.stage(try SyncFetchBatch(generationID: "g1", records: [envelope], engineState: Data([1]))))
    let state = try playbackState()
    let change = try SyncPendingChange(operation: .update, recordID: try WiltedRecordID.playback(state.itemID, state.revisionID), record: try playbackEnvelope(state))
    try await repository.enqueue(change)
    let deleted = try SyncFetchBatch(generationID: "g2", records: [], engineState: Data([2]), deletedRecordIDs: [envelope.id])
    try await repository.commit(try await repository.stage(deleted))
    let final = await repository.state()
    #expect(final.records.isEmpty)
    #expect(final.pendingChanges.isEmpty)
    #expect(final.conflictedRecordIDs.contains(change.recordID))
    #expect(final.remoteAcknowledgedRecordIDs.contains(envelope.id))
}

@Test("item deletion cascades its playback family")
func itemDeletionCascadesFamily() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let repository = try ListenerRepository(directoryURL: directory)
    let item = try itemEnvelope()
    let playback = try playbackEnvelope(try playbackState())
    let batch = try SyncFetchBatch(generationID: "g1", records: [item, playback], engineState: Data([1]))
    try await repository.commit(try await repository.stage(batch))
    let deletion = try SyncFetchBatch(generationID: "g2", records: [], engineState: Data([2]), deletedRecordIDs: [item.id])
    try await repository.commit(try await repository.stage(deletion))
    let state = await repository.state()
    #expect(state.records.isEmpty)
    #expect(state.remoteAcknowledgedRecordIDs.contains(item.id))
    #expect(state.remoteAcknowledgedRecordIDs.contains(playback.id))
}

@Test("malformed optional metadata is ignored while durable state remains usable")
func malformedOptionalMetadata() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let repository = try ListenerRepository(directoryURL: directory)
    try Data("not-json".utf8).write(to: directory.appendingPathComponent("listener-metadata.json"))
    #expect(await repository.loadMetadata() == nil)
    #expect((await repository.state()).records.isEmpty)
}

@Test("acknowledgement rejects unknown IDs and preserves retry work")
func acknowledgementValidation() async throws {
    let repository = try ListenerRepository(directoryURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
    let state = try playbackState()
    let id = try WiltedRecordID.playback(state.itemID, state.revisionID)
    let change = try SyncPendingChange(operation: .update, recordID: id, record: try playbackEnvelope(state))
    try await repository.enqueue(change)
    #expect((await repository.state()).records.contains(where: { $0.id == change.recordID }))
    #expect((await repository.state()).protectedRecordIDs.contains(change.recordID))
    let unknown = try WiltedRecordID.item(try ids().0)
    let invalid = try SyncSendResult(engineState: Data([1]), acknowledgedRecordIDs: [unknown])
    do { try await repository.acknowledge(invalid); Issue.record("expected unknown acknowledgement rejection") }
    catch let error as WiltedSyncError { #expect(error == .invalidValue(field: "acknowledgement IDs")) }
    let retry = try SyncSendResult(engineState: Data([2]), failures: [SyncSendFailure(recordID: id, disposition: .retryable)])
    try await repository.acknowledge(retry)
    #expect((await repository.state()).pendingChanges == [change])
}

@Test("saved acknowledgement requires matching server envelope and clears protection")
func savedAcknowledgementValidation() async throws {
    let repository = try ListenerRepository(directoryURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
    let state = try playbackState()
    let id = try WiltedRecordID.playback(state.itemID, state.revisionID)
    let local = try playbackEnvelope(state)
    try await repository.enqueue(try SyncPendingChange(operation: .update, recordID: id, record: local))
    let missing = try SyncSendResult(engineState: Data([1]), acknowledgedRecordIDs: [id])
    do { try await repository.acknowledge(missing); Issue.record("expected server envelope requirement") }
    catch let error as WiltedSyncError { #expect(error == .invalidValue(field: "acknowledgement server envelope")) }
    let server = try WiltedRecordEnvelope(id: local.id, schemaVersion: local.schemaVersion, fields: local.fields,
                                          sidecar: WiltedOpaqueSidecar(changeTag: "tag-1", encodedSystemFields: Data([9])))
    let valid = try SyncSendResult(engineState: Data([2]), acknowledgedRecordIDs: [id], serverEnvelopes: [server])
    try await repository.acknowledge(valid)
    let final = await repository.state()
    #expect(final.pendingChanges.isEmpty)
    #expect(!final.protectedRecordIDs.contains(id))
    #expect(final.records.first?.sidecar?.changeTag == "tag-1")
}

@Test("account change quarantines pending work across relaunch")
func accountChangeQuarantine() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let repository = try ListenerRepository(directoryURL: directory)
    let state = try playbackState()
    let id = try WiltedRecordID.playback(state.itemID, state.revisionID)
    let change = try SyncPendingChange(operation: .update, recordID: id, record: try playbackEnvelope(state))
    try await repository.enqueue(change)
    try await repository.quarantineAfterAccountChange()
    let reopened = try ListenerRepository(directoryURL: directory)
    let final = await reopened.state()
    #expect(final.pendingChanges.isEmpty)
    #expect(final.engineState == nil)
    #expect(final.conflictedRecordIDs.contains(id))
    #expect(final.records.contains(where: { $0.id == id }))
}

@Test("tombstones survive relaunch until remote deletion acknowledges them")
func tombstoneDurability() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let repository = try ListenerRepository(directoryURL: directory)
    let (item, _) = try ids()
    let tombstone = SyncTombstone(itemID: item, generationID: "local-delete", requestedAt: Timestamp(Date()))
    try await repository.retainTombstone(tombstone)
    let reopened = try ListenerRepository(directoryURL: directory)
    #expect((await reopened.state()).tombstones.first?.itemID == tombstone.itemID)
    #expect((await reopened.state()).tombstones.first?.remoteAcknowledged == false)
    let deleted = try SyncFetchBatch(generationID: "remote-delete", records: [], engineState: Data([3]), deletedRecordIDs: [try WiltedRecordID.item(item)])
    try await reopened.commit(try await reopened.stage(deleted))
    #expect((await reopened.state()).tombstones.first?.remoteAcknowledged == true)
}

@Test("audio cache validates bytes and preserves a valid prior entry")
func cacheValidationAndPreservation() async throws {
    let cache = try ListenerAudioCache(rootURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
    let good = Data("good-audio".utf8)
    let goodAsset = try asset(good)
    let url = try await cache.store(data: good, asset: goodAsset)
    #expect(await cache.url(for: goodAsset) == url)
    let reopened = try ListenerAudioCache(rootURL: url.deletingLastPathComponent())
    #expect(await reopened.url(for: goodAsset) == url)
    let bad = try WiltedAsset(assetID: "revision-audio", contentHash: "sha256:" + String(repeating: "b", count: 64))
    do { _ = try await cache.store(data: Data("bad".utf8), asset: bad); Issue.record("expected hash failure") }
    catch let error as ListenerError { #expect(error == .cacheHashMismatch("revision-audio")) }
    #expect(await cache.url(for: goodAsset) == url)
}

@Test("offline playback supports resume, rewind, restart, interruption, and route changes")
func offlinePlaybackControls() async throws {
    let bytes = Data("audio".utf8)
    let cache = try ListenerAudioCache(rootURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
    let audio = try asset(bytes)
    _ = try await cache.store(data: bytes, asset: audio)
    let engine = MemoryEngine()
    let nowPlaying = TestNowPlaying()
    let controller = ListenerPlaybackController(cache: cache, engine: engine, nowPlaying: nowPlaying)
    let initial = try playbackState(position: 10)
    let resumed = try await controller.play(asset: audio, title: "Offline", state: initial)
    #expect(resumed.positionSeconds == 10)
    let rewind = try await controller.play(asset: audio, title: "Offline", state: try playbackState(sequence: 2, intent: .rewind, position: 10))
    #expect(rewind.positionSeconds == 10)
    let restart = try await controller.play(asset: audio, title: "Offline", state: try playbackState(sequence: 3, intent: .restart, position: 10))
    #expect(restart.positionSeconds == 0)
    try await controller.handle(interruptionBegan: true)
    await controller.handleRouteChange()
    #expect(nowPlaying.updates >= 3)
}

@Test("playback merge accepts explicit restart and rejects stale progress")
func playbackConflictState() async throws {
    let bytes = Data("audio".utf8)
    let cache = try ListenerAudioCache(rootURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
    let audio = try asset(bytes)
    _ = try await cache.store(data: bytes, asset: audio)
    let controller = ListenerPlaybackController(cache: cache, engine: MemoryEngine())
    let current = try playbackState(sequence: 2, position: 10)
    _ = try await controller.play(asset: audio, title: "Offline", state: current)
    let stale = try playbackState(sequence: 1, position: 20)
    #expect(await controller.applyRemote(stale, changeTagMatches: true).decision == .reject)
    let restart = try playbackState(sequence: 1, intent: .restart, position: 0, sessionID: "session-b")
    #expect(await controller.applyRemote(restart, changeTagMatches: true).decision == .accept)
}

@Test("background publishing and remote commands remain injected and testable")
func backgroundAndRemoteCommands() async throws {
    let bytes = Data("audio".utf8)
    let cache = try ListenerAudioCache(rootURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
    let audio = try asset(bytes)
    _ = try await cache.store(data: bytes, asset: audio)
    let engine = MemoryEngine()
    let nowPlaying = TestNowPlaying()
    let remote = TestRemoteCommands()
    let controller = ListenerPlaybackController(cache: cache, engine: engine, nowPlaying: nowPlaying)
    await controller.install(remoteCommands: remote)
    _ = try await controller.play(asset: audio, title: "Remote", state: try playbackState())
    engine.currentTime = 12
    let backgrounded = try await controller.enterBackground()
    let started = await controller.current()
    #expect(started?.sequence == 3)
    #expect(backgrounded?.positionSeconds == 12)
    await remote.send(.pause)
    #expect((await controller.current())?.intent == .progress)
    #expect((await controller.current())?.sequence == 4)
    await remote.send(.play)
    #expect((await controller.current())?.sequence == 5)
    await remote.send(.rewind)
    let rewound = await controller.current()
    #expect(rewound?.intent == .rewind)
    #expect(rewound?.sequence == 6)
    #expect(rewound?.sessionID == "remote-6")
    await remote.send(.restart)
    let restarted = await controller.current()
    #expect(restarted?.intent == .restart)
    #expect(restarted?.sequence == 7)
    #expect(restarted?.sessionID == "remote-7")
    #expect(engine.playing == true)
    #expect(nowPlaying.updates >= 6)
    await controller.cancel()
}

@Test("live readout follows the active engine without changing durable sequence")
func liveReadoutFollowsEngine() async throws {
    let bytes = Data("audio".utf8)
    let cache = try ListenerAudioCache(rootURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
    let audio = try asset(bytes)
    _ = try await cache.store(data: bytes, asset: audio)
    let engine = MemoryEngine()
    let controller = ListenerPlaybackController(cache: cache, engine: engine)
    _ = try await controller.play(asset: audio, title: "Readout", state: try playbackState(position: 2))

    engine.currentTime = 9
    let readout = try await controller.liveReadout()

    #expect(readout?.positionSeconds == 9)
    #expect(readout?.sequence == 2)
    #expect((await controller.current())?.positionSeconds == 2)
}
