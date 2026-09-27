import CryptoKit
import MediaPlayer
import XCTest
@testable import WiltediOS
import WiltedDomain
@testable import WiltedListener
import WiltedSync
import CloudKit
import WiltedCloudKit

@MainActor
final class ListenerAppModelTests: XCTestCase {
    func testListenerLifetimeStatisticsAreExplicitlyUnavailableBecauseTheyAreMacLocal() throws {
        let model = WiltedListenerAppModel()
        XCTAssertEqual(
            model.lifetimeStatisticsUnavailableReason,
            "These lifetime statistics are stored only on the Mac that produces and plays audio."
        )

        let sourceRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(
            contentsOf: sourceRoot.appendingPathComponent("WiltediOS/ListenerAppView.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(source.contains("value: \"Unavailable\""))
        XCTAssertFalse(source.contains("model.lifetimeStatistics."))
        for identifierName in [
            "WiltedScreenCopy.audioProcessedIdentifier",
            "WiltedScreenCopy.speechGeneratedIdentifier",
            "WiltedScreenCopy.confirmedAdTimeRemovedIdentifier",
            "WiltedScreenCopy.fasterPlaybackTimeSavedIdentifier",
        ] {
            XCTAssertTrue(source.contains(identifierName))
        }
    }

    func testProductionLaunchRetainsRealRemoteCommandHandlerAndHandlesPause() async throws {
        var launchedModel: WiltedListenerAppModel?
        for _ in 0..<200 {
            if let model = WiltediOSApp.launchedModelForTesting {
                launchedModel = model
                break
            }
            try? await Task.sleep(for: .milliseconds(5))
        }

        let model = try XCTUnwrap(
            launchedModel,
            "the hosted test must reach the actual model retained by the app scene"
        )
        let commands = try XCTUnwrap(
            model.installedSystemRemoteCommandsForTesting,
            "the actual launched model must retain its one production command bridge"
        )
        XCTAssertEqual(commands.receivePause(nil), .success,
                       "the real production target action must still own its installed pause handler")
    }

    func testSystemRemoteCommandInstallIsIdempotentUnderModelOwnership() async throws {
        let harness = try await PlaybackHarness.make()

        await harness.model.installSystemRemoteCommands()
        let first = try XCTUnwrap(harness.model.installedSystemRemoteCommandsForTesting)
        await harness.model.installSystemRemoteCommands()
        let second = try XCTUnwrap(harness.model.installedSystemRemoteCommandsForTesting)

        XCTAssertTrue(first === second,
                      "repeated SwiftUI lifecycle delivery must not register a second system command target")
    }

    func testRealRemoteRewindAndPausePublishAndEnqueueDurablePlayback() async throws {
        let harness = try await PlaybackHarness.make()
        let remoteCommands = MediaPlayerRemoteCommands()
        await harness.model.install(remoteCommands: remoteCommands)
        await harness.model.refresh()
        await harness.model.play(itemID: harness.itemID)

        harness.engine.currentTime = 20
        let rewindHandled = remoteCommands.receiveRewind(nil)
        var changes = await waitForEnqueuedChanges(harness.repository, count: 2)
        XCTAssertEqual(rewindHandled, .success)
        XCTAssertEqual(changes.count, 2)
        let rewindEnvelope = try XCTUnwrap(changes.last?.record)
        let rewind = try WiltedRecordCodec().decodePlaybackRecord(rewindEnvelope).value
        XCTAssertEqual(rewind.intent, .rewind)
        XCTAssertEqual(rewind.positionSeconds, 5)
        XCTAssertEqual(harness.model.selectedPlayback, rewind)
        XCTAssertEqual(harness.model.playbackPhase, .playing)

        harness.engine.currentTime = 9
        let pauseHandled = remoteCommands.receivePause(nil)
        changes = await waitForEnqueuedChanges(harness.repository, count: 3)
        XCTAssertEqual(pauseHandled, .success)
        XCTAssertEqual(changes.count, 3)
        let rewoundPauseEnvelope = try XCTUnwrap(changes.last?.record)
        let rewoundPause = try WiltedRecordCodec().decodePlaybackRecord(rewoundPauseEnvelope).value
        XCTAssertEqual(rewoundPause.intent, .rewind)
        XCTAssertEqual(rewoundPause.positionSeconds, 9)
        XCTAssertEqual(harness.model.selectedPlayback, rewoundPause)
        XCTAssertEqual(harness.model.playbackPhase, .paused)
    }

