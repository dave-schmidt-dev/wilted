import CryptoKit
import Foundation
import Testing
import WiltedDomain
@testable import WiltedListener
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

private func playbackEnvelope(
    _ state: PlaybackState,
    sidecar: WiltedOpaqueSidecar? = nil,
    marker: String? = nil
) throws -> WiltedRecordEnvelope {
    try WiltedRecordCodec().encode(
        playback: state,
        sidecar: sidecar,
        opaqueFields: marker.map { ["mergeMarker": .string($0)] } ?? [:]
    )
}

private func transcriptEnvelope() throws -> WiltedRecordEnvelope {
    let (item, revision) = try ids()
    let transcript = try Transcript(
        itemID: item,
        revisionID: revision,
        availability: .available,
        text: "Listener transcript",
        format: .plainText,
        languageCode: "en",
        updatedAt: Timestamp(Date())
    )
    return try WiltedRecordCodec().encode(transcript: transcript)
}

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
    var allowsPlay = true
    var loadCallCount = 0
    var playCallCount = 0
    var completionGeneration: UInt64 = 0
    var completionHandler: (@Sendable (UInt64) -> Void)?
    var isPlaying: Bool { playing }
    func load(url: URL) throws { loadCallCount += 1; loadedURL = url }
    func load(url: URL, completionGeneration: UInt64) throws {
        try load(url: url)
        self.completionGeneration = completionGeneration
    }
    func play() -> Bool { playCallCount += 1; playing = allowsPlay; return allowsPlay }
    func pause() { playing = false }
    func installCompletionHandler(_ handler: @escaping @Sendable (UInt64) -> Void) { completionHandler = handler }
    func finishNaturally() { playing = false; completionHandler?(completionGeneration) }
    func fireCompletion(generation: UInt64) { completionHandler?(generation) }
}

private struct TestSession: ListenerAudioSession {
    let onActivate: @Sendable () -> Void
    func activate() throws { onActivate() }
    func deactivate() {}
}

private final class TestNowPlaying: ListenerNowPlaying, @unchecked Sendable {
    var updates = 0
    var lastRate: Double?
    func update(title: String, duration: Double, position: Double, rate: Double) {
        updates += 1
        lastRate = rate
    }
    func clear() {}
}

private final class TestRemoteCommands: ListenerRemoteCommands, @unchecked Sendable {
    var handler: (@Sendable (ListenerRemoteCommand) async -> Void)?
    func install(handler: @escaping @Sendable (ListenerRemoteCommand) async -> Void) { self.handler = handler }
    func send(_ command: ListenerRemoteCommand) async { await handler?(command) }
}

private final class WeakReference<Object: AnyObject> {
    weak var object: Object?
    init(_ object: Object?) { self.object = object }
}

