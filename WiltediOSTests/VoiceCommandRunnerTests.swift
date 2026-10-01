import Foundation
import WiltedDomain
import WiltedLibrary
import XCTest
@testable import WiltediOS

private struct Declined: Error {}

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
        let line = try await VoiceCommandRunner.run(.pause, on: nil) { _ in XCTFail("no confirmation") }
        XCTAssertEqual(line, VoiceCommandRunner.unavailableDialog)
    }

    func testPauseIsPerformedWithoutAskingAndSpeaksThePlannersLine() async throws {
        let target = RecordingTarget(snapshot: try snapshot(playing: true))
        let line = try await VoiceCommandRunner.run(.pause, on: target) { _ in XCTFail("no confirmation") }
        XCTAssertEqual(target.performed, [.pause])
        XCTAssertEqual(line, "Paused.")
    }

    func testNothingPlayingPerformsNothingAndSaysSo() async throws {
        let target = RecordingTarget(snapshot: try snapshot(playing: nil))
        let line = try await VoiceCommandRunner.run(.skipForward, on: target) { _ in }
        XCTAssertEqual(target.performed, [.none])
        XCTAssertEqual(line, "Nothing is playing.")
    }

    func testMarkCompletedAsksFirstAndPerformsOnlyAfterConfirmation() async throws {
        let target = RecordingTarget(snapshot: try snapshot(playing: true))
        var asked: [String] = []
        let line = try await VoiceCommandRunner.run(.markCompleted, on: target) { question in
            asked.append(question)
            XCTAssertTrue(target.performed.isEmpty, "nothing may run before the answer")
        }
        XCTAssertEqual(asked, ["Mark Title e1 completed?"])
        XCTAssertEqual(target.performed, [.markCompleted(try ItemID(rawValue: "e1"))])
        XCTAssertEqual(line, VoiceCommandRunner.completedDialog)
    }

    func testDecliningTheConfirmationPerformsNothing() async throws {
        let target = RecordingTarget(snapshot: try snapshot(playing: true))
        do {
            _ = try await VoiceCommandRunner.run(.markCompleted, on: target) { _ in throw Declined() }
            XCTFail("declining must throw")
        } catch is Declined {}
        XCTAssertTrue(target.performed.isEmpty)
    }

    func testMarkCompletedThatTheLarderDoesNotOfferNeverAsks() async throws {
        let target = RecordingTarget(snapshot: try snapshot(playing: true, canMark: false))
        let line = try await VoiceCommandRunner.run(.markCompleted, on: target) { _ in XCTFail("no confirmation") }
        XCTAssertEqual(target.performed, [.none])
        XCTAssertEqual(line, "I can't mark that completed yet.")
    }

    func testAFailedActionIsNeverAnnouncedAsSuccess() async throws {
        let target = RecordingTarget(snapshot: try snapshot(playing: false))
        target.outcome = .failed
        let resumed = try await VoiceCommandRunner.run(.resume, on: target) { _ in }
        XCTAssertEqual(resumed, VoiceCommandRunner.failedDialog)
        let marked = try await VoiceCommandRunner.run(.markCompleted, on: target) { _ in }
        XCTAssertEqual(marked, VoiceCommandRunner.failedDialog)
    }

    func testAQueuedMarkCompletedIsSaidToBeQueuedNotDone() async throws {
        let target = RecordingTarget(snapshot: try snapshot(playing: true))
        target.outcome = .queued
        let line = try await VoiceCommandRunner.run(.markCompleted, on: target) { _ in }
        XCTAssertEqual(line, VoiceCommandRunner.queuedDialog)
        XCTAssertNotEqual(line, VoiceCommandRunner.completedDialog)
    }
}
