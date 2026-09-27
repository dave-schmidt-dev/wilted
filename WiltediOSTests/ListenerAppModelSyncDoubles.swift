import CryptoKit
import MediaPlayer
import XCTest
@testable import WiltediOS
import WiltedDomain
@testable import WiltedListener
import WiltedSync
import CloudKit
import WiltedCloudKit

struct ChunkedCatalogFixture {
    let itemID: ItemID
    let bytes: Data
    let asset: WiltedAsset
    let repository: StaticSyncRepository
    let cache: ListenerAudioCache
}

actor CountingChunkLoader {
    let data: Data
    private(set) var count = 0

    init(data: Data) { self.data = data }

    func load(itemID: ItemID, revisionID: RevisionID, manifest: AudioChunkManifest) throws -> Data {
        count += 1
        return data
    }
}

actor BlockingChunkLoader {
    let data: Data
    private(set) var count = 0
    private var continuations: [CheckedContinuation<Data, Never>] = []

    init(data: Data) { self.data = data }

    func load(itemID: ItemID, revisionID: RevisionID, manifest: AudioChunkManifest) async -> Data {
        count += 1
        return await withCheckedContinuation { continuation in
            continuations.append(continuation)
        }
    }

    func release() {
        guard !continuations.isEmpty else { return }
        continuations.removeFirst().resume(returning: data)
    }
}

actor SessionCancelProbe {
    private(set) var wasCalled = false
    func record() { wasCalled = true }
}

actor FailingSessionFactory {
    private(set) var constructionCount = 0

    func makeSession(stateData: Data?) throws -> any ListenerSyncSession {
        constructionCount += 1
        throw TestSyncError.network
    }
}

actor SessionSequenceProbe {
    private var transports: [any SyncTransport]
    private let firstCancelProbe: SessionCancelProbe
    private var inputs: [Data?] = []
    private var creationCount = 0

    init(transports: [any SyncTransport], firstCancelProbe: SessionCancelProbe) {
        self.transports = transports
        self.firstCancelProbe = firstCancelProbe
    }

    func makeSession(stateData: Data?) async throws -> any ListenerSyncSession {
        inputs.append(stateData)
        guard !transports.isEmpty else { throw TestSyncError.network }
        let transport = transports.removeFirst()
        let isFirst = creationCount == 0
        creationCount += 1
        return TestSyncSession(
            transport: transport,
            cancelAction: { [firstCancelProbe] in
                if isFirst { await firstCancelProbe.record() }
            }
        )
    }

    func stateInputs() -> [Data?] { inputs }
}

/// Models the commit handshake that keeps CloudKit engine serialization local
/// until the repository has persisted the matching fetch or send result.
actor SerializedStateTransport: SyncTransport {
    nonisolated let statuses = AsyncStream<SyncStatus> { _ in }
    private var currentState: Data?
    private var fetchedState: Data?
    private var sentState: Data?
    private var fetchStates: [Data?]
    private var sendStates: [Data?]
    private var committedFetchStates: [Data?] = []
    private var committedSendStates: [Data?] = []
    private var saves = 0
    private let persistenceCheck: (@Sendable (Data?) async -> Bool)?

    init(
        initialState: Data?,
        fetchStates: [Data?] = [],
        sendStates: [Data?] = [],
        persistenceCheck: (@Sendable (Data?) async -> Bool)? = nil
    ) {
        self.currentState = initialState
        self.fetchStates = fetchStates
        self.sendStates = sendStates
        self.persistenceCheck = persistenceCheck
    }

    func fetchChanges() async throws -> SyncFetchBatch {
        let state = fetchStates.isEmpty ? currentState : fetchStates.removeFirst()
        currentState = state
        fetchedState = state
        return try SyncFetchBatch(generationID: "serialized-state-fetch-\(committedFetchStates.count)",
                                  records: [], engineState: state)
    }

    func save(changes: [SyncPendingChange], role: SyncDeviceRole) async throws -> SyncSendResult {
        saves += 1
        let state = sendStates.isEmpty ? currentState : sendStates.removeFirst()
        currentState = state
        sentState = state
        return try SyncSendResult(engineState: state, acknowledgedRecordIDs: changes.map(\.recordID),
                                  serverEnvelopes: changes.compactMap(\.record))
    }

    func commitFetchedState(_ engineState: Data?) async throws {
        guard engineState == fetchedState else { throw TestSyncError.network }
        if let persistenceCheck { guard await persistenceCheck(engineState) else { throw TestSyncError.network } }
        currentState = engineState
        committedFetchStates.append(engineState)
        fetchedState = nil
    }

    func commitSentState(_ engineState: Data?) async throws {
        guard engineState == (sentState ?? currentState) else { throw TestSyncError.network }
        if let persistenceCheck { guard await persistenceCheck(engineState) else { throw TestSyncError.network } }
        currentState = engineState
        committedSendStates.append(engineState)
        sentState = nil
    }

    func committedState() -> Data? { currentState }
    func fetchedCommitStates() -> [Data?] { committedFetchStates }
    func sentCommitStates() -> [Data?] { committedSendStates }
    func saveCount() -> Int { saves }
}

