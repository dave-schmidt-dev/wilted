import CryptoKit
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
            return XCTFail("Expected a visible local-larder failure")
        }
        XCTAssertTrue(message.contains("Local larder unavailable"))
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

    func testStartDiscoversCatalogOnceAndForegroundRefreshesItAgain() async {
        let repository = StaticSyncRepository(state: SyncRepositoryState(engineState: Data([1])))
        let transport = RecordingSyncTransport()
        let model = WiltedListenerAppModel(repository: repository, transport: transport)

        await model.start()
        await model.start()
        await model.resumeForeground()

        let fetchCount = await transport.fetchCountValue()
        XCTAssertEqual(fetchCount, 2,
                       "launch discovery is one fetch; foreground discovery is a later fetch")
        XCTAssertEqual(model.status, .ready)
    }

    func testConcurrentRefreshesShareTheInFlightOperation() async {
        let repository = StaticSyncRepository(state: SyncRepositoryState(engineState: Data([1])))
        let transport = BlockingSyncTransport()
        let model = WiltedListenerAppModel(repository: repository, transport: transport)

        let first = Task { await model.refresh() }
        for _ in 0..<100 {
            if await transport.fetchCountValue() > 0 { break }
            await Task.yield()
        }
        let second = Task { await model.refresh() }
        await Task.yield()
        await transport.releaseFetch()
        await first.value
        await second.value

        let fetchCount = await transport.fetchCountValue()
        XCTAssertEqual(fetchCount, 1)
        XCTAssertEqual(model.status, .ready)
    }

    func testAutomaticDiscoverySurfacesRetryableFailure() async {
        let repository = StaticSyncRepository(state: SyncRepositoryState(engineState: Data([1])))
        let transport = RecordingSyncTransport(fetchError: TestSyncError.network)
        let model = WiltedListenerAppModel(repository: repository, transport: transport)

        await model.start()

        guard case let .failed(message, retryable) = model.status else {
            return XCTFail("Expected automatic discovery failure, got \(model.status)")
        }
        XCTAssertTrue(message.contains("Refresh failed"))
        XCTAssertTrue(retryable)
    }

    func testRefreshRetriesAStaleStageWithoutDiscardingTheFetchedBatch() async throws {
        let (record, concurrentChanges) = try listenerStaleStageFixture(changeCount: 1)
        let batch = try SyncFetchBatch(generationID: "listener-stale-retry", records: [record], engineState: Data([4]))
        let repository = StaleStageListenerRepository(concurrentChanges: concurrentChanges)
        let transport = SingleBatchSyncTransport(batch: batch)
        let model = WiltedListenerAppModel(repository: repository, transport: transport)

        await model.refresh()

        XCTAssertEqual(model.status, .ready)
        let stageCalls = await repository.stageCalls
        let commitCalls = await repository.commitCalls
        let fetchCalls = await transport.fetchCalls
        let state = await repository.state()
        XCTAssertEqual(stageCalls, 2)
        XCTAssertEqual(commitCalls, 2)
        XCTAssertEqual(fetchCalls, 1)
        XCTAssertEqual(state.records, [record])
        XCTAssertEqual(state.pendingChanges, concurrentChanges)
    }

    func testRefreshFailsAfterBoundedStaleStageRetries() async throws {
        let (record, concurrentChanges) = try listenerStaleStageFixture(
            changeCount: SyncCoordinator.maximumStaleStageAttempts
        )
        let batch = try SyncFetchBatch(generationID: "listener-stale-exhaustion", records: [record], engineState: Data([5]))
        let repository = StaleStageListenerRepository(concurrentChanges: concurrentChanges)
        let transport = SingleBatchSyncTransport(batch: batch)
        let model = WiltedListenerAppModel(repository: repository, transport: transport)

        await model.refresh()

        guard case let .failed(message, retryable) = model.status else {
            return XCTFail("Expected stale retry exhaustion, got \(model.status)")
        }
        XCTAssertTrue(message.contains("The staged sync batch is stale"))
        XCTAssertTrue(retryable)
        let stageCalls = await repository.stageCalls
        let commitCalls = await repository.commitCalls
        let fetchCalls = await transport.fetchCalls
        let state = await repository.state()
        XCTAssertEqual(stageCalls, SyncCoordinator.maximumStaleStageAttempts)
        XCTAssertEqual(commitCalls, SyncCoordinator.maximumStaleStageAttempts)
        XCTAssertEqual(fetchCalls, 1)
        XCTAssertEqual(state.pendingChanges, [concurrentChanges.last!])
    }

    func testPixelFixturesAreAccountFreeAndExposeTheirIntendedTerminalStates() {
        let library = WiltedListenerAppModel.makePixelFixture()
        XCTAssertEqual(library.status, .ready)
        XCTAssertEqual(library.items.count, 1)
        XCTAssertEqual(library.transcriptsByItem.values.first?.availability, .available)
        XCTAssertEqual(library.downloadStatistics.fileCount, 1)
        XCTAssertNotNil(library.syncObservability.lastSuccessfulFetchAt)

        let playing = WiltedListenerAppModel.makePixelFixture(state: .nowPlaying)
        XCTAssertEqual(playing.status, .playing)
        XCTAssertEqual(playing.selectedPlayback?.positionSeconds, 31)

        let failure = WiltedListenerAppModel.makePixelFixture(state: .terminalFailure)
        XCTAssertEqual(failure.status, .failed("iCloud account changed; sync is quarantined", retryable: false))
        XCTAssertEqual(failure.items.count, 1)
    }

    func testCatalogPublishesOnlyTranscriptMatchingTheCurrentRevision() async throws {
        let url = URL(string: "https://example.test/transcript-listener")!
        let itemID = try ItemID.derive(from: url)
        let currentRevisionID = try RevisionID(rawValue: "revision-current")
        let oldRevisionID = try RevisionID(rawValue: "revision-old")
        let hash = "sha256:" + String(repeating: "a", count: 64)
        let asset = try WiltedAsset(assetID: "transcript-audio", contentHash: hash)
        let article = try Article(itemID: itemID, canonicalURL: url, title: "Transcript article",
                                  source: "Test", createdAt: Timestamp(Date()))
        let revision = try AudioRevision(itemID: itemID, revisionID: currentRevisionID,
                                         durationSeconds: 30, byteCount: 16, contentHash: hash,
                                         mediaType: "audio/m4a", createdAt: Timestamp(Date()), schemaVersion: 1)
        let current = try Transcript(itemID: itemID, revisionID: currentRevisionID,
                                     availability: .available, text: "Current transcript",
                                     languageCode: "en", updatedAt: Timestamp(Date()))
        let old = try Transcript(itemID: itemID, revisionID: oldRevisionID,
                                 availability: .available, text: "Old transcript",
                                 languageCode: "en", updatedAt: Timestamp(Date()))
        let codec = WiltedRecordCodec()
        let repository = StaticSyncRepository(state: SyncRepositoryState(records: [
            try codec.encode(article: article, currentRevisionID: currentRevisionID),
            try codec.encode(revision: revision, audioAsset: asset),
            try codec.encode(transcript: old),
            try codec.encode(transcript: current),
        ]))
        let model = WiltedListenerAppModel(repository: repository)

        await model.refresh()

        XCTAssertEqual(model.transcriptsByItem[itemID], current)
    }

    func testCatalogSelectsTheArticleDeclaredRevisionOverLaterSupersededRecord() async throws {
        let url = URL(string: "https://example.test/current-revision")!
        let itemID = try ItemID.derive(from: url)
        let currentRevisionID = try RevisionID(rawValue: "revision-current")
        let supersededRevisionID = try RevisionID(rawValue: "revision-superseded-z")
        let currentAsset = try WiltedAsset(assetID: "current-audio",
                                           contentHash: "sha256:" + String(repeating: "a", count: 64))
        let supersededAsset = try WiltedAsset(assetID: "superseded-audio",
                                              contentHash: "sha256:" + String(repeating: "b", count: 64))
        let article = try Article(itemID: itemID, canonicalURL: url, title: "Current revision",
                                  source: "Test", createdAt: Timestamp(Date()))
        let current = try AudioRevision(itemID: itemID, revisionID: currentRevisionID,
                                        durationSeconds: 30, byteCount: 1, contentHash: currentAsset.contentHash,
                                        mediaType: "audio/m4a", createdAt: Timestamp(Date()), schemaVersion: 1)
        let superseded = try AudioRevision(itemID: itemID, revisionID: supersededRevisionID,
                                            durationSeconds: 90, byteCount: 1, contentHash: supersededAsset.contentHash,
                                            mediaType: "audio/m4a", createdAt: Timestamp(Date()), schemaVersion: 1)
        let codec = WiltedRecordCodec()
        let repository = StaticSyncRepository(state: SyncRepositoryState(records: [
            try codec.encode(article: article, currentRevisionID: currentRevisionID),
            try codec.encode(revision: current, audioAsset: currentAsset),
            try codec.encode(revision: superseded, audioAsset: supersededAsset),
        ]))
        let model = WiltedListenerAppModel(repository: repository)

        await model.refresh()

        XCTAssertEqual(model.items.first?.revisionID, currentRevisionID)
        XCTAssertEqual(model.items.first?.durationSeconds, current.durationSeconds)
    }

    func testPlayStartsCurrentRevisionWhenCachedPlaybackHasAnotherRevision() async throws {
        let staleRevisionID = try RevisionID(rawValue: "revision-stale")
        let harness = try await PlaybackHarness.make(cachedPlaybackRevisionID: staleRevisionID)

        await harness.model.refresh()
        await harness.model.play(itemID: harness.itemID)

        let selected = try XCTUnwrap(harness.model.selectedPlayback)
        XCTAssertEqual(selected.revisionID, harness.model.items.first?.revisionID)
        XCTAssertEqual(selected.positionSeconds, 0)
    }

    func testRebuildMergesPlaybackCausallyInsteadOfUsingRecordOrder() async throws {
        let url = URL(string: "https://example.test/causal-playback")!
        let itemID = try ItemID.derive(from: url)
        let revisionID = try RevisionID(rawValue: "revision-causal-playback")
        let asset = try WiltedAsset(assetID: "causal-audio",
                                    contentHash: "sha256:" + String(repeating: "c", count: 64))
        let article = try Article(itemID: itemID, canonicalURL: url, title: "Causal playback",
                                  source: "Test", createdAt: Timestamp(Date()))
        let revision = try AudioRevision(itemID: itemID, revisionID: revisionID,
                                         durationSeconds: 30, byteCount: 1, contentHash: asset.contentHash,
                                         mediaType: "audio/m4a", createdAt: Timestamp(Date()), schemaVersion: 1)
        let first = try PlaybackState(itemID: itemID, revisionID: revisionID, sessionID: "causal-session",
                                      sequence: 1, positionSeconds: 4, durationSeconds: 30, completed: false,
                                      intent: .progress, deviceID: "iphone", updatedAt: Timestamp(Date()))
        let latest = try PlaybackState(itemID: itemID, revisionID: revisionID, sessionID: "causal-session",
                                       sequence: 2, positionSeconds: 11, durationSeconds: 30, completed: false,
                                       intent: .progress, deviceID: "iphone", updatedAt: Timestamp(Date()))
        let staleTag = try PlaybackState(itemID: itemID, revisionID: revisionID, sessionID: "causal-session",
                                         sequence: 3, positionSeconds: 18, durationSeconds: 30, completed: false,
                                         intent: .progress, deviceID: "iphone", updatedAt: Timestamp(Date()))
        let codec = WiltedRecordCodec()
        let playbackID = try WiltedRecordID.playback(itemID, revisionID)
        let repository = StaticSyncRepository(state: SyncRepositoryState(records: [
            try codec.encode(article: article, currentRevisionID: revisionID),
            try codec.encode(revision: revision, audioAsset: asset),
            try codec.encode(playback: latest, sidecar: WiltedOpaqueSidecar(changeTag: "tag-current")),
            try codec.encode(playback: first, sidecar: WiltedOpaqueSidecar(changeTag: "tag-current")),
            try codec.encode(playback: staleTag, sidecar: WiltedOpaqueSidecar(changeTag: "tag-stale")),
        ]))
        let model = WiltedListenerAppModel(repository: repository,
                                           metadataLoader: { ListenerMetadata(lastPlayedRecordID: playbackID) })

        await model.refresh()

        XCTAssertEqual(model.selectedPlayback?.sequence, latest.sequence)
        XCTAssertEqual(model.selectedPlayback?.positionSeconds, latest.positionSeconds)
    }

    func testSettingsFactsLoadPersistedFetchAndCacheStatistics() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("WiltedSettingsFacts-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = try ListenerRepository(directoryURL: root)
        let cache = try ListenerAudioCache(rootURL: root.appendingPathComponent("Audio", isDirectory: true))
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        try await repository.recordSuccessfulFetch(at: date)
        let bytes = Data("settings-cache".utf8)
        let digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        let asset = try WiltedAsset(assetID: "settings-cache", contentHash: "sha256:\(digest)")
        _ = try await cache.store(data: bytes, asset: asset)
        let model = WiltedListenerAppModel(repository: repository, cache: cache)

        await model.start()

        XCTAssertEqual(model.syncObservability.lastSuccessfulFetchAt, date)
        XCTAssertEqual(model.downloadStatistics, ListenerDownloadStatistics(fileCount: 1, byteCount: Int64(bytes.count)))
    }

    func testEveryTypedAccountChangeQuarantinesTheListener() async throws {
        let source = AccountSignalSource()
        let repository = StaticSyncRepository(state: SyncRepositoryState(engineState: Data([1])))
        let transport = RecordingSyncTransport()
        let model = WiltedListenerAppModel(repository: repository, sessionFactory: { _ in
            TestSyncSession(transport: transport, accountChanges: source.stream)
        })

        await model.refresh()
        for type in [ListenerAccountChangeType.signIn, .signOut, .switchAccounts] {
            source.send(.quarantined(type))
            let expected = type.userFacingName
            var observed = false
            for _ in 0..<100 {
                if case let .failed(message, retryable) = model.status,
                   message.contains(expected), !retryable {
                    observed = true
                    break
                }
                await Task.yield()
            }
            XCTAssertTrue(observed, "Expected quarantine for \(expected)")
        }
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

    func testAFullyConflictedPlaybackQueueReportsHeldWorkInsteadOfReady() async throws {
        let url = URL(string: "https://example.test/held-playback")!
        let itemID = try ItemID.derive(from: url)
        let revisionID = try RevisionID(rawValue: "revision-held-playback")
        let asset = try WiltedAsset(assetID: "audio-held-playback",
                                    contentHash: "sha256:" + String(repeating: "b", count: 64))
        let codec = WiltedRecordCodec()
        let article = try Article(itemID: itemID, canonicalURL: url, title: "Held playback",
                                  source: "Test", createdAt: Timestamp(Date()))
        let revision = try AudioRevision(itemID: itemID, revisionID: revisionID, durationSeconds: 30,
                                         byteCount: 1, contentHash: asset.contentHash,
                                         mediaType: "audio/mpeg", createdAt: Timestamp(Date()), schemaVersion: 1)
        let playback = try PlaybackState(itemID: itemID, revisionID: revisionID, sessionID: "held",
                                         sequence: 1, positionSeconds: 5, durationSeconds: 30,
                                         completed: false, intent: .progress, deviceID: "iphone",
                                         updatedAt: Timestamp(Date()))
        let itemRecord = try codec.encode(article: article, currentRevisionID: revisionID)
        let revisionRecord = try codec.encode(revision: revision, audioAsset: asset)
        let playbackRecord = try codec.encode(playback: playback)
        let change = try SyncPendingChange(operation: .update, recordID: playbackRecord.id, record: playbackRecord)
        let repository = StaticSyncRepository(state: SyncRepositoryState(
            records: [itemRecord, revisionRecord, playbackRecord], engineState: Data([1]),
            pendingChanges: [change], conflictedRecordIDs: [change.recordID],
            conflictServerRecords: [change.recordID: playbackRecord]))
        let transport = RecordingSyncTransport()
        let model = WiltedListenerAppModel(repository: repository, sessionFactory: { _ in
            TestSyncSession(transport: transport)
        })

        await model.refresh()
        await model.sendPending()

        // Every queued update is conflicted, so nothing left the device. Reporting ready here
        // is indistinguishable from having had nothing to send.
        let sent = await transport.savedChanges()
        XCTAssertTrue(sent.isEmpty)
        guard case let .failed(message, retryable) = model.status else {
            XCTFail("Expected a held-work failure, got \(model.status)")
            return
        }
        XCTAssertEqual(message, "Nothing was sent. 1 playback update is held by unresolved conflicts.")
        XCTAssertTrue(retryable)
    }

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

    func testAFirstEverPlayStartsPlaybackInsteadOfFailingTheSequenceFloor() async throws {
        let harness = try await PlaybackHarness.make()

        await harness.model.refresh()
        XCTAssertEqual(harness.model.items.first?.state, .downloaded,
                       "the cached asset should present as downloaded before play is attempted")

        await harness.model.play(itemID: harness.itemID)

        guard case .playing = harness.model.status else {
            return XCTFail("first play failed: \(harness.model.status)")
        }
        let started = try XCTUnwrap(harness.model.selectedPlayback)
        // `PlaybackState` rejects a sequence below one, so an item that has never been
        // played must not be given a zero: it would be unplayable for the life of the install.
        XCTAssertGreaterThanOrEqual(started.sequence, 1)
        XCTAssertEqual(started.positionSeconds, 0)
        XCTAssertTrue(harness.engine.isPlaying)
    }

    func testInitialPlayShowsProgressWhilePlaybackPreparationIsBlocked() async throws {
        let harness = try await PlaybackHarness.make()
        await harness.model.refresh()
        let gate = harness.engine.holdNextLoad()

        let play = Task { await harness.model.play(itemID: harness.itemID) }
        let loadStarted = await gate.waitUntilStarted()
        XCTAssertTrue(loadStarted)
        XCTAssertEqual(harness.model.status, .refreshing("Preparing offline audio"))

        gate.release.signal()
        await play.value
        XCTAssertEqual(harness.model.status, .playing)
    }

    func testPlaybackCompletionEventsPreservePlayingAndPausedStatuses() async throws {
        let harness = try await PlaybackHarness.make()
        await harness.model.refresh()

        await harness.model.play(itemID: harness.itemID)
        await drainPlaybackStatusDelivery()
        XCTAssertEqual(harness.model.status, .playing)

        await harness.model.pause()
        await drainPlaybackStatusDelivery()
        XCTAssertEqual(harness.model.status, .paused)
    }

    func testRestartOpensANewSessionInsteadOfFailingTheSequenceFloor() async throws {
        let harness = try await PlaybackHarness.make()
        await harness.model.refresh()
        await harness.model.play(itemID: harness.itemID)
        let firstSession = try XCTUnwrap(harness.model.selectedPlayback).sessionID

        await harness.model.restart()

        guard case .playing = harness.model.status else {
            return XCTFail("restart failed: \(harness.model.status)")
        }
        let restarted = try XCTUnwrap(harness.model.selectedPlayback)
        XCTAssertNotEqual(restarted.sessionID, firstSession, "restart should open a new session")
        XCTAssertGreaterThanOrEqual(restarted.sequence, 1)
        XCTAssertEqual(restarted.positionSeconds, 0)
    }

    func testRestartShowsProgressWhilePlaybackPreparationIsBlocked() async throws {
        let harness = try await PlaybackHarness.make()
        await harness.model.refresh()
        await harness.model.play(itemID: harness.itemID)
        let gate = harness.engine.holdNextLoad()

        let restart = Task { await harness.model.restart() }
        let loadStarted = await gate.waitUntilStarted()
        XCTAssertTrue(loadStarted)
        XCTAssertEqual(harness.model.status, .refreshing("Preparing offline audio"))

        gate.release.signal()
        await restart.value
        XCTAssertEqual(harness.model.status, .playing)
    }

    private func drainPlaybackStatusDelivery() async {
        // The controller publishes completion separately through AsyncStream. Yielding the
        // main actor drains that observer after the command has set its user-facing status.
        for _ in 0..<100 { await Task.yield() }
    }

    func testBackgroundPersistsLiveEnginePositionInsteadOfStaleSelectedPlayback() async throws {
        let harness = try await PlaybackHarness.make()
        await harness.model.refresh()
        await harness.model.play(itemID: harness.itemID)
        harness.engine.currentTime = 13

        await harness.model.enterBackground()

        XCTAssertEqual(harness.model.selectedPlayback?.positionSeconds, 13)
        let persisted = await harness.metadataCapture.last
        XCTAssertEqual(persisted?.lastPositionSeconds, 13)
    }

    func testNowPlayingReadoutFollowsActiveEngineWithoutPersistingEveryTick() async throws {
        let harness = try await PlaybackHarness.make()
        await harness.model.refresh()
        await harness.model.play(itemID: harness.itemID)
        harness.engine.currentTime = 11

        await harness.model.refreshNowPlayingReadout()

        XCTAssertEqual(harness.model.selectedPlayback?.positionSeconds, 11)
        let persisted = await harness.metadataCapture.last
        XCTAssertEqual(persisted?.lastPositionSeconds, 0)
    }

    func testChunkedCatalogRefreshDefersAudioRetrievalUntilDownload() async throws {
        let fixture = try makeChunkedCatalogFixture()
        let loader = CountingChunkLoader(data: fixture.bytes)
        let model = WiltedListenerAppModel(repository: fixture.repository, transport: RecordingSyncTransport(),
                                           cache: fixture.cache,
                                           audioChunkLoader: { itemID, revisionID, manifest in
                                               try await loader.load(itemID: itemID, revisionID: revisionID, manifest: manifest)
                                           })

        await model.refresh()
        XCTAssertEqual(model.items.first?.state, .metadataOnly)
        let initialLoadCount = await loader.count
        XCTAssertEqual(initialLoadCount, 0)

        await model.download(itemID: fixture.itemID)

        let loadCount = await loader.count
        XCTAssertEqual(loadCount, 1)
        XCTAssertEqual(model.items.first?.state, .downloaded)
        let cachedURL = await fixture.cache.url(for: fixture.asset)
        XCTAssertNotNil(cachedURL)
    }

    func testCorruptChunkDownloadLeavesMetadataOnlyAndNoCache() async throws {
        let fixture = try makeChunkedCatalogFixture()
        let model = WiltedListenerAppModel(repository: fixture.repository, transport: RecordingSyncTransport(),
                                           cache: fixture.cache,
                                           audioChunkLoader: { _, _, _ in Data("corrupt".utf8) })

        await model.refresh()
        await model.download(itemID: fixture.itemID)

        XCTAssertEqual(model.items.first?.state, .metadataOnly)
        let cachedURL = await fixture.cache.url(for: fixture.asset)
        XCTAssertNil(cachedURL)
        guard case let .failed(message, retryable) = model.status else {
            return XCTFail("Expected a retryable download failure")
        }
        XCTAssertTrue(message.contains("Download failed"))
        XCTAssertTrue(retryable)
    }

    func testMissingChunkDownloadLeavesMetadataOnlyAndReportsRetryableFailure() async throws {
        let fixture = try makeChunkedCatalogFixture()
        let model = WiltedListenerAppModel(repository: fixture.repository, transport: RecordingSyncTransport(),
                                           cache: fixture.cache,
                                           audioChunkLoader: { _, _, _ in throw TestSyncError.network })

        await model.refresh()
        await model.download(itemID: fixture.itemID)

        XCTAssertEqual(model.items.first?.state, .metadataOnly)
        XCTAssertEqual(model.status, .failed("Download failed: network unavailable", retryable: true))
    }

    func testDuplicateChunkDownloadsAreSuppressedWhileOneIsInFlight() async throws {
        let fixture = try makeChunkedCatalogFixture()
        let loader = BlockingChunkLoader(data: fixture.bytes)
        let model = WiltedListenerAppModel(repository: fixture.repository, transport: RecordingSyncTransport(),
                                           cache: fixture.cache,
                                           audioChunkLoader: { itemID, revisionID, manifest in
                                               await loader.load(itemID: itemID, revisionID: revisionID, manifest: manifest)
                                           })
        await model.refresh()

        let first = Task { await model.download(itemID: fixture.itemID) }
        for _ in 0..<100 {
            if await loader.count > 0 { break }
            await Task.yield()
        }
        await model.download(itemID: fixture.itemID)
        let loadCount = await loader.count
        XCTAssertEqual(loadCount, 1)
        await loader.release()
        await first.value
        XCTAssertEqual(model.items.first?.state, .downloaded)
    }

    func testCancelledChunkDownloadCannotCompleteOverItsRetry() async throws {
        let fixture = try makeChunkedCatalogFixture()
        let loader = BlockingChunkLoader(data: fixture.bytes)
        let model = WiltedListenerAppModel(repository: fixture.repository, transport: RecordingSyncTransport(),
                                           cache: fixture.cache,
                                           audioChunkLoader: { itemID, revisionID, manifest in
                                               await loader.load(itemID: itemID, revisionID: revisionID, manifest: manifest)
                                           })
        await model.refresh()

        let cancelled = Task { await model.download(itemID: fixture.itemID) }
        for _ in 0..<100 {
            if await loader.count == 1 { break }
            await Task.yield()
        }
        model.cancel()

        let retry = Task { await model.download(itemID: fixture.itemID) }
        for _ in 0..<100 {
            if await loader.count == 2 { break }
            await Task.yield()
        }

        await loader.release()
        await cancelled.value
        XCTAssertEqual(model.items.first?.state, .metadataOnly,
                       "the cancelled generation must not publish its completed bytes")
        XCTAssertTrue(model.status.isBusy,
                      "the cancelled generation must not clear the retry's visible progress")

        await loader.release()
        await retry.value
        XCTAssertEqual(model.items.first?.state, .downloaded)
        XCTAssertEqual(model.status, .ready)
    }

    func testAccountQuarantineInvalidatesAnActiveChunkDownload() async throws {
        let fixture = try makeChunkedCatalogFixture()
        let signals = AccountSignalSource()
        let loader = BlockingChunkLoader(data: fixture.bytes)
        let cancelProbe = SessionCancelProbe()
        let model = WiltedListenerAppModel(
            repository: fixture.repository,
            sessionFactory: { _ in
                TestSyncSession(
                    transport: RecordingSyncTransport(),
                    accountChanges: signals.stream,
                    audioChunkLoader: { itemID, revisionID, manifest in
                        await loader.load(itemID: itemID, revisionID: revisionID, manifest: manifest)
                    },
                    cancelAction: { await cancelProbe.record() }
                )
            },
            cache: fixture.cache
        )
        await model.refresh()

        let download = Task { await model.download(itemID: fixture.itemID) }
        for _ in 0..<100 {
            if await loader.count == 1 { break }
            await Task.yield()
        }
        signals.send(.quarantined(.switchAccounts))
        for _ in 0..<100 {
            if case .failed(_, retryable: false) = model.status { break }
            await Task.yield()
        }

        await loader.release()
        await download.value
        let cachedURL = await fixture.cache.url(for: fixture.asset)
        let sessionWasCancelled = await cancelProbe.wasCalled
        XCTAssertEqual(model.items.first?.state, .metadataOnly)
        XCTAssertNil(cachedURL)
        XCTAssertTrue(sessionWasCancelled)
        XCTAssertEqual(model.status,
                       .failed("iCloud account switch detected; sync is quarantined", retryable: false))
    }

    func testAccountQuarantineBlocksANewChunkDownload() async throws {
        let fixture = try makeChunkedCatalogFixture()
        let signals = AccountSignalSource()
        let loader = CountingChunkLoader(data: fixture.bytes)
        let model = WiltedListenerAppModel(
            repository: fixture.repository,
            sessionFactory: { _ in
                TestSyncSession(
                    transport: RecordingSyncTransport(),
                    accountChanges: signals.stream,
                    audioChunkLoader: { itemID, revisionID, manifest in
                        try await loader.load(itemID: itemID, revisionID: revisionID, manifest: manifest)
                    }
                )
            },
            cache: fixture.cache
        )
        await model.refresh()
        signals.send(.quarantined(.signOut))
        for _ in 0..<100 {
            if case .failed(_, retryable: false) = model.status { break }
            await Task.yield()
        }

        await model.download(itemID: fixture.itemID)

        let loadCount = await loader.count
        XCTAssertEqual(loadCount, 0)
        XCTAssertEqual(model.items.first?.state, .metadataOnly)
        XCTAssertEqual(model.status,
                       .failed("iCloud sign-out detected; sync is quarantined", retryable: false))
    }

    private func makeChunkedCatalogFixture() throws -> ChunkedCatalogFixture {
        let url = URL(string: "https://example.test/chunked-listener")!
        let itemID = try ItemID.derive(from: url)
        let revisionID = try RevisionID(rawValue: "revision-chunked-listener")
        let bytes = Data("chunked-listener-audio".utf8)
        let chunked = try AudioChunking.chunk(bytes, chunkSize: 4)
        let contentHash = "sha256:\(chunked.manifest.contentSHA256)"
        let asset = try WiltedAsset(assetID: "audio:\(revisionID.rawValue)", contentHash: contentHash)
        let article = try Article(itemID: itemID, canonicalURL: url, title: "Chunked listener",
                                  source: "Test", createdAt: Timestamp(Date()))
        let revision = try AudioRevision(itemID: itemID, revisionID: revisionID, durationSeconds: 30,
                                         byteCount: Int64(bytes.count), contentHash: contentHash,
                                         mediaType: "audio/mp4", createdAt: Timestamp(Date()), schemaVersion: 1)
        let codec = WiltedRecordCodec()
        let state = SyncRepositoryState(records: [
            try codec.encode(article: article, currentRevisionID: revisionID),
            try codec.encode(revision: revision, manifest: chunked.manifest)
        ], engineState: Data([1]))
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("wilted-listener-chunked-\(UUID().uuidString)", isDirectory: true)
        return try ChunkedCatalogFixture(itemID: itemID, bytes: bytes, asset: asset,
                                         repository: StaticSyncRepository(state: state),
                                         cache: ListenerAudioCache(rootURL: root))
    }
}

