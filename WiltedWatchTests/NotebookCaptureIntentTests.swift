import Foundation
import XCTest
@testable import WiltedWatch

@MainActor
final class NotebookCaptureIntentTests: XCTestCase {
    func testNotebookWatchIntentSendsOnePhoneCommandAndShowsAcknowledgement() throws {
        var sent: [WatchCommand] = []
        let model = WatchViewModel(commandSender: { sent.append($0) })
        let snapshot = WatchSnapshot(
            nowPlaying: NowPlaying(episodeID: "fixture-episode", title: "A quiet morning",
                                   showTitle: "Garden Radio", positionSeconds: 245,
                                   durationSeconds: 1_800, isPlaying: true))
        model.receive(context: try WatchLinkCodec.encode(snapshot))
        model.isPhoneReachable = true

        XCTAssertTrue(model.captureNotebook())
        XCTAssertEqual(sent.map(\.action), [.captureNotebook])
        XCTAssertTrue(model.isPending(.captureNotebook))

        model.notebookCaptureDidSucceed(queued: false)
        XCTAssertEqual(model.notebookFeedback, .saved)
        XCTAssertEqual(model.notebookFeedback?.message, "Saved to Notebook.")
        XCTAssertFalse(model.isPending(.captureNotebook))
    }

    func testNotebookWatchIntentReportsTypedFailureAndAllowsRetry() throws {
        var sent: [WatchCommand] = []
        let model = WatchViewModel(commandSender: { sent.append($0) })
        model.receive(context: try WatchLinkCodec.encode(WatchSnapshot(
            nowPlaying: NowPlaying(episodeID: "fixture-episode", title: "A quiet morning",
                                   showTitle: "Garden Radio", positionSeconds: 245,
                                   durationSeconds: 1_800, isPlaying: false))))
        model.isPhoneReachable = true

        XCTAssertTrue(model.captureNotebook())
        model.notebookCaptureDidFail(.failed)

        XCTAssertEqual(model.notebookFeedback?.message, "Couldn't save. Try again.")
        XCTAssertFalse(model.isPending(.captureNotebook))
        XCTAssertTrue(model.captureNotebook())
        XCTAssertEqual(sent.count, 2)
    }

    func testNotebookWatchIntentRequiresAnActiveEpisode() throws {
        var sent: [WatchCommand] = []
        let model = WatchViewModel(commandSender: { sent.append($0) })
        model.receive(context: try WatchLinkCodec.encode(WatchSnapshot()))
        model.isPhoneReachable = true

        XCTAssertFalse(model.captureNotebook())
        XCTAssertTrue(sent.isEmpty)
    }

    func testNotebookWatchIntentMapsPhoneRefusalsToHonestFeedback() {
        XCTAssertEqual(WatchNotebookFeedback.phoneRefusal(reason: "nothingPlaying"), .nothingPlaying)
        XCTAssertEqual(WatchNotebookFeedback.phoneRefusal(reason: "notReady"), .unreachable)
        XCTAssertEqual(WatchNotebookFeedback.phoneRefusal(reason: "captureFailed"), .failed)
        XCTAssertEqual(WatchNotebookFeedback.phoneRefusal(reason: nil), .failed)
    }
}
