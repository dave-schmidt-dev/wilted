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
        let pauseEnvelope = try XCTUnwrap(changes.last?.record)
        let pause = try WiltedRecordCodec().decodePlaybackRecord(pauseEnvelope).value
        XCTAssertEqual(pause.intent, .progress)
        XCTAssertEqual(pause.positionSeconds, 9)
        XCTAssertEqual(harness.model.selectedPlayback, pause)
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
        XCTAssertEqual(WiltedListenerAppModel.defaultSessionMode(environment: [:]), .liveCloudKit)
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

    func testNextRefreshRebuildsFailedSessionFromPersistedStateOnce() async throws {
        let (records, pendingChanges) = try listenerStaleStageFixture(changeCount: 1)
        let persistedEngineState = Data([1])
        let repository = StaticSyncRepository(state: SyncRepositoryState(
            records: records,
            engineState: persistedEngineState,
            pendingChanges: pendingChanges
        ))
        let failedTransport = RecordingSyncTransport(fetchError: TestSyncError.network)
        let recoveredTransport = RecordingSyncTransport()
        let cancelProbe = SessionCancelProbe()
        let factory = SessionSequenceProbe(
            transports: [failedTransport, recoveredTransport],
            firstCancelProbe: cancelProbe
        )
        let model = WiltedListenerAppModel(
            repository: repository,
            sessionFactory: { stateData in
                try await factory.makeSession(stateData: stateData)
            }
        )

        await model.refresh()
        guard case .failed(_, retryable: true) = model.syncPhase else {
            return XCTFail("Expected the initial transport to fail")
        }
        XCTAssertEqual(model.items.count, 1, "the committed local catalog remains visible")

        await model.refresh()

        XCTAssertEqual(model.syncPhase, .ready)
        let stateInputs = await factory.stateInputs()
        let firstSessionWasCancelled = await cancelProbe.wasCalled
        let failedFetchCount = await failedTransport.fetchCountValue()
        let recoveredFetchCount = await recoveredTransport.fetchCountValue()
        XCTAssertEqual(stateInputs, [persistedEngineState, persistedEngineState])
        XCTAssertTrue(firstSessionWasCancelled)
        XCTAssertEqual(failedFetchCount, 1)
        XCTAssertEqual(recoveredFetchCount, 1)
        let recoveredState = await repository.state()
        XCTAssertEqual(recoveredState.records, records)
        XCTAssertEqual(recoveredState.pendingChanges, pendingChanges)
    }

    func testPixelFixturesAreAccountFreeAndExposeTheirIntendedTerminalStates() {
        let library = WiltedListenerAppModel.makePixelFixture()
        XCTAssertEqual(library.syncPhase, .ready)
        XCTAssertEqual(library.items.count, 1)
        XCTAssertEqual(library.transcriptsByItem.values.first?.availability, .available)
        XCTAssertEqual(library.downloadStatistics.fileCount, 1)
        XCTAssertNotNil(library.syncObservability.lastSuccessfulFetchAt)

        let playing = WiltedListenerAppModel.makePixelFixture(state: .nowPlaying)
        XCTAssertEqual(playing.playbackPhase, .playing)
        XCTAssertEqual(playing.selectedPlayback?.positionSeconds, 31)

        let failure = WiltedListenerAppModel.makePixelFixture(state: .terminalFailure)
        XCTAssertEqual(failure.syncPhase, .failed("iCloud account changed; sync is quarantined", retryable: false))
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
                if case let .failed(message, retryable) = model.syncPhase,
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
        guard case let .failed(message, retryable) = model.syncPhase else {
            XCTFail("Expected a held-work failure, got \(model.syncPhase)")
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

    func testAFirstEverPlayStartsPlaybackInsteadOfFailingTheSequenceFloor() async throws {
        let harness = try await PlaybackHarness.make()

        await harness.model.refresh()
        XCTAssertEqual(harness.model.items.first?.state, .downloaded,
                       "the cached asset should present as downloaded before play is attempted")

        await harness.model.play(itemID: harness.itemID)

        guard case .playing = harness.model.playbackPhase else {
            return XCTFail("first play failed: \(harness.model.playbackPhase)")
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
        XCTAssertEqual(harness.model.playbackPhase, .refreshing("Preparing offline audio"))

        gate.release.signal()
        await play.value
        XCTAssertEqual(harness.model.playbackPhase, .playing)
    }

    func testPlaybackCompletionEventsPreservePlayingAndPausedStatuses() async throws {
        let harness = try await PlaybackHarness.make()
        await harness.model.refresh()

        await harness.model.play(itemID: harness.itemID)
        await drainPlaybackStatusDelivery()
        XCTAssertEqual(harness.model.playbackPhase, .playing)

        await harness.model.pause()
        await drainPlaybackStatusDelivery()
        XCTAssertEqual(harness.model.playbackPhase, .paused)
    }

    func testRestartOpensANewSessionInsteadOfFailingTheSequenceFloor() async throws {
        let harness = try await PlaybackHarness.make()
        await harness.model.refresh()
        await harness.model.play(itemID: harness.itemID)
        let firstSession = try XCTUnwrap(harness.model.selectedPlayback).sessionID

        await harness.model.restart()

        guard case .playing = harness.model.playbackPhase else {
            return XCTFail("restart failed: \(harness.model.playbackPhase)")
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
        XCTAssertEqual(harness.model.playbackPhase, .refreshing("Preparing offline audio"))

        gate.release.signal()
        await restart.value
        XCTAssertEqual(harness.model.playbackPhase, .playing)
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
        let writes = await harness.repository.enqueuedChanges()
        XCTAssertEqual(writes.count, 1, "the live readout must not add a durable write")
    }

    func testNaturalCompletionReachesRepositoryEnqueueAsCompletedCheckpoint() async throws {
        let harness = try await PlaybackHarness.make()
        await harness.model.refresh()
        await harness.model.play(itemID: harness.itemID)

        harness.engine.finishNaturally()
        var changes: [SyncPendingChange] = []
        for _ in 0..<100 {
            changes = await harness.repository.enqueuedChanges()
            if changes.count == 2 { break }
            try? await Task.sleep(for: .milliseconds(2))
        }

        XCTAssertEqual(changes.count, 2)
        let completedEnvelope = try XCTUnwrap(changes.last?.record)
        let completed = try WiltedRecordCodec().decodePlaybackRecord(completedEnvelope).value
        XCTAssertTrue(completed.completed)
        XCTAssertEqual(completed.positionSeconds, completed.durationSeconds)
        XCTAssertEqual(harness.model.selectedPlayback, completed)
    }

    func testBackgroundAfterNaturalCompletionKeepsCompletedCheckpointWithoutDuplicateWrite() async throws {
        let harness = try await PlaybackHarness.make()
        await harness.model.refresh()
        await harness.model.play(itemID: harness.itemID)

        harness.engine.finishNaturally()
        for _ in 0..<100 {
            if (await harness.repository.enqueuedChanges()).count == 2 { break }
            try? await Task.sleep(for: .milliseconds(2))
        }

        await harness.model.enterBackground()
        for _ in 0..<100 { await Task.yield() }

        let changes = await harness.repository.enqueuedChanges()
        XCTAssertEqual(changes.count, 2)
        let finalEnvelope = try XCTUnwrap(changes.last?.record)
        let final = try WiltedRecordCodec().decodePlaybackRecord(finalEnvelope).value
        XCTAssertTrue(final.completed)
        XCTAssertEqual(harness.model.selectedPlayback, final)
    }

    func testPausedBackgroundTransitionCreatesNoDuplicateDurableWrite() async throws {
        let harness = try await PlaybackHarness.make()
        await harness.model.refresh()
        await harness.model.play(itemID: harness.itemID)
        harness.engine.currentTime = 7
        await harness.model.pause()
        let beforeBackground = await harness.repository.enqueuedChanges()

        await harness.model.enterBackground()
        for _ in 0..<100 { await Task.yield() }

        let afterBackground = await harness.repository.enqueuedChanges()
        XCTAssertEqual(beforeBackground.count, 2)
        XCTAssertEqual(afterBackground, beforeBackground)
        XCTAssertEqual(harness.model.selectedPlayback?.positionSeconds, 7)
        XCTAssertFalse(harness.model.selectedPlayback?.completed ?? true)
    }

    func testItemSwitchPersistsOutgoingLivePositionBeforeSelectingSuccessor() async throws {
        let harness = try await PlaybackHarness.make(includeSecondItem: true)
        let successor = try XCTUnwrap(harness.secondItemID)
        await harness.model.refresh()
        await harness.model.play(itemID: harness.itemID)
        let supersededGeneration = harness.engine.completionGeneration
        harness.engine.currentTime = 9

        await harness.model.play(itemID: successor)

        let changes = await harness.repository.enqueuedChanges()
        XCTAssertEqual(changes.count, 3)
        let outgoingEnvelope = try XCTUnwrap(changes.dropFirst().first?.record)
        let outgoing = try WiltedRecordCodec().decodePlaybackRecord(outgoingEnvelope).value
        XCTAssertEqual(outgoing.itemID, harness.itemID)
        XCTAssertEqual(outgoing.positionSeconds, 9)
        XCTAssertEqual(harness.model.selectedItemID, successor)
        XCTAssertEqual(changes.last?.recordID,
                       try WiltedRecordID.playback(successor, try XCTUnwrap(harness.model.selectedPlayback?.revisionID)))

        harness.engine.fireCompletion(generation: supersededGeneration)
        for _ in 0..<100 { await Task.yield() }
        let changesAfterDelayedCompletion = await harness.repository.enqueuedChanges()
        XCTAssertEqual(changesAfterDelayedCompletion.count, 3)
        XCTAssertEqual(harness.model.selectedItemID, successor)
        XCTAssertFalse(harness.model.selectedPlayback?.completed ?? true)
    }

    func testDelayedOutgoingCompletionCannotPauseSelectedSuccessor() async throws {
        let harness = try await PlaybackHarness.make(includeSecondItem: true)
        let successor = try XCTUnwrap(harness.secondItemID)
        await harness.model.refresh()
        await harness.model.play(itemID: harness.itemID)
        let completionPersistence = AsyncEnqueueGate()
        await harness.repository.holdNextEnqueue(on: completionPersistence)

        harness.engine.finishNaturally()
        let completionStarted = await completionPersistence.waitUntilStarted()
        XCTAssertTrue(completionStarted)
        await harness.model.play(itemID: successor)
        XCTAssertEqual(harness.model.playbackPhase, .playing)

        await completionPersistence.release()
        for _ in 0..<100 {
            if (await harness.repository.enqueuedChanges()).count == 3 { break }
            try? await Task.sleep(for: .milliseconds(2))
        }

        XCTAssertEqual(harness.model.selectedItemID, successor)
        XCTAssertEqual(harness.model.playbackPhase, .playing)
        XCTAssertFalse(harness.model.selectedPlayback?.completed ?? true)
    }

    func testFastForegroundResumeInvalidatesPendingBackgroundEntry() async throws {
        let sleeper = BackgroundCheckpointSleeper()
        let harness = try await PlaybackHarness.make(
            backgroundSleeper: { duration in try await sleeper.sleep(for: duration) }
        )
        await harness.model.refresh()
        await harness.model.play(itemID: harness.itemID)
        let loadGate = harness.engine.holdNextLoad()
        let restart = Task { await harness.model.restart() }
        let loadStarted = await loadGate.waitUntilStarted()
        XCTAssertTrue(loadStarted)

        let background = Task { await harness.model.enterBackground() }
        for _ in 0..<100 { await Task.yield() }
        let foreground = Task { await harness.model.resumeForeground() }
        for _ in 0..<100 { await Task.yield() }
        loadGate.release.signal()

        await restart.value
        await background.value
        await foreground.value
        for _ in 0..<100 { await Task.yield() }

        let scheduledSleeps = await sleeper.sleepCount()
        XCTAssertEqual(scheduledSleeps, 0, "a superseded background entry must not persist or schedule checkpoints")
    }

    func testResumeCancelsBackgroundTimerBeforePersistingOneForegroundCheckpoint() async throws {
        let sleeper = BackgroundCheckpointSleeper()
        let harness = try await PlaybackHarness.make(
            backgroundSleeper: { duration in try await sleeper.sleep(for: duration) }
        )
        await harness.model.refresh()
        await harness.model.play(itemID: harness.itemID)
        harness.engine.currentTime = 2
        await harness.model.enterBackground()
        let interval = await sleeper.waitUntilSleeping()
        XCTAssertEqual(interval, .seconds(15))

        harness.engine.currentTime = 18
        await sleeper.releaseOne()
        await harness.model.resumeForeground()
        for _ in 0..<100 { await Task.yield() }

        let changes = await harness.repository.enqueuedChanges()
        XCTAssertEqual(changes.count, 3, "resume and the cancelled timer must produce only one final checkpoint")
        let finalEnvelope = try XCTUnwrap(changes.last?.record)
        let final = try WiltedRecordCodec().decodePlaybackRecord(finalEnvelope).value
        XCTAssertEqual(final.positionSeconds, 18)
        XCTAssertFalse(final.completed)
    }

    func testBackgroundCheckpointLoopStopsAfterNaturalCompletion() async throws {
        let sleeper = BackgroundCheckpointSleeper()
        let harness = try await PlaybackHarness.make(
            backgroundSleeper: { duration in try await sleeper.sleep(for: duration) }
        )
        await harness.model.refresh()
        await harness.model.play(itemID: harness.itemID)
        harness.engine.currentTime = 2
        await harness.model.enterBackground()
        let interval = await sleeper.waitUntilSleeping()
        XCTAssertEqual(interval, .seconds(15))

        harness.engine.finishNaturally()
        for _ in 0..<100 {
            if (await harness.repository.enqueuedChanges()).count == 3 { break }
            try? await Task.sleep(for: .milliseconds(2))
        }
        await sleeper.releaseOne()
        for _ in 0..<100 { await Task.yield() }

        let changes = await harness.repository.enqueuedChanges()
        let sleepCount = await sleeper.sleepCount()
        XCTAssertEqual(changes.count, 3)
        XCTAssertEqual(sleepCount, 1, "completed playback must terminate the checkpoint loop")
    }

    func testActiveBackgroundBeyondFifteenSecondCheckpointIntervalRestoresAfterSimulatedRelaunch() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("wilted-background-checkpoint-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = try ListenerRepository(directoryURL: root)
        let cache = try ListenerAudioCache(rootURL: root.appendingPathComponent("Audio", isDirectory: true))
        let url = URL(string: "https://example.test/background-checkpoint")!
        let itemID = try ItemID.derive(from: url)
        let revisionID = try RevisionID(rawValue: "revision-background-checkpoint")
        let bytes = Data("background-checkpoint-audio".utf8)
        let digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        let asset = try WiltedAsset(assetID: "background-checkpoint-audio", contentHash: "sha256:\(digest)")
        let article = try Article(itemID: itemID, canonicalURL: url, title: "Background checkpoint",
                                  source: "Test", createdAt: Timestamp(Date()))
        let revision = try AudioRevision(itemID: itemID, revisionID: revisionID, durationSeconds: 60,
                                         byteCount: Int64(bytes.count), contentHash: asset.contentHash,
                                         mediaType: "audio/mp4", createdAt: Timestamp(Date()), schemaVersion: 1)
        let codec = WiltedRecordCodec()
        let records = [try codec.encode(article: article, currentRevisionID: revisionID),
                       try codec.encode(revision: revision, audioAsset: asset)]
        try await repository.commit(try await repository.stage(
            try SyncFetchBatch(generationID: "background-seed", records: records, engineState: Data([1]))
        ))
        _ = try await cache.store(data: bytes, asset: asset)
        let engine = FakeAudioEngine(duration: 60)
        let controller = ListenerPlaybackController(cache: cache, engine: engine,
                                                    session: FakeAudioSession(), nowPlaying: FakeNowPlaying())
        let sleeper = BackgroundCheckpointSleeper()
        let model = WiltedListenerAppModel(
            repository: repository,
            cache: cache,
            playback: controller,
            metadataLoader: { await repository.loadMetadata() },
            metadataSaver: { metadata in try await repository.saveMetadata(metadata) },
            backgroundSleeper: { duration in try await sleeper.sleep(for: duration) }
        )
        await model.refresh()
        await model.play(itemID: itemID)
        engine.currentTime = 2
        await model.enterBackground()
        let interval = await sleeper.waitUntilSleeping()
        XCTAssertEqual(interval, .seconds(15), "the durable background cadence is fifteen seconds, not per-second")

        engine.currentTime = 18
        await sleeper.releaseOne()
        var persistedPosition: Double?
        for _ in 0..<100 {
            let state = await repository.state()
            persistedPosition = state.records.compactMap { try? codec.decodePlaybackRecord($0).value.positionSeconds }.first
            if persistedPosition == 18 { break }
            try? await Task.sleep(for: .milliseconds(2))
        }
        XCTAssertEqual(persistedPosition, 18)

        let reopened = try ListenerRepository(directoryURL: root)
        let relaunched = WiltedListenerAppModel(repository: reopened,
                                                metadataLoader: { await reopened.loadMetadata() })
        await relaunched.refresh()
        XCTAssertEqual(relaunched.selectedPlayback?.positionSeconds, 18)
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

    func testLegacyRevisionDownloadsThroughDirectRecordFetch() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("wilted-legacy-download-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let cloudRoot = root.appendingPathComponent("CloudAssets", isDirectory: true)
        let cache = try ListenerAudioCache(rootURL: root.appendingPathComponent("Audio", isDirectory: true))
        let stager = try FileCloudKitAssetStager(rootURL: cloudRoot)
        let mapper = try CloudKitRecordMapper(stager: stager)
        let bytes = Data("legacy-listener-audio".utf8)
        let source = root.appendingPathComponent("legacy-source.m4a")
        try bytes.write(to: source)
        let contentHash = "sha256:" + SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        let itemID = try ItemID.derive(from: URL(string: "https://example.test/legacy-listener")!)
        let revisionID = try RevisionID(rawValue: "revision-legacy-listener")
        let article = try Article(
            itemID: itemID,
            canonicalURL: URL(string: "https://example.test/legacy-listener")!,
            title: "Legacy listener",
            source: "Test",
            createdAt: Timestamp(Date())
        )
        let revision = try AudioRevision(
            itemID: itemID,
            revisionID: revisionID,
            durationSeconds: 12,
            byteCount: Int64(bytes.count),
            contentHash: contentHash,
            mediaType: "audio/mp4",
            createdAt: Timestamp(Date()),
            schemaVersion: 1
        )
        let codec = WiltedRecordCodec()
        let legacyEnvelope = try codec.encode(
            revision: revision,
            audioAsset: WiltedAsset(assetID: "legacy-write-fixture", contentHash: contentHash)
        )
        let cloudRecord = try mapper.encode(legacyEnvelope, assetURLs: ["legacy-write-fixture": source])
        let metadataEnvelope = try mapper.decodeMetadataOnly(cloudRecord).envelope
        let repository = StaticSyncRepository(state: SyncRepositoryState(records: [
            try codec.encode(article: article, currentRevisionID: revisionID),
            metadataEnvelope,
        ]))
        let driver = LegacyAssetEngineDriver(record: cloudRecord)
        let transport = try CloudKitSyncTransport(driver: driver, role: .iphone, mapper: mapper)
        let model = WiltedListenerAppModel(
            repository: repository,
            cache: cache,
            assetLoader: { recordID, asset in
                try await transport.fetchLegacyRevisionAsset(recordID: recordID, expectedAsset: asset)
            }
        )

        await model.refresh()
        await model.download(itemID: itemID)

        let cached = await cache.url(for: try XCTUnwrap(model.items.first?.asset))
        let requestedRecordNames = await driver.requestedRecordNames()
        XCTAssertEqual(model.items.first?.state, .downloaded)
        XCTAssertEqual(try cached.map { try Data(contentsOf: $0) }, bytes)
        XCTAssertEqual(requestedRecordNames, [legacyEnvelope.id.recordName])
    }

    func testQuarantinedLegacyRevisionDownloadLeavesMetadataOnlyAndNoCache() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("wilted-legacy-quarantine-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = try ListenerAudioCache(rootURL: root.appendingPathComponent("Audio", isDirectory: true))
        let stager = try FileCloudKitAssetStager(
            rootURL: root.appendingPathComponent("CloudAssets", isDirectory: true)
        )
        let mapper = try CloudKitRecordMapper(stager: stager)
        let bytes = Data("legacy-quarantined-audio".utf8)
        let source = root.appendingPathComponent("legacy-source.m4a")
        try bytes.write(to: source)
        let contentHash = "sha256:" + SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        let itemID = try ItemID.derive(from: URL(string: "https://example.test/legacy-quarantine")!)
        let revisionID = try RevisionID(rawValue: "revision-legacy-quarantine")
        let article = try Article(
            itemID: itemID,
            canonicalURL: URL(string: "https://example.test/legacy-quarantine")!,
            title: "Legacy quarantine",
            source: "Test",
            createdAt: Timestamp(Date())
        )
        let revision = try AudioRevision(
            itemID: itemID,
            revisionID: revisionID,
            durationSeconds: 12,
            byteCount: Int64(bytes.count),
            contentHash: contentHash,
            mediaType: "audio/mp4",
            createdAt: Timestamp(Date()),
            schemaVersion: 1
        )
        let codec = WiltedRecordCodec()
        let legacyEnvelope = try codec.encode(
            revision: revision,
            audioAsset: WiltedAsset(assetID: "legacy-quarantine-fixture", contentHash: contentHash)
        )
        let cloudRecord = try mapper.encode(
            legacyEnvelope,
            assetURLs: ["legacy-quarantine-fixture": source]
        )
        let metadataEnvelope = try mapper.decodeMetadataOnly(cloudRecord).envelope
        let repository = StaticSyncRepository(state: SyncRepositoryState(records: [
            try codec.encode(article: article, currentRevisionID: revisionID),
            metadataEnvelope,
        ]))
        let driver = LegacyAssetEngineDriver(record: cloudRecord, holdRecordFetch: true)
        let transport = try CloudKitSyncTransport(driver: driver, role: .iphone, mapper: mapper)
        let model = WiltedListenerAppModel(
            repository: repository,
            cache: cache,
            assetLoader: { recordID, asset in
                try await transport.fetchLegacyRevisionAsset(recordID: recordID, expectedAsset: asset)
            }
        )

        await model.refresh()
        let download = Task { await model.download(itemID: itemID) }
        let fetchStarted = await driver.waitForRecordFetch()
        XCTAssertTrue(fetchStarted)
        await driver.emit(.accountChanged(.switchAccounts))
        for _ in 0..<100 {
            if await transport.isQuarantined() { break }
            try? await Task.sleep(for: .milliseconds(5))
        }
        let quarantined = await transport.isQuarantined()
        XCTAssertTrue(quarantined)
        await driver.releaseRecordFetch()
        await download.value

        let cached = await cache.url(for: try XCTUnwrap(model.items.first?.asset))
        XCTAssertEqual(model.items.first?.state, .metadataOnly)
        XCTAssertNil(cached)
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
        guard case let .failed(message, retryable) = model.syncPhase else {
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
        XCTAssertEqual(model.syncPhase, .failed("Download failed: network unavailable", retryable: true))
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
        XCTAssertTrue(model.syncPhase.isBusy,
                      "the cancelled generation must not clear the retry's visible progress")

        await loader.release()
        await retry.value
        XCTAssertEqual(model.items.first?.state, .downloaded)
        XCTAssertEqual(model.syncPhase, .ready)
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
            if case .failed(_, retryable: false) = model.syncPhase { break }
            await Task.yield()
        }

        await loader.release()
        await download.value
        let cachedURL = await fixture.cache.url(for: fixture.asset)
        let sessionWasCancelled = await cancelProbe.wasCalled
        XCTAssertEqual(model.items.first?.state, .metadataOnly)
        XCTAssertNil(cachedURL)
        XCTAssertTrue(sessionWasCancelled)
        XCTAssertEqual(model.syncPhase,
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
            if case .failed(_, retryable: false) = model.syncPhase { break }
            await Task.yield()
        }

        await model.download(itemID: fixture.itemID)

        let loadCount = await loader.count
        XCTAssertEqual(loadCount, 0)
        XCTAssertEqual(model.items.first?.state, .metadataOnly)
        XCTAssertEqual(model.syncPhase,
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

private actor SessionSequenceProbe {
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

private func listenerStaleStageFixture(changeCount: Int) throws -> ([WiltedRecordEnvelope], [SyncPendingChange]) {
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

private actor StaticSyncRepository: SyncRepository {
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

private actor LegacyAssetEngineDriver: CloudKitEngineDriver {
    nonisolated let events: AsyncStream<CloudKitEngineEvent>
    private let continuation: AsyncStream<CloudKitEngineEvent>.Continuation
    private let record: CKRecord
    private let holdRecordFetch: Bool
    private let recordFetchRelease: AsyncStream<Void>.Continuation
    private let recordFetchReleaseStream: AsyncStream<Void>
    private var requestedNames: [String] = []

    init(record: CKRecord, holdRecordFetch: Bool = false) {
        let (events, continuation) = AsyncStream<CloudKitEngineEvent>.makeStream()
        let (releaseStream, release) = AsyncStream<Void>.makeStream()
        self.events = events
        self.continuation = continuation
        self.record = record
        self.holdRecordFetch = holdRecordFetch
        self.recordFetchRelease = release
        self.recordFetchReleaseStream = releaseStream
    }

    func fetchChanges() async throws {}
    func fetchRecords(_ ids: [CKRecord.ID]) async throws -> [CKRecord] {
        requestedNames.append(contentsOf: ids.map(\.recordName))
        if holdRecordFetch {
            for await _ in recordFetchReleaseStream { break }
        }
        return ids.contains(record.recordID) ? [record] : []
    }
    func sendChanges() async throws {}
    func cancelOperations() async {}
    func addPendingRecordZoneChanges(_ changes: [CKSyncEngine.PendingRecordZoneChange]) async {}
    nonisolated func isValidStateData(_ data: Data) -> Bool { true }
    func requestedRecordNames() -> [String] { requestedNames }
    func emit(_ event: CloudKitEngineEvent) { continuation.yield(event) }
    func releaseRecordFetch() { recordFetchRelease.yield(()) }
    func waitForRecordFetch() async -> Bool {
        let clock = ContinuousClock()
        let end = clock.now + .seconds(5)
        while clock.now < end {
            if !requestedNames.isEmpty { return true }
            try? await Task.sleep(for: .milliseconds(2))
        }
        return !requestedNames.isEmpty
    }
}

private actor BlockingSyncTransport: SyncTransport {
    let statuses = AsyncStream<SyncStatus> { _ in }
    private var fetchCount = 0
    private var release: CheckedContinuation<Void, Never>?
    private var failReleasedFetch = false
    private var sent: [[SyncPendingChange]] = []

    func fetchChanges() async throws -> SyncFetchBatch {
        fetchCount += 1
        await withCheckedContinuation { continuation in
            release = continuation
        }
        if failReleasedFetch {
            failReleasedFetch = false
            throw TestSyncError.network
        }
        return try SyncFetchBatch(generationID: "refresh", records: [], engineState: Data([2]))
    }

    func save(changes: [SyncPendingChange], role: SyncDeviceRole) async throws -> SyncSendResult {
        sent.append(changes)
        return try SyncSendResult(engineState: Data([3]))
    }

    func fetchCountValue() -> Int { fetchCount }

    func releaseFetch(failing: Bool = false) {
        failReleasedFetch = failing
        release?.resume()
        release = nil
    }

    func savedChanges() -> [[SyncPendingChange]] { sent }
}

private actor BlockingSaveSyncTransport: SyncTransport {
    nonisolated let statuses = AsyncStream<SyncStatus> { _ in }
    private var saveCount = 0
    private var saveWaiters: [CheckedContinuation<Void, Never>] = []

    func fetchChanges() async throws -> SyncFetchBatch {
        try SyncFetchBatch(generationID: "blocking-save-refresh", records: [], engineState: Data([2]))
    }

    func save(changes: [SyncPendingChange], role: SyncDeviceRole) async throws -> SyncSendResult {
        saveCount += 1
        await withCheckedContinuation { saveWaiters.append($0) }
        return try SyncSendResult(engineState: Data([3]))
    }

    func saveCountValue() -> Int { saveCount }

    func waitForSaveCount(_ expected: Int) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now + .seconds(2)
        while saveCount < expected, clock.now < deadline {
            try? await Task.sleep(for: .milliseconds(2))
        }
        return saveCount >= expected
    }

    func releaseNextSave() {
        guard !saveWaiters.isEmpty else { return }
        saveWaiters.removeFirst().resume()
    }
}

private actor BlockingAssetLoader {
    private let sourceURL: URL
    private var requestCount = 0
    private var release: CheckedContinuation<Void, Never>?

    init() throws {
        sourceURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("wilted-blocking-asset-\(UUID().uuidString).m4a")
        try Data("wilted-second-play-audio".utf8).write(to: sourceURL, options: .atomic)
    }

    func load(recordID: WiltedRecordID, asset: WiltedAsset) async -> URL {
        requestCount += 1
        await withCheckedContinuation { release = $0 }
        return sourceURL
    }

    func waitUntilRequested() async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now + .seconds(2)
        while requestCount == 0, clock.now < deadline {
            try? await Task.sleep(for: .milliseconds(2))
        }
        return requestCount > 0
    }

    func releaseLoad() {
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
    let repository: StaticSyncRepository
    let secondItemID: ItemID?

    static func make(
        cachedPlaybackRevisionID: RevisionID? = nil,
        includeSecondItem: Bool = false,
        cacheSecondItem: Bool = true,
        transport: (any SyncTransport)? = nil,
        assetLoader: ListenerAssetLoader? = nil,
        backgroundSleeper: @escaping @Sendable (Duration) async throws -> Void = { duration in
            try await Task.sleep(for: duration)
        }
    ) async throws -> PlaybackHarness {
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
        var secondItemID: ItemID?
        if includeSecondItem {
            let secondURL = URL(string: "https://example.test/second-play")!
            let secondID = try ItemID.derive(from: secondURL)
            let secondRevisionID = try RevisionID(rawValue: "revision-second-play")
            let secondBytes = Data("wilted-second-play-audio".utf8)
            let secondHash = "sha256:" + SHA256.hash(data: secondBytes).map { String(format: "%02x", $0) }.joined()
            let secondAsset = try WiltedAsset(assetID: "audio-second-play", contentHash: secondHash)
            let secondArticle = try Article(itemID: secondID, canonicalURL: secondURL, title: "Second play",
                                            source: "Test", createdAt: Timestamp(Date()))
            let secondRevision = try AudioRevision(itemID: secondID, revisionID: secondRevisionID,
                                                   durationSeconds: 30, byteCount: Int64(secondBytes.count),
                                                   contentHash: secondHash, mediaType: "audio/mp4",
                                                   createdAt: Timestamp(Date()), schemaVersion: 1)
            if cacheSecondItem {
                _ = try await cache.store(data: secondBytes, asset: secondAsset)
            }
            records.append(try codec.encode(article: secondArticle, currentRevisionID: secondRevisionID))
            records.append(try codec.encode(revision: secondRevision, audioAsset: secondAsset))
            secondItemID = secondID
        }
        if let cachedPlayback { records.append(try codec.encode(playback: cachedPlayback)) }
        let repository = StaticSyncRepository(state: SyncRepositoryState(
            records: records,
            engineState: Data([1])))
        return PlaybackHarness(model: WiltedListenerAppModel(
            repository: repository,
            transport: transport,
            cache: cache,
            playback: controller,
            assetLoader: assetLoader,
            metadataSaver: { metadata in await metadataCapture.save(metadata) },
            backgroundSleeper: backgroundSleeper
        ), itemID: itemID, engine: engine, metadataCapture: metadataCapture,
        repository: repository, secondItemID: secondItemID)
    }
}

private final class FakeAudioEngine: ListenerAudioEngine, @unchecked Sendable {
    let duration: Double
    var currentTime: Double = 0
    private(set) var playing = false
    var allowsPlayback = true
    private let loadGateLock = NSLock()
    private var nextLoadGate: LoadGate?
    private(set) var completionGeneration: UInt64 = 0
    private var completionHandler: (@Sendable (UInt64) -> Void)?
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
    func load(url: URL, completionGeneration: UInt64) throws {
        try load(url: url)
        self.completionGeneration = completionGeneration
    }
    func play() -> Bool { playing = allowsPlayback; return allowsPlayback }
    func pause() { playing = false }
    func installCompletionHandler(_ handler: @escaping @Sendable (UInt64) -> Void) { completionHandler = handler }
    func finishNaturally() {
        playing = false
        currentTime = duration
        completionHandler?(completionGeneration)
    }
    func fireCompletion(generation: UInt64) { completionHandler?(generation) }
}

private actor BackgroundCheckpointSleeper {
    private var recorded: [Duration] = []
    private var waiters: [CheckedContinuation<Void, Error>] = []

    func sleep(for duration: Duration) async throws {
        recorded.append(duration)
        try await withCheckedThrowingContinuation { continuation in waiters.append(continuation) }
    }

    func waitUntilSleeping() async -> Duration? {
        let clock = ContinuousClock()
        let end = clock.now + .seconds(2)
        while clock.now < end {
            if let duration = recorded.last { return duration }
            try? await Task.sleep(for: .milliseconds(2))
        }
        return recorded.last
    }

    func releaseOne() {
        guard !waiters.isEmpty else { return }
        waiters.removeFirst().resume()
    }

    func sleepCount() -> Int { recorded.count }
}

private actor AsyncEnqueueGate {
    private var started = false
    private var releaseContinuation: CheckedContinuation<Void, Never>?

    func suspend() async {
        started = true
        await withCheckedContinuation { releaseContinuation = $0 }
    }

    func waitUntilStarted() async -> Bool {
        let clock = ContinuousClock()
        let end = clock.now + .seconds(2)
        while clock.now < end {
            if started { return true }
            try? await Task.sleep(for: .milliseconds(2))
        }
        return started
    }

    func release() {
        releaseContinuation?.resume()
        releaseContinuation = nil
    }
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
