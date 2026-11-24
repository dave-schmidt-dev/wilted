import XCTest
import WiltedDomain
import WiltedLibrary

final class ListenNextPlaybackLedgerTests: XCTestCase {
    private let deviceID = "phone-A"
    private let ownerToken = "account-A"
    private let generation: UInt64 = 7
    private let anchor = try! ItemID(rawValue: "episode-current")
    private let firstStory = try! ItemID(rawValue: "story-first")
    private let secondStory = try! ItemID(rawValue: "story-second")
    private let successor = try! ItemID(rawValue: "episode-next")

    func testLaterReadyStoryWaitsForOldestRequest() {
        var ledger = makeLedger()
        record(&ledger, id: "request-1", story: firstStory, at: 1, phase: .preparing)
        record(&ledger, id: "request-2", story: secondStory, at: 2, phase: .ready)

        XCTAssertNil(ledger.selectAtNaturalBoundary(
            boundaryID: "end-1", continuation: continuation(), currentHoldEpoch: 0))

        ledger.updateRequestPhase(requestID: "request-1", phase: .ready)
        let selected = ledger.selectAtNaturalBoundary(
            boundaryID: "end-1", continuation: continuation(), currentHoldEpoch: 0)
        XCTAssertEqual(selected?.requestID, "request-1")
    }

    func testFailedAndCancelledHeadsDoNotBlockReadyStory() {
        var ledger = makeLedger()
        record(&ledger, id: "request-failed", story: firstStory, at: 1, phase: .failed)
        record(&ledger, id: "request-cancelled", story: firstStory, at: 2, phase: .cancelled)
        record(&ledger, id: "request-ready", story: secondStory, at: 3, phase: .ready)

        XCTAssertEqual(
            ledger.selectAtNaturalBoundary(
                boundaryID: "end-1", continuation: continuation(), currentHoldEpoch: 0)?.requestID,
            "request-ready")
    }

    func testLateAudioUsesContinuationAtNextNaturalBoundary() {
        var ledger = makeLedger()
        record(&ledger, id: "request-1", story: firstStory, at: 1, phase: .preparing)

        XCTAssertNil(ledger.selectAtNaturalBoundary(
            boundaryID: "end-1", continuation: continuation(), currentHoldEpoch: 0))
        ledger.updateRequestPhase(requestID: "request-1", phase: .ready)
        let nextContinuation = ListenNextContinuation(
            kind: .phoneForwardSequence, anchorID: successor, entryIDs: [successor])
        let selected = ledger.selectAtNaturalBoundary(
            boundaryID: "end-2", continuation: nextContinuation, currentHoldEpoch: 0)
        XCTAssertEqual(selected?.boundaryID, "end-2")
        XCTAssertEqual(selected?.continuation, nextContinuation)
    }

    func testEmptySuccessorSuffixRemainsAvailableForLateStoryAudio() throws {
        var ledger = makeLedger()
        record(&ledger, id: "request-1", story: firstStory, at: 1, phase: .preparing)
        let emptyContinuation = ListenNextContinuation(kind: .phoneForwardSequence, anchorID: anchor, entryIDs: [])
        ledger.recordNaturalBoundary(boundaryID: "end-with-no-successor", continuation: emptyContinuation,
                                     holdEpoch: 0)
        ledger.updateRequestPhase(requestID: "request-1", phase: .ready)

        var restored = try reload(ledger)
        XCTAssertEqual(restored.latestBoundaryID, "end-with-no-successor")
        XCTAssertTrue(restored.latestContinuation?.entryIDs.isEmpty == true)
        XCTAssertEqual(restored.latestHoldEpoch, 0)
        XCTAssertEqual(restored.selectAtNaturalBoundary(
            boundaryID: "end-with-no-successor", continuation: emptyContinuation,
            currentHoldEpoch: 0)?.requestID, "request-1")
    }

