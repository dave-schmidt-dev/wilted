import Foundation
import WiltedDomain
import WiltedLibrary
import XCTest
@testable import WiltediOS

@MainActor
final class VoiceCommandRunnerTests: XCTestCase {
    private func episode(_ name: String) throws -> VoiceEpisode {
        VoiceEpisode(id: try ItemID(rawValue: name), title: "Title \(name)", showTitle: "Show")
    }

    private func snapshot(playing: Bool? = nil, canMark: Bool = true) throws -> VoiceSnapshot {
        let current = try episode("e1")
        return VoiceSnapshot(
            downloaded: [current, try episode("e2")], knownShowTitles: ["Show"],
            nowPlaying: playing.map { VoiceNowPlaying(episode: current, isPlaying: $0, canMarkCompleted: canMark) })
    }

    func testWithoutATargetItSaysToOpenTheApp() async throws {
        let line = await VoiceCommandRunner.run(.pause, on: nil)
        XCTAssertEqual(line, VoiceCommandRunner.unavailableDialog)
    }

    func testPauseIsPerformedWithoutAskingAndSpeaksThePlannersLine() async throws {
        let target = RecordingTarget(snapshot: try snapshot(playing: true))
        let line = await VoiceCommandRunner.run(.pause, on: target)
        XCTAssertEqual(target.performed, [.pause])
        XCTAssertEqual(line, "Paused.")
    }

    func testNothingPlayingPerformsNothingAndSaysSo() async throws {
        let target = RecordingTarget(snapshot: try snapshot(playing: nil))
        let line = await VoiceCommandRunner.run(.skipForward, on: target)
        XCTAssertEqual(target.performed, [.none])
        XCTAssertEqual(line, "Nothing is playing.")
    }

    /// A question left unanswered recorded nothing (2026-11-18), so the request itself is the decision.
    func testMarkCompletedIsPerformedAtOnceAndNamesTheEpisode() async throws {
        let target = RecordingTarget(snapshot: try snapshot(playing: true))
        let line = await VoiceCommandRunner.run(.markCompleted, on: target)
        XCTAssertEqual(target.performed, [.markCompleted(try ItemID(rawValue: "e1"))])
        XCTAssertEqual(line, "Marked Title e1 completed.")
    }

    func testMarkCompletedThatTheLarderDoesNotOfferPerformsNothing() async throws {
        let target = RecordingTarget(snapshot: try snapshot(playing: true, canMark: false))
        let line = await VoiceCommandRunner.run(.markCompleted, on: target)
        XCTAssertEqual(target.performed, [.none])
        XCTAssertEqual(line, "I can't mark that completed yet.")
    }

    func testAFailedActionIsNeverAnnouncedAsSuccess() async throws {
        let target = RecordingTarget(snapshot: try snapshot(playing: false))
        target.outcome = .failed
        let resumed = await VoiceCommandRunner.run(.resume, on: target)
        XCTAssertEqual(resumed, VoiceCommandRunner.failedDialog)
        let marked = await VoiceCommandRunner.run(.markCompleted, on: target)
        XCTAssertEqual(marked, VoiceCommandRunner.failedDialog)
    }

    func testAQueuedMarkCompletedIsSaidToBeQueuedNotDone() async throws {
        let target = RecordingTarget(snapshot: try snapshot(playing: true))
        target.outcome = .queued
        let line = await VoiceCommandRunner.run(.markCompleted, on: target)
        XCTAssertEqual(line, VoiceCommandRunner.queuedDialog)
    }
}
