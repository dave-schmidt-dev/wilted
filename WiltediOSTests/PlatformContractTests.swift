import XCTest
@testable import WiltediOS

final class PlatformContractTests: XCTestCase {
    func testAudioSessionLifecycleFailureInterruptionRouteAndCancellation() {
        var state = AudioSessionState()
        state = AudioSessionReducer.reduce(state, .activationRequested)
        XCTAssertEqual(state.phase, .activating)
        state = AudioSessionReducer.reduce(state, .activationSucceeded(route: .builtInSpeaker))
        state = AudioSessionReducer.reduce(state, .interruptionBegan)
        XCTAssertEqual(state.phase, .interrupted)
        state = AudioSessionReducer.reduce(state, .routeChanged(.bluetooth))
        XCTAssertEqual(state.route, .bluetooth)
        state = AudioSessionReducer.reduce(state, .interruptionEnded(shouldResume: true))
        XCTAssertEqual(state.phase, .active)
        state = AudioSessionReducer.reduce(state, .activationFailed(reason: "permission denied"))
        XCTAssertEqual(state.lastError, "permission denied")
        state = AudioSessionReducer.reduce(state, .cancelled)
        XCTAssertEqual(state.phase, .idle)
    }

    func testProgressClampsFractionAndPreservesTerminalCancellation() {
        let progress = PlatformProgress(
            sequence: 2,
            stage: "buffering",
            detail: "Waiting for audio",
            fraction: 4,
            cancellable: true,
            outcome: .cancelled
        )
        XCTAssertEqual(progress.fraction, 1)
        XCTAssertEqual(progress.outcome, .cancelled)
        XCTAssertFalse(progress.cancellable)
        let state = AudioSessionReducer.reduce(AudioSessionState(), .progress(progress))
        XCTAssertEqual(state.lastProgress, progress)
    }

    func testProgressCadenceAndTerminalSuccessContract() {
        XCTAssertEqual(PlatformProgress.maximumStatusSilenceSeconds, 5)
        let running = PlatformProgress(sequence: 1, stage: "waiting", detail: "Still alive", cancellable: true)
        XCTAssertTrue(running.cancellable)
        let succeeded = PlatformProgress(
            sequence: 2,
            stage: "ready",
            detail: "Playback ready",
            cancellable: true,
            outcome: .succeeded
        )
        XCTAssertFalse(succeeded.cancellable)
    }

    func testBackgroundEligibilityProgressFailureAndCancellation() {
        var state = BackgroundPlaybackState()
        state = BackgroundPlaybackReducer.reduce(state, .eligibilityChanged(.eligible))
        state = BackgroundPlaybackReducer.reduce(state, .enteredBackground)
        state = BackgroundPlaybackReducer.reduce(
            state,
            .progress(.init(sequence: 1, stage: "waiting", detail: "Still alive", cancellable: true))
        )
        XCTAssertEqual(state.lastProgress?.sequence, 1)
        state = BackgroundPlaybackReducer.reduce(state, .failed(reason: "audio unavailable"))
        XCTAssertEqual(state.phase, .failed)
        XCTAssertEqual(state.lastError, "audio unavailable")
        state = BackgroundPlaybackReducer.reduce(state, .cancelled)
        XCTAssertEqual(state.phase, .ended)

        let unavailable = BackgroundPlaybackReducer.reduce(
            BackgroundPlaybackState(),
            .eligibilityChanged(.unavailable(reason: "background audio not enabled"))
        )
        XCTAssertEqual(unavailable.phase, .failed)
        XCTAssertEqual(unavailable.lastError, "background audio not enabled")
    }

    func testNowPlayingProjectionPreservesUnknownMetadataAndBoundsElapsed() {
        let metadata = NowPlayingProjector.project(
            NowPlayingProjectionInput(
                title: nil,
                source: nil,
                author: nil,
                duration: 90,
                position: 120,
                isPlaying: true
            )
        )
        XCTAssertNil(metadata.title)
        XCTAssertNil(metadata.artist)
        XCTAssertNil(metadata.album)
        XCTAssertEqual(metadata.elapsed, 90)
        XCTAssertEqual(metadata.playbackRate, 1)

        let paused = NowPlayingProjector.project(
            NowPlayingProjectionInput(title: "Article", duration: -1, position: -5, isPlaying: false)
        )
        XCTAssertNil(paused.duration)
        XCTAssertEqual(paused.elapsed, 0)
        XCTAssertEqual(paused.playbackRate, 0)
    }

    func testRemoteCommandsRouteAndClampSeekWithoutMediaMutation() {
        let state = RemotePlaybackState(hasMedia: true, position: 10, duration: 30, isPlaying: false)
        XCTAssertEqual(RemoteCommandRouter.route(.play, state: state), .accepted(.play))
        XCTAssertEqual(RemoteCommandRouter.route(.pause, state: state), .accepted(.pause))
        XCTAssertEqual(RemoteCommandRouter.route(.seekForward(seconds: 40), state: state), .accepted(.seek(to: 30)))
        XCTAssertEqual(RemoteCommandRouter.route(.seekBackward(seconds: 40), state: state), .accepted(.seek(to: 0)))
        XCTAssertEqual(RemoteCommandRouter.route(.seek(to: .infinity), state: state), .rejected(.invalidSeek))
        XCTAssertEqual(
            RemoteCommandRouter.route(
                .play,
                state: RemotePlaybackState(hasMedia: false, position: 0, duration: nil, isPlaying: false)
            ),
            .rejected(.noMedia)
        )
        XCTAssertEqual(state.position, 10)
    }

    func testStatusSequenceCanProveAWaitingOperationIsAliveAndTerminal() async {
        let events = [
            PlatformProgress(sequence: 1, stage: "starting", detail: "Preparing", cancellable: true),
            PlatformProgress(sequence: 2, stage: "waiting", detail: "Still alive", cancellable: true),
            PlatformProgress(
                sequence: 3,
                stage: "cancelled",
                detail: "Stopped by user",
                cancellable: false,
                outcome: .cancelled
            )
        ]
        var previous: UInt64 = 0
        for event in events {
            XCTAssertGreaterThan(event.sequence, previous)
            previous = event.sequence
        }
        XCTAssertEqual(events.last?.outcome, .cancelled)
    }
}
