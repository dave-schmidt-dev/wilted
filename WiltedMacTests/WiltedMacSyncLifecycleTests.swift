import XCTest
import CryptoKit
import WiltedDomain
import WiltedProducer
import WiltedSync
@testable import WiltedMac

private actor LifecycleFakeTransport: SyncTransport {
    nonisolated let statuses: AsyncStream<SyncStatus>
    private let statusContinuation: AsyncStream<SyncStatus>.Continuation
    private let batch: SyncFetchBatch
    private let fetchError: Error?
    private let saveError: Error?
    private let delayNanoseconds: UInt64
    private var fetchStarted = false
    private var cancelled = false

    init(batch: SyncFetchBatch, fetchError: Error? = nil, saveError: Error? = nil, delayNanoseconds: UInt64 = 0) {
        self.batch = batch; self.fetchError = fetchError; self.saveError = saveError; self.delayNanoseconds = delayNanoseconds
        let (stream, continuation) = AsyncStream<SyncStatus>.makeStream()
        statuses = stream; statusContinuation = continuation
    }

    func fetchChanges() async throws -> SyncFetchBatch {
        fetchStarted = true
        statusContinuation.yield(.init(phase: .fetching, message: "fake fetch"))
        if delayNanoseconds > 0 {
            do { try await Task.sleep(nanoseconds: delayNanoseconds) }
            catch { throw WiltedSyncError.transport("cancelled") }
        }
        if cancelled { throw WiltedSyncError.transport("cancelled") }
        if let fetchError { throw fetchError }
        return batch
    }

    func save(changes: [SyncPendingChange], role: SyncDeviceRole) async throws -> SyncSendResult {
        guard role == .mac else { throw WiltedSyncError.ownershipViolation(role: role, operation: .update, recordType: .item) }
        if let saveError { throw saveError }
        let acknowledged = changes.map(\.recordID)
        let envelopes = changes.compactMap(\.record)
        return try SyncSendResult(engineState: Data([8, 8]), acknowledgedRecordIDs: acknowledged, serverEnvelopes: envelopes)
    }

    func didStartFetch() -> Bool { fetchStarted }

    func cancel() { cancelled = true }

    func wasCancelled() -> Bool { cancelled }
}

private actor SyncFactoryProbe {
    private(set) var factoryCalls = 0
    private(set) var resetCalls = 0

    func madeFactory() { factoryCalls += 1 }
    func reset() { resetCalls += 1 }
}

@MainActor
final class WiltedMacSyncLifecycleTests: XCTestCase {
    private func storeURL(_ name: String = #function) -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("wilted-mac-sync-\(name)-\(UUID().uuidString)").appendingPathComponent("library.sqlite")
    }

    private func article(_ suffix: String = "article") throws -> Article {
        let url = URL(string: "https://example.test/mac/\(suffix)")!
        return try Article(itemID: ItemID.derive(from: url), canonicalURL: url, title: suffix, source: "example.test",
                           createdAt: Timestamp(Date(timeIntervalSince1970: 1_700_000_000)))
    }

    private func lifecycle(_ store: LocalLibraryStore, transport: LifecycleFakeTransport,
                           assetURL: URL? = nil) -> WiltedMacSyncLifecycle {
        WiltedMacSyncLifecycle(
            store: store,
            transportFactory: { WiltedMacSyncTransportHandle(transport: transport) { await transport.cancel() } },
            assetResolver: { _, _ in assetURL }
        )
    }