actor CommitHandshakeRepository: SyncRepository {
    nonisolated let statuses = AsyncStream<SyncStatus> { _ in }
    private var snapshot: SyncRepositoryState
    private var commitFailuresRemaining: Int
    private var stageGate: AsyncEnqueueGate?

    init(
        state: SyncRepositoryState,
        commitFailuresRemaining: Int = 0,
        stageGate: AsyncEnqueueGate? = nil
    ) {
        self.snapshot = state
        self.commitFailuresRemaining = commitFailuresRemaining
        self.stageGate = stageGate
    }

    func state() async -> SyncRepositoryState { snapshot }

    func setStageGate(_ gate: AsyncEnqueueGate?) { stageGate = gate }

    func stage(_ batch: SyncFetchBatch) async throws -> StagedSyncBatch {
        if let stageGate { await stageGate.suspend() }
        return StagedSyncBatch(batch: batch, priorState: snapshot)
    }

    func commit(_ staged: StagedSyncBatch) async throws {
        guard commitFailuresRemaining == 0 else {
            commitFailuresRemaining -= 1
            throw TestSyncError.network
        }
        snapshot = SyncRepositoryState(
            records: staged.batch.records.isEmpty ? snapshot.records : staged.batch.records,
            engineState: staged.batch.engineState ?? snapshot.engineState,
            pendingChanges: snapshot.pendingChanges,
            tombstones: snapshot.tombstones,
            remoteAcknowledgedRecordIDs: snapshot.remoteAcknowledgedRecordIDs,
            protectedRecordIDs: snapshot.protectedRecordIDs,
            conflictedRecordIDs: snapshot.conflictedRecordIDs,
            conflictServerRecords: snapshot.conflictServerRecords,
            accountOwnerToken: snapshot.accountOwnerToken
        )
    }

    func enqueue(_ change: SyncPendingChange) async throws {
        snapshot = SyncRepositoryState(
            records: snapshot.records,
            engineState: snapshot.engineState,
            pendingChanges: snapshot.pendingChanges.filter { $0.recordID != change.recordID } + [change],
            tombstones: snapshot.tombstones,
            remoteAcknowledgedRecordIDs: snapshot.remoteAcknowledgedRecordIDs,
            protectedRecordIDs: snapshot.protectedRecordIDs,
            conflictedRecordIDs: snapshot.conflictedRecordIDs,
            conflictServerRecords: snapshot.conflictServerRecords,
            accountOwnerToken: snapshot.accountOwnerToken
        )
    }

    func acknowledge(_ result: SyncSendResult, sent _: [SyncPendingChange]) async throws {
        let acknowledged = Set(result.acknowledgedRecordIDs)
        snapshot = SyncRepositoryState(
            records: snapshot.records,
            engineState: result.engineState ?? snapshot.engineState,
            pendingChanges: snapshot.pendingChanges.filter { !acknowledged.contains($0.recordID) },
            tombstones: snapshot.tombstones,
            remoteAcknowledgedRecordIDs: snapshot.remoteAcknowledgedRecordIDs.union(acknowledged),
            protectedRecordIDs: snapshot.protectedRecordIDs.subtracting(acknowledged),
            conflictedRecordIDs: snapshot.conflictedRecordIDs.subtracting(acknowledged),
            conflictServerRecords: snapshot.conflictServerRecords.filter { !acknowledged.contains($0.key) },
            accountOwnerToken: snapshot.accountOwnerToken
        )
    }
}

