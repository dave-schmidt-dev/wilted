import CloudKit
import Foundation
import WiltedCloudKit
import WiltedDomain
import WiltedLibrary
import XCTest
@testable import WiltedCloudKitLibrary

final class ListenNextTransportIntegrationTests: XCTestCase {
    private let owner = "fixture-owner"

    private func endpoint(_ fixture: MediaFixture, id: String, writer: Bool = false) async throws -> CloudKitLibraryTransport {
        let transport = try fixture.endpoint(id, writer: writer).transport
        await transport.handleAccountChange(.signIn, CloudKitAccountIdentity(currentOwnerToken: owner))
        return transport
    }

    private func offer(for audio: URL, revision: String = "rev-first") throws -> LibraryStoryAudioOffer {
        try LibraryStoryAudioOffer(requestID: "story-request", storyID: "item-headline",
                                   requesterDeviceID: "phone", voiceID: "casey", voiceRevision: "casey-v1",
                                   audioRevision: RevisionID(rawValue: revision), contentHash: MediaHash.sha256(fileAt: audio),
                                   byteCount: 100, mediaType: "audio/mp4", durationSeconds: 3)
    }

    private func sendRequest(_ offer: LibraryStoryAudioOffer, from phone: CloudKitLibraryTransport) async throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let card = try LibraryHeadlineStory(
            id: offer.storyID, title: "A fixture story", publisherID: "fixture-source",
            publisherName: "Fixture", link: URL(string: "https://example.invalid/article"),
            publishedAt: now, firstSeenAt: now, lastSeenAt: now
        )
        try await phone.send(intent: LibraryIntent(
            id: offer.requestID, deviceID: offer.requesterDeviceID, createdAt: now,
            action: .listenNext(story: card, anchorID: nil)
        ))
    }

    func testOnlyRequesterCanFetchExactAudioRevisionWithoutLarderMembership() async throws {
        let fixture = try MediaFixture()
        let mac = try await endpoint(fixture, id: "mac", writer: true)
        let phone = try await endpoint(fixture, id: "phone")
        let other = try await endpoint(fixture, id: "other-phone")
        let file = try fixture.audioFile()
        let first = try offer(for: file)
        let second = try offer(for: file, revision: "rev-second")
        try await sendRequest(first, from: phone)
        for offer in [first, second] {
            try await mac.publishStoryAudio(offer: offer, fileURL: file, expectedOwner: owner)
        }
        let cloudRecords = await fixture.server.allRecords()
        XCTAssertEqual(cloudRecords.filter { $0.recordType == LibraryStoryAudioRecord.recordType }.count, 2)
        for record in cloudRecords where record.recordType == LibraryStoryAudioRecord.recordType {
            XCTAssertEqual(Set(record.allKeys()), Set(["offer", "asset"]))
        }
        do {
            _ = try await other.fetchStoryAudio(first, expectedOwner: owner) { _ in }
            XCTFail("A second phone received another device's reading.")
        } catch LibraryTransportError.ownershipViolation {}
        try await mac.removeStoryAudio(first, expectedOwner: owner)
        let liveWrapper: any LibraryTransport = ThrottledLibraryTransport(wrapping: phone, gate: TransportGate())
        let downloaded = try await liveWrapper.storyAudioService().fetchStoryAudio(second, expectedOwner: owner) { _ in }
        defer { try? FileManager.default.removeItem(at: downloaded) }
        XCTAssertEqual(try Data(contentsOf: file), try Data(contentsOf: downloaded))
        let ordinaryOffers = try await phone.mediaOffers()
        XCTAssertTrue(ordinaryOffers.isEmpty)
    }

    func testMacCanPublishAudioForAnIDOnlyBulletinIntent() async throws {
        let fixture = try MediaFixture()
        let mac = try await endpoint(fixture, id: "mac", writer: true)
        let phone = try await endpoint(fixture, id: "phone")
        let file = try fixture.audioFile()
        let base = try offer(for: file)
        let requestID = "bulletin-audio-request"
        let bulletinID = "headline:fixture-42"
        let offer = try LibraryStoryAudioOffer(
            requestID: requestID, storyID: bulletinID, requesterDeviceID: "phone",
            voiceID: "casey-kasem", voiceRevision: "casey-kasem-short-v1",
            audioRevision: base.audioRevision, contentHash: base.contentHash,
            byteCount: base.byteCount, mediaType: base.mediaType, durationSeconds: base.durationSeconds)
        let request = try LibraryIntent.requestBulletinAudio(
            bulletinID: bulletinID, deviceID: "phone", createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            id: requestID)

        try await phone.send(intent: request)
        let wrongStory = try LibraryStoryAudioOffer(
            requestID: requestID, storyID: "headline:another-story", requesterDeviceID: "phone",
            voiceID: offer.voiceID, voiceRevision: offer.voiceRevision, audioRevision: offer.audioRevision,
            contentHash: offer.contentHash, byteCount: offer.byteCount,
            mediaType: offer.mediaType, durationSeconds: offer.durationSeconds)
        do {
            try await mac.publishStoryAudio(offer: wrongStory, fileURL: file, expectedOwner: owner)
            XCTFail("An audio offer for another bulletin must not match the phone's request.")
        } catch LibraryTransportError.ownershipViolation {}

        try await mac.publishStoryAudio(offer: offer, fileURL: file, expectedOwner: owner)
        let fetched = try await phone.fetchStoryAudio(offer, expectedOwner: owner) { _ in }
        defer { try? FileManager.default.removeItem(at: fetched) }
        XCTAssertEqual(try Data(contentsOf: file), try Data(contentsOf: fetched))
    }

    func testOnlyRequesterSeesProgressAndAnOlderStatusCannotRestoreCancelledAudio() async throws {
        let fixture = try MediaFixture()
        let mac = try await endpoint(fixture, id: "mac", writer: true)
        let phone = try await endpoint(fixture, id: "phone")
        let other = try await endpoint(fixture, id: "second-phone")
        let offer = try offer(for: fixture.audioFile())
        try await sendRequest(offer, from: phone)
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let preparing = try LibraryListenNextStatus(
            requestID: offer.requestID, storyID: offer.storyID, requesterDeviceID: offer.requesterDeviceID,
            phase: .preparing, statusRevision: 1, updatedAt: now
        )
        let cancelled = try LibraryListenNextStatus(
            requestID: offer.requestID, storyID: offer.storyID, requesterDeviceID: offer.requesterDeviceID,
            phase: .cancelled, statusRevision: 2, updatedAt: now.addingTimeInterval(1)
        )
        let lateReady = try LibraryListenNextStatus(
            requestID: offer.requestID, storyID: offer.storyID, requesterDeviceID: offer.requesterDeviceID,
            phase: .ready, statusRevision: 3, updatedAt: now.addingTimeInterval(2),
            voiceID: offer.voiceID, voiceRevision: offer.voiceRevision, audioOffer: offer
        )
        for state in [preparing, cancelled, preparing, lateReady] {
            try await mac.publishListenNextStatus(state, expectedOwner: owner)
        }
        let actual = try await phone.listenNextStatuses(requestIDs: [offer.requestID], expectedOwner: owner)
        let invisible = try await other.listenNextStatuses(requestIDs: [offer.requestID], expectedOwner: owner)
        XCTAssertEqual(actual, [cancelled])
        XCTAssertTrue(invisible.isEmpty)
    }

    func testReadyStatusReplayedAfterMacRestartHasOnePublishedTransition() async throws {
        let fixture = try MediaFixture()
        let mac = try await endpoint(fixture, id: "mac", writer: true)
        let phone = try await endpoint(fixture, id: "phone")
        let offer = try offer(for: fixture.audioFile())
        try await sendRequest(offer, from: phone)
        let status = try LibraryListenNextStatus(
            requestID: offer.requestID, storyID: offer.storyID, requesterDeviceID: offer.requesterDeviceID,
            phase: .ready, statusRevision: 2, updatedAt: Date(timeIntervalSince1970: 1_700_000_001),
            voiceID: offer.voiceID, voiceRevision: offer.voiceRevision, audioOffer: offer
        )
        try await mac.publishListenNextStatus(status, expectedOwner: owner)
        let originalSaves = await fixture.server.log.filter { $0.hasPrefix("engine save story-status-") }
        let restarted = try await endpoint(fixture, id: "mac", writer: true)
        try await restarted.publishListenNextStatus(status, expectedOwner: owner)
        let afterReplay = await fixture.server.log.filter { $0.hasPrefix("engine save story-status-") }
        XCTAssertEqual(originalSaves.count, 1)
        XCTAssertEqual(afterReplay, originalSaves)
        let observed = try await phone.listenNextStatuses(requestIDs: [status.requestID], expectedOwner: owner)
        XCTAssertEqual(observed, [status])
    }

    func testSameSizeDifferentBytesAreRejectedBeforeUploadAndAfterDownload() async throws {
        let fixture = try MediaFixture()
        let mac = try await endpoint(fixture, id: "mac", writer: true)
        let phone = try await endpoint(fixture, id: "phone")
        let file = try fixture.audioFile()
        let offer = try offer(for: file)
        try await sendRequest(offer, from: phone)
        let changed = fixture.scratch.appendingPathComponent("changed.wav")
        try Data(repeating: 7, count: Int(offer.byteCount)).write(to: changed)
        do {
            try await mac.publishStoryAudio(offer: offer, fileURL: changed, expectedOwner: owner)
            XCTFail("Mismatched bytes were uploaded.")
        } catch LibraryTransportError.transport {}
        let record = try LibraryStoryAudioRecord.record(for: offer, audio: changed, in: fixture.mapper.mediaZoneID)
        await fixture.server.putRaw(record)
        do {
            _ = try await phone.fetchStoryAudio(offer, expectedOwner: owner) { _ in }
            XCTFail("Mismatched bytes were accepted.")
        } catch LibraryTransportError.transport {}
    }

    func testAccountSwitchDuringAssetDownloadDiscardsTheTransferredAudio() async throws {
        let fixture = try MediaFixture()
        let mac = try await endpoint(fixture, id: "mac", writer: true)
        let phone = try fixture.endpoint("phone", writer: false)
        await phone.transport.handleAccountChange(.signIn, CloudKitAccountIdentity(currentOwnerToken: owner))
        let file = try fixture.audioFile()
        let offer = try offer(for: file)
        try await sendRequest(offer, from: phone.transport)
        try await mac.publishStoryAudio(offer: offer, fileURL: file, expectedOwner: owner)
        let transport = phone.transport
        await phone.driver.onNextAssetFetch {
            await transport.handleAccountChange(.switchAccounts, CloudKitAccountIdentity(currentOwnerToken: "other-owner", hadPreviousOwner: true))
        }
        do {
            _ = try await transport.fetchStoryAudio(offer, expectedOwner: owner) { _ in }
            XCTFail("A transfer that completed after the account changed produced playable audio.")
        } catch CloudKitSyncError.accountChanged {}
    }

    func testExistingOfferCannotGrantMissingRequestOrCrossAnAccountSwitch() async throws {
        let fixture = try MediaFixture()
        let mac = try await endpoint(fixture, id: "mac", writer: true)
        let phone = try await endpoint(fixture, id: "phone")
        let file = try fixture.audioFile()
        let offer = try offer(for: file)
        do {
            try await mac.publishStoryAudio(offer: offer, fileURL: file, expectedOwner: owner)
            XCTFail("The Mac uploaded audio without a matching device request.")
        } catch LibraryTransportError.ownershipViolation {}
        try await sendRequest(offer, from: phone)
        try await mac.publishStoryAudio(offer: offer, fileURL: file, expectedOwner: owner)
        await phone.handleAccountChange(.signOut, CloudKitAccountIdentity())
        do {
            _ = try await phone.fetchStoryAudio(offer, expectedOwner: owner) { _ in }
            XCTFail("A prior owner's offer survived account quarantine.")
        } catch CloudKitSyncError.quarantined {}
    }
}
