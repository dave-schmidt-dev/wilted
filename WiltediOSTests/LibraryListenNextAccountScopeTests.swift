import Foundation
import XCTest
import WiltedDomain
import WiltedLibrary
@testable import WiltediOS

@MainActor
func assertAccountSwitchRejectsCachedStoryAndCancelsOldGenerationDelivery(
    _ tests: LibraryListenNextPhoneModelTests
) async throws {
    let recovery = LibraryAccountRecovery(
        quarantineEvents: AsyncStream<Void> { continuation in continuation.finish() }) {
            InMemoryLibraryStore()
        }
    let phoneTransport = tests.transport(OutboxSendScript(.deliver))
    let phone = tests.model(phoneTransport, recovery: recovery)
    await phone.loadLocalState()

    let cachedStory = try tests.story(id: "headline-cached")
    await phone.listenNext(cachedStory)
    let cachedRequest = try XCTUnwrap(phone.listenNextRequests.first { $0.storyID == cachedStory.id })
    await phoneTransport.audio.setStatus(try readyStatus(
        for: cachedRequest, revision: "cached", sourceFile: tests.sourceFile, now: tests.now))
    await phone.syncListenNextRequests()
    await tests.eventually("the first story's durable cache") {
        guard case let .saved(saved) = LibraryListenNextPhoneOutbox(
            url: tests.scratch.appendingPathComponent("pending-listen-next-v1.json")).load() else { return false }
        return saved.entries.first(where: { $0.id == cachedRequest.requestID })?.audioCached == true
    }
    let cachedReady = try XCTUnwrap(phone.listenNextRequests.first { $0.requestID == cachedRequest.requestID })
    let cachedCandidate = await phone.listenNextAudioURL(for: cachedReady)
    let cachedURL = try XCTUnwrap(cachedCandidate)
    XCTAssertTrue(FileManager.default.fileExists(atPath: cachedURL.path))

    await phoneTransport.audio.setHoldFetch(true)
    let pendingStory = try tests.story(id: "headline-pending")
    await phone.listenNext(pendingStory)
    let pendingRequest = try XCTUnwrap(phone.listenNextRequests.first { $0.storyID == pendingStory.id })
    await phoneTransport.audio.setStatus(try readyStatus(
        for: pendingRequest, revision: "pending", sourceFile: tests.sourceFile, now: tests.now))
    await phone.syncListenNextRequests()
    await tests.eventually("the second story's in-flight media delivery") {
        await phoneTransport.audio.didStartFetch(requestID: pendingRequest.requestID)
    }

    await phoneTransport.switchAccount(to: "listen-next-new-owner")
    await phone.syncListenNextRequests()
    await tests.eventually("old-generation delivery cancellation") {
        await phoneTransport.audio.wasFetchCancelled(requestID: pendingRequest.requestID)
    }
    let staleAudio = await phone.listenNextAudioURL(for: cachedReady)
    XCTAssertNil(staleAudio, "The old owner's cached story must be inaccessible after the account switch.")

    await phone.recoverFromAccountChange()
    XCTAssertFalse(FileManager.default.fileExists(atPath: cachedURL.path))
    XCTAssertTrue(phone.listenNextRequests.isEmpty)
    guard case let .saved(cleared) = LibraryListenNextPhoneOutbox(
        url: tests.scratch.appendingPathComponent("pending-listen-next-v1.json")).load() else {
        return XCTFail("The account switch did not persist an empty request outbox.")
    }
    XCTAssertNil(cleared.ownerToken)
    XCTAssertTrue(cleared.entries.isEmpty)
    XCTAssertNil(tests.defaults.data(forKey: "wilted.listenNext.playback.v1"))
}

private func readyStatus(
    for request: LibraryListenNextRequestSnapshot,
    revision: String,
    sourceFile: URL,
    now: Date
) throws -> LibraryListenNextStatus {
    let offer = try LibraryStoryAudioOffer(
        requestID: request.requestID, storyID: request.storyID, requesterDeviceID: "phone-1",
        voiceID: "approved-voice", voiceRevision: "voice-revision-1",
        audioRevision: RevisionID(rawValue: "story-audio-\(revision)"),
        contentHash: try MediaHash.sha256(fileAt: sourceFile), byteCount: 4,
        mediaType: "audio/mp4", durationSeconds: 3)
    return try LibraryListenNextStatus(
        requestID: request.requestID, storyID: request.storyID, requesterDeviceID: "phone-1",
        phase: .ready, statusRevision: 1, updatedAt: now, voiceID: offer.voiceID,
        voiceRevision: offer.voiceRevision, audioOffer: offer)
}