func listenerCommitHandshakeFixture() throws -> (records: [WiltedRecordEnvelope], pendingChange: SyncPendingChange) {
    let url = URL(string: "https://example.test/listener-commit-handshake")!
    let itemID = try ItemID.derive(from: url)
    let revisionID = try RevisionID(rawValue: "listener-commit-handshake")
    let hash = "sha256:" + String(repeating: "c", count: 64)
    let asset = try WiltedAsset(assetID: "listener-commit-handshake", contentHash: hash)
    let article = try Article(itemID: itemID, canonicalURL: url, title: "Commit handshake",
                              source: "Test", createdAt: Timestamp(Date()))
    let revision = try AudioRevision(itemID: itemID, revisionID: revisionID,
                                     durationSeconds: 30, byteCount: 1, contentHash: hash,
                                     mediaType: "audio/m4a", createdAt: Timestamp(Date()), schemaVersion: 1)
    let playback = try PlaybackState(itemID: itemID, revisionID: revisionID, sessionID: "handshake",
                                     sequence: 1, positionSeconds: 5, durationSeconds: 30,
                                     completed: false, intent: .progress, deviceID: "iphone",
                                     updatedAt: Timestamp(Date()))
    let codec = WiltedRecordCodec()
    let playbackRecord = try codec.encode(playback: playback)
    let pendingChange = try SyncPendingChange(operation: .update, recordID: playbackRecord.id, record: playbackRecord)
    return ([
        try codec.encode(article: article, currentRevisionID: revisionID),
        try codec.encode(revision: revision, audioAsset: asset),
        playbackRecord,
    ], pendingChange)
}

func listenerStaleStageFixture(changeCount: Int) throws -> ([WiltedRecordEnvelope], [SyncPendingChange]) {
    let url = URL(string: "https://example.test/listener-stale-stage")!
    let itemID = try ItemID.derive(from: url)
    let revisionID = try RevisionID(rawValue: "listener-stale-stage")
    let hash = "sha256:" + String(repeating: "a", count: 64)
    let asset = try WiltedAsset(assetID: "listener-stale-stage", contentHash: hash)
    let article = try Article(itemID: itemID, canonicalURL: url, title: "Stale stage",
                              source: "Test", createdAt: Timestamp(Date()))
    let revision = try AudioRevision(itemID: itemID, revisionID: revisionID,
                                     durationSeconds: 30, byteCount: 1, contentHash: hash,
                                     mediaType: "audio/m4a", createdAt: Timestamp(Date()), schemaVersion: 1)
    let codec = WiltedRecordCodec()
    let record = try codec.encode(article: article, currentRevisionID: revisionID)
    let records = [record, try codec.encode(revision: revision, audioAsset: asset)]
    let changes = try (1...changeCount).map { sequence in
        let changedRecord = try WiltedRecordEnvelope(
            id: record.id,
            schemaVersion: record.schemaVersion,
            fields: record.fields,
            sidecar: WiltedOpaqueSidecar(changeTag: "local-\(sequence)")
        )
        return try SyncPendingChange(operation: .update, recordID: record.id, record: changedRecord)
    }
    return (records, changes)
}