private actor OrderedRemoteRecorder {
    private var commands: [ListenerRemoteCommand] = []

    func receive(_ command: ListenerRemoteCommand) async {
        if command == .rewind { try? await Task.sleep(for: .milliseconds(20)) }
        commands.append(command)
    }

    func waitForCount(_ count: Int) async -> [ListenerRemoteCommand] {
        let clock = ContinuousClock()
        let deadline = clock.now + .seconds(2)
        while commands.count < count, clock.now < deadline {
            try? await Task.sleep(for: .milliseconds(2))
        }
        return commands
    }
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

@Test("a clean listener install accepts its first remote catalog batch")
func cleanInstallAcceptsFirstRemoteCatalogBatch() async throws {
    let repository = try ListenerRepository(
        directoryURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    )
    let remote = try itemEnvelope()

    try await repository.commit(try await repository.stage(
        try SyncFetchBatch(generationID: "first-install", records: [remote], engineState: Data([1]))
    ))

    let state = await repository.state()
    #expect(state.records == [remote])
    #expect(state.pendingChanges.isEmpty)
    #expect(state.protectedRecordIDs.isEmpty)
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

@Test("transcript records validate and enter listener state")
func transcriptRecordsEnterListenerState() async throws {
    let repository = try ListenerRepository(directoryURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
    let transcript = try transcriptEnvelope()
    let batch = try SyncFetchBatch(generationID: "transcript-g1", records: [transcript], engineState: Data([1]))

    try await repository.commit(try await repository.stage(batch))

    #expect((await repository.state()).records.map(\.id) == [transcript.id])
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

@Test("incoming catalog records remain protected and playback uses causal merge")
func protectedCatalogRecordsRemainLocalWhilePlaybackUpdates() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let item = try itemEnvelope()
    let transcript = try transcriptEnvelope()
    let (itemID, revisionID) = try ids()
    let revisionAsset = try asset(Data("revision".utf8))
    let revision = try AudioRevision(itemID: itemID, revisionID: revisionID, durationSeconds: 30,
                                     byteCount: 8, contentHash: revisionAsset.contentHash,
                                     mediaType: "audio/mpeg", createdAt: Timestamp(Date()), schemaVersion: 1)
    let codec = WiltedRecordCodec()
    let revisionRecord = try codec.encode(revision: revision, audioAsset: revisionAsset)
    let playback = try playbackEnvelope(try playbackState(position: 2))
    let local = [item, revisionRecord, transcript, playback]
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try JSONEncoder().encode(SyncRepositoryState(records: local, engineState: Data([1]),
                                                  protectedRecordIDs: Set(local.map(\.id)))).write(
        to: directory.appendingPathComponent("listener-state.json")
    )
    let repository = try ListenerRepository(directoryURL: directory)
    let remote = try local.map { envelope -> WiltedRecordEnvelope in
        var fields = envelope.fields
        fields["remoteMarker"] = .string("incoming")
        return try WiltedRecordEnvelope(id: envelope.id, schemaVersion: envelope.schemaVersion,
                                        fields: fields, sidecar: envelope.sidecar)
    }

    try await repository.commit(try await repository.stage(
        try SyncFetchBatch(generationID: "protected-incoming", records: remote, engineState: Data([2]))
    ))

    let final = await repository.state()
    for localRecord in local where localRecord.id.recordType != .playbackState {
        #expect(final.records.first(where: { $0.id == localRecord.id })?.fields["remoteMarker"] == nil)
    }
    #expect(final.records.first(where: { $0.id == playback.id })?.fields["remoteMarker"] == nil)
}

@Test("fetched playback uses causal merge and always refreshes incoming sidecar")
func fetchedPlaybackUsesMergeAndRefreshesSidecar() async throws {
    let repository = try ListenerRepository(
        directoryURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    )
    let current = try playbackEnvelope(
        playbackState(sequence: 3, position: 20),
        sidecar: WiltedOpaqueSidecar(changeTag: "stored-tag", encodedSystemFields: Data([1])),
        marker: "current"
    )
    try await repository.commit(try await repository.stage(
        try SyncFetchBatch(generationID: "playback-current", records: [current], engineState: Data([1]))
    ))
    let staleIncoming = try playbackEnvelope(
        playbackState(sequence: 2, position: 10),
        sidecar: WiltedOpaqueSidecar(changeTag: "fresh-tag", encodedSystemFields: Data([2])),
        marker: "incoming"
    )

    try await repository.commit(try await repository.stage(
        try SyncFetchBatch(generationID: "playback-stale", records: [staleIncoming], engineState: Data([2]))
    ))

    let stored = try #require((await repository.state()).records.first(where: { $0.id == current.id }))
    let decoded = try WiltedRecordCodec().decodePlayback(stored)
    #expect(decoded.sequence == 3)
    #expect(decoded.positionSeconds == 20)
    #expect(stored.fields["mergeMarker"] == .string("current"))
    #expect(stored.sidecar?.changeTag == "fresh-tag")
    #expect(stored.sidecar?.encodedSystemFields == Data([2]))
}

@Test("fetched newer playback is accepted without a pending tag comparison")
func fetchedNewerPlaybackWinsWithoutPendingWrite() async throws {
    let repository = try ListenerRepository(
        directoryURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    )
    let current = try playbackEnvelope(
        playbackState(sequence: 1, position: 5),
        sidecar: WiltedOpaqueSidecar(changeTag: "old-tag", encodedSystemFields: Data([1]))
    )
    try await repository.commit(try await repository.stage(
        try SyncFetchBatch(generationID: "playback-old", records: [current], engineState: Data([1]))
    ))
    let incoming = try playbackEnvelope(
        playbackState(sequence: 2, position: 12),
        sidecar: WiltedOpaqueSidecar(changeTag: "different-tag", encodedSystemFields: Data([2])),
        marker: "incoming"
    )

    try await repository.commit(try await repository.stage(
        try SyncFetchBatch(generationID: "playback-new", records: [incoming], engineState: Data([2]))
    ))

    let stored = try #require((await repository.state()).records.first(where: { $0.id == current.id }))
    let decoded = try WiltedRecordCodec().decodePlayback(stored)
    #expect(decoded.sequence == 2)
    #expect(decoded.positionSeconds == 12)
    #expect(stored.fields["mergeMarker"] == .string("incoming"))
    #expect(stored.sidecar?.changeTag == "different-tag")
}

@Test("fetched playback rebases a causally newer pending write onto the server sidecar")
func fetchedPlaybackRebasesNewerPendingWrite() async throws {
    let repository = try ListenerRepository(
        directoryURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    )
    let baseline = try playbackEnvelope(
        playbackState(sequence: 1, position: 5),
        sidecar: WiltedOpaqueSidecar(changeTag: "baseline-tag", encodedSystemFields: Data([1]))
    )
    try await repository.commit(try await repository.stage(
        try SyncFetchBatch(generationID: "playback-baseline", records: [baseline], engineState: Data([1]))
    ))
    let pendingEnvelope = try playbackEnvelope(
        playbackState(sequence: 3, position: 15),
        sidecar: baseline.sidecar,
        marker: "pending"
    )
    let pending = try SyncPendingChange(
        operation: .update,
        recordID: pendingEnvelope.id,
        record: pendingEnvelope
    )
    try await repository.enqueue(pending)
    let incoming = try playbackEnvelope(
        playbackState(sequence: 2, position: 10),
        sidecar: WiltedOpaqueSidecar(changeTag: "fetched-tag", encodedSystemFields: Data([3])),
        marker: "incoming"
    )

    try await repository.commit(try await repository.stage(
        try SyncFetchBatch(generationID: "playback-deferred", records: [incoming], engineState: Data([2]))
    ))

    let state = await repository.state()
    let stored = try #require(state.records.first(where: { $0.id == pendingEnvelope.id }))
    let decoded = try WiltedRecordCodec().decodePlayback(stored)
    #expect(decoded.sequence == 3)
    #expect(stored.fields["mergeMarker"] == .string("pending"))
    #expect(stored.sidecar?.changeTag == "fetched-tag")
    #expect(stored.sidecar?.encodedSystemFields == Data([3]))
    let rebased = try #require(state.pendingChanges.first)
    #expect(rebased.record == stored)
    let acknowledged = try SyncSendResult(
        engineState: Data([3]),
        acknowledgedRecordIDs: [rebased.recordID],
        serverEnvelopes: [stored]
    )
    try await repository.acknowledge(acknowledged, sent: [rebased])
    #expect((await repository.state()).pendingChanges.isEmpty)
}

@Test("fetched playback adopts a causal remote winner and clears obsolete pending work")
func fetchedPlaybackAdoptsRemoteWinner() async throws {
    let repository = try ListenerRepository(
        directoryURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    )
    let local = try playbackEnvelope(
        playbackState(sequence: 2, position: 10),
        sidecar: WiltedOpaqueSidecar(changeTag: "local-tag", encodedSystemFields: Data([1])),
        marker: "local"
    )
    let change = try SyncPendingChange(operation: .update, recordID: local.id, record: local)
    try await repository.enqueue(change)
    let remote = try playbackEnvelope(
        playbackState(sequence: 3, position: 15),
        sidecar: WiltedOpaqueSidecar(changeTag: "remote-tag", encodedSystemFields: Data([2])),
        marker: "remote"
    )

    try await repository.commit(try await repository.stage(
        try SyncFetchBatch(generationID: "remote-wins", records: [remote], engineState: Data([2]))
    ))

    let state = await repository.state()
    #expect(state.records.first(where: { $0.id == remote.id }) == remote)
    #expect(state.pendingChanges.isEmpty)
    #expect(!state.protectedRecordIDs.contains(remote.id))
    #expect(!state.conflictedRecordIDs.contains(remote.id))
}

@Test("fetched explicit rewind in a new session supersedes stale pending progress")
func fetchedRewindInNewSessionClearsStalePendingProgress() async throws {
    let repository = try ListenerRepository(
        directoryURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    )
    let local = try playbackEnvelope(
        playbackState(sequence: 4, position: 20, sessionID: "iphone-session-1"),
        sidecar: WiltedOpaqueSidecar(changeTag: "iphone-tag", encodedSystemFields: Data([1])),
        marker: "iphone-progress"
    )
    let change = try SyncPendingChange(operation: .update, recordID: local.id, record: local)
    try await repository.enqueue(change)
    let server = try playbackEnvelope(
        playbackState(sequence: 1, intent: .rewind, position: 5, sessionID: "mac-session-2"),
        sidecar: WiltedOpaqueSidecar(changeTag: "mac-rewind-tag", encodedSystemFields: Data([2])),
        marker: "mac-rewind"
    )

    try await repository.commit(try await repository.stage(
        try SyncFetchBatch(generationID: "new-session-rewind", records: [server], engineState: Data([2]))
    ))

    let state = await repository.state()
    #expect(state.records.first(where: { $0.id == server.id }) == server)
    #expect(state.pendingChanges.isEmpty)
    #expect(!state.protectedRecordIDs.contains(server.id))
    #expect(!state.conflictedRecordIDs.contains(server.id))
    #expect(state.conflictServerRecords[server.id] == nil)
}

@Test("conflict acknowledgement adopts a new-session rewind over stale pending progress")
func conflictAcknowledgementAdoptsNewSessionRewindOverStalePendingProgress() async throws {
    let repository = try ListenerRepository(
        directoryURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    )
    let local = try playbackEnvelope(
        playbackState(sequence: 4, position: 20, sessionID: "iphone-session-1"),
        sidecar: WiltedOpaqueSidecar(changeTag: "iphone-tag", encodedSystemFields: Data([1])),
        marker: "iphone-progress"
    )
    let change = try SyncPendingChange(operation: .update, recordID: local.id, record: local)
    try await repository.enqueue(change)
    let server = try playbackEnvelope(
        playbackState(sequence: 1, intent: .rewind, position: 5, sessionID: "mac-session-2"),
        sidecar: WiltedOpaqueSidecar(changeTag: "mac-rewind-tag", encodedSystemFields: Data([2])),
        marker: "mac-rewind"
    )

    try await repository.acknowledge(try SyncSendResult(
        engineState: Data([2]),
        failures: [SyncSendFailure(recordID: local.id, disposition: .conflict, serverRecord: server)]
    ), sent: [change])

    let state = await repository.state()
    #expect(state.records.first(where: { $0.id == server.id }) == server)
    #expect(state.pendingChanges.isEmpty)
    #expect(!state.protectedRecordIDs.contains(server.id))
    #expect(!state.conflictedRecordIDs.contains(server.id))
    #expect(state.conflictServerRecords[server.id] == nil)
}

@Test("stale playback acknowledgement cannot erase a newly queued write")
func stalePlaybackAcknowledgementKeepsNewerPendingWrite() async throws {
    let repository = try ListenerRepository(
        directoryURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    )
    let first = try playbackEnvelope(
        playbackState(sequence: 1, position: 5),
        sidecar: WiltedOpaqueSidecar(changeTag: "first-tag", encodedSystemFields: Data([1]))
    )
    let firstChange = try SyncPendingChange(operation: .update, recordID: first.id, record: first)
    try await repository.enqueue(firstChange)
    let newer = try playbackEnvelope(
        playbackState(sequence: 2, position: 10),
        sidecar: WiltedOpaqueSidecar(changeTag: "first-tag", encodedSystemFields: Data([1]))
    )
    let newerChange = try SyncPendingChange(operation: .update, recordID: newer.id, record: newer)
    try await repository.enqueue(newerChange)
    let server = try playbackEnvelope(
        playbackState(sequence: 1, position: 5),
        sidecar: WiltedOpaqueSidecar(changeTag: "server-tag", encodedSystemFields: Data([2]))
    )

    try await repository.acknowledge(try SyncSendResult(
        engineState: Data([2]), acknowledgedRecordIDs: [first.id], serverEnvelopes: [server]
    ), sent: [firstChange])

    let state = await repository.state()
    #expect(state.pendingChanges == [newerChange])
    #expect(state.records.first(where: { $0.id == newer.id }) == newer)
    #expect(state.protectedRecordIDs.contains(newer.id))
}

@Test("stale playback conflict acknowledgement rebases a newer pending write")
func stalePlaybackConflictAcknowledgementRebasesNewerPendingWrite() async throws {
    let repository = try ListenerRepository(
        directoryURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    )
    let first = try playbackEnvelope(
        playbackState(sequence: 1, position: 5),
        sidecar: WiltedOpaqueSidecar(changeTag: "first-tag", encodedSystemFields: Data([1]))
    )
    let firstChange = try SyncPendingChange(operation: .update, recordID: first.id, record: first)
    try await repository.enqueue(firstChange)
    let newer = try playbackEnvelope(
        playbackState(sequence: 2, position: 10),
        sidecar: first.sidecar
    )
    try await repository.enqueue(try SyncPendingChange(operation: .update, recordID: newer.id, record: newer))
    let server = try playbackEnvelope(
        playbackState(sequence: 1, position: 5),
        sidecar: WiltedOpaqueSidecar(changeTag: "server-tag", encodedSystemFields: Data([2]))
    )

    try await repository.acknowledge(try SyncSendResult(
        engineState: Data([2]),
        failures: [SyncSendFailure(recordID: first.id, disposition: .conflict, serverRecord: server)]
    ), sent: [firstChange])

    let rebasedState = await repository.state()
    let rebased = try #require(rebasedState.pendingChanges.first)
    let rebasedRecord = try #require(rebased.record)
    let rebasedPlayback = try WiltedRecordCodec().decodePlayback(rebasedRecord)
    #expect(rebasedPlayback.sequence == 2)
    #expect(rebasedRecord.sidecar == server.sidecar)
    #expect(rebasedState.records.first(where: { $0.id == newer.id }) == rebasedRecord)
    #expect(rebasedState.protectedRecordIDs.contains(newer.id))
    #expect(!rebasedState.conflictedRecordIDs.contains(newer.id))

    let retriedServer = try playbackEnvelope(
        playbackState(sequence: 2, position: 10),
        sidecar: WiltedOpaqueSidecar(changeTag: "retry-tag", encodedSystemFields: Data([3]))
    )
    try await repository.acknowledge(try SyncSendResult(
        engineState: Data([3]), acknowledgedRecordIDs: [rebased.recordID], serverEnvelopes: [retriedServer]
    ), sent: [rebased])

    let converged = await repository.state()
    #expect(converged.pendingChanges.isEmpty)
    #expect(!converged.protectedRecordIDs.contains(newer.id))
    #expect(!converged.conflictedRecordIDs.contains(newer.id))
    let stored = try #require(converged.records.first(where: { $0.id == newer.id }))
    #expect(try WiltedRecordCodec().decodePlayback(stored).sequence == 2)
    #expect(stored.sidecar == retriedServer.sidecar)
}

@Test("acknowledged playback uses causal merge and refreshes server sidecar")
func acknowledgedPlaybackUsesMergeAndRefreshesSidecar() async throws {
    let repository = try ListenerRepository(
        directoryURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    )
    let local = try playbackEnvelope(
        playbackState(sequence: 3, position: 20),
        sidecar: WiltedOpaqueSidecar(changeTag: "sent-tag", encodedSystemFields: Data([1])),
        marker: "local"
    )
    let change = try SyncPendingChange(operation: .update, recordID: local.id, record: local)
    try await repository.enqueue(change)
    let server = try playbackEnvelope(
        playbackState(sequence: 2, position: 10),
        sidecar: WiltedOpaqueSidecar(changeTag: "acknowledged-tag", encodedSystemFields: Data([9])),
        marker: "server"
    )
    let result = try SyncSendResult(
        engineState: Data([2]),
        acknowledgedRecordIDs: [local.id],
        serverEnvelopes: [server]
    )

    try await repository.acknowledge(result, sent: [change])

    let state = await repository.state()
    let stored = try #require(state.records.first(where: { $0.id == local.id }))
    let decoded = try WiltedRecordCodec().decodePlayback(stored)
    #expect(decoded.sequence == 3)
    #expect(decoded.positionSeconds == 20)
    #expect(stored.fields["mergeMarker"] == .string("local"))
    #expect(stored.sidecar?.changeTag == "acknowledged-tag")
    #expect(stored.sidecar?.encodedSystemFields == Data([9]))
    #expect(state.pendingChanges.isEmpty)
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

@Test("listener fetch observability persists success and failure without identity")
func listenerFetchObservabilityPersistsAcrossRelaunch() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let repository = try ListenerRepository(directoryURL: directory)
    let date = Date(timeIntervalSince1970: 1_700_000_123)
    try await repository.recordSuccessfulFetch(at: date)
    try await repository.recordFetchFailure("network unavailable")
    let reopened = try ListenerRepository(directoryURL: directory)
    let value = await reopened.loadObservability()
    #expect(value?.lastSuccessfulFetchAt == date)
    #expect(value?.lastFetchFailure == "network unavailable")
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
    do { try await repository.acknowledge(invalid, sent: [change]); Issue.record("expected unknown acknowledgement rejection") }
    catch let error as WiltedSyncError { #expect(error == .invalidValue(field: "acknowledgement sent IDs")) }
    let retry = try SyncSendResult(engineState: Data([2]), failures: [SyncSendFailure(recordID: id, disposition: .retryable)])
    try await repository.acknowledge(retry, sent: [change])
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
    let change = try SyncPendingChange(operation: .update, recordID: id, record: local)
    do { try await repository.acknowledge(missing, sent: [change]); Issue.record("expected server envelope requirement") }
    catch let error as WiltedSyncError { #expect(error == .invalidValue(field: "acknowledgement server envelope")) }
    let server = try WiltedRecordEnvelope(id: local.id, schemaVersion: local.schemaVersion, fields: local.fields,
                                          sidecar: WiltedOpaqueSidecar(changeTag: "tag-1", encodedSystemFields: Data([9])))
    let valid = try SyncSendResult(engineState: Data([2]), acknowledgedRecordIDs: [id], serverEnvelopes: [server])
    try await repository.acknowledge(valid, sent: [change])
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

@Test("audio cache statistics count only downloaded regular files")
func audioCacheStatistics() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let cache = try ListenerAudioCache(rootURL: root)
    let first = Data("first".utf8)
    let second = Data("second".utf8)
    _ = try await cache.store(data: first, asset: try asset(first))
    _ = try await cache.store(data: second, asset: try asset(second))
    try Data("partial".utf8).write(to: root.appendingPathComponent(".incoming-test.tmp"))
    let stats = try await cache.statistics()
    #expect(stats == ListenerDownloadStatistics(fileCount: 2, byteCount: Int64(first.count + second.count)))
}

@Test("audio cache reconciliation retains shared hashes and reclaims only managed orphans")
func audioCacheReconciliation() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let cache = try ListenerAudioCache(rootURL: root)
    let sharedBytes = Data("shared-audio".utf8)
    let orphanedBytes = Data("orphaned-audio".utf8)
    let sharedHash = "sha256:" + SHA256.hash(data: sharedBytes).map { String(format: "%02x", $0) }.joined()
    let orphanedHash = "sha256:" + SHA256.hash(data: orphanedBytes).map { String(format: "%02x", $0) }.joined()
    let firstReference = try WiltedAsset(assetID: "shared-first", contentHash: sharedHash)
    let secondReference = try WiltedAsset(assetID: "shared-second", contentHash: sharedHash)
    let orphanedReference = try WiltedAsset(assetID: "orphaned", contentHash: orphanedHash)
    _ = try await cache.store(data: sharedBytes, asset: firstReference)
    _ = try await cache.store(data: orphanedBytes, asset: orphanedReference)
    let unmanaged = root.appendingPathComponent("future-cache-format")
    try Data("leave this alone".utf8).write(to: unmanaged)

    await cache.reconcile(retaining: [firstReference, secondReference])

    #expect(await cache.url(for: firstReference) != nil)
    #expect(await cache.url(for: secondReference) != nil)
    #expect(await cache.url(for: orphanedReference) == nil)
    #expect(FileManager.default.fileExists(atPath: unmanaged.path))

    await cache.reconcile(retaining: [secondReference])
    #expect(await cache.url(for: secondReference) != nil)

    await cache.reconcile(retaining: [])
    #expect(await cache.url(for: secondReference) == nil)
}

@Test("full-file hash benchmark reports deterministic cache validation cost")
func fullFileHashCostBenchmark() async throws {
    let revisionCount = 4
    let fixtureBytesPerRevision = 4 * 1_024 * 1_024
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let cache = try ListenerAudioCache(rootURL: root)
    var assets: [WiltedAsset] = []
    for index in 0..<revisionCount {
        let bytes = Data(repeating: UInt8(index), count: fixtureBytesPerRevision)
        let hash = "sha256:" + SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        let asset = try WiltedAsset(assetID: "benchmark-\(index)", contentHash: hash)
        _ = try await cache.store(data: bytes, asset: asset)
        assets.append(asset)
    }

    let clock = ContinuousClock()
    let start = clock.now
    for asset in assets { #expect(await cache.url(for: asset) != nil) }
    let elapsed = start.duration(to: clock.now)
    let milliseconds = Double(elapsed.components.seconds) * 1_000
        + Double(elapsed.components.attoseconds) / 1_000_000_000_000_000
    let formattedMilliseconds = String(format: "%.3f", milliseconds)
    print("HASH_COST_BENCHMARK revisions=\(revisionCount) fixture_bytes=\(fixtureBytesPerRevision) total_bytes=\(revisionCount * fixtureBytesPerRevision) hash=sha256 command=swift-test-filter duration_ms=\(formattedMilliseconds) proposed_threshold_ms=100.000 optimizationNeeded=awaiting-owner-threshold")
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

@Test("natural engine completion emits a completed durable checkpoint")
func naturalCompletionEmitsDurableCheckpoint() async throws {
    let bytes = Data("completed-audio".utf8)
    let cache = try ListenerAudioCache(
        rootURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    )
    let audio = try asset(bytes)
    _ = try await cache.store(data: bytes, asset: audio)
    let engine = MemoryEngine()
    let controller = ListenerPlaybackController(cache: cache, engine: engine)
    _ = try await controller.play(asset: audio, title: "Complete", state: try playbackState(position: 4))
    let completion = Task<PlaybackState?, Never> {
        for await checkpoint in controller.durableCheckpoints { return checkpoint }
        return nil
    }

    engine.finishNaturally()
    let checkpoint = await completion.value

    #expect(checkpoint?.completed == true)
    #expect(checkpoint?.positionSeconds == checkpoint?.durationSeconds)
    #expect(checkpoint?.sequence == 3)
    #expect((await controller.current()) == checkpoint)
}

@Test("durable listener checkpoints retain an explicit session intent")
func durableCheckpointsRetainExplicitSessionIntent() async throws {
    let bytes = Data("session-intent-audio".utf8)
    let cache = try ListenerAudioCache(
        rootURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    )
    let audio = try asset(bytes)
    _ = try await cache.store(data: bytes, asset: audio)
    let engine = MemoryEngine()
    let remote = TestRemoteCommands()
    let controller = ListenerPlaybackController(cache: cache, engine: engine)
    await controller.install(remoteCommands: remote)
    _ = try await controller.play(asset: audio, title: "Session", state: try playbackState(position: 20))

    let rewind = try #require(try await controller.seek(position: 5, intent: .rewind, newSession: true))
    engine.currentTime = 7
    let paused = try #require(try await controller.pause())
    _ = engine.play()
    engine.currentTime = 9
    let backgrounded = try #require(try await controller.enterBackground())
    engine.currentTime = 11
    let checkpoint = try #require(try await controller.liveCheckpoint())
    #expect([rewind, paused, backgrounded, checkpoint].allSatisfy { $0.intent == .rewind })

    var remoteResults = controller.remoteCommandResults.makeAsyncIterator()
    await remote.send(.pause)
    let remotePause = await remoteResults.next()
    #expect(remotePause?.state.intent == .rewind)
    await remote.send(.play)
    let remotePlay = await remoteResults.next()
    #expect(remotePlay?.state.intent == .rewind)

    await remote.send(.restart)
    let restart = try #require(await remoteResults.next())
    #expect(restart.state.intent == .restart)
    engine.currentTime = 2
    let restartedPause = try #require(try await controller.pause())
    _ = engine.play()
    engine.currentTime = 4
    let restartedBackground = try #require(try await controller.enterBackground())
    engine.currentTime = 6
    let restartedCheckpoint = try #require(try await controller.liveCheckpoint())
    #expect([restart.state, restartedPause, restartedBackground, restartedCheckpoint].allSatisfy { $0.intent == .restart })
    await remote.send(.pause)
    let restartedRemotePause = await remoteResults.next()
    #expect(restartedRemotePause?.state.intent == .restart)
    await remote.send(.play)
    let restartedRemotePlay = await remoteResults.next()
    #expect(restartedRemotePlay?.state.intent == .restart)

    engine.finishNaturally()
    for _ in 0..<100 { await Task.yield() }
    let completed = try #require(await controller.current())
    #expect(completed.completed == true)
    #expect(completed.intent == .restart)
}

@Test("delayed completion from a superseded playback generation is ignored")
func supersededCompletionGenerationIsIgnored() async throws {
    let bytes = Data("generation-audio".utf8)
    let cache = try ListenerAudioCache(
        rootURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    )
    let audio = try asset(bytes)
    _ = try await cache.store(data: bytes, asset: audio)
    let engine = MemoryEngine()
    let controller = ListenerPlaybackController(cache: cache, engine: engine)
    _ = try await controller.play(asset: audio, title: "First", state: try playbackState(position: 4))
    let supersededGeneration = engine.completionGeneration
    _ = try await controller.play(
        asset: audio,
        title: "Restarted",
        state: try playbackState(sequence: 3, intent: .restart, position: 0, sessionID: "new-session")
    )

    engine.fireCompletion(generation: supersededGeneration)
    for _ in 0..<100 { await Task.yield() }

    let current = await controller.current()
    #expect(current?.completed == false)
    #expect(current?.sessionID == "new-session")
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
    var remote: TestRemoteCommands? = TestRemoteCommands()
    let installedRemote = WeakReference(remote)
    let controller = ListenerPlaybackController(cache: cache, engine: engine, nowPlaying: nowPlaying)
    await controller.install(remoteCommands: remote!)
    remote = nil
    #expect(installedRemote.object != nil, "the controller must retain its installed command bridge")
    _ = try await controller.play(asset: audio, title: "Remote", state: try playbackState())
    engine.currentTime = 12
    let backgrounded = try await controller.enterBackground()
    let started = await controller.current()
    #expect(started?.sequence == 3)
    #expect(backgrounded?.positionSeconds == 12)
    let pauseResult = Task<ListenerRemoteCommandResult?, Never> {
        for await result in controller.remoteCommandResults { return result }
        return nil
    }
    await installedRemote.object?.send(.pause)
    let durablePause = await pauseResult.value
    #expect(durablePause?.command == .pause)
    #expect(durablePause?.state.sequence == 4)
    #expect(durablePause?.isPlaying == false)
    #expect((await controller.current())?.intent == .progress)
    #expect((await controller.current())?.sequence == 4)
    await installedRemote.object?.send(.play)
    #expect((await controller.current())?.sequence == 5)
    await installedRemote.object?.send(.rewind)
    let rewound = await controller.current()
    #expect(rewound?.intent == .rewind)
    #expect(rewound?.sequence == 6)
    #expect(rewound?.sessionID == "remote-6")
    await installedRemote.object?.send(.pause)
    let pausedRewind = await controller.current()
    #expect(pausedRewind?.intent == .rewind)
    #expect(pausedRewind?.sequence == 7)
    await installedRemote.object?.send(.play)
    let resumedRewind = await controller.current()
    #expect(resumedRewind?.intent == .rewind)
    #expect(resumedRewind?.sequence == 8)
    await installedRemote.object?.send(.restart)
    let restarted = await controller.current()
    #expect(restarted?.intent == .restart)
    #expect(restarted?.sequence == 9)
    #expect(restarted?.sessionID == "remote-9")
    #expect(engine.playing == true)
    #expect(nowPlaying.updates >= 6)
    await controller.cancel()
}

@Test("system remote target actions serialize rapid commands in FIFO order")
func mediaPlayerRemoteCommandsSerializeDeliveryFIFO() async {
    let recorder = OrderedRemoteRecorder()
    let remote = MediaPlayerRemoteCommands()
    remote.install { command in await recorder.receive(command) }

    #expect(remote.receiveRewind(nil) == .success)
    #expect(remote.receivePause(nil) == .success)

    let commands = await recorder.waitForCount(2)
    #expect(commands == [.rewind, .pause])
}

@Test("remote rewind and restart preserve the paused engine state and Now Playing rate")
func inactiveRewindAndRestartKeepPausedRateAndState() async throws {
    let bytes = Data("audio".utf8)
    let cache = try ListenerAudioCache(
        rootURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    )
    let audio = try asset(bytes)
    _ = try await cache.store(data: bytes, asset: audio)
    let engine = MemoryEngine()
    let nowPlaying = TestNowPlaying()
    let remote = TestRemoteCommands()
    let controller = ListenerPlaybackController(cache: cache, engine: engine, nowPlaying: nowPlaying)
    await controller.install(remoteCommands: remote)
    _ = try await controller.play(asset: audio, title: "Remote", state: try playbackState())
    _ = try await controller.pause()

    engine.currentTime = 20
    var results = controller.remoteCommandResults.makeAsyncIterator()
    await remote.send(.rewind)
    let rewind = await results.next()
    #expect(rewind?.command == .rewind)
    #expect(rewind?.isPlaying == false)
    #expect(engine.isPlaying == false)
    #expect(nowPlaying.lastRate == 0)

    await remote.send(.restart)
    let restart = await results.next()
    #expect(restart?.command == .restart)
    #expect(restart?.isPlaying == false)
    #expect(engine.isPlaying == false)
    #expect(nowPlaying.lastRate == 0)
}

@Test("paused seeks update causal state without reloading or starting audio")
func pausedSeekDoesNotRestartAudio() async throws {
    let bytes = Data("paused-seek-audio".utf8)
    let cache = try ListenerAudioCache(
        rootURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    )
    let audio = try asset(bytes)
    _ = try await cache.store(data: bytes, asset: audio)
    let engine = MemoryEngine()
    let nowPlaying = TestNowPlaying()
    let controller = ListenerPlaybackController(cache: cache, engine: engine, nowPlaying: nowPlaying)
    _ = try await controller.play(asset: audio, title: "Paused seek", state: try playbackState(position: 20))
    let pausedState = try await controller.pause()
    let paused = try #require(pausedState)
    let loadsBeforeSeek = engine.loadCallCount
    let playsBeforeSeek = engine.playCallCount

    let rewindState = try await controller.seek(position: 5, intent: .rewind, newSession: true)
    let rewind = try #require(rewindState)
    #expect(rewind.intent == .rewind)
    #expect(rewind.sessionID != paused.sessionID)
    #expect(rewind.sequence == 1)
    #expect(rewind.positionSeconds == 5)
    #expect(engine.isPlaying == false)
    #expect(nowPlaying.lastRate == 0)

    let progressState = try await controller.seek(position: 20, intent: .progress, newSession: false)
    let progress = try #require(progressState)
    #expect(progress.intent == .rewind)
    #expect(progress.sessionID == rewind.sessionID)
    #expect(progress.sequence == rewind.sequence + 1)
    #expect(progress.positionSeconds == 20)
    #expect(engine.loadCallCount == loadsBeforeSeek)
    #expect(engine.playCallCount == playsBeforeSeek)
    #expect(engine.isPlaying == false)
}

@Test("a refused remote play does not publish an active playback transition")
func remotePlayFailureDoesNotAdvanceState() async throws {
    let bytes = Data("audio".utf8)
    let cache = try ListenerAudioCache(
        rootURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    )
    let audio = try asset(bytes)
    _ = try await cache.store(data: bytes, asset: audio)
    let engine = MemoryEngine()
    let remote = TestRemoteCommands()
    let controller = ListenerPlaybackController(cache: cache, engine: engine)
    await controller.install(remoteCommands: remote)
    _ = try await controller.play(asset: audio, title: "Remote", state: try playbackState())
    _ = try await controller.pause()
    let before = await controller.current()
    engine.allowsPlay = false

    await remote.send(.play)

    #expect(await controller.current() == before)
    #expect(engine.isPlaying == false)
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
