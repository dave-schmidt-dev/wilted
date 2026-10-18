import Foundation
import XCTest
@testable import WiltedMac

@MainActor
final class WiltedMacPlaybackTraceTests: XCTestCase {
    // TRACE 1.1: the held-presentation fixture causes a measured inherited
    // command wait, and the trace names its acknowledgment/play-call limits
    // without carrying any owner data.
    func testStageTraceMeasuresInheritedCommandWaitForHeldPresentation() async throws {
        let (model, backend, episode) = makePlaybackCommandModel()
        await model.waitForFixturePodcastInstallForTesting()
        let gate = WiltedMacCommandGate()
        model.installPlaybackCommandHookForTesting { await gate.hold($0) }
        model.playbackCommands.trace.reset()

        gate.arm()
        model.playLarderEpisode(episode)
        await gate.waitUntilHeld()
        let heldToken = model.playbackCommands.generation
        XCTAssertEqual(backend.loadCount, 0, "the held effect never reached the backend")

        model.playEpisode(episode)
        let inheritedToken = model.playbackCommands.generation
        XCTAssertNotEqual(heldToken, inheritedToken)

        try await Task.sleep(for: .milliseconds(40))
        gate.release()
        await model.waitForPlaybackOperationForTesting()
        await model.waitForLifetimeStatisticsRefreshForTesting()

        let trace = model.playbackCommands.trace
        let inherited = try XCTUnwrap(
            trace.measuredWait(.acknowledgedToInheritedWait, token: inheritedToken),
            "the second command's inherited wait is not complete"
        )
        XCTAssertGreaterThanOrEqual(
            Double(inherited) / 1_000_000, 39,
            "the second command waited out the held first effect"
        )
        let heldSettled = try XCTUnwrap(trace.offsetNanos(.settled, token: heldToken))
        let inheritedEnded = try XCTUnwrap(trace.offsetNanos(.inheritedWaitEnded, token: inheritedToken))
        XCTAssertGreaterThanOrEqual(inheritedEnded, heldSettled)

        let report = trace.report()
        print(report)
        retainTraceReport(report)
        XCTAssertTrue(report.contains("acknowledged=dispatch-boundary"), report)
        XCTAssertTrue(report.contains("playCalled=call-boundary"), report)
        XCTAssertFalse(report.contains(episode.title), report)
        XCTAssertFalse(report.contains(episode.id), report)
        XCTAssertGreaterThanOrEqual(trace.summaries().count, 2)
        await model.close()
    }

    // The same causal baseline now proves that the presentation hold is outside audio admission.
    func testTranscriptTailDoesNotBlockNextAudioCommand() async throws {
        let (model, backend, episode) = makePlaybackCommandModel()
        await model.waitForFixturePodcastInstallForTesting()
        let gate = WiltedMacCommandGate()
        model.playbackCommands.beforeTranscriptTailForTesting = {
            await gate.hold(.init(token: 0, kind: .select, itemID: nil, revisionID: nil))
        }
        model.playbackCommands.trace.reset()
        gate.arm()
        model.playEpisode(episode)
        await gate.waitUntilHeld()
        let firstToken = model.playbackCommands.generation
        let plays = backend.playCount
        model.pausePlayback()
        await model.waitForPlaybackOperationForTesting()
        XCTAssertFalse(backend.isPlaying, "Pause is immediate while old presentation is held")
        model.startPlayback()
        let secondToken = model.playbackCommands.generation
        await model.waitForPlaybackOperationForTesting()
        XCTAssertGreaterThan(backend.playCount, plays, "audio must start before release of old presentation")
        let wait = try XCTUnwrap(model.playbackCommands.trace.measuredWait(.acknowledgedToPlayCalled, token: secondToken))
        XCTAssertLessThan(Double(wait) / 1_000_000, Double(WiltedMacPlaybackTrace.preAudioTargetMilliseconds))
        try await Task.sleep(for: .milliseconds(500))
        gate.release()
        await model.waitForPlaybackPresentationForTesting()
        let trace = model.playbackCommands.trace
        let tailEnded = try XCTUnwrap(trace.offsetNanos(.transcriptTailEnded, token: firstToken))
        let secondPlayed = try XCTUnwrap(trace.offsetNanos(.playCalled, token: secondToken))
        XCTAssertLessThan(secondPlayed, tailEnded)
        XCTAssertGreaterThanOrEqual(Double(try XCTUnwrap(trace.measuredWait(.transcriptTailDuration, token: firstToken))) / 1_000_000, 500)
        print(trace.report())
        retainTraceReport(trace.report())
        await model.close()
    }

    // TRACE 1.1: repeated held-presentation runs record the pre-audio call
    // boundary baseline: sample count, median, p95 and max, with the
    // acknowledgment/play-call limits named in the output.
    func testStageTraceRecordsBaselineSampleCountsAndOrderedPercentiles() async throws {
        let (model, _, episode) = makePlaybackCommandModel()
        await model.waitForFixturePodcastInstallForTesting()
        await loadPausedThroughOwner(model, episode)
        model.playbackCommands.trace.reset()
        for _ in 0..<6 {
            // Re-selecting an already playing item is a no-op, not another
            // measured start. Each sample begins paused through the owner.
            model.pausePlayback()
            await model.waitForPlaybackOperationForTesting()
            let gate = WiltedMacCommandGate()
            model.installPlaybackCommandHookForTesting { await gate.hold($0) }
            gate.arm()
            model.startPlayback()
            await gate.waitUntilHeld()
            gate.release()
            await model.waitForPlaybackOperationForTesting()
            await model.waitForLifetimeStatisticsRefreshForTesting()
        }

        let summary = try XCTUnwrap(
            model.playbackCommands.trace.summaries().first { $0.wait == .acknowledgedToPlayCalled }
        )
        XCTAssertGreaterThanOrEqual(summary.sampleCount, 6)
        XCTAssertLessThanOrEqual(summary.medianMicros, summary.p95Micros)
        XCTAssertLessThanOrEqual(summary.p95Micros, summary.maxMicros)
        let report = model.playbackCommands.trace.report()
        print(report)
        retainTraceReport(report)
        XCTAssertTrue(report.contains("acknowledged-to-playCalled"), report)
        XCTAssertTrue(report.contains("acknowledged=dispatch-boundary"), report)
        XCTAssertTrue(report.contains("playCalled=call-boundary"), report)
        await model.close()
    }

    private func retainTraceReport(_ report: String) {
        let attachment = XCTAttachment(string: report)
        attachment.name = "Playback call boundaries and qualified synthetic target"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

}
