import Foundation
import XCTest
import WiltedLibrary
import WiltedProducer
@testable import WiltedMac

@MainActor
final class WiltedMacNarrationAvailabilityTests: XCTestCase {
    func testHeadlineVoiceAvailabilityCheckDoesNotBlockTheMainActor() async throws {
        let availability = BlockingVoiceAvailability()
        let renderedVoices = NarrationAvailabilityVoiceCapture()
        let now = Date()
        let bulletin = try Bulletin(
            id: "headline:availability-main-actor", kind: .headline, text: "City Wire. Service expands.",
            issuedAt: now, expiresAt: now.addingTimeInterval(3_600), storyID: "availability-main-actor")
        let narration = WiltedMacHeadlineNarration(
            render: { _, voiceID, outputURL in
                await renderedVoices.record(voiceID)
                return ArticleNarrationAudio(
                    audioURL: outputURL, duration: 1,
                    voiceRevision: ArticleNarrationCoordinator.shortTextVoiceRevision(for: voiceID))
            },
            availability: { _ in availability.check() },
            now: { now })
        defer {
            availability.resumeCheck()
            narration.shutdown()
        }

        narration.update(
            current: [bulletin], newlyPublished: [bulletin], enabled: true,
            selectedVoice: .caseyKasem, accountIdentity: "test-owner", isEligible: { _ in true })

        let checkStarted = await availability.waitForCheck()
        XCTAssertTrue(checkStarted)
        let mainActorResponse = await Task { @MainActor in "responsive" }.value
        XCTAssertEqual(mainActorResponse, "responsive")
        XCTAssertFalse(availability.checkHasFinished,
                       "voice-file checks can take time while the Mac main actor remains available")
        XCTAssertFalse(availability.ranOnMainThread)
        availability.resumeCheck()

        await WiltedMacHeadless.eventually("the headline starts rendering after the voice check") {
            narration.readyBulletins.contains(where: { $0.id == bulletin.id })
        }
        let voices = await renderedVoices.values()
        XCTAssertEqual(voices, [.caseyKasem])
    }

    func testWeatherVoiceAvailabilityCheckDoesNotBlockTheMainActor() async throws {
        let availability = BlockingVoiceAvailability()
        let renderedVoices = NarrationAvailabilityVoiceCapture()
        let now = Date()
        let alert = try Bulletin(
            id: "alert:availability-main-actor", kind: .alert, text: "A weather alert is active.",
            severity: .severe, issuedAt: now, expiresAt: now.addingTimeInterval(3_600))
        let narration = WiltedMacWeatherAlertNarration(
            render: { _, voiceID, outputURL in
                await renderedVoices.record(voiceID)
                try Data(repeating: 0x58, count: 128).write(to: outputURL)
                return ArticleNarrationAudio(
                    audioURL: outputURL, duration: 1,
                    voiceRevision: ArticleNarrationCoordinator.shortTextVoiceRevision(for: voiceID))
            },
            availability: { _ in availability.check() },
            now: { now })
        defer {
            availability.resumeCheck()
            narration.shutdown()
        }

        narration.update(current: [alert], enabled: true, selectedVoice: .wolfmanJack)

        let checkStarted = await availability.waitForCheck()
        XCTAssertTrue(checkStarted)
        let mainActorResponse = await Task { @MainActor in "responsive" }.value
        XCTAssertEqual(mainActorResponse, "responsive")
        XCTAssertFalse(availability.checkHasFinished,
                       "voice-file checks can take time while the Mac main actor remains available")
        XCTAssertFalse(availability.ranOnMainThread)
        availability.resumeCheck()

        await WiltedMacHeadless.eventually("the weather alert starts rendering after the voice check") {
            narration.readyBulletins.contains(where: { $0.id == alert.id })
        }
        let voices = await renderedVoices.values()
        XCTAssertEqual(voices, [.wolfmanJack])
    }

    func testHeadlineThatExpiresDuringVoiceCheckIsDiscardedWithoutRendering() async throws {
        let clock = NarrationAvailabilityClock(Date())
        let availability = BlockingVoiceAvailability()
        let renderedVoices = NarrationAvailabilityVoiceCapture()
        let expiresAt = clock.read().addingTimeInterval(30)
        let bulletin = try Bulletin(
            id: "headline:availability-expiry", kind: .headline, text: "City Wire. Service expands.",
            issuedAt: clock.read(), expiresAt: expiresAt, storyID: "availability-expiry")
        let narration = WiltedMacHeadlineNarration(
            render: { _, voiceID, outputURL in
                await renderedVoices.record(voiceID)
                return ArticleNarrationAudio(
                    audioURL: outputURL, duration: 1,
                    voiceRevision: ArticleNarrationCoordinator.shortTextVoiceRevision(for: voiceID))
            },
            availability: { _ in availability.check() },
            now: { clock.read() })
        defer {
            availability.resumeCheck()
            narration.shutdown()
        }

        narration.update(
            current: [bulletin], newlyPublished: [bulletin], enabled: true,
            selectedVoice: .caseyKasem, accountIdentity: "test-owner", isEligible: { _ in true })

        let checkStarted = await availability.waitForCheck()
        XCTAssertTrue(checkStarted)
        let mainActorResponse = await Task { @MainActor in "responsive" }.value
        XCTAssertEqual(mainActorResponse, "responsive")
        clock.set(expiresAt.addingTimeInterval(1))
        availability.resumeCheck()

        let discarded = await WiltedMacHeadless.eventually("the expired headline is discarded") {
            narration.states[bulletin.id] == nil
        }
        XCTAssertTrue(discarded)
        let voices = await renderedVoices.values()
        XCTAssertTrue(voices.isEmpty, "an expired headline must not be rendered after the voice check")
    }
}

private actor NarrationAvailabilityVoiceCapture {
    private var rendered: [ApprovedReadingVoiceID] = []

    func record(_ voice: ApprovedReadingVoiceID) { rendered.append(voice) }
    func values() -> [ApprovedReadingVoiceID] { rendered }
}

/// Pauses the synthetic filesystem probe while the test exercises UI work on the main actor.
final class BlockingVoiceAvailability: @unchecked Sendable {
    private let lock = NSLock()
    private let resume = DispatchSemaphore(value: 0)
    private var startedOnMain: Bool?
    private var finished = false

    var ranOnMainThread: Bool { lock.withLock { startedOnMain == true } }
    var checkHasFinished: Bool { lock.withLock { finished } }

    func check() -> ArticleVoiceAvailability {
        lock.withLock { startedOnMain = Thread.isMainThread }
        _ = resume.wait(timeout: .now() + .seconds(5))
        lock.withLock { finished = true }
        return .available
    }

    func waitForCheck() async -> Bool {
        for _ in 0..<300 {
            if lock.withLock({ startedOnMain != nil }) { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return false
    }

    func resumeCheck() { resume.signal() }
}

private final class NarrationAvailabilityClock: @unchecked Sendable {
    private let lock = NSLock()
    private var date: Date

    init(_ date: Date) { self.date = date }

    func read() -> Date {
        lock.lock()
        defer { lock.unlock() }
        return date
    }

    func set(_ date: Date) {
        lock.lock()
        self.date = date
        lock.unlock()
    }
}