private struct ChunkedCatalogFixture {
    let itemID: ItemID
    let bytes: Data
    let asset: WiltedAsset
    let repository: StaticSyncRepository
    let cache: ListenerAudioCache
}

private actor CountingChunkLoader {
    let data: Data
    private(set) var count = 0

    init(data: Data) { self.data = data }

    func load(itemID: ItemID, revisionID: RevisionID, manifest: AudioChunkManifest) throws -> Data {
        count += 1
        return data
    }
}

private actor BlockingChunkLoader {
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

private actor SessionCancelProbe {
    private(set) var wasCalled = false
    func record() { wasCalled = true }
}

private func listenerStaleStageFixture(changeCount: Int) throws -> (WiltedRecordEnvelope, [SyncPendingChange]) {
    let url = URL(string: "https://example.test/listener-stale-stage")!
    let itemID = try ItemID.derive(from: url)
    let revisionID = try RevisionID(rawValue: "listener-stale-stage")
    let article = try Article(itemID: itemID, canonicalURL: url, title: "Stale stage",
                              source: "Test", createdAt: Timestamp(Date()))
    let record = try WiltedRecordCodec().encode(article: article, currentRevisionID: revisionID)
    let changes = try (1...changeCount).map { sequence in
        let changedRecord = try WiltedRecordEnvelope(
            id: record.id,
            schemaVersion: record.schemaVersion,
            fields: record.fields,
            sidecar: WiltedOpaqueSidecar(changeTag: "local-\(sequence)")
        )
        return try SyncPendingChange(operation: .update, recordID: record.id, record: changedRecord)
    }
    return (record, changes)
}

private actor StaticSyncRepository: SyncRepository {
    let statuses: AsyncStream<SyncStatus>
    private var snapshot: SyncRepositoryState
    private var acknowledgements: [[SyncPendingChange]] = []

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
    func acknowledge(_ result: SyncSendResult, sent: [SyncPendingChange]) async throws { acknowledgements.append(sent) }
    func acknowledgedBatches() -> [[SyncPendingChange]] { acknowledgements }
}

private actor StaleStageListenerRepository: SyncRepository {
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

private actor SingleBatchSyncTransport: SyncTransport {
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

private actor RecordingSyncTransport: SyncTransport {
    let statuses: AsyncStream<SyncStatus>
    private var sent: [[SyncPendingChange]] = []
    private var fetchCount = 0
    private let fetchError: TestSyncError?

    init(fetchError: TestSyncError? = nil) {
        statuses = AsyncStream { _ in }
        self.fetchError = fetchError
    }

    func fetchChanges() async throws -> SyncFetchBatch {
        fetchCount += 1
        if let fetchError { throw fetchError }
        return try SyncFetchBatch(generationID: "refresh", records: [], engineState: Data([2]))
    }

    func save(changes: [SyncPendingChange], role: SyncDeviceRole) async throws -> SyncSendResult {
        sent.append(changes)
        return try SyncSendResult(engineState: Data([3]))
    }

    func savedChanges() -> [[SyncPendingChange]] { sent }
    func fetchCountValue() -> Int { fetchCount }
}

private actor BlockingSyncTransport: SyncTransport {
    let statuses = AsyncStream<SyncStatus> { _ in }
    private var fetchCount = 0
    private var release: CheckedContinuation<Void, Never>?

    func fetchChanges() async throws -> SyncFetchBatch {
        fetchCount += 1
        await withCheckedContinuation { continuation in
            release = continuation
        }
        return try SyncFetchBatch(generationID: "refresh", records: [], engineState: Data([2]))
    }

    func save(changes: [SyncPendingChange], role: SyncDeviceRole) async throws -> SyncSendResult {
        try SyncSendResult(engineState: Data([3]))
    }

    func fetchCountValue() -> Int { fetchCount }

    func releaseFetch() {
        release?.resume()
        release = nil
    }
}

private enum TestSyncError: Error, LocalizedError, Sendable {
    case network

    var errorDescription: String? { "network unavailable" }
}

private final class AccountSignalSource: @unchecked Sendable {
    let stream: AsyncStream<ListenerAccountChange>
    private let continuation: AsyncStream<ListenerAccountChange>.Continuation

    init() {
        let (stream, continuation) = AsyncStream<ListenerAccountChange>.makeStream()
        self.stream = stream
        self.continuation = continuation
    }

    func send(_ change: ListenerAccountChange) { continuation.yield(change) }
}

private actor MetadataCapture {
    private(set) var values: [ListenerMetadata?] = []
    func save(_ metadata: ListenerMetadata?) { values.append(metadata) }
    var last: ListenerMetadata? { values.last ?? nil }
}

private struct TestSyncSession: ListenerSyncSession {
    let transport: any SyncTransport
    let assetLoader: ListenerAssetLoader
    let audioChunkLoader: ListenerAudioChunkLoader
    let accountChanges: AsyncStream<ListenerAccountChange>
    let cancelAction: @Sendable () async -> Void

    init(transport: any SyncTransport,
         accountChanges: AsyncStream<ListenerAccountChange>? = nil,
         audioChunkLoader: ListenerAudioChunkLoader? = nil,
         cancelAction: @escaping @Sendable () async -> Void = {}) {
        self.transport = transport
        self.assetLoader = { _, asset in throw ListenerError.cacheUnavailable(asset.assetID) }
        self.audioChunkLoader = audioChunkLoader ?? { _, _, _ in throw TestSyncError.network }
        self.accountChanges = accountChanges ?? AsyncStream { _ in }
        self.cancelAction = cancelAction
    }

    func cancel() async { await cancelAction() }
    func resetAfterAccountChange() async {}
}


/// Wires a real audio cache and playback controller around fake device I/O.
///
/// The engine, session, and now-playing surfaces are the only parts that need hardware,
/// so faking exactly those keeps the playback path itself under the Debug gate. That path
/// was previously reachable only on a device, which is how a first play that could never
/// construct its own state shipped.
@MainActor
private struct PlaybackHarness {
    let model: WiltedListenerAppModel
    let itemID: ItemID
    let engine: FakeAudioEngine
    let metadataCapture: MetadataCapture

    static func make(cachedPlaybackRevisionID: RevisionID? = nil) async throws -> PlaybackHarness {
        let url = URL(string: "https://example.test/first-play")!
        let itemID = try ItemID.derive(from: url)
        let revisionID = try RevisionID(rawValue: "revision-first-play")
        let bytes = Data("wilted-first-play-audio".utf8)
        let contentHash = "sha256:" + SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        let asset = try WiltedAsset(assetID: "audio-first-play", contentHash: contentHash)
        let article = try Article(itemID: itemID, canonicalURL: url, title: "First play",
                                  source: "Test", createdAt: Timestamp(Date()))
        let revision = try AudioRevision(itemID: itemID, revisionID: revisionID, durationSeconds: 30,
                                         byteCount: Int64(bytes.count), contentHash: contentHash,
                                         mediaType: "audio/mp4", createdAt: Timestamp(Date()), schemaVersion: 1)
        let codec = WiltedRecordCodec()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("wilted-playback-\(UUID().uuidString)", isDirectory: true)
        let cache = try ListenerAudioCache(rootURL: root)
        _ = try await cache.store(data: bytes, asset: asset)
        let engine = FakeAudioEngine(duration: 30)
        let controller = ListenerPlaybackController(cache: cache, engine: engine,
                                                    session: FakeAudioSession(), nowPlaying: FakeNowPlaying())
        let metadataCapture = MetadataCapture()
        let cachedPlayback = try cachedPlaybackRevisionID.map {
            try PlaybackState(itemID: itemID, revisionID: $0, sessionID: "stale-session", sequence: 7,
                              positionSeconds: 12, durationSeconds: 30, completed: false,
                              intent: .progress, deviceID: "iphone", updatedAt: Timestamp(Date()))
        }
        var records = [try codec.encode(article: article, currentRevisionID: revisionID),
                       try codec.encode(revision: revision, audioAsset: asset)]
        if let cachedPlayback { records.append(try codec.encode(playback: cachedPlayback)) }
        let repository = StaticSyncRepository(state: SyncRepositoryState(
            records: records,
            engineState: Data([1])))
        return PlaybackHarness(model: WiltedListenerAppModel(
            repository: repository,
            cache: cache,
            playback: controller,
            metadataSaver: { metadata in await metadataCapture.save(metadata) }
        ), itemID: itemID, engine: engine, metadataCapture: metadataCapture)
    }
}

private final class FakeAudioEngine: ListenerAudioEngine, @unchecked Sendable {
    let duration: Double
    var currentTime: Double = 0
    private(set) var playing = false
    private let loadGateLock = NSLock()
    private var nextLoadGate: LoadGate?
    var isPlaying: Bool { playing }
    init(duration: Double) { self.duration = duration }
    func holdNextLoad() -> LoadGate {
        let gate = LoadGate()
        loadGateLock.withLock { nextLoadGate = gate }
        return gate
    }
    func load(url: URL) throws {
        let gate = loadGateLock.withLock {
            defer { nextLoadGate = nil }
            return nextLoadGate
        }
        gate?.started.signal()
        gate?.release.wait()
    }
    func play() -> Bool { playing = true; return true }
    func pause() { playing = false }
}

private final class LoadGate: @unchecked Sendable {
    let started = DispatchSemaphore(value: 0)
    let release = DispatchSemaphore(value: 0)

    func waitUntilStarted() async -> Bool {
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async { [self] in
                continuation.resume(returning: started.wait(timeout: .now() + 2) == .success)
            }
        }
    }
}

private struct FakeAudioSession: ListenerAudioSession {
    func activate() throws {}
    func deactivate() {}
}

private struct FakeNowPlaying: ListenerNowPlaying {
    func update(title: String, duration: Double, position: Double, rate: Double) {}
    func clear() {}
}
