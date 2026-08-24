import XCTest
import CryptoKit
import WiltedCloudKit
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
    private let saveGate: LifecycleSaveGate?
    private var fetchStarted = false
    private var saveCalls = 0
    private var savedRecordTypes: [[WiltedRecordType]] = []
    private var cancelled = false

    init(batch: SyncFetchBatch, fetchError: Error? = nil, saveError: Error? = nil, delayNanoseconds: UInt64 = 0,
         saveGate: LifecycleSaveGate? = nil) {
        self.batch = batch; self.fetchError = fetchError; self.saveError = saveError
        self.delayNanoseconds = delayNanoseconds; self.saveGate = saveGate
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
        saveCalls += 1
        await saveGate?.markStarted()
        await saveGate?.waitForRelease()
        if let saveError { throw saveError }
        let acknowledged = changes.map(\.recordID)
        let envelopes = changes.compactMap(\.record)
        savedRecordTypes.append(envelopes.map(\.id.recordType))
        return try SyncSendResult(engineState: Data([8, 8]), acknowledgedRecordIDs: acknowledged, serverEnvelopes: envelopes)
    }

    func didStartFetch() -> Bool { fetchStarted }

    func cancel() { cancelled = true }

    func wasCancelled() -> Bool { cancelled }

    func saveCallCount() -> Int { saveCalls }

    func sentRecordTypes() -> [WiltedRecordType] { savedRecordTypes.flatMap { $0 } }
}