    func testRemotePlayWhileBackgroundedRestartsBoundedPersistence() async throws {
        let sleeper = BackgroundCheckpointSleeper()
        let harness = try await PlaybackHarness.make(
            backgroundSleeper: { duration in try await sleeper.sleep(for: duration) }
        )
        let remoteCommands = MediaPlayerRemoteCommands()
        await harness.model.install(remoteCommands: remoteCommands)
        await harness.model.refresh()
        await harness.model.play(itemID: harness.itemID)
        await harness.model.enterBackground()
        let initialInterval = await sleeper.waitUntilSleeping()
        XCTAssertEqual(initialInterval, .seconds(15))

        XCTAssertEqual(remoteCommands.receivePause(nil), .success)
        _ = await waitForEnqueuedChanges(harness.repository, count: 3)
        XCTAssertEqual(harness.model.playbackPhase, .paused)

        XCTAssertEqual(remoteCommands.receivePlay(nil), .success)
        let changes = await waitForEnqueuedChanges(harness.repository, count: 4)
        XCTAssertEqual(changes.count, 4)
        XCTAssertEqual(harness.model.playbackPhase, .playing)
        for _ in 0..<100 {
            if await sleeper.sleepCount() == 2 { break }
            try? await Task.sleep(for: .milliseconds(2))
        }
        let sleepCount = await sleeper.sleepCount()
        XCTAssertEqual(sleepCount, 2,
                       "remote resume in the background must restart the bounded checkpoint loop")
    }

    func testRemotePlayFailureDoesNotPublishOrEnqueueActiveState() async throws {
        let harness = try await PlaybackHarness.make()
        let remoteCommands = MediaPlayerRemoteCommands()
        await harness.model.install(remoteCommands: remoteCommands)
        await harness.model.refresh()
        await harness.model.play(itemID: harness.itemID)
        harness.engine.currentTime = 8
        await harness.model.pause()
        let selectedBefore = harness.model.selectedPlayback
        let writesBefore = await harness.repository.enqueuedChanges()
        harness.engine.allowsPlayback = false

        XCTAssertEqual(remoteCommands.receivePlay(nil), .success)
        for _ in 0..<100 { await Task.yield() }

        let writesAfter = await harness.repository.enqueuedChanges()
        XCTAssertEqual(writesAfter, writesBefore)
        XCTAssertEqual(harness.model.selectedPlayback, selectedBefore)
        XCTAssertEqual(harness.model.playbackPhase, .paused)
        XCTAssertFalse(harness.engine.isPlaying)
    }

    func testStaleRemoteResultCannotDivergeSelectedSuccessorStatus() async throws {
        let harness = try await PlaybackHarness.make(includeSecondItem: true)
        let successor = try XCTUnwrap(harness.secondItemID)
        let remoteCommands = MediaPlayerRemoteCommands()
        await harness.model.install(remoteCommands: remoteCommands)
        await harness.model.refresh()
        await harness.model.play(itemID: harness.itemID)
        harness.engine.currentTime = 20
        let delayedRemotePersistence = AsyncEnqueueGate()
        await harness.repository.holdNextEnqueue(on: delayedRemotePersistence)

        XCTAssertEqual(remoteCommands.receiveRewind(nil), .success)
        let remotePersistenceStarted = await delayedRemotePersistence.waitUntilStarted()
        XCTAssertTrue(remotePersistenceStarted)
        await harness.model.play(itemID: successor)
        XCTAssertEqual(harness.model.playbackPhase, .playing)

        await delayedRemotePersistence.release()
        for _ in 0..<100 { await Task.yield() }

        XCTAssertEqual(harness.model.selectedItemID, successor)
        XCTAssertEqual(harness.model.selectedPlayback?.itemID, successor)
        XCTAssertEqual(harness.model.playbackPhase, .playing,
                       "a delayed outgoing remote result must not overwrite the active successor")
    }

    private func waitForEnqueuedChanges(
        _ repository: StaticSyncRepository,
        count: Int
    ) async -> [SyncPendingChange] {
        for _ in 0..<100 {
            let changes = await repository.enqueuedChanges()
            if changes.count == count { return changes }
            try? await Task.sleep(for: .milliseconds(2))
        }
        return await repository.enqueuedChanges()
    }

