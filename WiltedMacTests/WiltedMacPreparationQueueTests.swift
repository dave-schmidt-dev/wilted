import Foundation
import XCTest
@testable import WiltedMac

/// Three episodes downloaded together showed one preparing, one queued, and one
/// that appeared to be doing nothing. All three prepared; the third had simply
/// lost the only evidence it was waiting. These cover the two reasons it did.
@MainActor
final class WiltedMacPreparationQueueTests: XCTestCase {
    // MARK: - The queue itself

    func testTheQueueKeepsThePlacesItHandedOut() {
        var queue = WiltedMacPreparationQueue()
        XCTAssertTrue(queue.isEmpty)

        queue.enter(waiting("first"))
        queue.enter(waiting("second"))
        queue.enter(waiting("third"))

        XCTAssertEqual(queue.entries.map(\.id), ["first", "second", "third"])
        XCTAssertEqual(queue.itemIDs, ["first", "second", "third"])
        XCTAssertFalse(queue.isEmpty)
    }

    /// Preparation refuses a second run for an item that already has one, so a
    /// second entry could only ever be a row for a run that does not exist.
    func testEnteringTwiceKeepsTheFirstPlaceRatherThanListingTheItemAgain() {
        var queue = WiltedMacPreparationQueue()
        queue.enter(waiting("first"))
        queue.enter(waiting("second"))
        queue.enter(waiting("first", title: "A different title"))

        XCTAssertEqual(queue.entries.map(\.id), ["first", "second"])
        XCTAssertEqual(queue.entries.first?.title, "first title")
    }

    func testLeavingRemovesOnlyThatItemAndTolerateAnItemThatNeverQueued() {
        var queue = WiltedMacPreparationQueue()
        queue.enter(waiting("first"))
        queue.enter(waiting("second"))

        queue.leave("never-queued")
        XCTAssertEqual(queue.entries.map(\.id), ["first", "second"])

        queue.leave("first")
        XCTAssertEqual(queue.entries.map(\.id), ["second"])

        queue.leave("second")
        XCTAssertTrue(queue.isEmpty)
    }

    // MARK: - Surviving a library reload

    /// The bug: `preparationState` is derived from what the library can prove,
    /// and a preparation waiting for the run slot has journalled nothing, so
    /// the store reports it as not prepared. Every download that lands reloads
    /// the whole library, so one episode finishing its transfer put another
    /// episode's `Queued` row back to offering `Prepare`.
    func testAQueuedRowSurvivesTheReloadAnotherDownloadTriggers() {
        let queued = episode("queued", preparation: .preparing(stage: WiltedMacModel.preparationQueuedStage))
        let reloaded = episode("queued", preparation: .notPrepared)

        let applied = WiltedMacModel.applyingRunningPreparations(
            to: [reloaded], from: [queued], running: ["queued"]
        )

        XCTAssertEqual(applied.first?.preparationState,
                       .preparing(stage: WiltedMacModel.preparationQueuedStage))
    }

    /// The same gap closes over a run that has been admitted but whose worker
    /// has not written its first journal entry yet.
    func testAnAdmittedRunThatHasNotJournalledYetKeepsSayingSo() {
        let running = episode("running", preparation: .preparing(stage: WiltedMacModel.preparingStage))
        let reloaded = episode("running", preparation: .notPrepared)

        let applied = WiltedMacModel.applyingRunningPreparations(
            to: [reloaded], from: [running], running: ["running"]
        )

        XCTAssertEqual(applied.first?.preparationState,
                       .preparing(stage: WiltedMacModel.preparingStage))
    }

    /// Only a run this process is holding open is carried over. An episode
    /// prepared by an earlier launch, or by the other half of a sync, takes
    /// whatever the library proves.
    func testAnEpisodeWithNoRunInThisProcessTakesTheLoadedState() {
        let stale = episode("done", preparation: .preparing(stage: WiltedMacModel.preparingStage))
        let reloaded = episode("done", preparation: .prepared(summary: "Ready · no ads found"))

        let applied = WiltedMacModel.applyingRunningPreparations(
            to: [reloaded], from: [stale], running: []
        )

        XCTAssertEqual(applied.first?.preparationState, .prepared(summary: "Ready · no ads found"))
    }

    /// A run that has settled hands the row back. The terminal state is written
    /// straight after the reload it settled in, and the reload must not put the
    /// spinner back in the meantime.
    func testASettledRunDoesNotHoldTheRowOnPreparing() {
        let settled = episode("settled", preparation: .failed("Preparation failed."))
        let reloaded = episode("settled", preparation: .failed("Preparation failed."))

        let applied = WiltedMacModel.applyingRunningPreparations(
            to: [reloaded], from: [settled], running: ["settled"]
        )

        XCTAssertEqual(applied.first?.preparationState, .failed("Preparation failed."))
    }

    /// The reload is the only source for every other row, and for every other
    /// field of the row it preserves.
    func testEverythingButTheRunningPreparationComesFromTheReload() {
        let before = [
            episode("queued", preparation: .preparing(stage: WiltedMacModel.preparationQueuedStage),
                    download: .downloading(received: 1, expected: 2)),
            episode("other", preparation: .notPrepared, download: .notDownloaded)
        ]
        let loaded = [
            episode("queued", preparation: .notPrepared, download: .completed),
            episode("other", preparation: .prepared(summary: "Ready"), download: .completed)
        ]

        let applied = WiltedMacModel.applyingRunningPreparations(
            to: loaded, from: before, running: ["queued"]
        )

        XCTAssertEqual(applied.map(\.downloadState), [.completed, .completed])
        XCTAssertEqual(applied.first?.preparationState,
                       .preparing(stage: WiltedMacModel.preparationQueuedStage))
        XCTAssertEqual(applied.last?.preparationState, .prepared(summary: "Ready"))
    }

    // MARK: - Fixtures

    private func waiting(_ id: String, title: String? = nil) -> WiltedMacWaitingPreparation {
        WiltedMacWaitingPreparation(id: id, title: title ?? "\(id) title", source: "Show")
    }

    private func episode(
        _ id: String,
        preparation: WiltedMacEpisodePreparationState,
        download: WiltedMacEpisodeDownloadState = .completed
    ) -> WiltedMacEpisode {
        WiltedMacEpisode(
            id: id, title: "\(id) title", feedTitle: "Show", summary: "Summary",
            artworkURL: nil, releasedAt: Date(timeIntervalSince1970: 1_700_000_000),
            durationSeconds: 600, playbackSeconds: 0,
            downloadState: download, preparationState: preparation
        )
    }
}