    func testExplicitStopFenceNeedsANewExplicitStart() {
        var ledger = makeLedger()
        record(&ledger, id: "request-1", story: firstStory, at: 1, phase: .ready, holdEpoch: 0)

        XCTAssertNil(ledger.selectAtNaturalBoundary(
            boundaryID: "end-1", continuation: continuation(), currentHoldEpoch: 1))

        ledger.releaseHold(onExplicitStartAt: 2)
        XCTAssertEqual(
            ledger.selectAtNaturalBoundary(
                boundaryID: "end-1", continuation: continuation(), currentHoldEpoch: 2)?.requestID,
            "request-1")
    }

    func testSelectedAndPlayingStateSurviveRelaunchBeforeCompletionAdmission() throws {
        var ledger = makeLedger()
        record(&ledger, id: "request-1", story: firstStory, at: 1, phase: .ready)
        _ = ledger.selectAtNaturalBoundary(
            boundaryID: "end-1", continuation: continuation(), currentHoldEpoch: 0)
        ledger.markStarting(requestID: "request-1")

        let selectedAfterCrash = try reload(ledger)
        XCTAssertEqual(selectedAfterCrash.activeEntry?.phase, .starting)
        XCTAssertEqual(selectedAfterCrash.activeEntry?.continuation, continuation())

        var playing = selectedAfterCrash
        playing.markPlaying(requestID: "request-1")
        playing.savePosition(requestID: "request-1", positionSeconds: 91.5)
        let playingAfterCrash = try reload(playing)
        XCTAssertEqual(playingAfterCrash.activeEntry?.phase, .playing)
        XCTAssertEqual(playingAfterCrash.activeEntry?.positionSeconds, 91.5)

        var completed = playingAfterCrash
        completed.markCompleted(requestID: "request-1")
        let completionAfterCrash = try reload(completed)
        XCTAssertEqual(completionAfterCrash.entries.first?.phase, .completed)
        XCTAssertEqual(completionAfterCrash.entries.first?.continuation, continuation())
        XCTAssertNil(completionAfterCrash.activeEntry)
    }

    func testLocallyCompletedStoryRecoversWhenRemoteCompletionWriteWasInterrupted() throws {
        var ledger = makeLedger()
        record(&ledger, id: "request-1", story: firstStory, at: 1, phase: .ready)
        _ = ledger.selectAtNaturalBoundary(
            boundaryID: "end-1", continuation: continuation(), currentHoldEpoch: 0)
        ledger.markStarting(requestID: "request-1")
        ledger.markPlaying(requestID: "request-1")
        ledger.markCompleted(requestID: "request-1")

        let restored = try reload(ledger)
        let recovered = restored.completedEntryForRecovery(requestID: "request-1", remotePhase: .playing)
        XCTAssertEqual(recovered?.continuation, continuation())
        XCTAssertNil(restored.completedEntryForRecovery(requestID: "request-1", remotePhase: .ready))
        XCTAssertEqual(
            restored.completedEntryForRecovery(requestID: "request-1", remotePhase: .completed)?.requestID,
            "request-1")
    }

    func testCompletedContinuationPersistsAutoPlayStopFence() throws {
        var ledger = makeLedger()
        let stoppedContinuation = ListenNextContinuation(
            kind: .phoneForwardSequence, anchorID: anchor, entryIDs: [successor],
            allowsAutomaticContinuation: false)
        record(&ledger, id: "request-1", story: firstStory, at: 1, phase: .ready)
        _ = ledger.selectAtNaturalBoundary(
            boundaryID: "end-1", continuation: stoppedContinuation, currentHoldEpoch: 0)
        ledger.markStarting(requestID: "request-1")
        ledger.markPlaying(requestID: "request-1")
        ledger.markCompleted(requestID: "request-1")

        let restored = try reload(ledger)
        let recovered = restored.completedEntryForRecovery(requestID: "request-1", remotePhase: .playing)
        XCTAssertEqual(recovered?.continuation?.shouldAutomaticallyContinue, false)
    }