    func testDefaultConstructionKeepsXCTestLocalWithoutDisablingLiveCloudKit() {
        XCTAssertEqual(WiltedListenerAppModel.defaultSessionMode(), .localOnly)
        XCTAssertEqual(
            WiltedListenerAppModel.defaultSessionMode(
                environment: ["XCTestConfigurationFilePath": "/tmp/wilted-tests.xctestconfiguration"]
            ),
            .localOnly
        )
        XCTAssertEqual(
            WiltedListenerAppModel.defaultSessionMode(environment: [:], isXCTestRuntime: true),
            .localOnly
        )
#if WILTED_CLOUDKIT_LIVE
        XCTAssertEqual(
            WiltedListenerAppModel.defaultSessionMode(environment: [:], isXCTestRuntime: false),
            .liveCloudKit
        )
#else
        XCTAssertEqual(
            WiltedListenerAppModel.defaultSessionMode(environment: [:], isXCTestRuntime: false),
            .localOnly
        )
#endif
    }

    func testColdLaunchSessionConstructionFailureKeepsLocalCatalogAndDownloadedAudio() async throws {
        let fixture = try makeChunkedCatalogFixture()
        _ = try await fixture.cache.store(data: fixture.bytes, asset: fixture.asset)
        let factory = FailingSessionFactory()
        let model = WiltedListenerAppModel(
            repository: fixture.repository,
            sessionFactory: { stateData in
                try await factory.makeSession(stateData: stateData)
            },
            cache: fixture.cache
        )

        await model.start()

        let constructionCount = await factory.constructionCount
        let cachedURL = await fixture.cache.url(for: fixture.asset)
        XCTAssertEqual(constructionCount, 1, "cold launch must attempt the live session once")
        XCTAssertEqual(model.items.map(\.itemID), [fixture.itemID])
        XCTAssertEqual(model.items.first?.state, .downloaded,
                       "the local cache must remain available when live session construction fails")
        XCTAssertNotNil(cachedURL)
        XCTAssertEqual(model.downloadStatistics, ListenerDownloadStatistics(fileCount: 1, byteCount: Int64(fixture.bytes.count)))
        guard case let .failed(message, retryable) = model.syncPhase else {
            return XCTFail("Expected a retryable live-session construction failure, got \(model.syncPhase)")
        }
        XCTAssertTrue(message.contains("Sync unavailable"))
        XCTAssertTrue(retryable)
    }