private actor LifecycleSaveGate {
    private var started = false
    private var released = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    func markStarted() {
        started = true
        let waiters = startWaiters
        startWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }

    func waitForStart() async {
        guard !started else { return }
        await withCheckedContinuation { continuation in
            if started { continuation.resume() } else { startWaiters.append(continuation) }
        }
    }

    func release() {
        released = true
        let waiters = releaseWaiters
        releaseWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }

    func waitForRelease() async {
        guard !released else { return }
        await withCheckedContinuation { continuation in
            if released { continuation.resume() } else { releaseWaiters.append(continuation) }
        }
    }
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
                           assetURL: URL? = nil,
                           accountSignals: AsyncStream<CloudKitAccountChangeSignal> = AsyncStream { $0.finish() }) -> WiltedMacSyncLifecycle {
        WiltedMacSyncLifecycle(
            store: store,
            transportFactory: {
                WiltedMacSyncTransportHandle(transport: transport,
                                             cancel: { await transport.cancel() },
                                             accountSignals: accountSignals)
            },
            assetResolver: { _, _ in assetURL }
        )
    }

    func testObservabilityDefaultsToUnavailableIdentityAndRestoresTimestamps() async throws {
        let url = storeURL(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = try LocalLibraryStore(url: url)
        let fetched = Timestamp(Date(timeIntervalSince1970: 1_700_000_100))
        let sent = Timestamp(Date(timeIntervalSince1970: 1_700_000_200))
        try await store.save(syncState: LocalLibrarySyncState(key: "private-zone", lastFetchAt: fetched, lastSendAt: sent))
        let lifecycle = lifecycle(store, transport: LifecycleFakeTransport(
            batch: try SyncFetchBatch(generationID: "empty", records: [], engineState: Data([1]))
        ))
        for _ in 0..<100 where lifecycle.observability.lastSuccessfulFetchAt == nil {
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        XCTAssertEqual(lifecycle.observability.producerIdentity, .unavailable)
        XCTAssertEqual(lifecycle.observability.lastSuccessfulFetchAt, fetched.date)
        XCTAssertEqual(lifecycle.observability.lastSuccessfulSendAt, sent.date)
    }

    func testRefreshReturnsWithCurrentObservability() async throws {
        let url = storeURL(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = try LocalLibraryStore(url: url)
        let lifecycle = lifecycle(store, transport: LifecycleFakeTransport(
            batch: try SyncFetchBatch(generationID: "observability-fetch", records: [], engineState: Data([1]))
        ))

        let result = await lifecycle.refresh()
        let state = try await store.syncState(for: "private-zone")

        XCTAssertTrue(isSuccess(result))
        XCTAssertEqual(lifecycle.observability.lastSuccessfulFetchAt, state?.lastFetchAt?.date)
        XCTAssertNotNil(lifecycle.observability.lastSuccessfulFetchAt)
    }

    func testUploadReturnsWithCurrentObservability() async throws {
        let url = storeURL(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = try LocalLibraryStore(url: url)
        let lifecycle = lifecycle(store, transport: LifecycleFakeTransport(
            batch: try SyncFetchBatch(generationID: "observability-upload", records: [], engineState: Data([1]))
        ))
        let queued = await lifecycle.queueItem(try article("observability-upload"),
                                               currentRevisionID: try RevisionID(rawValue: "revision-observability-upload"))
        XCTAssertTrue(isSuccess(queued))

        let result = await lifecycle.uploadPending()
        let state = try await store.syncState(for: "private-zone")

        XCTAssertTrue(isSuccess(result))
        XCTAssertEqual(lifecycle.observability.lastSuccessfulSendAt, state?.lastSendAt?.date)
        XCTAssertNotNil(lifecycle.observability.lastSuccessfulSendAt)
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

    func testQueuesManifestAndChunkRecordsWithoutCatalogAudioAsset() async throws {
        let url = storeURL(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let item = try article("chunked-publication")
        let revisionID = try RevisionID(rawValue: "revision-chunked-publication")
        let bytes = Data("chunked-mac-media".utf8)
        let chunked = try AudioChunking.chunk(bytes, chunkSize: 3)
        let hash = "sha256:" + SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        let revision = try AudioRevision(itemID: item.itemID, revisionID: revisionID,
                                         durationSeconds: 4, byteCount: Int64(bytes.count),
                                         contentHash: hash, mediaType: "audio/mp4",
                                         createdAt: Timestamp(Date()), schemaVersion: 1)
        let store = try LocalLibraryStore(url: url)
        let lifecycle = lifecycle(store, transport: LifecycleFakeTransport(
            batch: try SyncFetchBatch(generationID: "empty", records: [], engineState: Data([1]))
        ))

        let result = await lifecycle.queueRevision(revision, chunkedFile: chunked)
        XCTAssertTrue(isSuccess(result))
        let pending = try await store.syncRepositoryState()?.pendingChanges ?? []
        XCTAssertEqual(pending.count, 1 + chunked.chunks.count)
        let revisionRecord = try XCTUnwrap(pending.first { $0.recordID.recordType == .revision }?.record)
        XCTAssertNil(revisionRecord.fields["audioAsset"])
        guard case .bytes = revisionRecord.fields["audioManifest"] else {
            return XCTFail("chunked revision must carry the manifest as metadata")
        }
        XCTAssertEqual(pending.filter { $0.recordID.recordType == .revisionChunk }.count, chunked.chunks.count)
        XCTAssertTrue(pending.filter { $0.recordID.recordType == .revisionChunk }.allSatisfy {
            if case .asset = $0.record?.fields["chunkAsset"] { return true }
            return false
        })
    }

    func testRetryingChunkedPublicationIsIdempotent() async throws {
        let url = storeURL(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let item = try article("chunked-retry")
        let revisionID = try RevisionID(rawValue: "revision-chunked-retry")
        let bytes = Data("retryable-chunked-media".utf8)
        let chunked = try AudioChunking.chunk(bytes, chunkSize: 4)
        let hash = "sha256:" + SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        let revision = try AudioRevision(itemID: item.itemID, revisionID: revisionID,
                                         durationSeconds: 4, byteCount: Int64(bytes.count),
                                         contentHash: hash, mediaType: "audio/mp4",
                                         createdAt: Timestamp(Date()), schemaVersion: 1)
        let store = try LocalLibraryStore(url: url)
        let lifecycle = lifecycle(store, transport: LifecycleFakeTransport(
            batch: try SyncFetchBatch(generationID: "empty", records: [], engineState: Data([1]))
        ))

        let firstQueueResult = await lifecycle.queueRevision(revision, chunkedFile: chunked)
        XCTAssertTrue(isSuccess(firstQueueResult))
        let first = try await store.syncRepositoryState()?.pendingChanges ?? []
        let secondQueueResult = await lifecycle.queueRevision(revision, chunkedFile: chunked)
        XCTAssertTrue(isSuccess(secondQueueResult))
        let second = try await store.syncRepositoryState()?.pendingChanges ?? []
        XCTAssertEqual(second.count, first.count)
        XCTAssertEqual(Set(second.map(\.recordID)).count, second.count)
        XCTAssertEqual(Set(first.map(\.recordID)), Set(second.map(\.recordID)))
    }

    func testAutomaticUploadCoalescesTriggersAndDrainsQueuedPublication() async throws {
        let url = storeURL(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let item = try article("automatic-publication")
        let revisionID = try RevisionID(rawValue: "revision-automatic-publication")
        let batch = try SyncFetchBatch(generationID: "empty", records: [], engineState: Data([1]))
        let transport = LifecycleFakeTransport(batch: batch)
        let store = try LocalLibraryStore(url: url)
        let lifecycle = lifecycle(store, transport: transport)

        let queued = await lifecycle.queueItem(item, currentRevisionID: revisionID)
        XCTAssertTrue(isSuccess(queued))
        lifecycle.startAutomaticUpload()
        lifecycle.startAutomaticUpload()

        for _ in 0..<200 {
            if lifecycle.status.phase == .completed,
               (try? await store.syncRepositoryState())?.pendingChanges.isEmpty == true { break }
            try await Task.sleep(nanoseconds: 1_000_000)
        }

        let saveCallCount = await transport.saveCallCount()
        let pendingCount = try await store.syncRepositoryState()?.pendingChanges.count
        XCTAssertEqual(saveCallCount, 1)
        XCTAssertEqual(pendingCount, 0)
        XCTAssertEqual(lifecycle.status.phase, .completed)
    }

    func testAutomaticUploadSchedulesFollowUpForWorkCompletedDuringActiveSend() async throws {
        let url = storeURL(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let first = try article("automatic-first")
        let second = try article("automatic-second")
        let batch = try SyncFetchBatch(generationID: "empty", records: [], engineState: Data([1]))
        let saveGate = LifecycleSaveGate()
        let transport = LifecycleFakeTransport(batch: batch, saveGate: saveGate)
        let store = try LocalLibraryStore(url: url)
        let lifecycle = lifecycle(store, transport: transport)

        let firstQueued = await lifecycle.queueItem(first, currentRevisionID: try RevisionID(rawValue: "revision-automatic-first"))
        XCTAssertTrue(isSuccess(firstQueued))
        lifecycle.startAutomaticUpload()
        await saveGate.waitForStart()

        let secondQueued = await lifecycle.queueItem(second, currentRevisionID: try RevisionID(rawValue: "revision-automatic-second"))
        XCTAssertTrue(isSuccess(secondQueued))
        lifecycle.startAutomaticUpload()
        await saveGate.release()

        for _ in 0..<200 {
            if lifecycle.status.phase == .completed,
               (try? await store.syncRepositoryState())?.pendingChanges.isEmpty == true { break }
            try await Task.sleep(nanoseconds: 1_000_000)
        }

        let saveCallCount = await transport.saveCallCount()
        let pendingCount = try await store.syncRepositoryState()?.pendingChanges.count
        XCTAssertEqual(saveCallCount, 2)
        XCTAssertEqual(pendingCount, 0)
    }

    func testStartupReconciliationQueuesReadyRevisionAndAutomaticallySends() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("wilted-mac-startup-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let libraryURL = root.appendingPathComponent("library.sqlite")
        let mediaURL = root.appendingPathComponent("media.m4a")
        let item = try article("startup-reconciliation")
        let bytes = Data("startup-ready-media".utf8)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try bytes.write(to: mediaURL)
        let hash = "sha256:" + SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        let revision = try AudioRevision(
            itemID: item.itemID, revisionID: try RevisionID(rawValue: "revision-startup-reconciliation"),
            durationSeconds: 4, byteCount: Int64(bytes.count), contentHash: hash,
            mediaType: "audio/mp4", createdAt: Timestamp(Date()), schemaVersion: 1
        )
        do {
            let store = try LocalLibraryStore(url: libraryURL)
            try await store.save(article: item)
            try await store.saveReadyRevision(revision, mediaURL: mediaURL)
        }

        let transport = LifecycleFakeTransport(batch: try SyncFetchBatch(
            generationID: "empty", records: [], engineState: Data([1])
        ))
        do {
            let model = WiltedMacModel(
                arguments: [],
                syncTransportFactory: {
                    WiltedMacSyncTransportHandle(
                        transport: transport,
                        cancel: { await transport.cancel() }
                    )
                },
                stateDirectoryOverride: root
            )

            // Startup and foreground callbacks can arrive together; only one reconciliation
            // should queue this durable revision. Publication intentionally uses two transport
            // sends so chunks are acknowledged before the manifest and item pointer.
            model.reconcileSyncOnLaunchOrForeground()
            model.reconcileSyncOnLaunchOrForeground()
            for _ in 0..<300 {
                if await transport.saveCallCount() == 2,
                   model.syncStatus.phase == .completed,
                   model.syncObservability.lastSuccessfulSendAt != nil { break }
                try await Task.sleep(nanoseconds: 1_000_000)
            }

            let saveCallCount = await transport.saveCallCount()
            XCTAssertEqual(saveCallCount, 2)
            XCTAssertEqual(model.syncStatus.phase, .completed)
            XCTAssertNotNil(model.syncObservability.lastSuccessfulSendAt)
            let sentTypes = await transport.sentRecordTypes()
            XCTAssertTrue(sentTypes.contains(.item))
            XCTAssertTrue(sentTypes.contains(.revision))
            XCTAssertTrue(sentTypes.contains(.revisionChunk))
        }
    }

    func testStartupReconciliationSendsAlreadyQueuedManifestAndChunks() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("wilted-mac-startup-pending-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let libraryURL = root.appendingPathComponent("library.sqlite")
        let mediaURL = root.appendingPathComponent("media.m4a")
        let item = try article("startup-pending")
        let bytes = Data("startup-pending-media".utf8)
        let chunked = try AudioChunking.chunk(bytes, chunkSize: 3)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try bytes.write(to: mediaURL)
        let hash = "sha256:" + SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        let revision = try AudioRevision(
            itemID: item.itemID, revisionID: try RevisionID(rawValue: "revision-startup-pending"),
            durationSeconds: 4, byteCount: Int64(bytes.count), contentHash: hash,
            mediaType: "audio/mp4", createdAt: Timestamp(Date()), schemaVersion: 1
        )
        let transport = LifecycleFakeTransport(batch: try SyncFetchBatch(
            generationID: "empty", records: [], engineState: Data([1])
        ))
        do {
            let store = try LocalLibraryStore(url: libraryURL)
            try await store.save(article: item)
            try await store.saveReadyRevision(revision, mediaURL: mediaURL)
            let queueLifecycle = lifecycle(store, transport: transport)
            let queued = await queueLifecycle.queueRevision(revision, chunkedFile: chunked)
            XCTAssertTrue(isSuccess(queued))
        }

        do {
            let model = WiltedMacModel(
                arguments: [],
                syncTransportFactory: {
                    WiltedMacSyncTransportHandle(
                        transport: transport,
                        cancel: { await transport.cancel() }
                    )
                },
                stateDirectoryOverride: root
            )

            model.reconcileSyncOnLaunchOrForeground()
            for _ in 0..<300 {
                if await transport.saveCallCount() == 2,
                   model.syncStatus.phase == .completed,
                   model.syncObservability.lastSuccessfulSendAt != nil { break }
                try await Task.sleep(nanoseconds: 1_000_000)
            }

            let saveCallCount = await transport.saveCallCount()
            XCTAssertEqual(saveCallCount, 2)
            XCTAssertEqual(model.syncStatus.phase, .completed)
            XCTAssertNotNil(model.syncObservability.lastSuccessfulSendAt)
            let sentTypes = await transport.sentRecordTypes()
            XCTAssertTrue(sentTypes.contains(.revision))
            XCTAssertTrue(sentTypes.contains(.revisionChunk))
        }
    }

    func testEmptyPersistedEngineStateReadsAsAbsentRatherThanCorrupt() {
        // LocalLibraryStore mirrors the engine bytes into a non-optional column and writes
        // zero bytes for "no state yet", so a fresh install reads back empty non-nil Data.
        // Decoding that as a CKSyncEngine serialization reported stateCorrupt on the first
        // sync of every fresh install and after every account reset.
        XCTAssertNil(WiltedMacSyncEngineState.normalized(Data()))
        XCTAssertNil(WiltedMacSyncEngineState.normalized(nil))
        XCTAssertEqual(WiltedMacSyncEngineState.normalized(Data([7, 7])), Data([7, 7]))
    }

    func testAFailedRevisionQueueReachesABoundedFailureInsteadOfParkingOnStaging() async throws {
        // queueRevision's Result is discarded by the model, so the status is the only
        // surface a failure can reach. Without a terminal status the panel sits on
        // "Queued WiltedRevision publication." forever and reads as still working.
        let url = storeURL(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let item = try article("unqueueable")
        let revisionID = try RevisionID(rawValue: "revision-unqueueable")
        let hash = "sha256:" + SHA256.hash(data: Data("absent-media".utf8)).map { String(format: "%02x", $0) }.joined()
        let revision = try AudioRevision(itemID: item.itemID, revisionID: revisionID, durationSeconds: 4, byteCount: 12,
                                         contentHash: hash, mediaType: "audio/mp4", createdAt: Timestamp(Date()), schemaVersion: 1)
        let batch = try SyncFetchBatch(generationID: "empty", records: [], engineState: Data([1]))
        let transport = LifecycleFakeTransport(batch: batch)
        // No assetURL and no stored revision, so the media can never be resolved.
        let lifecycle = lifecycle(try LocalLibraryStore(url: url), transport: transport)

        let result = await lifecycle.queueRevision(revision, audioAsset: try WiltedAsset(assetID: "absent", contentHash: hash))

        XCTAssertFalse(isSuccess(result))
        XCTAssertEqual(lifecycle.status.phase, .failed)
        XCTAssertTrue(lifecycle.status.detail.hasPrefix("Could not queue WiltedRevision publication:"),
                      "unexpected detail: \(lifecycle.status.detail)")
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

    func testAccountReviewReleasesQuarantinedWorkSoTheNextUploadDrainsIt() async throws {
        let url = storeURL(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let item = try article("account-release")
        let revisionID = try RevisionID(rawValue: "revision-account-release")
        let recordID = try WiltedRecordID.item(item.itemID)
        let batch = try SyncFetchBatch(generationID: "released", records: [], engineState: Data([3]))
        let transport = LifecycleFakeTransport(batch: batch)
        let lifecycle = lifecycle(try LocalLibraryStore(url: url), transport: transport)

        let queued = await lifecycle.queueItem(item, currentRevisionID: revisionID)
        XCTAssertTrue(isSuccess(queued))
        lifecycle.quarantineAccount()
        for _ in 0..<200 where lifecycle.status.phase != .quarantined {
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        XCTAssertEqual(lifecycle.status.phase, .quarantined)

        lifecycle.resetAfterAccountChange()
        for _ in 0..<200 where lifecycle.status.phase != .idle {
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        XCTAssertEqual(lifecycle.status.phase, .idle)

        // Before the release, the quarantine's conflicted marks survived review and the
        // coordinator filtered this change out of every batch, so the upload "succeeded"
        // while the work stayed queued forever.
        let uploaded = await lifecycle.uploadPending()
        XCTAssertTrue(isSuccess(uploaded))
        let store = try LocalLibraryStore(url: url)
        let state = try await store.syncRepositoryState()
        XCTAssertEqual(state?.pendingChanges.count, 0)
        XCTAssertEqual(state?.conflictedRecordIDs.isEmpty, true)
        XCTAssertEqual(state?.remoteAcknowledgedRecordIDs.contains(recordID), true)
    }

    func testRelaunchKeepsTheAccountReviewReachableAndNeverReportsABlockedUploadAsDone() async throws {
        let url = storeURL(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let item = try article("relaunch-quarantine")
        let revisionID = try RevisionID(rawValue: "revision-relaunch-quarantine")
        let recordID = try WiltedRecordID.item(item.itemID)
        let batch = try SyncFetchBatch(generationID: "restored", records: [], engineState: Data([3]))

        let launched = lifecycle(try LocalLibraryStore(url: url), transport: LifecycleFakeTransport(batch: batch))
        let queued = await launched.queueItem(item, currentRevisionID: revisionID)
        XCTAssertTrue(isSuccess(queued))
        launched.quarantineAccount()
        for _ in 0..<200 where launched.status.phase != .quarantined {
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        XCTAssertEqual(launched.status.phase, .quarantined)

        // Relaunch. The quarantine flag was in-memory only, so this surface starts clean
        // while the persisted quarantine still conflicts every queued record.
        let relaunched = lifecycle(try LocalLibraryStore(url: url), transport: LifecycleFakeTransport(batch: batch))
        XCTAssertFalse(relaunched.isQuarantined)

        // The send filters conflicted records out and returns cleanly, so before the fix
        // this reported a completed upload while nothing left the device.
        let blocked = await relaunched.uploadPending()
        XCTAssertFalse(isSuccess(blocked))
        XCTAssertEqual(relaunched.status.phase, .failed)
        XCTAssertEqual(relaunched.status.detail,
                       SyncCoordinator.blockedMessage(count: 1, accountReviewRequired: true))

        // The review control renders only for the quarantined phase, so without the
        // durable restore the release path is unreachable for the life of the install.
        relaunched.restoreAccountQuarantine()
        for _ in 0..<200 where relaunched.status.phase != .quarantined {
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        XCTAssertEqual(relaunched.status.phase, .quarantined)
        XCTAssertTrue(relaunched.isQuarantined)

        relaunched.resetAfterAccountChange()
        for _ in 0..<200 where relaunched.status.phase != .idle {
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        let uploaded = await relaunched.uploadPending()
        XCTAssertTrue(isSuccess(uploaded))
        let state = try await LocalLibraryStore(url: url).syncRepositoryState()
        let pendingCount = state?.pendingChanges.count
        let acknowledged = state?.remoteAcknowledgedRecordIDs.contains(recordID)
        XCTAssertEqual(pendingCount, 0)
        XCTAssertEqual(acknowledged, true)
    }

    func testRestoringTheQuarantineIgnoresAGenuineRemoteConflict() async throws {
        let url = storeURL(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let item = try article("remote-conflict")
        let revisionID = try RevisionID(rawValue: "revision-remote-conflict")
        let record = try WiltedRecordCodec().encode(article: item, currentRevisionID: revisionID)
        let store = try LocalLibraryStore(url: url)
        let repository = try await LocalLibrarySyncRepository(store: store)
        try await repository.enqueue(try SyncPendingChange(operation: .create, recordID: record.id, record: record))
        // A server rejection records the server version; that conflict is not an account
        // review gate and must not make a relaunch look quarantined.
        try await repository.acknowledge(try SyncSendResult(
            engineState: Data([7]),
            failures: [SyncSendFailure(recordID: record.id, disposition: .conflict, serverRecord: record)]))

        let batch = try SyncFetchBatch(generationID: "remote-conflict", records: [], engineState: Data([3]))
        let relaunched = lifecycle(try LocalLibraryStore(url: url), transport: LifecycleFakeTransport(batch: batch))
        relaunched.restoreAccountQuarantine()
        try await Task.sleep(nanoseconds: 20_000_000)
        XCTAssertFalse(relaunched.isQuarantined)

        let blocked = await relaunched.uploadPending()
        XCTAssertFalse(isSuccess(blocked))
        XCTAssertEqual(relaunched.status.detail,
                       SyncCoordinator.blockedMessage(count: 1, accountReviewRequired: false))
    }

    func testAPartlyBlockedUploadNamesWhatMovedAndWhatIsStillHeld() async throws {
        let url = storeURL(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let held = try article("partly-held")
        let heldRecord = try WiltedRecordCodec().encode(article: held, currentRevisionID: try RevisionID(rawValue: "revision-partly-held"))
        let clean = try article("partly-clean")
        let cleanRecord = try WiltedRecordCodec().encode(article: clean, currentRevisionID: try RevisionID(rawValue: "revision-partly-clean"))
        let store = try LocalLibraryStore(url: url)
        let repository = try await LocalLibrarySyncRepository(store: store)
        try await repository.enqueue(try SyncPendingChange(operation: .create, recordID: heldRecord.id, record: heldRecord))
        try await repository.enqueue(try SyncPendingChange(operation: .create, recordID: cleanRecord.id, record: cleanRecord))
        try await repository.acknowledge(try SyncSendResult(
            engineState: Data([7]),
            failures: [SyncSendFailure(recordID: heldRecord.id, disposition: .conflict, serverRecord: heldRecord)]))

        let batch = try SyncFetchBatch(generationID: "partly-blocked", records: [], engineState: Data([3]))
        let relaunched = lifecycle(try LocalLibraryStore(url: url), transport: LifecycleFakeTransport(batch: batch))
        let uploaded = await relaunched.uploadPending()
        XCTAssertTrue(isSuccess(uploaded))
        XCTAssertEqual(relaunched.status.phase, .completed)
        // A send that moved one record and left another behind must say so; a bare
        // "uploaded" here reads as a drained queue while a record is still stranded.
        XCTAssertEqual(relaunched.status.detail, "Uploaded 1 change. 1 change is held by unresolved conflicts.")
        let state = try await LocalLibraryStore(url: url).syncRepositoryState()
        let stillPending = state?.pendingChanges.map(\.recordID)
        XCTAssertEqual(stillPending, [heldRecord.id])
        XCTAssertEqual(state?.remoteAcknowledgedRecordIDs.contains(cleanRecord.id), true)
    }

    func testAnAdoptedFirstSignInRecordsTheOwnerAndLetsTheUploadFinish() async throws {
        let url = storeURL(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let item = try article("adopted")
        let recordID = try WiltedRecordID.item(item.itemID)
        let batch = try SyncFetchBatch(generationID: "adopted", records: [], engineState: Data([3]))
        let (signals, continuation) = AsyncStream<CloudKitAccountChangeSignal>.makeStream()
        let lifecycle = lifecycle(try LocalLibraryStore(url: url), transport: LifecycleFakeTransport(batch: batch),
                                  accountSignals: signals)
        let queued = await lifecycle.queueItem(item, currentRevisionID: try RevisionID(rawValue: "revision-adopted"))
        XCTAssertTrue(isSuccess(queued))
        // The account observer starts with the first operation, which is also where a real
        // sign-in event originates.
        _ = await lifecycle.refresh()

        // A sync engine with no persisted state always reports a first sign-in. Quarantining
        // it deadlocked the first-ever sync: no send meant no engine state, which meant
        // another first sign-in on the next launch, forever.
        let token = CloudKitAccountIdentity.token(for: "_first-owner")
        continuation.yield(.ownershipAdopted(token: token))
        for _ in 0..<200 where (try? await LocalLibraryStore(url: url).syncRepositoryState())??.accountOwnerToken == nil {
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        XCTAssertFalse(lifecycle.isQuarantined)
        let uploaded = await lifecycle.uploadPending()
        XCTAssertTrue(isSuccess(uploaded))
        let state = try await LocalLibraryStore(url: url).syncRepositoryState()
        XCTAssertEqual(state?.accountOwnerToken, token)
        XCTAssertEqual(state?.pendingChanges.count, 0)
        XCTAssertEqual(state?.remoteAcknowledgedRecordIDs.contains(recordID), true)
    }

    func testASignInTheAdapterFlaggedForReviewStillQuarantinesAndStaysReviewable() async throws {
        let url = storeURL(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let item = try article("flagged")
        let recordID = try WiltedRecordID.item(item.itemID)
        let batch = try SyncFetchBatch(generationID: "flagged", records: [], engineState: Data([3]))
        let (signals, continuation) = AsyncStream<CloudKitAccountChangeSignal>.makeStream()
        let lifecycle = lifecycle(try LocalLibraryStore(url: url), transport: LifecycleFakeTransport(batch: batch),
                                  accountSignals: signals)
        let queued = await lifecycle.queueItem(item, currentRevisionID: try RevisionID(rawValue: "revision-flagged"))
        XCTAssertTrue(isSuccess(queued))
        _ = await lifecycle.refresh()

        continuation.yield(.quarantineRequired(.signIn))
        for _ in 0..<200 where lifecycle.status.phase != .quarantined {
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        XCTAssertTrue(lifecycle.isQuarantined)
        XCTAssertEqual(lifecycle.status.detail, "iCloud sign-in detected. Review local sync before continuing.")
        let quarantinedState = try await LocalLibraryStore(url: url).syncRepositoryState()
        XCTAssertEqual(quarantinedState?.conflictedRecordIDs.contains(recordID), true)
    }

    private func isSuccess(_ result: Result<Void, Error>) -> Bool {
        if case .success = result { return true }
        return false
    }
}