    func testQueuesItemRevisionAndPlaybackThenUploads() async throws {
        let url = storeURL(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let item = try article(); let revisionID = try RevisionID(rawValue: "revision-mac")
        let bytes = Data("mac-media".utf8)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let mediaURL = url.deletingLastPathComponent().appendingPathComponent("media.m4a")
        try bytes.write(to: mediaURL)
        let hash = "sha256:" + SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        let revision = try AudioRevision(itemID: item.itemID, revisionID: revisionID, durationSeconds: 4, byteCount: Int64(bytes.count),
                                         contentHash: hash, mediaType: "audio/mp4", createdAt: Timestamp(Date()), schemaVersion: 1)
        let playback = try PlaybackState(itemID: item.itemID, revisionID: revisionID, sessionID: "session", sequence: 1,
                                         positionSeconds: 1, durationSeconds: 4, completed: false, intent: .progress,
                                         deviceID: "mac", updatedAt: Timestamp(Date()))
        let batch = try SyncFetchBatch(generationID: "empty", records: [], engineState: Data([1]))
        let transport = LifecycleFakeTransport(batch: batch)
        let lifecycle = lifecycle(try LocalLibraryStore(url: url), transport: transport, assetURL: mediaURL)

        let itemResult = await lifecycle.queueItem(item, currentRevisionID: revisionID)
        let revisionResult = await lifecycle.queueRevision(revision, audioAsset: try WiltedAsset(assetID: "media", contentHash: hash))
        let playbackResult = await lifecycle.queuePlayback(playback)
        XCTAssertTrue(isSuccess(itemResult)); XCTAssertTrue(isSuccess(revisionResult)); XCTAssertTrue(isSuccess(playbackResult))
        let upload = await lifecycle.uploadPending()
        XCTAssertTrue(isSuccess(upload))
        XCTAssertEqual(lifecycle.status.phase, .completed)
    }

    func testRefreshAndUploadExposeOfflineErrorCancellationQuarantineAndRelaunchState() async throws {
        let url = storeURL(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let item = try article("relaunch")
        let itemRecord = try WiltedRecordCodec().encode(article: item, currentRevisionID: try RevisionID(rawValue: "revision-relaunch"))
        let batch = try SyncFetchBatch(generationID: "generation", records: [itemRecord], engineState: Data([2]))
        let store = try LocalLibraryStore(url: url)
        let unopened = lifecycle(store, transport: LifecycleFakeTransport(batch: batch))
        unopened.quarantineAccount()
        try await Task.sleep(nanoseconds: 5_000_000)
        let unopenedRefresh = await unopened.refresh()
        XCTAssertFalse(isSuccess(unopenedRefresh))
        XCTAssertEqual(unopened.status.phase, .quarantined)

        let offline = lifecycle(store, transport: LifecycleFakeTransport(batch: batch, fetchError: WiltedSyncError.transport("offline")))
        let offlineResult = await offline.refresh()
        XCTAssertFalse(isSuccess(offlineResult)); XCTAssertEqual(offline.status.phase, .failed)

        let delayedTransport = LifecycleFakeTransport(batch: batch, delayNanoseconds: 100_000_000)
        let cancellable = lifecycle(store, transport: delayedTransport)
        let refreshTask = Task { await cancellable.refresh() }
        var sawTransportStatus = false
        for _ in 0..<50 {
            if cancellable.status.detail == "fake fetch" { sawTransportStatus = true; break }
            if await delayedTransport.didStartFetch() { break }
            try await Task.sleep(nanoseconds: 2_000_000)
        }
        let transportStarted = await delayedTransport.didStartFetch()
        XCTAssertTrue(transportStarted)
        XCTAssertTrue(sawTransportStatus || cancellable.status.phase == .fetching)
        cancellable.cancel()
        let cancelled = await refreshTask.value
        XCTAssertFalse(isSuccess(cancelled)); XCTAssertEqual(cancellable.status.phase, .cancelled)
        let transportCancelled = await delayedTransport.wasCancelled()
        XCTAssertTrue(transportCancelled)

        cancellable.quarantineAccount()
        let quarantined = await cancellable.refresh()
        XCTAssertFalse(isSuccess(quarantined)); XCTAssertEqual(cancellable.status.phase, .quarantined)
        cancellable.resetAfterAccountChange()
        for _ in 0..<20 where cancellable.status.phase != .idle {
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        XCTAssertEqual(cancellable.status.phase, .idle)

        let queued = await cancellable.queueItem(item, currentRevisionID: try RevisionID(rawValue: "revision-relaunch"))
        XCTAssertTrue(isSuccess(queued))
        let relaunched = lifecycle(try LocalLibraryStore(url: url), transport: LifecycleFakeTransport(batch: batch))
        let uploaded = await relaunched.uploadPending()
        XCTAssertTrue(isSuccess(uploaded))
        XCTAssertEqual(relaunched.status.phase, .completed)
    }

    func testAccountReviewResetsTheExistingTransportBeforeNextRefresh() async throws {
        let url = storeURL(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let item = try article("account-review")
        let revisionID = try RevisionID(rawValue: "revision-account-review")
        let record = try WiltedRecordCodec().encode(article: item, currentRevisionID: revisionID)
        let batch = try SyncFetchBatch(generationID: "reviewed", records: [record], engineState: Data([3]))
        let transport = LifecycleFakeTransport(batch: batch)
        let probe = SyncFactoryProbe()
        let store = try LocalLibraryStore(url: url)
        let lifecycle = WiltedMacSyncLifecycle(
            store: store,
            transportFactory: {
                await probe.madeFactory()
                return WiltedMacSyncTransportHandle(
                    transport: transport,
                    cancel: { await transport.cancel() },
                    reset: { await probe.reset() }
                )
            }
        )

        let initial = await lifecycle.refresh()
        XCTAssertTrue(isSuccess(initial))
        lifecycle.quarantineAccount()
        for _ in 0..<100 where lifecycle.status.phase != .quarantined {
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        XCTAssertEqual(lifecycle.status.phase, .quarantined)
        lifecycle.resetAfterAccountChange()
        for _ in 0..<100 where lifecycle.status.phase != .idle {
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        XCTAssertEqual(lifecycle.status.phase, .idle)

        let refreshed = await lifecycle.refresh()
        XCTAssertTrue(isSuccess(refreshed))
        let factoryCalls = await probe.factoryCalls
        let resetCalls = await probe.resetCalls
        XCTAssertEqual(factoryCalls, 1)
        XCTAssertEqual(resetCalls, 1)
    }

    private func isSuccess(_ result: Result<Void, Error>) -> Bool {
        if case .success = result { return true }
        return false
    }
}
