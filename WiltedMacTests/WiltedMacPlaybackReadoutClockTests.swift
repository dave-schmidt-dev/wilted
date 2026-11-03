import Foundation
import XCTest
@testable import WiltedMac
import WiltedDomain
@testable import WiltedProducer

@MainActor
final class WiltedMacPlaybackReadoutClockTests: XCTestCase {
    func testMountedSurfacesShareOneClockPauseStopsItAndResubscribeRestartsIt() async throws {
        let (model, _, episode) = makePlaybackCommandModel()
        await loadPausedThroughOwner(model, episode)
        let clock = makeClock(for: model)

        let first = Task { @MainActor in await clock.subscribe() }
        let firstMounted = await waitUntil { clock.subscriberCountForTesting == 1 }
        XCTAssertTrue(firstMounted)
        XCTAssertFalse(clock.isTickingForTesting, "a paused item has no readout ticker")

        let second = Task { @MainActor in await clock.subscribe() }
        let bothMounted = await waitUntil { clock.subscriberCountForTesting == 2 }
        XCTAssertTrue(bothMounted)

        model.startPlayback()
        await model.waitForPlaybackOperationForTesting()
        await model.waitForPlaybackPresentationForTesting()
        let playing = await waitUntil { model.isPlaying && clock.isTickingForTesting }
        XCTAssertTrue(playing)
        XCTAssertEqual(clock.tickLoopStartCountForTesting, 1, "both mounted views share one ticker")

        clock.tickForTesting()
        XCTAssertEqual(clock.tickCountForTesting, 1)
        first.cancel()
        await first.value
        XCTAssertEqual(clock.subscriberCountForTesting, 1)
        XCTAssertTrue(clock.isTickingForTesting, "one remaining view keeps the shared clock active")

        second.cancel()
        await second.value
        XCTAssertEqual(clock.subscriberCountForTesting, 0)
        XCTAssertFalse(clock.isTickingForTesting, "the last view cancels the ticker")

        // A transport event with no mounted surface must not leave an active
        // flag that prevents a later view from starting the clock.
        model.refreshPlaybackReadout()
        XCTAssertFalse(clock.isTickingForTesting)
        let third = Task { @MainActor in await clock.subscribe() }
        let remounted = await waitUntil { clock.subscriberCountForTesting == 1 && clock.isTickingForTesting }
        XCTAssertTrue(remounted)
        XCTAssertEqual(clock.tickLoopStartCountForTesting, 2)

        model.pausePlayback()
        await model.waitForPlaybackOperationForTesting()
        let paused = await waitUntil { !clock.isTickingForTesting }
        XCTAssertTrue(paused)
        let ticksAtPause = clock.tickCountForTesting
        clock.tickForTesting()
        XCTAssertEqual(clock.tickCountForTesting, ticksAtPause, "a paused clock cannot tick")

        third.cancel()
        await third.value
    }

    func testControllerResumeAndFaultTransitionsKeepClockLifecycleInSync() async throws {
        let (model, backend, episode) = makePreparedSeamPlaybackCommandModel()
        await loadPausedThroughOwner(model, episode)
        let clock = makeClock(for: model)
        let subscription = Task { @MainActor in await clock.subscribe() }
        let mounted = await waitUntil { clock.subscriberCountForTesting == 1 }
        XCTAssertTrue(mounted)

        model.startPlayback()
        await model.waitForPlaybackOperationForTesting()
        await model.waitForPlaybackPresentationForTesting()
        let playing = await waitUntil { model.isPlaying && clock.isTickingForTesting }
        XCTAssertTrue(playing)
        XCTAssertFalse(model.currentRemovedSpans.isEmpty, "the prepared fixture has a seam to schedule")
        let startsBeforeResume = clock.tickLoopStartCountForTesting

        let playback = try XCTUnwrap(model.playback)
        try await playback.recoverFromRouteChange()
        XCTAssertTrue(playback.isPlaying, "route recovery resumes the controller internally")
        XCTAssertTrue(clock.isTickingForTesting)
        XCTAssertEqual(clock.tickLoopStartCountForTesting, startsBeforeResume,
                       "an internal resume keeps the existing ticker")

        backend.finish(successfully: false)
        let faultSettled = await waitUntil {
            playback.recoverableFault != nil && !clock.isTickingForTesting
        }
        XCTAssertTrue(faultSettled, "an engine fault stops the readout ticker")
        XCTAssertFalse(model.isPlaying)

        subscription.cancel()
        await subscription.value
    }

    func testSeekAndRateRefreshImmediatelyAndTheReadoutTickKeepsTheSeamDeadline() async throws {
        let (model, _, episode) = makePreparedSeamPlaybackCommandModel()
        await loadPausedThroughOwner(model, episode)
        let clock = makeClock(for: model)
        let subscription = Task { @MainActor in await clock.subscribe() }
        let mounted = await waitUntil { clock.subscriberCountForTesting == 1 }
        XCTAssertTrue(mounted)

        model.startPlayback()
        await model.waitForPlaybackOperationForTesting()
        await model.waitForPlaybackPresentationForTesting()
        let playing = await waitUntil { model.isPlaying && clock.isTickingForTesting }
        XCTAssertTrue(playing)
        XCTAssertFalse(model.currentRemovedSpans.isEmpty, "the fixture has a scheduled seam")

        await model.seekPlaybackForTesting(to: 15)
        XCTAssertEqual(model.playbackPositionSeconds, 15, "a seek updates the visible playhead immediately")
        model.setPlaybackRate(1.5)
        XCTAssertEqual(model.playbackRate, 1.5, "a rate change updates the visible rate immediately")

        let scheduleCount = model.seamMarkerScheduleCountForTesting
        model.refreshPlaybackReadout(preservingSeamDeadline: true)
        XCTAssertEqual(model.seamMarkerScheduleCountForTesting, scheduleCount,
                       "a normal readout refresh keeps the existing seam deadline")

        model.pausePlayback()
        await model.waitForPlaybackOperationForTesting()
        subscription.cancel()
        await subscription.value
    }

