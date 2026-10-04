import Foundation
import XCTest
@testable import WiltedMac
import WiltedDomain
import WiltedProducer

/// The playback command owner, driven through a scripted backend and an
/// injected suspension so each ordering is caused rather than raced.
/// Scenario IDs come from the retired Batch 1 prototype.
@MainActor
final class WiltedMacPlaybackCommandTests: XCTestCase {
    // PLAY-DELAY, RACE duplicate primary and space presses.
    func testPrimaryPressPublishesPendingBeforeFirstAwaitAndRepeatsStartOnce() async throws {
        let (model, backend, episode) = makePlaybackCommandModel()
        await loadPausedThroughOwner(model, episode)
        let gate = WiltedMacCommandGate()
        model.installPlaybackCommandHookForTesting { await gate.hold($0) }
        let playsBefore = backend.playCount

        gate.arm()
        model.togglePlayback()
        // Synchronous: nothing has been awaited yet.
        XCTAssertEqual(model.playbackStatusMessage, "Starting playback…")
        XCTAssertEqual(model.playbackStatusTone, .caution)
        XCTAssertFalse(model.isPlaying, "playing is never inferred from the press")
        let token = model.playbackCommands.generation
        model.togglePlayback()
        model.togglePlayback()
        model.handleRemoteCommand(.play)
        XCTAssertEqual(model.playbackCommands.generation, token, "repeats coalesce into the pending start")

        await gate.waitUntilHeld()
        XCTAssertEqual(backend.playCount, playsBefore, "the effect has not reached the backend while held")
        XCTAssertEqual(model.playbackStatusMessage, "Starting playback…")
        gate.release()
        await model.waitForPlaybackOperationForTesting()

        XCTAssertEqual(backend.playCount, playsBefore + 1)
        XCTAssertEqual(backend.pauseCount, 1, "a duplicate press must never read as Pause")
        XCTAssertTrue(model.isPlaying)
        XCTAssertNil(model.playbackCommands.pending)
        XCTAssertEqual(model.playbackStatusMessage, "Playing")
    }

    // RACE selection: the newer intent wins and the stale one changes nothing.
    func testNewerSelectionSupersedesPendingEpisodeStart() async throws {
        let (model, backend, episode) = makePlaybackCommandModel()
        let article = try XCTUnwrap(model.articles.first(where: \.isReady))
        let gate = WiltedMacCommandGate()
        model.installPlaybackCommandHookForTesting { await gate.hold($0) }

        gate.arm()
        model.playEpisode(episode)
        XCTAssertEqual(model.playbackStatusMessage, "Opening \(episode.title)…")
        await gate.waitUntilHeld()
        model.openNowPlaying(for: article, autoplay: true)
        gate.release()
        await model.waitForPlaybackOperationForTesting()

        XCTAssertEqual(model.playback?.itemID?.rawValue, article.id)
        XCTAssertNil(model.currentPodcastEpisodeID, "the superseded episode never became current")
        XCTAssertEqual(backend.loadCount, 1, "the stale selection never loaded")
        XCTAssertEqual(backend.playCount, 1)
        XCTAssertTrue(model.isPlaying)
        XCTAssertNil(model.playbackError)
        XCTAssertNil(model.playbackCommands.failure)
    }

    // RACE system pause mid-load: Play Now loads without autoplay, so a Pause
    // that lands while the media is loading means the backend never starts.
    func testPauseWhilePlayNowIsLoadingNeverStartsTheBackend() async throws {
        let (model, backend, episode) = makePlaybackCommandModel()
        await model.waitForFixturePodcastInstallForTesting()
        backend.onLoad = { [weak model] in
            backend.onLoad = nil
            model?.pausePlayback()
        }

        model.playEpisode(episode)
        await model.waitForPlaybackOperationForTesting()

        XCTAssertEqual(backend.loadCount, 1)
        XCTAssertEqual(backend.playCount, 0, "a Pause during the load wins without a brief start")
        XCTAssertFalse(model.isPlaying)
        XCTAssertEqual(model.currentPodcastEpisodeID, episode.id, "the selection itself still lands")
        XCTAssertNil(model.playbackCommands.pending)
    }

    // A toggle pressed once audio has started reads as Pause, even while the
    // selection is still finishing its queue and transcript work.
    func testToggleAfterSelectionStartsAudioPausesInsteadOfCoalescing() async throws {
        let (model, backend, episode) = makePlaybackCommandModel()
        await model.waitForFixturePodcastInstallForTesting()
        backend.onPlay = { [weak model] in
            backend.onPlay = nil
            // Runs at the selection's next suspension, after its start.
            Task { @MainActor in model?.togglePlayback() }
        }

        model.playEpisode(episode)
        await model.waitForPlaybackOperationForTesting()

        XCTAssertEqual(backend.playCount, 1)
        XCTAssertEqual(backend.pauseCount, 1, "the toggle paused the started audio")
        XCTAssertFalse(model.isPlaying)
        XCTAssertEqual(model.currentPodcastEpisodeID, episode.id)
    }

