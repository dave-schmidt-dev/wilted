import Foundation
import WiltedDomain
import WiltedLibrary
import XCTest
@testable import WiltediOS

@MainActor
final class NotebookCaptureVoiceTests: XCTestCase {
    private var savedProvider: (@MainActor () async -> (any VoiceCommandTarget)?)!

    override func setUp() async throws {
        savedProvider = VoiceRuntime.provider
    }

    override func tearDown() async throws {
        VoiceRuntime.provider = savedProvider
    }

    private func target(playing: Bool = true) throws -> RecordingTarget {
        let episode = VoiceEpisode(id: try ItemID(rawValue: "notebook-voice-fixture"),
                                   title: "A quiet morning", showTitle: "Garden Radio")
        return RecordingTarget(snapshot: VoiceSnapshot(
            downloaded: [episode], knownShowTitles: [episode.showTitle],
            nowPlaying: playing ? VoiceNowPlaying(episode: episode, isPlaying: true, canMarkCompleted: false) : nil))
    }

    func testNotebookSiriIntentRoutesOneCapture() async throws {
        let target = try target()
        VoiceRuntime.provider = { target }

        _ = try await SaveThatIntent().perform()

        XCTAssertEqual(target.performed, [.captureNotebook(origin: .siri)])
    }

    func testNotebookSiriFeedbackReflectsDurablePhoneOutcome() async throws {
        let target = try target()
        let savedLine = await VoiceCommandRunner.run(.saveThat, on: target)
        XCTAssertEqual(savedLine, "Saved to Notebook.")
        XCTAssertEqual(target.performed, [.captureNotebook(origin: .siri)])

        let failed = try self.target()
        failed.outcome = .failed
        let failedLine = await VoiceCommandRunner.run(.saveThat, on: failed)
        XCTAssertEqual(failedLine, VoiceCommandRunner.failedDialog)
        XCTAssertEqual(failed.performed, [.captureNotebook(origin: .siri)])
    }

    func testNotebookSiriDoesNotCaptureWithoutCurrentEpisode() throws {
        let plan = VoiceCommandPlanner.plan(.saveThat, snapshot: try target(playing: false).snapshot)
        XCTAssertEqual(plan.action, .none)
        XCTAssertEqual(plan.dialog, "Nothing is playing.")
    }
}