    func testTickDoesNotConsumeAControllerSeekBeforeItsObservationRefreshesTheSeam() async throws {
        let (model, backend, episode) = makePreparedSeamPlaybackCommandModel()
        model.playEpisode(episode)
        await model.waitForPlaybackOperationForTesting()
        await model.waitForPlaybackPresentationForTesting()
        XCTAssertFalse(model.currentRemovedSpans.isEmpty)

        let clock = makeClock(for: model)
        let subscription = Task { @MainActor in await clock.subscribe() }
        let mounted = await waitUntil { clock.subscriberCountForTesting == 1 && clock.isTickingForTesting }
        XCTAssertTrue(mounted)

        let originalSeam = try XCTUnwrap(model.pendingSeamMarkerForTesting)
        let validSeams = model.currentRemovedSpans.map(\.preparedSeconds).sorted()
        XCTAssertGreaterThanOrEqual(validSeams.count, 2, "the seek race needs at least two prepared cuts")
        let laterSeam = try XCTUnwrap(validSeams.first(where: { $0 > originalSeam }))
        let newPosition = laterSeam - 0.1
        let playback = try XCTUnwrap(model.playback)
        let schedulesBeforeSeek = model.seamMarkerScheduleCountForTesting

        // Observation schedules its callback on the main actor. Keep this
        // synchronous so the clock tick runs before that queued callback.
        backend.currentTime = newPosition
        playback.positionSeconds = newPosition
        clock.tickForTesting()

        XCTAssertEqual(model.playbackPositionSeconds, newPosition)
        XCTAssertEqual(model.pendingSeamMarkerForTesting, laterSeam)
        XCTAssertEqual(model.seamMarkerScheduleCountForTesting, schedulesBeforeSeek + 1,
                       "the tick replans the changed seek exactly once")

        subscription.cancel()
        await subscription.value
    }

    func testNaturalEndStopsTheClock() async throws {
        let (model, backend, _) = makePlaybackCommandModel()
        let article = try XCTUnwrap(model.articles.first(where: \.isReady))
        model.openNowPlaying(for: article, autoplay: true)
        await model.waitForPlaybackOperationForTesting()

        let clock = makeClock(for: model)
        let subscription = Task { @MainActor in await clock.subscribe() }
        let playing = await waitUntil { model.isPlaying && clock.isTickingForTesting }
        XCTAssertTrue(playing)

        backend.finish(successfully: true)
        let ended = await waitUntil { model.playbackCompleted && !clock.isTickingForTesting }
        XCTAssertTrue(ended, "EOF updates completion and stops the ticker")

        subscription.cancel()
        await subscription.value
    }

    func testUnchangedReadoutDoesNotRewriteTheLibraryPlaybackProjection() async throws {
        let (model, backend, episode) = makePlaybackCommandModel()
        model.playEpisode(episode)
        await model.waitForPlaybackOperationForTesting()
        await model.waitForPlaybackPresentationForTesting()
        backend.currentTime = 42
        model.refreshPlaybackReadout()
        let writesAfterPositionChange = model.playbackProjectionWriteCountForTesting
        XCTAssertGreaterThan(writesAfterPositionChange, 0)

        model.refreshPlaybackReadout()
        XCTAssertEqual(model.playbackProjectionWriteCountForTesting, writesAfterPositionChange,
                       "identical position and completion values do not rewrite the row")
    }

    private func makeClock(for model: WiltedMacModel) -> WiltedMacPlaybackReadoutClock {
        let clock = WiltedMacPlaybackReadoutClock(model: model, tickInterval: .seconds(60))
        model.playbackReadoutClock = clock
        return clock
    }

    private func makePreparedSeamPlaybackCommandModel() -> (
        WiltedMacModel, WiltedMacScriptedBackend, WiltedMacEpisode
    ) {
        let model = WiltedMacModel(
            arguments: [
                "--wilted-ui-fixture-ready", "--wilted-ui-fixture-podcasts",
                "--wilted-ui-fixture-prepared", "--wilted-ui-fixture-long-transcript",
            ],
            stateDirectoryOverride: wiltedTemporaryDirectory("playback-readout-seams"),
            preferences: WiltedMacTestPreferences.ephemeral()
        )
        let backend = WiltedMacScriptedBackend()
        model.installPlaybackBackendForTesting(backend)
        return (model, backend, model.episodes[0])
    }

    private func waitUntil(
        _ condition: @MainActor () -> Bool,
        iterations: Int = 2_000
    ) async -> Bool {
        for _ in 0..<iterations {
            if condition() { return true }
            await Task.yield()
        }
        return condition()
    }
}
