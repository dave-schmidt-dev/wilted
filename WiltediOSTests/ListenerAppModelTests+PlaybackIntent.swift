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

    func testPausedBackwardAndForwardSeekPersistIntentWithoutRestartingAudio() async throws {
        let harness = try await PlaybackHarness.make()
        await harness.model.refresh()
        await harness.model.play(itemID: harness.itemID)
        harness.engine.currentTime = 20
        await harness.model.pause()
        let paused = try XCTUnwrap(harness.model.selectedPlayback)
        let playCallsBeforeSeek = harness.engine.playCallCount
        let loadCallsBeforeSeek = harness.engine.loadCallCount

        await harness.model.seekBackward()

        let rewind = try XCTUnwrap(harness.model.selectedPlayback)
        XCTAssertEqual(harness.model.playbackPhase, .paused)
        XCTAssertEqual(rewind.intent, .rewind)
        XCTAssertEqual(rewind.positionSeconds, 5)
        XCTAssertNotEqual(rewind.sessionID, paused.sessionID)
        XCTAssertEqual(rewind.sequence, 1)
        XCTAssertFalse(harness.engine.isPlaying)
        XCTAssertEqual(harness.engine.playCallCount, playCallsBeforeSeek)
        XCTAssertEqual(harness.engine.loadCallCount, loadCallsBeforeSeek)

        await harness.model.seekForward()

        let continuedRewind = try XCTUnwrap(harness.model.selectedPlayback)
        XCTAssertEqual(harness.model.playbackPhase, .paused)
        XCTAssertEqual(continuedRewind.intent, .rewind)
        XCTAssertEqual(continuedRewind.positionSeconds, 30)
        XCTAssertEqual(continuedRewind.sessionID, rewind.sessionID)
        XCTAssertEqual(continuedRewind.sequence, rewind.sequence + 1)
        XCTAssertFalse(harness.engine.isPlaying)
        XCTAssertEqual(harness.engine.playCallCount, playCallsBeforeSeek)
        XCTAssertEqual(harness.engine.loadCallCount, loadCallsBeforeSeek)
        let changes = await harness.repository.enqueuedChanges()
        XCTAssertEqual(changes.count, 4)
        let rewindEnvelope = try XCTUnwrap(changes[2].record)
        let continuedRewindEnvelope = try XCTUnwrap(changes[3].record)
        XCTAssertEqual(try WiltedRecordCodec().decodePlaybackRecord(rewindEnvelope).value, rewind)
        XCTAssertEqual(try WiltedRecordCodec().decodePlaybackRecord(continuedRewindEnvelope).value, continuedRewind)
    }

    func testPlayingRewindThenForwardSeekPreservesExplicitIntent() async throws {
        let harness = try await PlaybackHarness.make()
        await harness.model.refresh()
        await harness.model.play(itemID: harness.itemID)
        harness.engine.currentTime = 20
        await harness.model.refreshNowPlayingReadout()
        let initialPlayback = try XCTUnwrap(harness.model.selectedPlayback)

        await harness.model.rewind()

        let rewind = try XCTUnwrap(harness.model.selectedPlayback)
        XCTAssertEqual(harness.model.playbackPhase, .playing)
        XCTAssertEqual(rewind.intent, .rewind)
        XCTAssertEqual(rewind.positionSeconds, 5)
        XCTAssertNotEqual(rewind.sessionID, initialPlayback.sessionID)
        XCTAssertGreaterThanOrEqual(rewind.sequence, 1)

        await harness.model.seekForward()

        let continuedRewind = try XCTUnwrap(harness.model.selectedPlayback)
        XCTAssertEqual(harness.model.playbackPhase, .playing)
        XCTAssertEqual(continuedRewind.sessionID, rewind.sessionID)
        XCTAssertGreaterThan(continuedRewind.sequence, rewind.sequence)
        XCTAssertEqual(continuedRewind.intent, .rewind)
        let changes = await harness.repository.enqueuedChanges()
        XCTAssertEqual(changes.count, 3)
        let rewindEnvelope = try XCTUnwrap(changes[1].record)
        let continuedRewindEnvelope = try XCTUnwrap(changes[2].record)
        XCTAssertEqual(try WiltedRecordCodec().decodePlaybackRecord(rewindEnvelope).value, rewind)
        XCTAssertEqual(try WiltedRecordCodec().decodePlaybackRecord(continuedRewindEnvelope).value, continuedRewind)
    }

    func testPlayingRestartThenForwardSeekPreservesExplicitIntent() async throws {
        let harness = try await PlaybackHarness.make()
        await harness.model.refresh()
        await harness.model.play(itemID: harness.itemID)
        harness.engine.currentTime = 20
        await harness.model.refreshNowPlayingReadout()
        let initialPlayback = try XCTUnwrap(harness.model.selectedPlayback)

        await harness.model.restart()

        let restart = try XCTUnwrap(harness.model.selectedPlayback)
        XCTAssertEqual(harness.model.playbackPhase, .playing)
        XCTAssertEqual(restart.intent, .restart)
        XCTAssertEqual(restart.positionSeconds, 0)
        XCTAssertNotEqual(restart.sessionID, initialPlayback.sessionID)
        XCTAssertGreaterThanOrEqual(restart.sequence, 1)

        await harness.model.seekForward()

        let continuedRestart = try XCTUnwrap(harness.model.selectedPlayback)
        XCTAssertEqual(harness.model.playbackPhase, .playing)
        XCTAssertEqual(continuedRestart.sessionID, restart.sessionID)
        XCTAssertGreaterThan(continuedRestart.sequence, restart.sequence)
        XCTAssertEqual(continuedRestart.intent, .restart)
        let changes = await harness.repository.enqueuedChanges()
        XCTAssertEqual(changes.count, 3)
        let restartEnvelope = try XCTUnwrap(changes[1].record)
        let continuedRestartEnvelope = try XCTUnwrap(changes[2].record)
        XCTAssertEqual(try WiltedRecordCodec().decodePlaybackRecord(restartEnvelope).value, restart)
        XCTAssertEqual(try WiltedRecordCodec().decodePlaybackRecord(continuedRestartEnvelope).value, continuedRestart)
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

}
