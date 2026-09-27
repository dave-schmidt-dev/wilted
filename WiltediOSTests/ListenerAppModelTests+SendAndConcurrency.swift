import CryptoKit
import MediaPlayer
import XCTest
@testable import WiltediOS
import WiltedDomain
@testable import WiltedListener
import WiltedSync
import CloudKit
import WiltedCloudKit

extension ListenerAppModelTests {
    func testPlaybackSendForwardsTheExactEligibleChangesToAcknowledgement() async throws {
        let url = URL(string: "https://example.test/forwarded-playback")!
        let itemID = try ItemID.derive(from: url)
        let revisionID = try RevisionID(rawValue: "revision-forwarded-playback")
        let asset = try WiltedAsset(assetID: "audio-forwarded-playback",
                                    contentHash: "sha256:" + String(repeating: "c", count: 64))
        let codec = WiltedRecordCodec()
        let article = try Article(itemID: itemID, canonicalURL: url, title: "Forwarded playback",
                                  source: "Test", createdAt: Timestamp(Date()))
        let revision = try AudioRevision(itemID: itemID, revisionID: revisionID, durationSeconds: 30,
                                         byteCount: 1, contentHash: asset.contentHash,
                                         mediaType: "audio/mpeg", createdAt: Timestamp(Date()), schemaVersion: 1)
        let playback = try PlaybackState(itemID: itemID, revisionID: revisionID, sessionID: "forwarded",
                                         sequence: 1, positionSeconds: 5, durationSeconds: 30,
                                         completed: false, intent: .progress, deviceID: "iphone",
                                         updatedAt: Timestamp(Date()))
        let itemRecord = try codec.encode(article: article, currentRevisionID: revisionID)
        let revisionRecord = try codec.encode(revision: revision, audioAsset: asset)
        let playbackRecord = try codec.encode(playback: playback)
        let change = try SyncPendingChange(operation: .update, recordID: playbackRecord.id, record: playbackRecord)
        let repository = StaticSyncRepository(state: SyncRepositoryState(
            records: [itemRecord, revisionRecord, playbackRecord], engineState: Data([1]), pendingChanges: [change]
        ))
        let transport = RecordingSyncTransport()
        let model = WiltedListenerAppModel(repository: repository, transport: transport)

        await model.refresh()
        await model.sendPending()

        let saved = await transport.savedChanges()
        let acknowledged = await repository.acknowledgedBatches()
        XCTAssertEqual(saved, [[change]])
        XCTAssertEqual(acknowledged, [[change]])
    }

    func testPlaybackConflictRebaseIsSentWithoutLeavingTheUIStuck() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let repository = try ListenerRepository(directoryURL: root)
        let url = URL(string: "https://example.test/rebased-playback")!
        let itemID = try ItemID.derive(from: url)
        let revisionID = try RevisionID(rawValue: "revision-rebased-playback")
        let asset = try WiltedAsset(assetID: "audio-rebased-playback",
                                    contentHash: "sha256:" + String(repeating: "a", count: 64))
        let codec = WiltedRecordCodec()
        let article = try Article(itemID: itemID, canonicalURL: url, title: "Rebased playback",
                                  source: "Test", createdAt: Timestamp(Date()))
        let revision = try AudioRevision(itemID: itemID, revisionID: revisionID, durationSeconds: 30,
                                         byteCount: 1, contentHash: asset.contentHash,
                                         mediaType: "audio/mpeg", createdAt: Timestamp(Date()), schemaVersion: 1)
        let local = try PlaybackState(itemID: itemID, revisionID: revisionID, sessionID: "session",
                                      sequence: 3, positionSeconds: 15, durationSeconds: 30,
                                      completed: false, intent: .progress, deviceID: "iphone",
                                      updatedAt: Timestamp(Date()))
        let localRecord = try codec.encode(
            playback: local,
            sidecar: WiltedOpaqueSidecar(changeTag: "local-tag", encodedSystemFields: Data([1]))
        )
        let remote = try codec.encode(
            playback: try PlaybackState(itemID: itemID, revisionID: revisionID, sessionID: "session",
                                         sequence: 2, positionSeconds: 10, durationSeconds: 30,
                                         completed: false, intent: .progress, deviceID: "mac",
                                         updatedAt: Timestamp(Date())),
            sidecar: WiltedOpaqueSidecar(changeTag: "server-tag", encodedSystemFields: Data([2]))
        )
        try await repository.commit(try await repository.stage(try SyncFetchBatch(
            generationID: "catalog", records: [try codec.encode(article: article, currentRevisionID: revisionID),
                                                    try codec.encode(revision: revision, audioAsset: asset)],
            engineState: Data([1])
        )))
        try await repository.enqueue(try SyncPendingChange(operation: .update, recordID: localRecord.id, record: localRecord))
        let transport = RebasedPlaybackTransport(serverRecord: remote)
        let model = WiltedListenerAppModel(repository: repository, transport: transport)