    // RACE system pause; Done-when 4.
    func testExplicitPauseDuringPendingStartWinsAndDuplicateToggleIsNotPause() async throws {
        let (model, backend, episode) = makePlaybackCommandModel()
        await loadPausedThroughOwner(model, episode)
        let gate = WiltedMacCommandGate()
        model.installPlaybackCommandHookForTesting { await gate.hold($0) }
        let playsBefore = backend.playCount
        let pausesBefore = backend.pauseCount

        gate.arm()
        model.togglePlayback()
        model.togglePlayback()
        XCTAssertEqual(backend.pauseCount, pausesBefore, "the second press coalesced instead of pausing")
        await gate.waitUntilHeld()
        model.handleRemoteCommand(.pause)
        XCTAssertEqual(model.playbackStatusMessage, "Pausing…")
        gate.release()
        await model.waitForPlaybackOperationForTesting()

        XCTAssertEqual(backend.playCount, playsBefore, "the cancelled start never reached the backend")
        XCTAssertFalse(model.isPlaying)
        XCTAssertFalse(backend.isPlaying)
        XCTAssertEqual(model.playbackStatusMessage, "Paused")
    }

    // RACE seek: a seek during a pending start leaves playback paused there.
    func testSeekDuringPendingStartLeavesPausedAtNewPosition() async throws {
        let (model, backend, episode) = makePlaybackCommandModel()
        await loadPausedThroughOwner(model, episode)
        let gate = WiltedMacCommandGate()
        model.installPlaybackCommandHookForTesting { await gate.hold($0) }
        let playsBefore = backend.playCount

        gate.arm()
        model.togglePlayback()
        await gate.waitUntilHeld()
        model.scrub(to: 120)
        gate.release()
        await model.waitForPlaybackOperationForTesting()

        XCTAssertEqual(backend.playCount, playsBefore)
        XCTAssertFalse(model.isPlaying)
        XCTAssertEqual(backend.currentTime, 120, accuracy: 0.001)
        XCTAssertEqual(model.playbackPositionSeconds, 120, accuracy: 0.001)
    }

    // PLAY-IDLE: the pending start outranks the idle line; a system Pause
    // still cancels it before anything is current.
    func testIdlePendingStartOverridesIdleStatusAndSystemPauseCancelsIt() async throws {
        let (model, backend, episode) = makePlaybackCommandModel()
        let gate = WiltedMacCommandGate()
        model.installPlaybackCommandHookForTesting { await gate.hold($0) }
        XCTAssertEqual(model.playbackStatusMessage, "Nothing is playing")

        gate.arm()
        model.playLarderEpisode(episode)
        XCTAssertFalse(model.hasCurrentPlayback)
        XCTAssertEqual(model.playbackStatusMessage, "Opening \(episode.title)…")
        XCTAssertEqual(model.playbackCommands.pending?.command.itemID, episode.id, "the row shows its own pending state")
        await gate.waitUntilHeld()
        model.handleRemoteCommand(.pause)
        gate.release()
        await model.waitForPlaybackOperationForTesting()

        XCTAssertEqual(backend.playCount, 0, "Pause won over the pending first start")
        XCTAssertEqual(backend.loadCount, 0, "a start cancelled before its queue move never loads")
        XCTAssertFalse(model.isPlaying)
        XCTAssertNil(model.currentPodcastEpisodeID)
        XCTAssertNil(model.playbackCommands.pending)
        XCTAssertEqual(model.playbackStatusMessage, "Nothing is playing")
    }

    // PLAY-FAIL: a refused start is visible, keeps the playhead, and retries.
    func testBackendRefusalIsVisibleAndRetryStarts() async throws {
        let (model, backend, episode) = makePlaybackCommandModel()
        await loadPausedThroughOwner(model, episode)
        model.scrub(to: 42)
        await model.waitForPlaybackOperationForTesting()
        backend.refusesPlay = true

        model.togglePlayback()
        await model.waitForPlaybackOperationForTesting()

        XCTAssertEqual(model.playbackCommands.failure?.kind, .refused)
        XCTAssertEqual(model.playbackStatusMessage, "Playback refused. Your position is kept.")
        XCTAssertEqual(model.playbackStatusTone, .failure)
        XCTAssertFalse(model.isPlaying)
        XCTAssertFalse(model.audioRouteFault, "a refusal is not a route fault")
        XCTAssertFalse(model.audioRouteRecoveryAttempted)
        XCTAssertEqual(backend.currentTime, 42, accuracy: 0.001)

        backend.refusesPlay = false
        model.retryPlayback()
        await model.waitForPlaybackOperationForTesting()
        XCTAssertTrue(model.isPlaying)
        XCTAssertNil(model.playbackCommands.failure)
        XCTAssertEqual(model.playbackStatusMessage, "Playing")
    }