    func testDebugModelDoesNotContactTransportAndReportsLocalFailure() async {
        let model = WiltedListenerAppModel()
        await model.refresh()

        guard case let .failed(message, retryable) = model.syncPhase else {
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

    func testRetryDownloadRepeatsTheFailedDownloadWithoutRefreshing() async throws {
        let fixture = try makeChunkedCatalogFixture()
        let loader = FailOnceChunkLoader(data: fixture.bytes)
        let transport = RecordingSyncTransport()
        let model = WiltedListenerAppModel(
            repository: fixture.repository,
            transport: transport,
            cache: fixture.cache,
            audioChunkLoader: { itemID, revisionID, manifest in
                try await loader.load(itemID: itemID, revisionID: revisionID, manifest: manifest)
            }
        )

        await model.refresh()
        let refreshesBeforeRetry = await transport.fetchCountValue()
        await model.download(itemID: fixture.itemID)
        XCTAssertEqual(model.syncPhase, .failed("Download failed: network unavailable", retryable: true))

        await model.retrySyncOperation()

        let attempts = await loader.attemptCount()
        let refreshesAfterRetry = await transport.fetchCountValue()
        XCTAssertEqual(attempts, 2)
        XCTAssertEqual(refreshesAfterRetry, refreshesBeforeRetry,
                       "retrying a download must not refresh the catalog")
        XCTAssertEqual(model.items.first?.state, .downloaded)
        XCTAssertEqual(model.syncPhase, .ready)
    }

    func testRetrySendRepeatsTheFailedSendWithoutRefreshing() async throws {
        let transport = RecordingSyncTransport(saveErrors: [.network])
        let harness = try await PlaybackHarness.make(transport: transport)
        await harness.model.refresh()
        await harness.model.play(itemID: harness.itemID)
        let refreshesBeforeRetry = await transport.fetchCountValue()

        await harness.model.sendPending()
        XCTAssertEqual(harness.model.syncPhase, .failed("Send failed: network unavailable", retryable: true))

        await harness.model.retrySyncOperation()

        let saves = await transport.saveCountValue()
        let refreshesAfterRetry = await transport.fetchCountValue()
        XCTAssertEqual(saves, 2)
        XCTAssertEqual(refreshesAfterRetry, refreshesBeforeRetry,
                       "retrying a send must not refresh the catalog")
        XCTAssertEqual(harness.model.syncPhase, .ready)
    }

    func testRetryPlaybackRepeatsTheFailedPlayWithoutRefreshing() async throws {
        let transport = RecordingSyncTransport()
        let harness = try await PlaybackHarness.make(transport: transport)
        await harness.model.refresh()
        let refreshesBeforeRetry = await transport.fetchCountValue()
        harness.engine.allowsPlayback = false

        await harness.model.play(itemID: harness.itemID)
        guard case .failed(_, retryable: true) = harness.model.playbackPhase else {
            return XCTFail("Expected a retryable playback failure")
        }

        harness.engine.allowsPlayback = true
        await harness.model.retryPlaybackOperation()

        let refreshesAfterRetry = await transport.fetchCountValue()
        XCTAssertEqual(refreshesAfterRetry, refreshesBeforeRetry,
                       "retrying playback must not refresh the catalog")
        XCTAssertEqual(harness.model.playbackPhase, .playing)
        XCTAssertTrue(harness.engine.isPlaying)
    }

    func testRetrySeekRepeatsTheFailedSeekWithoutRefreshing() async throws {
        let transport = RecordingSyncTransport()
        let harness = try await PlaybackHarness.make(transport: transport)
        await harness.model.refresh()
        await harness.model.play(itemID: harness.itemID)
        let refreshesBeforeRetry = await transport.fetchCountValue()
        harness.engine.allowsPlayback = false

        await harness.model.seek(to: 12)
        guard case .failed(_, retryable: true) = harness.model.playbackPhase else {
            return XCTFail("Expected a retryable seek failure")
        }

        harness.engine.allowsPlayback = true
        await harness.model.retryPlaybackOperation()

        let refreshesAfterRetry = await transport.fetchCountValue()
        XCTAssertEqual(refreshesAfterRetry, refreshesBeforeRetry,
                       "retrying a seek must not refresh the catalog")
        XCTAssertEqual(harness.model.selectedPlayback?.positionSeconds, 12)
        XCTAssertEqual(harness.model.playbackPhase, .playing)
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
        XCTAssertEqual(model.syncPhase, .ready)
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
        XCTAssertEqual(model.syncPhase, .ready)
    }

    func testAutomaticDiscoverySurfacesRetryableFailure() async {
        let repository = StaticSyncRepository(state: SyncRepositoryState(engineState: Data([1])))
        let transport = RecordingSyncTransport(fetchError: TestSyncError.network)
        let model = WiltedListenerAppModel(repository: repository, transport: transport)

        await model.start()

        guard case let .failed(message, retryable) = model.syncPhase else {
            return XCTFail("Expected automatic discovery failure, got \(model.syncPhase)")
        }
        XCTAssertTrue(message.contains("Refresh failed"))
        XCTAssertTrue(retryable)
    }

    func testRefreshRetriesAStaleStageWithoutDiscardingTheFetchedBatch() async throws {
        let (records, concurrentChanges) = try listenerStaleStageFixture(changeCount: 1)
        let batch = try SyncFetchBatch(generationID: "listener-stale-retry", records: records, engineState: Data([4]))
        let repository = StaleStageListenerRepository(concurrentChanges: concurrentChanges)
        let transport = SingleBatchSyncTransport(batch: batch)
        let model = WiltedListenerAppModel(repository: repository, transport: transport)

        await model.refresh()

        XCTAssertEqual(model.syncPhase, .ready)
        let stageCalls = await repository.stageCalls
        let commitCalls = await repository.commitCalls
        let fetchCalls = await transport.fetchCalls
        let state = await repository.state()
        XCTAssertEqual(stageCalls, 2)
        XCTAssertEqual(commitCalls, 2)
        XCTAssertEqual(fetchCalls, 1)
        XCTAssertEqual(state.records, records)
        XCTAssertEqual(state.pendingChanges, concurrentChanges)
    }

    func testRefreshFailsAfterBoundedStaleStageRetries() async throws {
        let (records, concurrentChanges) = try listenerStaleStageFixture(
            changeCount: SyncCoordinator.maximumStaleStageAttempts
        )
        let batch = try SyncFetchBatch(generationID: "listener-stale-exhaustion", records: records, engineState: Data([5]))
        let repository = StaleStageListenerRepository(concurrentChanges: concurrentChanges)
        let transport = SingleBatchSyncTransport(batch: batch)
        let model = WiltedListenerAppModel(repository: repository, transport: transport)

        await model.refresh()

        guard case let .failed(message, retryable) = model.syncPhase else {
            return XCTFail("Expected stale retry exhaustion, got \(model.syncPhase)")
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

}