        await model.refresh()
        await model.sendPending()

        let batches = await transport.savedBatches()
        XCTAssertEqual(batches.count, 2)
        XCTAssertEqual(batches[1].first?.record?.sidecar?.changeTag, "server-tag")
        let finalState = await repository.state()
        XCTAssertEqual(finalState.pendingChanges, [])
        XCTAssertEqual(model.syncPhase, .ready)
    }

    func testPlaybackSendAcknowledgementReconcilesAnAlreadyCachedItemAsDownloaded() async throws {
        let fixture = try makeChunkedCatalogFixture()
        let revisionID = try RevisionID(rawValue: "revision-chunked-listener")
        let playback = try PlaybackState(
            itemID: fixture.itemID,
            revisionID: revisionID,
            sessionID: "cached-send",
            sequence: 1,
            positionSeconds: 5,
            durationSeconds: 30,
            completed: false,
            intent: .progress,
            deviceID: "iphone",
            updatedAt: Timestamp(Date())
        )
        let playbackRecord = try WiltedRecordCodec().encode(playback: playback)
        let change = try SyncPendingChange(operation: .update, recordID: playbackRecord.id, record: playbackRecord)
        try await fixture.repository.enqueue(change)
        let model = WiltedListenerAppModel(
            repository: fixture.repository,
            transport: RecordingSyncTransport(),
            cache: fixture.cache
        )

        await model.refresh()
        XCTAssertEqual(model.items.first?.state, .metadataOnly)
        _ = try await fixture.cache.store(data: fixture.bytes, asset: fixture.asset)

        await model.sendPending()

        XCTAssertEqual(model.items.first?.state, .downloaded,
                       "send acknowledgement must reconcile an asset that was cached while it was in flight")
    }

    func testRemoteDeletionRetainsSharedCachedAudioForTheSurvivingItem() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("shared-cache-\(UUID().uuidString)")
        let repository = try ListenerRepository(directoryURL: root.appendingPathComponent("Repository", isDirectory: true))
        let cache = try ListenerAudioCache(rootURL: root.appendingPathComponent("Audio", isDirectory: true))
        let bytes = Data("shared-cached-audio".utf8)
        let contentHash = "sha256:" + SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        let firstURL = URL(string: "https://example.test/shared-first")!
        let secondURL = URL(string: "https://example.test/shared-second")!
        let firstItemID = try ItemID.derive(from: firstURL)
        let secondItemID = try ItemID.derive(from: secondURL)
        let firstRevisionID = try RevisionID(rawValue: "shared-first-revision")
        let secondRevisionID = try RevisionID(rawValue: "shared-second-revision")
        let firstAsset = try WiltedAsset(assetID: "shared-first-audio", contentHash: contentHash)
        let secondAsset = try WiltedAsset(assetID: "shared-second-audio", contentHash: contentHash)
        let firstArticle = try Article(itemID: firstItemID, canonicalURL: firstURL, title: "Shared first",
                                       source: "Test", createdAt: Timestamp(Date()))
        let secondArticle = try Article(itemID: secondItemID, canonicalURL: secondURL, title: "Shared second",
                                        source: "Test", createdAt: Timestamp(Date()))
        let firstRevision = try AudioRevision(itemID: firstItemID, revisionID: firstRevisionID, durationSeconds: 30,
                                              byteCount: Int64(bytes.count), contentHash: contentHash,
                                              mediaType: "audio/mpeg", createdAt: Timestamp(Date()), schemaVersion: 1)
        let secondRevision = try AudioRevision(itemID: secondItemID, revisionID: secondRevisionID, durationSeconds: 30,
                                               byteCount: Int64(bytes.count), contentHash: contentHash,
                                               mediaType: "audio/mpeg", createdAt: Timestamp(Date()), schemaVersion: 1)
        let codec = WiltedRecordCodec()
        let seed = [
            try codec.encode(article: firstArticle, currentRevisionID: firstRevisionID),
            try codec.encode(revision: firstRevision, audioAsset: firstAsset),
            try codec.encode(article: secondArticle, currentRevisionID: secondRevisionID),
            try codec.encode(revision: secondRevision, audioAsset: secondAsset)
        ]
        try await repository.commit(try await repository.stage(
            try SyncFetchBatch(generationID: "shared-seed", records: seed, engineState: Data([1]))
        ))
        _ = try await cache.store(data: bytes, asset: firstAsset)
        let transport = SequencedSyncTransport(batches: [
            try SyncFetchBatch(generationID: "shared-warmup", records: [], engineState: Data([2])),
            try SyncFetchBatch(generationID: "shared-delete", records: [], engineState: Data([3]),
                               deletedRecordIDs: [try WiltedRecordID.item(firstItemID)])
        ])
        let playback = ListenerPlaybackController(cache: cache, engine: FakeAudioEngine(duration: 30),
                                                  session: FakeAudioSession(), nowPlaying: FakeNowPlaying())
        let model = WiltedListenerAppModel(repository: repository, transport: transport, cache: cache, playback: playback)

        await model.refresh()
        XCTAssertEqual(model.items.filter { $0.state == .downloaded }.count, 2)

        await model.refresh()

        XCTAssertEqual(model.items.first(where: { $0.itemID == firstItemID })?.state, .deleted)
        XCTAssertEqual(model.items.first(where: { $0.itemID == secondItemID })?.state, .downloaded)
        let survivingURL = await cache.url(for: secondAsset)
        XCTAssertNotNil(survivingURL)
        await model.play(itemID: secondItemID)
        XCTAssertEqual(model.playbackPhase, .playing)
    }

    func testOneRecordRevisionPointerDeltaReclaimsSupersededCachedAudio() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("revision-cache-\(UUID().uuidString)")
        let repository = try ListenerRepository(directoryURL: root.appendingPathComponent("Repository", isDirectory: true))
        let cache = try ListenerAudioCache(rootURL: root.appendingPathComponent("Audio", isDirectory: true))
        let itemURL = URL(string: "https://example.test/revision-replacement")!
        let itemID = try ItemID.derive(from: itemURL)
        let oldRevisionID = try RevisionID(rawValue: "revision-old")
        let newRevisionID = try RevisionID(rawValue: "revision-new")
        let oldBytes = Data("old-cached-audio".utf8)
        let newBytes = Data("new-cached-audio".utf8)
        let oldHash = "sha256:" + SHA256.hash(data: oldBytes).map { String(format: "%02x", $0) }.joined()
        let newHash = "sha256:" + SHA256.hash(data: newBytes).map { String(format: "%02x", $0) }.joined()
        let oldAsset = try WiltedAsset(assetID: "old-audio", contentHash: oldHash)
        let newAsset = try WiltedAsset(assetID: "new-audio", contentHash: newHash)
        let article = try Article(itemID: itemID, canonicalURL: itemURL, title: "Replacement",
                                  source: "Test", createdAt: Timestamp(Date()))
        let oldRevision = try AudioRevision(itemID: itemID, revisionID: oldRevisionID, durationSeconds: 30,
                                            byteCount: Int64(oldBytes.count), contentHash: oldHash,
                                            mediaType: "audio/mpeg", createdAt: Timestamp(Date()), schemaVersion: 1)
        let newRevision = try AudioRevision(itemID: itemID, revisionID: newRevisionID, durationSeconds: 30,
                                            byteCount: Int64(newBytes.count), contentHash: newHash,
                                            mediaType: "audio/mpeg", createdAt: Timestamp(Date()), schemaVersion: 1)
        let codec = WiltedRecordCodec()
        let oldArticleRecord = try codec.encode(article: article, currentRevisionID: oldRevisionID)
        let newArticleRecord = try codec.encode(article: article, currentRevisionID: newRevisionID)
        try await repository.commit(try await repository.stage(
            try SyncFetchBatch(generationID: "revision-seed", records: [
                oldArticleRecord,
                try codec.encode(revision: oldRevision, audioAsset: oldAsset),
                try codec.encode(revision: newRevision, audioAsset: newAsset)
            ], engineState: Data([1]))
        ))
        _ = try await cache.store(data: oldBytes, asset: oldAsset)
        let transport = SequencedSyncTransport(batches: [
            try SyncFetchBatch(generationID: "revision-warmup", records: [], engineState: Data([2])),
            try SyncFetchBatch(generationID: "revision-pointer-update", records: [newArticleRecord], engineState: Data([3]))
        ])
        let model = WiltedListenerAppModel(repository: repository, transport: transport, cache: cache)

        await model.refresh()
        XCTAssertEqual(model.items.first?.revisionID, oldRevisionID)
        XCTAssertEqual(model.items.first?.state, .downloaded)
        _ = try await cache.store(data: newBytes, asset: newAsset)

        await model.refresh()

        XCTAssertEqual(model.items.first?.revisionID, newRevisionID)
        XCTAssertEqual(model.items.first?.state, .downloaded)
        let oldURL = await cache.url(for: oldAsset)
        let newURL = await cache.url(for: newAsset)
        XCTAssertNil(oldURL)
        XCTAssertNotNil(newURL)
    }

    func testConcurrentRefreshSuccessAndFailurePreservePlayingPhaseAndLivePosition() async throws {
        let transport = BlockingSyncTransport()
        let harness = try await PlaybackHarness.make(transport: transport)
        let initialRefresh = Task { await harness.model.refresh() }
        for _ in 0..<100 {
            if await transport.fetchCountValue() == 1 { break }
            await Task.yield()
        }
        await transport.releaseFetch()
        await initialRefresh.value
        await harness.model.play(itemID: harness.itemID)
        harness.engine.currentTime = 11
        await harness.model.refreshNowPlayingReadout()

        let successfulRefresh = Task { await harness.model.refresh() }
        for _ in 0..<100 {
            if await transport.fetchCountValue() == 2 { break }
            await Task.yield()
        }
        XCTAssertTrue(harness.model.syncPhase.isBusy)
        XCTAssertEqual(harness.model.playbackPhase, .playing)
        XCTAssertEqual(harness.model.selectedPlayback?.positionSeconds, 11)
        XCTAssertTrue(harness.engine.isPlaying)
        await transport.releaseFetch()
        await successfulRefresh.value
        XCTAssertEqual(harness.model.syncPhase, .ready)
        XCTAssertEqual(harness.model.playbackPhase, .playing)
        XCTAssertEqual(harness.model.selectedPlayback?.positionSeconds, 11)

        harness.engine.currentTime = 17
        await harness.model.refreshNowPlayingReadout()
        let failedRefresh = Task { await harness.model.refresh() }
        for _ in 0..<100 {
            if await transport.fetchCountValue() == 3 { break }
            await Task.yield()
        }
        await transport.releaseFetch(failing: true)
        await failedRefresh.value

        guard case .failed(_, retryable: true) = harness.model.syncPhase else {
            return XCTFail("the failed refresh must remain a retryable library phase")
        }
        XCTAssertEqual(harness.model.playbackPhase, .playing)
        XCTAssertEqual(harness.model.selectedPlayback?.positionSeconds, 17)
        XCTAssertTrue(harness.engine.isPlaying)
    }

    func testConcurrentDownloadPreservesPlayingPhaseAndLivePosition() async throws {
        let loader = try BlockingAssetLoader()
        let harness = try await PlaybackHarness.make(
            includeSecondItem: true,
            cacheSecondItem: false,
            assetLoader: { recordID, asset in
                await loader.load(recordID: recordID, asset: asset)
            }
        )
        let secondItemID = try XCTUnwrap(harness.secondItemID)
        await harness.model.refresh()
        await harness.model.play(itemID: harness.itemID)
        harness.engine.currentTime = 12
        await harness.model.refreshNowPlayingReadout()

        let download = Task { await harness.model.download(itemID: secondItemID) }
        let downloadRequested = await loader.waitUntilRequested()
        XCTAssertTrue(downloadRequested)
        XCTAssertTrue(harness.model.syncPhase.isBusy)
        XCTAssertEqual(harness.model.playbackPhase, .playing)
        XCTAssertEqual(harness.model.selectedPlayback?.positionSeconds, 12)
        XCTAssertTrue(harness.engine.isPlaying)

        await loader.releaseLoad()
        await download.value
        XCTAssertEqual(harness.model.syncPhase, .ready)
        XCTAssertEqual(harness.model.playbackPhase, .playing)
        XCTAssertEqual(harness.model.selectedPlayback?.positionSeconds, 12)
        XCTAssertEqual(harness.model.items.first(where: { $0.itemID == secondItemID })?.state, .downloaded)
    }

    func testSendQueuesBehindConcurrentRefreshAndIsNotDroppedWhilePlaying() async throws {
        let transport = BlockingSyncTransport()
        let harness = try await PlaybackHarness.make(transport: transport)
        let initialRefresh = Task { await harness.model.refresh() }
        for _ in 0..<100 {
            if await transport.fetchCountValue() == 1 { break }
            await Task.yield()
        }
        await transport.releaseFetch()
        await initialRefresh.value
        await harness.model.play(itemID: harness.itemID)
        harness.engine.currentTime = 9
        await harness.model.refreshNowPlayingReadout()

        let refresh = Task { await harness.model.refresh() }
        for _ in 0..<100 {
            if await transport.fetchCountValue() == 2 { break }
            await Task.yield()
        }
        let send = Task { await harness.model.sendPending() }
        for _ in 0..<100 { await Task.yield() }
        let sentWhileRefreshBlocked = await transport.savedChanges()
        XCTAssertTrue(sentWhileRefreshBlocked.isEmpty,
                      "the send must wait for the active refresh rather than overlap it")
        XCTAssertEqual(harness.model.playbackPhase, .playing)
        XCTAssertEqual(harness.model.selectedPlayback?.positionSeconds, 9)

        await transport.releaseFetch()
        await refresh.value
        await send.value

        let sent = await transport.savedChanges()
        XCTAssertEqual(sent.count, 1, "the queued send must execute exactly once")
        XCTAssertFalse(sent[0].isEmpty)
        XCTAssertEqual(harness.model.syncPhase, .ready)
        XCTAssertEqual(harness.model.playbackPhase, .playing)
        XCTAssertEqual(harness.model.selectedPlayback?.positionSeconds, 9)
        XCTAssertTrue(harness.engine.isPlaying)
    }

    func testPlaybackEnqueueStatusDoesNotReplaceExistingSyncFailure() async throws {
        let transport = RecordingSyncTransport(fetchError: .network)
        let harness = try await PlaybackHarness.make(transport: transport)
        await harness.model.refresh()
        let failedPhase = harness.model.syncPhase
        guard case .failed(_, retryable: true) = failedPhase else {
            return XCTFail("the setup must expose a retryable sync failure")
        }

        await harness.model.play(itemID: harness.itemID)
        for _ in 0..<100 { await Task.yield() }

        XCTAssertEqual(harness.model.syncPhase, failedPhase,
                       "durably enqueuing playback must not publish a successful sync")
        XCTAssertEqual(harness.model.playbackPhase, .playing)
    }

    func testQuarantineInvalidatesRemoveDownloadWithoutRemovingOrClearingFailure() async throws {
        let harness = try await PlaybackHarness.make()
        await harness.model.refresh()
        await harness.model.play(itemID: harness.itemID)
        let pausePersistence = AsyncEnqueueGate()
        await harness.repository.holdNextEnqueue(on: pausePersistence)

        let removal = Task { await harness.model.removeDownload(itemID: harness.itemID) }
        let pauseStarted = await pausePersistence.waitUntilStarted()
        XCTAssertTrue(pauseStarted)
        harness.model.quarantineForMVPFixture()
        await pausePersistence.release()
        await removal.value
        for _ in 0..<100 { await Task.yield() }

        XCTAssertEqual(harness.model.items.first?.state, .downloaded)
        XCTAssertTrue(harness.model.accountQuarantined)
        XCTAssertEqual(
            harness.model.syncPhase,
            .failed("iCloud account switch detected; sync is quarantined", retryable: false)
        )
    }

    func testCancelledRemoveDownloadDoesNotReleaseTwoQueuedSends() async throws {
        let transport = BlockingSaveSyncTransport()
        let harness = try await PlaybackHarness.make(transport: transport)
        await harness.model.refresh()
        await harness.model.play(itemID: harness.itemID)
        let pausePersistence = AsyncEnqueueGate()
        await harness.repository.holdNextEnqueue(on: pausePersistence)

        let removal = Task { await harness.model.removeDownload(itemID: harness.itemID) }
        let pauseStarted = await pausePersistence.waitUntilStarted()
        XCTAssertTrue(pauseStarted)
        let firstSend = Task { await harness.model.sendPending() }
        let secondSend = Task { await harness.model.sendPending() }
        for _ in 0..<100 { await Task.yield() }

        harness.model.cancel()
        let firstSaveStarted = await transport.waitForSaveCount(1)
        XCTAssertTrue(firstSaveStarted)
        await pausePersistence.release()
        await removal.value
        for _ in 0..<100 { await Task.yield() }
        let saveCountWhileFirstBlocked = await transport.saveCountValue()
        XCTAssertEqual(saveCountWhileFirstBlocked, 1,
                       "the invalidated removal must not release the second waiter over the active send")

        await transport.releaseNextSave()
        let secondSaveStarted = await transport.waitForSaveCount(2)
        XCTAssertTrue(secondSaveStarted)
        await transport.releaseNextSave()
        await firstSend.value
        await secondSend.value
    }

    func testCancelledRefreshCannotClobberUnblockedSendPhaseDuringLocalFallback() async throws {
        let transport = BlockingSyncTransport()
        let harness = try await PlaybackHarness.make(transport: transport)
        let initialRefresh = Task { await harness.model.refresh() }
        for _ in 0..<100 {
            if await transport.fetchCountValue() == 1 { break }
            await Task.yield()
        }
        await transport.releaseFetch()
        await initialRefresh.value
        await harness.model.play(itemID: harness.itemID)

        let localFallback = AsyncEnqueueGate()
        await harness.repository.holdNextState(on: localFallback)
        let failedRefresh = Task { await harness.model.refresh() }
        for _ in 0..<100 {
            if await transport.fetchCountValue() == 2 { break }
            await Task.yield()
        }
        await transport.releaseFetch(failing: true)
        let fallbackStarted = await localFallback.waitUntilStarted()
        XCTAssertTrue(fallbackStarted)

        harness.model.cancel()
        let send = Task { await harness.model.sendPending() }
        await send.value
        XCTAssertEqual(harness.model.syncPhase, .ready)
        let savedChanges = await transport.savedChanges()
        XCTAssertEqual(savedChanges.count, 1)

        await localFallback.release()
        await failedRefresh.value
        XCTAssertEqual(harness.model.syncPhase, .ready,
                       "stale local fallback must not replace the completed queued send phase")
    }

}