    func testAbandonedSelectedStartReturnsToFifoWithoutCrossingNewerHold() {
        var ledger = makeLedger()
        record(&ledger, id: "request-1", story: firstStory, at: 1, phase: .ready)
        record(&ledger, id: "request-2", story: secondStory, at: 2, phase: .ready)
        _ = ledger.selectAtNaturalBoundary(
            boundaryID: "end-1", continuation: continuation(), currentHoldEpoch: 0)
        ledger.markStarting(requestID: "request-1")

        ledger.returnAbandonedStartToReady(requestID: "request-1")
        XCTAssertEqual(ledger.entries.first?.phase, .ready)
        XCTAssertNil(ledger.entries.first?.boundaryID)
        XCTAssertNil(ledger.entries.first?.continuation)
        XCTAssertNil(ledger.selectAtNaturalBoundary(
            boundaryID: "end-2", continuation: continuation(), currentHoldEpoch: 1))

        ledger.releaseHold(onExplicitStartAt: 1)
        XCTAssertEqual(ledger.selectAtNaturalBoundary(
            boundaryID: "end-2", continuation: continuation(), currentHoldEpoch: 1)?.requestID,
            "request-1")
    }

    func testReadyAudioPathSurvivesRelaunchAndExplicitStopNeedsPlay() throws {
        var ledger = makeLedger()
        record(&ledger, id: "request-1", story: firstStory, at: 1, phase: .preparing)
        let audioURL = URL(fileURLWithPath: "/Library/Caches/story-audio.m4a")
        let offer = ListenNextAudioOfferIdentity(
            audioRevisionID: "audio-revision-1", contentHash: "sha256:" + String(repeating: "a", count: 64),
            byteCount: 1234, mediaType: "audio/mp4", durationSeconds: 18.5)
        ledger.setReadyMedia(requestID: "request-1", fileURL: audioURL, audioOfferIdentity: offer)
        ledger.releaseHold(onExplicitStartAt: 2)

        var restored = try reload(ledger)
        XCTAssertEqual(restored.entries.first?.phase, .ready)
        XCTAssertEqual(restored.entries.first?.mediaFilePath, audioURL.path)
        XCTAssertEqual(restored.entries.first?.audioOfferIdentity, offer)
        XCTAssertEqual(
            restored.selectAtNaturalBoundary(
                boundaryID: "end-1", continuation: continuation(), currentHoldEpoch: 2)?.requestID,
            "request-1")
    }

    func testStaleOwnerOrGenerationCannotLoadAnotherAccountsQueue() throws {
        var ledger = makeLedger()
        record(&ledger, id: "request-1", story: firstStory, at: 1, phase: .ready)
        let data = try ledger.encoded()

        let otherOwner = ListenNextPlaybackLedger.decode(
            data, requesterDeviceID: deviceID, ownerToken: "account-B", operationGeneration: generation)
        let newerGeneration = ListenNextPlaybackLedger.decode(
            data, requesterDeviceID: deviceID, ownerToken: ownerToken, operationGeneration: generation + 1)
        let otherDevice = ListenNextPlaybackLedger.decode(
            data, requesterDeviceID: "phone-B", ownerToken: ownerToken, operationGeneration: generation)

        XCTAssertTrue(otherOwner.entries.isEmpty)
        XCTAssertTrue(newerGeneration.entries.isEmpty)
        XCTAssertTrue(otherDevice.entries.isEmpty)
    }

    private func makeLedger() -> ListenNextPlaybackLedger {
        ListenNextPlaybackLedger(
            requesterDeviceID: deviceID, ownerToken: ownerToken, operationGeneration: generation)
    }

    private func continuation() -> ListenNextContinuation {
        ListenNextContinuation(kind: .phoneForwardSequence, anchorID: anchor, entryIDs: [successor])
    }

    private func record(
        _ ledger: inout ListenNextPlaybackLedger, id: String, story: ItemID,
        at seconds: TimeInterval, phase: ListenNextPlaybackPhase, holdEpoch: UInt64 = 0
    ) {
        ledger.record(
            requestID: id, storyID: story, requesterDeviceID: deviceID, ownerToken: ownerToken,
            operationGeneration: generation, anchorID: anchor, createdAt: Date(timeIntervalSince1970: seconds),
            holdEpoch: holdEpoch, phase: phase)
    }

    private func reload(_ ledger: ListenNextPlaybackLedger) throws -> ListenNextPlaybackLedger {
        ListenNextPlaybackLedger.decode(
            try ledger.encoded(), requesterDeviceID: deviceID, ownerToken: ownerToken,
            operationGeneration: generation)
    }
}
