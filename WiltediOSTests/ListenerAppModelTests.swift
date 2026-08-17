import XCTest
@testable import WiltediOS
import WiltedDomain
import WiltedListener
import WiltedSync

@MainActor
final class ListenerAppModelTests: XCTestCase {
    func testDebugModelDoesNotContactTransportAndReportsLocalFailure() async {
        let model = WiltedListenerAppModel()
        await model.refresh()

        guard case let .failed(message, retryable) = model.status else {
            return XCTFail("Expected a visible local-library failure")
        }
        XCTAssertTrue(message.contains("Local library unavailable"))
        XCTAssertFalse(retryable)
    }

    func testMetadataAndDownloadStatesRemainDistinct() {
        XCTAssertNotEqual(ListenerItemState.metadataOnly, ListenerItemState.downloaded)
        XCTAssertTrue(ListenerItemState.metadataOnly.label.contains("download"))
        XCTAssertEqual(ListenerItemState.deleted.label, "Deleted remotely")
    }

    func testBusyStatusExposesCancellationSurface() {
        XCTAssertTrue(ListenerAppStatus.refreshing("Waiting for sync").isBusy)
        XCTAssertTrue(ListenerAppStatus.sending("Sending playback").isBusy)
        XCTAssertFalse(ListenerAppStatus.offline("Offline").isBusy)
    }

    func testResetDoesNotSendQuarantinedPendingPlayback() async throws {
        let url = URL(string: "https://example.test/account-reset")!
        let itemID = try ItemID.derive(from: url)
        let revisionID = try RevisionID(rawValue: "revision-account-reset")
        let asset = try WiltedAsset(assetID: "audio-account-reset",
                                    contentHash: "sha256:" + String(repeating: "a", count: 64))
        let codec = WiltedRecordCodec()
        let article = try Article(itemID: itemID, canonicalURL: url, title: "Account reset",
                                  source: "Test", createdAt: Timestamp(Date()))
        let revision = try AudioRevision(itemID: itemID, revisionID: revisionID, durationSeconds: 30,
                                        byteCount: 1, contentHash: asset.contentHash,
                                        mediaType: "audio/mpeg", createdAt: Timestamp(Date()), schemaVersion: 1)
        let playback = try PlaybackState(itemID: itemID, revisionID: revisionID, sessionID: "old-account",
                                         sequence: 1, positionSeconds: 5, durationSeconds: 30,
                                         completed: false, intent: .progress, deviceID: "iphone",
                                         updatedAt: Timestamp(Date()))
        let itemRecord = try codec.encode(article: article, currentRevisionID: revisionID)
        let revisionRecord = try codec.encode(revision: revision, audioAsset: asset)
        let playbackRecord = try codec.encode(playback: playback)
        let change = try SyncPendingChange(operation: .update, recordID: playbackRecord.id, record: playbackRecord)
        let repository = StaticSyncRepository(state: SyncRepositoryState(
            records: [itemRecord, revisionRecord, playbackRecord], engineState: Data([1]),
            pendingChanges: [change], conflictedRecordIDs: [change.recordID]))
        let transport = RecordingSyncTransport()
        let model = WiltedListenerAppModel(repository: repository, sessionFactory: { _ in
            TestSyncSession(transport: transport)
        })

        await model.refresh()
        await model.resetAfterAccountChange()
        await model.sendPending()

        let sent = await transport.savedChanges()
        XCTAssertTrue(sent.isEmpty)
    }
}

private actor StaticSyncRepository: SyncRepository {
    let statuses: AsyncStream<SyncStatus>
    private var snapshot: SyncRepositoryState

    init(state: SyncRepositoryState) {
        self.snapshot = state
        self.statuses = AsyncStream { _ in }
    }

    func state() async -> SyncRepositoryState { snapshot }

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

    func enqueue(_ change: SyncPendingChange) async throws {}
    func acknowledge(_ result: SyncSendResult) async throws {}
}

private actor RecordingSyncTransport: SyncTransport {
    let statuses: AsyncStream<SyncStatus>
    private var sent: [[SyncPendingChange]] = []

    init() { statuses = AsyncStream { _ in } }

    func fetchChanges() async throws -> SyncFetchBatch {
        try SyncFetchBatch(generationID: "refresh", records: [], engineState: Data([2]))
    }

    func save(changes: [SyncPendingChange], role: SyncDeviceRole) async throws -> SyncSendResult {
        sent.append(changes)
        return try SyncSendResult(engineState: Data([3]))
    }

    func savedChanges() -> [[SyncPendingChange]] { sent }
}

private struct TestSyncSession: ListenerSyncSession {
    let transport: any SyncTransport
    let assetLoader: ListenerAssetLoader
    let accountChanges: AsyncStream<ListenerAccountChange>

    init(transport: any SyncTransport) {
        self.transport = transport
        self.assetLoader = { _, asset in throw ListenerError.cacheUnavailable(asset.assetID) }
        self.accountChanges = AsyncStream { _ in }
    }

    func cancel() async {}
    func resetAfterAccountChange() async {}
}