    // PLAY-RETRY: an engine failure whose rebuild fails is a route fault;
    // the one automatic recovery rebuilds and then starts.
    func testRouteFaultOnStartRecoversOnceAndStarts() async throws {
        let (model, backend, episode) = makePlaybackCommandModel()
        await loadPausedThroughOwner(model, episode)
        try await failEngine(model, backend)
        let loadsBefore = backend.loadCount
        backend.failNextLoads = 1

        model.startPlayback()
        await model.waitForPlaybackOperationForTesting()

        XCTAssertTrue(model.isPlaying)
        XCTAssertTrue(model.audioRouteRecoveryAttempted)
        XCTAssertFalse(model.audioRouteFault)
        XCTAssertNil(model.playbackCommands.failure)
        XCTAssertEqual(backend.loadCount, loadsBefore + 1, "exactly one successful rebuild")
    }

    // PLAY-RETRY-FAIL: when the one recovery fails too, manual retry shows.
    func testRouteRecoveryFailureExposesManualRetryWithoutPlaying() async throws {
        let (model, backend, episode) = makePlaybackCommandModel()
        await loadPausedThroughOwner(model, episode)
        try await failEngine(model, backend)
        backend.failNextLoads = 2

        model.startPlayback()
        await model.waitForPlaybackOperationForTesting()

        XCTAssertFalse(model.isPlaying)
        XCTAssertTrue(model.audioRouteFault)
        XCTAssertEqual(model.playbackError, "Audio route recovery failed.")
        XCTAssertEqual(model.playbackCommands.failure?.kind, .routeFault)
        XCTAssertEqual(backend.playCount, 0)

        model.recoverAudioRoute()
        await model.waitForPlaybackOperationForTesting()
        XCTAssertFalse(model.audioRouteFault)
        XCTAssertNil(model.playbackError)
    }

    // PLAY-MISSING; Done-when 5.
    func testMissingMediaAndIdleStartDoNotSpendRecoveryAndNewSessionResetsBudget() async throws {
        let (model, backend, episode) = makePlaybackCommandModel()
        model.startPlayback()
        await model.waitForPlaybackOperationForTesting()
        XCTAssertEqual(model.playbackCommands.failure?.kind, .unavailable, "nothing is loaded on the idle player")
        XCTAssertFalse(model.audioRouteRecoveryAttempted)

        await model.waitForFixturePodcastInstallForTesting()
        let store = try XCTUnwrap(model.store)
        let ready = try await store.readyRevision(for: ItemID(rawValue: episode.id))
        let mediaURL = try XCTUnwrap(ready).mediaURL
        let bytes = try Data(contentsOf: mediaURL)
        try FileManager.default.removeItem(at: mediaURL)
        model.playEpisode(episode)
        await model.waitForPlaybackOperationForTesting()
        XCTAssertEqual(model.playbackCommands.failure?.kind, .missingMedia)
        XCTAssertEqual(model.playbackStatusMessage, "This episode's saved audio is unavailable.")
        XCTAssertFalse(model.audioRouteRecoveryAttempted, "missing media never spends route recovery")
        XCTAssertFalse(model.audioRouteFault)

        try bytes.write(to: mediaURL)
        if let index = model.episodes.firstIndex(where: { $0.id == episode.id }) {
            model.episodes[index].isReadyMediaAvailable = true
        }
        model.playEpisode(episode)
        await model.waitForPlaybackOperationForTesting()
        XCTAssertTrue(model.isPlaying)

        let loadsBefore = backend.loadCount
        backend.failNextLoads = 1
        model.restartPlayback()
        await model.waitForPlaybackOperationForTesting()
        XCTAssertFalse(model.audioRouteFault, "the later route fault still had its automatic recovery")
        XCTAssertEqual(backend.loadCount, loadsBefore + 1)

        backend.failNextLoads = 1
        model.restartPlayback()
        await model.waitForPlaybackOperationForTesting()
        XCTAssertTrue(model.audioRouteFault, "the same session does not get a second automatic recovery")
        XCTAssertEqual(model.playbackError, "Audio route recovery failed.")

        model.recoverAudioRoute()
        await model.waitForPlaybackOperationForTesting()
        let session = model.playback?.sessionID
        model.restartPlayback()
        await model.waitForPlaybackOperationForTesting()
        XCTAssertNotEqual(model.playback?.sessionID, session, "restart began a new session")

        backend.failNextLoads = 1
        model.restartPlayback()
        await model.waitForPlaybackOperationForTesting()
        XCTAssertFalse(model.audioRouteFault, "a new session resets the automatic recovery")
        XCTAssertNil(model.playbackCommands.failure)
    }

