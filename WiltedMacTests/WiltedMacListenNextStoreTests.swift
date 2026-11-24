import Foundation
import WiltedDomain
import WiltedLibrary
import XCTest
@testable import WiltedMac
@testable import WiltedProducer

@MainActor
final class WiltedMacListenNextStoreTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let owner = "owner-1"

    private func story() throws -> LibraryHeadlineStory {
        try LibraryHeadlineStory(
            id: "story-1", title: "A story", publisherID: "feed-1", publisherName: "Publisher",
            link: URL(string: "https://example.com/story"), publishedAt: now,
            firstSeenAt: now, lastSeenAt: now)
    }

    private func intent(id: String = "request-1", device: String = "phone-1") throws -> LibraryIntent {
        try LibraryIntent.listenNext(story: story(), anchorID: nil, deviceID: device, createdAt: now, id: id)
    }

    private func offer() throws -> LibraryStoryAudioOffer {
        try LibraryStoryAudioOffer(
            requestID: "request-1", storyID: "story-1", requesterDeviceID: "phone-1",
            voiceID: "casey", voiceRevision: "voice-r1", audioRevision: RevisionID(rawValue: "audio-r1"),
            contentHash: "sha256:" + String(repeating: "b", count: 64), byteCount: 100,
            mediaType: "audio/mp4", durationSeconds: 2)
    }

    func testAdmissionReceiptSurvivesRelaunchWithoutCreatingAnotherTicket() async throws {
        let file = wiltedTemporaryDirectory("listen-next-admission").appendingPathComponent("requests.json")
        let fixedNow = now
        let first = WiltedMacListenNextStore(fileURL: file, now: { fixedNow })
        _ = try await first.activate(ownerToken: owner, operationGeneration: 4)
        let original = try await first.admit(
            intent(), ownerToken: owner, operationGeneration: 4, voiceID: "casey", voiceRevision: "voice-r1")
        let duplicate = try await first.admit(
            intent(), ownerToken: owner, operationGeneration: 4, voiceID: "casey", voiceRevision: "voice-r1")
        XCTAssertEqual(original, duplicate)

        let restarted = WiltedMacListenNextStore(fileURL: file, now: { fixedNow })
        let recovered = try await restarted.activate(ownerToken: owner, operationGeneration: 8)
        XCTAssertEqual(recovered.count, 1)
        XCTAssertEqual(recovered.first?.requestID, "request-1")
        XCTAssertEqual(recovered.first?.operationGeneration, 8)
        XCTAssertEqual(recovered.first?.status, .preparing)
    }

    func testRequestIDCannotBeReusedForAnotherPlaybackAnchor() async throws {
        let fixedNow = now
        let store = WiltedMacListenNextStore(fileURL: nil, now: { fixedNow })
        _ = try await store.activate(ownerToken: owner, operationGeneration: 1)
        _ = try await store.admit(
            intent(), ownerToken: owner, operationGeneration: 1, voiceID: "casey", voiceRevision: "voice-r1")
        let changedAnchor = try LibraryIntent.listenNext(
            story: story(), anchorID: try ItemID(rawValue: "episode-2"), deviceID: "phone-1", createdAt: now,
            id: "request-1")
        do {
            _ = try await store.admit(
                changedAnchor, ownerToken: owner, operationGeneration: 1,
                voiceID: "casey", voiceRevision: "voice-r1")
            XCTFail("The same request id was accepted with a different playback anchor.")
        } catch LibraryTransportError.ownershipViolation {}
    }

    func testCancelBeforeIntentArrivalLeavesTombstoneAndBlocksLateAudio() async throws {
        let file = wiltedTemporaryDirectory("listen-next-cancel-before-arrival").appendingPathComponent("requests.json")
        let fixedNow = now
        let store = WiltedMacListenNextStore(fileURL: file, now: { fixedNow })
        _ = try await store.activate(ownerToken: owner, operationGeneration: 3)
        let absent = try await store.cancel(
            requestID: "request-1", requesterDeviceID: "phone-1", ownerToken: owner, operationGeneration: 3)
        XCTAssertNil(absent)

        let lateAdmission = try await store.admit(
            intent(), ownerToken: owner, operationGeneration: 3, voiceID: "casey", voiceRevision: "voice-r1")
        XCTAssertEqual(lateAdmission.status, .cancelled)
        let lateReady = try await store.setStatus(
            requestID: "request-1", ownerToken: owner, operationGeneration: 3,
            status: .ready, offer: offer())
        XCTAssertNil(lateReady)
        let cancelledRows = await store.snapshots(requesterDeviceID: "phone-1", ownerToken: owner)
        XCTAssertEqual(cancelledRows.first?.status, .cancelled)
    }

    func testAccountAndGenerationFencesRejectLatePreparationResults() async throws {
        let file = wiltedTemporaryDirectory("listen-next-generation").appendingPathComponent("requests.json")
        let fixedNow = now
        let store = WiltedMacListenNextStore(fileURL: file, now: { fixedNow })
        _ = try await store.activate(ownerToken: owner, operationGeneration: 5)
        _ = try await store.admit(
            intent(), ownerToken: owner, operationGeneration: 5, voiceID: "casey", voiceRevision: "voice-r1")
        let wrongOwner = try await store.setStatus(
            requestID: "request-1", ownerToken: "other-owner", operationGeneration: 5,
            status: .failed, failure: .narrationFailed)
        XCTAssertNil(wrongOwner)

        _ = try await store.activate(ownerToken: owner, operationGeneration: 6)
        let staleGeneration = try await store.setStatus(
            requestID: "request-1", ownerToken: owner, operationGeneration: 5,
            status: .failed, failure: .narrationFailed)
        XCTAssertNil(staleGeneration)
        let readyState = try await store.setStatus(
            requestID: "request-1", ownerToken: owner, operationGeneration: 6,
            status: .ready, offer: offer())
        let ready = try XCTUnwrap(readyState)
        XCTAssertEqual(ready.status, .ready)

        _ = try await store.activate(ownerToken: "owner-2", operationGeneration: 1)
        let oldAccountRows = await store.snapshots(requesterDeviceID: "phone-1", ownerToken: owner)
        let newAccountRows = await store.snapshots(requesterDeviceID: "phone-1", ownerToken: "owner-2")
        XCTAssertTrue(oldAccountRows.isEmpty)
        XCTAssertTrue(newAccountRows.isEmpty)
    }

    func testQueueTransitionRequiresTheExactSnapshotSelectedForPlayback() async throws {
        let file = wiltedTemporaryDirectory("listen-next-transition").appendingPathComponent("requests.json")
        let fixedNow = now
        let store = WiltedMacListenNextStore(fileURL: file, now: { fixedNow })
        _ = try await store.activate(ownerToken: owner, operationGeneration: 2)
        _ = try await store.admit(
            intent(), ownerToken: owner, operationGeneration: 2,
            voiceID: "casey", voiceRevision: "voice-r1")
        let readyResult = try await store.setStatus(
            requestID: "request-1", ownerToken: owner, operationGeneration: 2,
            status: .ready, offer: offer())
        let ready = try XCTUnwrap(readyResult)
        let selectedResult = try await store.transition(from: ready, to: .selected)
        let selected = try XCTUnwrap(selectedResult)
        XCTAssertEqual(selected.status, .selected)
        let staleStart = try await store.transition(from: ready, to: .playing)
        XCTAssertNil(staleStart)
        let playingResult = try await store.transition(from: selected, to: .playing)
        let playing = try XCTUnwrap(playingResult)
        let completedResult = try await store.transition(from: playing, to: .completed)
        let completed = try XCTUnwrap(completedResult)
        XCTAssertEqual(completed.status, .completed)
    }

    func testFailedQueueTransitionDropsItsAudioOfferAndBecomesTerminal() async throws {
        let fixedNow = now.addingTimeInterval(100)
        let store = WiltedMacListenNextStore(fileURL: nil, now: { fixedNow })
        _ = try await store.activate(ownerToken: owner, operationGeneration: 2)
        _ = try await store.admit(
            intent(), ownerToken: owner, operationGeneration: 2,
            voiceID: "casey", voiceRevision: "voice-r1")
        let readyResult = try await store.setStatus(
            requestID: "request-1", ownerToken: owner, operationGeneration: 2,
            status: .ready, offer: offer())
        let ready = try XCTUnwrap(readyResult)
        let failedResult = try await store.transition(from: ready, to: .failed, failure: .narrationFailed)
        let failed = try XCTUnwrap(failedResult)
        XCTAssertNil(failed.audioOffer)
        XCTAssertEqual(failed.failure, .narrationFailed)
        XCTAssertTrue(failed.isTerminal)
        XCTAssertEqual(failed.statusUpdatedAt, now.addingTimeInterval(100))
    }

    func testMissingVoiceCanBeRecordedWithoutInventingAVoiceRevision() async throws {
        let file = wiltedTemporaryDirectory("listen-next-missing-voice").appendingPathComponent("requests.json")
        let fixedNow = now
        let store = WiltedMacListenNextStore(fileURL: file, now: { fixedNow })
        _ = try await store.activate(ownerToken: owner, operationGeneration: 1)
        let pending = try await store.admit(
            intent(), ownerToken: owner, operationGeneration: 1, voiceID: nil, voiceRevision: nil)
        XCTAssertNil(pending.voiceID)
        let failedResult = try await store.setStatus(
            requestID: pending.requestID, ownerToken: owner, operationGeneration: 1,
            status: .failed, failure: .missingVoice)
        let failed = try XCTUnwrap(failedResult)
        XCTAssertEqual(failed.failure, .missingVoice)
    }
}
