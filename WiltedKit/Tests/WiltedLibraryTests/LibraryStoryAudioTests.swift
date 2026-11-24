import Foundation
import WiltedDomain
import XCTest
@testable import WiltedLibrary

final class LibraryStoryAudioTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func story() throws -> LibraryHeadlineStory {
        try LibraryHeadlineStory(
            id: "story-1", title: "A story", publisherID: "feed-1", publisherName: "Publisher",
            link: URL(string: "https://example.com/story"), publishedAt: now,
            firstSeenAt: now, lastSeenAt: now)
    }

    private func offer(voice: String = "casey", revision: String = "story-audio-r1") throws -> LibraryStoryAudioOffer {
        try LibraryStoryAudioOffer(
            requestID: "request-1", storyID: "story-1", requesterDeviceID: "phone-1",
            voiceID: voice, voiceRevision: "voice-r1", audioRevision: RevisionID(rawValue: revision),
            contentHash: "sha256:" + String(repeating: "a", count: 64), byteCount: 120,
            mediaType: "audio/mp4", durationSeconds: 8)
    }

    func testStoryAudioOfferRoundTripsAndRequiresValidIdentityAndHash() throws {
        let expected = try offer()
        let data = try JSONEncoder().encode(expected)
        XCTAssertEqual(try JSONDecoder().decode(LibraryStoryAudioOffer.self, from: data), expected)
        XCTAssertThrowsError(try LibraryStoryAudioOffer(
            requestID: "request-1", storyID: "story-1", requesterDeviceID: "phone-1",
            voiceID: "casey", voiceRevision: "voice-r1", audioRevision: RevisionID(rawValue: "r1"),
            contentHash: "invalid", byteCount: 120, mediaType: "audio/mp4", durationSeconds: 8))
        XCTAssertThrowsError(try LibraryStoryAudioOffer(
            requestID: "request-1", storyID: "story-1", requesterDeviceID: "phone-1",
            voiceID: "casey", voiceRevision: "voice-r1", audioRevision: RevisionID(rawValue: "r1"),
            contentHash: "sha256:" + String(repeating: "a", count: 64), byteCount: 120,
            mediaType: "audio/wav", durationSeconds: 8))
    }

    func testReadyStatusCarriesTheExactRequestDeviceAndVoiceOffer() throws {
        let offer = try offer()
        let status = try LibraryListenNextStatus(
            requestID: offer.requestID, storyID: offer.storyID, requesterDeviceID: offer.requesterDeviceID,
            phase: .ready, statusRevision: 3, updatedAt: now, voiceID: offer.voiceID,
            voiceRevision: offer.voiceRevision, audioOffer: offer)
        XCTAssertEqual(try JSONDecoder().decode(LibraryListenNextStatus.self, from: JSONEncoder().encode(status)), status)
        XCTAssertThrowsError(try LibraryListenNextStatus(
            requestID: offer.requestID, storyID: offer.storyID, requesterDeviceID: "another-phone",
            phase: .ready, statusRevision: 3, updatedAt: now, voiceID: offer.voiceID,
            voiceRevision: offer.voiceRevision, audioOffer: offer))
    }

    func testSnapshotRetainsOriginalURLForRetryAfterFailure() throws {
        let source = try story()
        let snapshot = try LibraryListenNextRequestSnapshot(
            requestID: "request-1", story: source, requesterDeviceID: "phone-1", ownerToken: "owner-1",
            operationGeneration: 2, anchorID: nil, createdAt: now, status: .failed,
            statusRevision: 2, failure: .unsafeArticle)
        let decoded = try JSONDecoder().decode(
            LibraryListenNextRequestSnapshot.self, from: JSONEncoder().encode(snapshot))
        XCTAssertEqual(decoded.story.link, source.link)
        XCTAssertEqual(decoded.failure, .unsafeArticle)
        XCTAssertEqual(decoded.statusUpdatedAt, source.firstSeenAt)

        var legacy = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(snapshot)) as? [String: Any])
        legacy.removeValue(forKey: "statusUpdatedAt")
        let legacyData = try JSONSerialization.data(withJSONObject: legacy)
        let recovered = try JSONDecoder().decode(LibraryListenNextRequestSnapshot.self, from: legacyData)
        XCTAssertEqual(recovered.statusUpdatedAt, recovered.createdAt)
    }

    func testReadySnapshotRequiresItsExactAudioOffer() throws {
        XCTAssertThrowsError(try LibraryListenNextRequestSnapshot(
            requestID: "request-1", story: story(), requesterDeviceID: "phone-1", ownerToken: "owner-1",
            operationGeneration: 2, anchorID: nil, createdAt: now, status: .ready))
    }

    func testListenNextIntentUsesItsOwnIdAsRequestIdAndRejectsUnsafeLinks() throws {
        let source = try story()
        let intent = try LibraryIntent.listenNext(
            story: source, anchorID: nil, deviceID: "phone-1", createdAt: now, id: "request-1")
        XCTAssertTrue(intent.action.isDecision)
        XCTAssertEqual(intent.id, "request-1")
        XCTAssertEqual(try JSONDecoder().decode(LibraryIntent.self, from: JSONEncoder().encode(intent)), intent)

        let cancellation = try LibraryIntent.cancelListenNext(
            requestID: intent.id, deviceID: "phone-1", createdAt: now, id: "cancel-1")
        XCTAssertTrue(cancellation.action.isDecision)
        XCTAssertEqual(try JSONDecoder().decode(LibraryIntent.self, from: JSONEncoder().encode(cancellation)), cancellation)
        let longOfflineDate = now.addingTimeInterval(IntentRetention.maximumAge + 30)
        XCTAssertFalse(IntentRetention.isExpired(intent, now: longOfflineDate))
        XCTAssertFalse(IntentRetention.isExpired(cancellation, now: longOfflineDate))

        let unsafeStory = try LibraryHeadlineStory(
            id: "story-2", title: "Unsafe", publisherID: "feed-1", publisherName: "Publisher",
            link: URL(string: "http://127.0.0.1/private"), publishedAt: now, firstSeenAt: now, lastSeenAt: now)
        XCTAssertThrowsError(try LibraryIntent.listenNext(
            story: unsafeStory, anchorID: nil, deviceID: "phone-1", createdAt: now, id: "unsafe-request"))
    }
}