    /// Ends the loaded run with an engine failure, as AVAudioPlayer reports it.
    private func failEngine(_ model: WiltedMacModel, _ backend: WiltedMacScriptedBackend) async throws {
        let playing = try XCTUnwrap(model.playback)
        model.startPlayback()
        await model.waitForPlaybackOperationForTesting()
        backend.finish(successfully: false)
        for _ in 0..<200 where playing.recoverableFault == nil { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertNotNil(playing.recoverableFault)
        // The controller reports the fault through its observation too; let
        // that land first so it cannot overwrite the command's own answer.
        for _ in 0..<200 where model.playbackError == nil { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertNotNil(model.playbackError)
        model.refreshPlaybackReadout()
        backend.resetCounts()
    }
}

/// Shared by the command tests and their visual-system counterparts.
extension XCTestCase {
    @MainActor
    func makePlaybackCommandModel(prepared: Bool = true) -> (WiltedMacModel, WiltedMacScriptedBackend, WiltedMacEpisode) {
        var arguments = ["--wilted-ui-fixture-ready", "--wilted-ui-fixture-podcasts"]
        if prepared { arguments.append("--wilted-ui-fixture-prepared") }
        let model = WiltedMacModel(
            arguments: arguments,
            stateDirectoryOverride: wiltedTemporaryDirectory("playback-commands"),
            preferences: WiltedMacTestPreferences.ephemeral()
        )
        let backend = WiltedMacScriptedBackend()
        model.installPlaybackBackendForTesting(backend)
        return (model, backend, model.episodes[0])
    }

    /// Loads the fixture episode through the owner, then pauses it.
    @MainActor
    func loadPausedThroughOwner(_ model: WiltedMacModel, _ episode: WiltedMacEpisode) async {
        model.playEpisode(episode)
        await model.waitForPlaybackOperationForTesting()
        model.pausePlayback()
        await model.waitForPlaybackOperationForTesting()
        XCTAssertFalse(model.isPlaying)
        XCTAssertEqual(model.playback?.itemID?.rawValue, episode.id)
    }
}

/// A backend whose start can be refused and whose rebuild can fail.
@MainActor
final class WiltedMacScriptedBackend: PlaybackBackend {
    var duration: TimeInterval = 600
    var currentTime: TimeInterval = 0
    private(set) var isPlaying = false
    var rate: Float = 1
    var volume: Float = 0
    private(set) var loadedGeneration: UInt64 = 0
    var completionHandler: (@MainActor @Sendable (UInt64, Bool) -> Void)?
    var refusesPlay = false
    var failNextLoads = 0
    private(set) var playCount = 0
    private(set) var pauseCount = 0
    private(set) var loadCount = 0
    /// Runs inside `load(url:)`, i.e. while a selection is mid-flight.
    var onLoad: (() -> Void)?
    /// Runs inside `play()`, i.e. at the moment a start reaches the backend.
    var onPlay: (() -> Void)?

    func load(url: URL) throws {
        if failNextLoads > 0 {
            failNextLoads -= 1
            throw CocoaError(.fileReadCorruptFile)
        }
        loadCount += 1
        loadedGeneration += 1
        currentTime = 0
        isPlaying = false
        onLoad?()
    }

    func play() -> Bool {
        playCount += 1
        onPlay?()
        isPlaying = !refusesPlay
        return isPlaying
    }

    func pause() { pauseCount += 1; isPlaying = false }
    func stop() { isPlaying = false }

    func finish(successfully: Bool) {
        isPlaying = false
        completionHandler?(loadedGeneration, successfully)
    }

    func resetCounts() { playCount = 0; pauseCount = 0; loadCount = 0 }
}

/// Holds the first command it is armed for until released.
@MainActor
final class WiltedMacCommandGate {
    private var armed = false
    private var held: CheckedContinuation<Void, Never>?
    private var waiter: CheckedContinuation<Void, Never>?
    private var didHold = false

    func arm() {
        armed = true
        didHold = false
    }

    func hold(_ command: WiltedMacPlaybackCommand) async {
        guard armed else { return }
        armed = false
        didHold = true
        waiter?.resume()
        waiter = nil
        await withCheckedContinuation { held = $0 }
    }

    func waitUntilHeld() async {
        guard !didHold else { return }
        await withCheckedContinuation { waiter = $0 }
    }

    func release() {
        held?.resume()
        held = nil
    }
}
