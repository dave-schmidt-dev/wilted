import Foundation
import WiltedLibrary
import WiltedProducer
import XCTest
@testable import WiltedMac

@MainActor
final class WiltedMacBulletinAvailabilityTests: XCTestCase {
    func testBulletinVoiceAvailabilityCheckDoesNotBlockMainActorOrRenderStaleBulletin() async throws {
        let owner = "bulletin-availability-owner"
        let macID = "bulletin-availability-mac"
        let phoneID = "bulletin-availability-phone"
        let now = Date()
        let story = try Bulletin(
            id: "headline:availability-main-actor", kind: .headline, text: "Current headline",
            issuedAt: now, expiresAt: now.addingTimeInterval(600))
        var currentBulletin: Bulletin? = story
        let gate = BlockingVoiceAvailability()
        let audioTransport = BulletinAudioTransportRecorder(owner: owner)
        let authority = BulletinAudioAuthority(owner: owner, generation: 4)
        let renders = BulletinAudioRenderRecorder()
        let directory = wiltedTemporaryDirectory("bulletin-availability")
        let coordinator = WiltedMacBulletinAudioCoordinator(
            audioTransport: audioTransport, deviceID: macID, directory: directory,
            currentOwner: { await authority.owner() },
            currentGeneration: { await authority.generation() },
            bulletin: { id in currentBulletin?.id == id ? currentBulletin : nil },
            readyAudioURL: { _, _ in nil },
            selectedVoice: { _ in .caseyKasem },
            voiceAvailability: { _ in gate.check() },
            render: { text, voice, outputURL in
                await renders.record(text: text, voice: voice)
                try writeSilentAAC(to: outputURL)
                return ArticleNarrationAudio(
                    audioURL: outputURL, duration: 0.1,
                    voiceRevision: ArticleNarrationCoordinator.shortTextVoiceRevision(for: voice))
            },
            now: { now })
        defer {
            gate.resumeCheck()
            coordinator.invalidate()
        }
        let intent = try LibraryIntent.requestBulletinAudio(
            bulletinID: story.id, deviceID: phoneID,
            spokenTextSHA256: MediaHash.sha256(text: story.text),
            createdAt: now, id: "bulletin-availability-stale-story")

        let outcome = try await coordinator.handle(intent)
        XCTAssertTrue(outcome.isApplied)
        let checkStarted = await gate.waitForCheck()
        XCTAssertTrue(checkStarted)
        let mainActorResponse = await Task { @MainActor in "responsive" }.value
        XCTAssertEqual(mainActorResponse, "responsive")
        XCTAssertFalse(gate.checkHasFinished)
        XCTAssertFalse(gate.ranOnMainThread)

        currentBulletin = try Bulletin(
            id: story.id, kind: .headline, text: "Replacement headline",
            issuedAt: now, expiresAt: story.expiresAt)
        gate.resumeCheck()

        let failed = try await eventuallyStatus(intent.id, from: audioTransport)
        let snapshot = await audioTransport.snapshot()
        let renderCalls = await renders.value()
        XCTAssertEqual(failed.failure, .unavailableStory)
        XCTAssertTrue(snapshot.audio.isEmpty)
        XCTAssertTrue(renderCalls.isEmpty)
    }

    private func eventuallyStatus(
        _ requestID: String, from transport: BulletinAudioTransportRecorder
    ) async throws -> LibraryListenNextStatus {
        for _ in 0..<200 {
            let snapshot = await transport.snapshot()
            if let status = snapshot.statusHistory.last(where: {
                $0.requestID == requestID && $0.phase == .failed
            }) {
                return status
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Timed out waiting for the stale bulletin request to fail.")
        throw BulletinAudioTestError.statusTimedOut
    }
}