actor StaticSyncRepository: SyncRepository {
    nonisolated let statuses: AsyncStream<SyncStatus>
    private let statusContinuation: AsyncStream<SyncStatus>.Continuation
    private var snapshot: SyncRepositoryState
    private var acknowledgements: [[SyncPendingChange]] = []
    private var enqueued: [SyncPendingChange] = []
    private var nextEnqueueGate: AsyncEnqueueGate?
    private var nextStateGate: AsyncEnqueueGate?

    init(state: SyncRepositoryState) {
        self.snapshot = state
        let (stream, continuation) = AsyncStream<SyncStatus>.makeStream()
        self.statuses = stream
        self.statusContinuation = continuation
    }

    func state() async -> SyncRepositoryState {
        if let gate = nextStateGate {
            nextStateGate = nil
            await gate.suspend()
        }
        return snapshot
    }

    func stage(_ batch: SyncFetchBatch) async throws -> StagedSyncBatch {
        StagedSyncBatch(batch: batch, priorState: snapshot)
    }

    func commit(_ staged: StagedSyncBatch) async throws {
        snapshot = SyncRepositoryState(
            records: staged.batch.records.isEmpty ? snapshot.records : staged.batch.records,
            engineState: staged.batch.engineState ?? snapshot.engineState,
            pendingChanges: snapshot.pendingChanges,
            tombstones: snapshot.tombstones,
            remoteAcknowledgedRecordIDs: snapshot.remoteAcknowledgedRecordIDs,
            protectedRecordIDs: snapshot.protectedRecordIDs,
            conflictedRecordIDs: snapshot.conflictedRecordIDs,
            conflictServerRecords: snapshot.conflictServerRecords)
    }

    func enqueue(_ change: SyncPendingChange) async throws {
        if let gate = nextEnqueueGate {
            nextEnqueueGate = nil
            await gate.suspend()
        }
        enqueued.append(change)
        var records = snapshot.records.filter { $0.id != change.recordID }
        if let record = change.record { records.append(record) }
        let pending = snapshot.pendingChanges.filter { $0.recordID != change.recordID } + [change]
        snapshot = SyncRepositoryState(
            records: records,
            engineState: snapshot.engineState,
            pendingChanges: pending,
            tombstones: snapshot.tombstones,
            remoteAcknowledgedRecordIDs: snapshot.remoteAcknowledgedRecordIDs,
            protectedRecordIDs: snapshot.protectedRecordIDs,
            conflictedRecordIDs: snapshot.conflictedRecordIDs,
            conflictServerRecords: snapshot.conflictServerRecords
        )
        statusContinuation.yield(.init(phase: .completed, message: "Listener playback change queued"))
    }
    func acknowledge(_ result: SyncSendResult, sent: [SyncPendingChange]) async throws { acknowledgements.append(sent) }
    func acknowledgedBatches() -> [[SyncPendingChange]] { acknowledgements }
    func enqueuedChanges() -> [SyncPendingChange] { enqueued }
    func holdNextEnqueue(on gate: AsyncEnqueueGate) { nextEnqueueGate = gate }
    func holdNextState(on gate: AsyncEnqueueGate) { nextStateGate = gate }
}

actor StaleStageListenerRepository: SyncRepository {
    nonisolated let statuses = AsyncStream<SyncStatus> { _ in }
    private var snapshot: SyncRepositoryState
    private var concurrentChanges: [SyncPendingChange]
    private(set) var stageCalls = 0
    private(set) var commitCalls = 0

    init(state: SyncRepositoryState = .init(), concurrentChanges: [SyncPendingChange]) {
        self.snapshot = state
        self.concurrentChanges = concurrentChanges
    }

    func state() async -> SyncRepositoryState { snapshot }

    func stage(_ batch: SyncFetchBatch) async throws -> StagedSyncBatch {
        stageCalls += 1
        return StagedSyncBatch(batch: batch, priorState: snapshot)
    }

    func commit(_ staged: StagedSyncBatch) async throws {
        commitCalls += 1
        if !concurrentChanges.isEmpty {
            try await enqueue(concurrentChanges.removeFirst())
        }
        guard staged.priorState == snapshot else { throw ListenerError.staleStage }
        snapshot = SyncRepositoryState(records: staged.batch.records,
                                       engineState: staged.batch.engineState,
                                       pendingChanges: snapshot.pendingChanges)
    }

    func enqueue(_ change: SyncPendingChange) async throws {
        snapshot = SyncRepositoryState(records: snapshot.records, engineState: snapshot.engineState,
                                       pendingChanges: snapshot.pendingChanges.filter { $0.recordID != change.recordID } + [change])
    }

    func acknowledge(_ result: SyncSendResult, sent: [SyncPendingChange]) async throws {}
}

actor SingleBatchSyncTransport: SyncTransport {
    nonisolated let statuses = AsyncStream<SyncStatus> { _ in }
    private let batch: SyncFetchBatch
    private(set) var fetchCalls = 0

    init(batch: SyncFetchBatch) { self.batch = batch }

    func fetchChanges() async throws -> SyncFetchBatch {
        fetchCalls += 1
        return batch
    }

    func save(changes: [SyncPendingChange], role: SyncDeviceRole) async throws -> SyncSendResult {
        try SyncSendResult(engineState: Data([3]))
    }
}

actor SequencedSyncTransport: SyncTransport {
    nonisolated let statuses = AsyncStream<SyncStatus> { _ in }
    private var batches: [SyncFetchBatch]

    init(batches: [SyncFetchBatch]) { self.batches = batches }

    func fetchChanges() async throws -> SyncFetchBatch {
        guard !batches.isEmpty else { throw TestSyncError.network }
        return batches.removeFirst()
    }

    func save(changes: [SyncPendingChange], role: SyncDeviceRole) async throws -> SyncSendResult {
        try SyncSendResult(engineState: Data([3]))
    }
}

actor RecordingSyncTransport: SyncTransport {
    let statuses: AsyncStream<SyncStatus>
    private var sent: [[SyncPendingChange]] = []
    private var fetchCount = 0
    private var saveCount = 0
    private let fetchError: TestSyncError?
    private var saveErrors: [TestSyncError]

    init(fetchError: TestSyncError? = nil, saveErrors: [TestSyncError] = []) {
        statuses = AsyncStream { _ in }
        self.fetchError = fetchError
        self.saveErrors = saveErrors
    }

    func fetchChanges() async throws -> SyncFetchBatch {
        fetchCount += 1
        if let fetchError { throw fetchError }
        return try SyncFetchBatch(generationID: "refresh", records: [], engineState: Data([2]))
    }

    func save(changes: [SyncPendingChange], role: SyncDeviceRole) async throws -> SyncSendResult {
        saveCount += 1
        sent.append(changes)
        if !saveErrors.isEmpty { throw saveErrors.removeFirst() }
        return try SyncSendResult(engineState: Data([3]))
    }

    func savedChanges() -> [[SyncPendingChange]] { sent }
    func fetchCountValue() -> Int { fetchCount }
    func saveCountValue() -> Int { saveCount }
}

actor RebasedPlaybackTransport: SyncTransport {
    nonisolated let statuses = AsyncStream<SyncStatus> { _ in }
    private let serverRecord: WiltedRecordEnvelope
    private var batches: [[SyncPendingChange]] = []

    init(serverRecord: WiltedRecordEnvelope) { self.serverRecord = serverRecord }

    func fetchChanges() async throws -> SyncFetchBatch {
        try SyncFetchBatch(generationID: "empty", records: [], engineState: Data([1]))
    }

    func save(changes: [SyncPendingChange], role: SyncDeviceRole) async throws -> SyncSendResult {
        batches.append(changes)
        if batches.count == 1 {
            return try SyncSendResult(engineState: Data([2]), failures: [
                SyncSendFailure(recordID: serverRecord.id, disposition: .conflict, serverRecord: serverRecord)
            ])
        }
        return try SyncSendResult(engineState: Data([3]), acknowledgedRecordIDs: changes.map(\.recordID),
                                  serverEnvelopes: changes.compactMap(\.record))
    }

    func savedBatches() -> [[SyncPendingChange]] { batches }
    func operationGeneration() async -> UInt64 { 0 }
}
