import Foundation
import XCTest
import WiltedLibrary
import WiltedProducer
@testable import WiltedMac

@MainActor
final class WiltedMacHeadlineNarrationTests: XCTestCase {
    func testHubWiresPreparedAudioIntoItsDefaultHeadlineSpeaker() async throws {
        let library = try await AccountingLibrary.make(in: wiltedTemporaryDirectory("headline-speaker-wiring"))
        addTeardownBlock { await library.model.close() }
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let bulletin = try makeHeadline(id: "wired-story", title: "Council approves night service", now: now)
        let player = NarrationTestAudioPlayer()
        let narrator = WiltedMacHeadlineNarration(
            render: { _, voiceID, outputURL in
                try Data(repeating: 0x39, count: 128).write(to: outputURL)
                return ArticleNarrationAudio(
                    audioURL: outputURL, duration: 1,
                    voiceRevision: ArticleNarrationCoordinator.voiceRevision(for: voiceID))
            },
            availability: { _ in .available }, now: { now })
        defer { narrator.shutdown() }
        let hub = WiltedMacBulletinHub(
            model: library.model,
            makeHeadlineNarration: { narrator },
            makeHeadlineAudioPlayer: { player })

        narrator.update(current: [bulletin], newlyPublished: [bulletin], enabled: true,
                        selectedVoice: .paulHarvey, accountIdentity: nil, isEligible: { _ in true })
        for _ in 0..<100 where narrator.audioURL(for: bulletin, accountIdentity: nil) == nil {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertNotNil(narrator.audioURL(for: bulletin, accountIdentity: nil))

        let wiredSpeaker = hub.makeInterruptionSpeaker()
        XCTAssertTrue(wiredSpeaker.speak(bulletin, playbackVolume: 0.7, finished: {}))
        XCTAssertEqual(player.playCalls, 1)
        XCTAssertEqual(player.url, narrator.audioURL(for: bulletin, accountIdentity: nil))
        XCTAssertEqual(player.volume, BulletinSpeechGain.volume(forPlaybackVolume: 0.7))
        hub.shutdown()
    }

    func testFreshHeadlineWaitsForSelectedVoiceAndThenUsesItsExactAudio() async throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let bulletin = try makeHeadline(id: "story-1", title: "Council approves night service", now: now)
        let narrator = WiltedMacHeadlineNarration(
            render: { text, voiceID, outputURL in
                XCTAssertEqual(text, bulletin.text)
                XCTAssertEqual(voiceID, .caseyKasem)
                try Data(repeating: 0x2a, count: 100).write(to: outputURL)
                return ArticleNarrationAudio(
                    audioURL: outputURL, duration: 1,
                    voiceRevision: ArticleNarrationCoordinator.voiceRevision(for: voiceID))
            },
            availability: { _ in .available }, now: { now })
        defer { narrator.shutdown() }

        narrator.update(current: [bulletin], newlyPublished: [bulletin], enabled: true,
                        selectedVoice: nil, accountIdentity: "owner-a", isEligible: { _ in true })
        XCTAssertEqual(narrator.state(for: "story-1"), .chooseVoice(storyID: "story-1", bulletinID: bulletin.id))
        XCTAssertNil(narrator.audioURL(for: bulletin, accountIdentity: "owner-a"))

        narrator.update(current: [bulletin], newlyPublished: [], enabled: true,
                        selectedVoice: .caseyKasem, accountIdentity: "owner-a", isEligible: { _ in true })
        for _ in 0..<100 where narrator.audioURL(for: bulletin, accountIdentity: "owner-a") == nil {
            try await Task.sleep(for: .milliseconds(10))
        }
        guard case let .ready(storyID, bulletinID, voiceID, revision) = narrator.state(for: "story-1") else {
            return XCTFail("the rendered announcement should become ready")
        }
        XCTAssertEqual(storyID, "story-1")
        XCTAssertEqual(bulletinID, bulletin.id)
        XCTAssertEqual(voiceID, .caseyKasem)
        XCTAssertEqual(revision, ArticleNarrationCoordinator.voiceRevision(for: .caseyKasem))
        XCTAssertNotNil(narrator.audioURL(for: bulletin, accountIdentity: "owner-a"))
        XCTAssertNil(narrator.audioURL(for: bulletin, accountIdentity: "owner-b"))

        narrator.update(current: [], newlyPublished: [], enabled: true,
                        selectedVoice: .caseyKasem, accountIdentity: "owner-a", isEligible: { _ in true })
        XCTAssertNil(narrator.audioURL(for: bulletin, accountIdentity: "owner-a"))
        XCTAssertEqual(narrator.state(for: "story-1"), .notScheduled(storyID: "story-1"))
    }

    func testCancelledRenderCannotClearTheNewVoiceRender() async throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let first = try makeHeadline(id: "story-first", title: "Council approves night service", now: now)
        let second = try makeHeadline(
            id: "story-second", title: "Transit board meets today", now: now.addingTimeInterval(60))
        let gate = SuspendedHeadlineRenderGate()
        let narrator = WiltedMacHeadlineNarration(
            render: { _, voiceID, outputURL in
                try Data(repeating: 0x39, count: 128).write(to: outputURL)
                return try await gate.wait(voiceID: voiceID, outputURL: outputURL)
            },
            availability: { _ in .available }, now: { now })
        defer { narrator.shutdown() }

        narrator.update(current: [first], newlyPublished: [first], enabled: true,
                        selectedVoice: .caseyKasem, accountIdentity: "owner-a", isEligible: { _ in true })
        try await gate.waitForCount(1)
        narrator.update(current: [first, second], newlyPublished: [second], enabled: true,
                        selectedVoice: .caseyKasem, accountIdentity: "owner-a", isEligible: { _ in true })
        narrator.update(current: [first, second], newlyPublished: [], enabled: true,
                        selectedVoice: .paulHarvey, accountIdentity: "owner-a", isEligible: { _ in true })
        try await gate.waitForCount(2)
        await gate.resumeFirst()
        try await Task.sleep(for: .milliseconds(20))
        let pendingCount = await gate.count
        XCTAssertEqual(pendingCount, 1, "the next candidate must wait for the current voice render")
        guard case let .preparing(storyID, bulletinID, voiceID, _) = narrator.state(for: "story-first") else {
            return XCTFail("the current render should remain in flight")
        }
        XCTAssertEqual(storyID, "story-first")
        XCTAssertEqual(bulletinID, first.id)
        XCTAssertEqual(voiceID, .paulHarvey)
        await gate.resumeFirst()
        for _ in 0..<100 where narrator.audioURL(for: first, accountIdentity: "owner-a") == nil {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertNotNil(narrator.audioURL(for: first, accountIdentity: "owner-a"))
        try await gate.waitForCount(1)
        await gate.resumeFirst()
    }

    func testHeadlineWithoutPreparedAudioNeverFallsBackToSystemVoice() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let headline = try makeHeadline(id: "story-2", title: "Transit board meets today", now: now)
        let system = NarrationTestSpeaker()
        let audio = NarrationTestAudioPlayer()
        let speaker = WiltedMacHeadlineBulletinSpeaker(
            alertSpeaker: system, audioURL: { _ in nil }, audioPlayer: audio)

        XCTAssertFalse(speaker.speak(headline, playbackVolume: 0.8, finished: {}))
        XCTAssertFalse(speaker.speak(headline.text, playbackVolume: 0.8, finished: {}),
                       "untyped text cannot be routed to the system voice")
        XCTAssertEqual(system.bulletinCalls, 0)
        XCTAssertEqual(system.textCalls, 0)
        XCTAssertEqual(audio.playCalls, 0)
    }

    func testPreparedHeadlineUsesAttenuatedAudioAndAlertsStayOnSystemSpeaker() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let headline = try makeHeadline(id: "story-3", title: "Council approves night service", now: now)
        let alert = try Bulletin(
            id: "alert-1", kind: .alert, text: "A weather warning is active.", issuedAt: now,
            expiresAt: now.addingTimeInterval(3_600))
        let system = NarrationTestSpeaker()
        let audio = NarrationTestAudioPlayer()
        let url = URL(fileURLWithPath: "/private/tmp/prepared-headline.m4a")
        let speaker = WiltedMacHeadlineBulletinSpeaker(
            alertSpeaker: system, audioURL: { $0.id == headline.id ? url : nil }, audioPlayer: audio)

        XCTAssertTrue(speaker.speak(headline, playbackVolume: 0.8, finished: {}))
        XCTAssertEqual(audio.url, url)
        XCTAssertEqual(audio.volume, BulletinSpeechGain.volume(forPlaybackVolume: 0.8))
        XCTAssertEqual(system.bulletinCalls, 0)
        XCTAssertTrue(speaker.speak(alert, playbackVolume: 0.4, finished: {}))
        XCTAssertEqual(system.bulletinCalls, 1)
        XCTAssertEqual(audio.stopCalls, 1)
    }

    private func makeHeadline(id: String, title: String, now: Date) throws -> Bulletin {
        try Bulletin(id: "headline:\(id)", kind: .headline, text: "City Wire. \(title)",
                     issuedAt: now, expiresAt: now.addingTimeInterval(3_600), storyID: id,
                     publisherID: "wire", publisherName: "City Wire", headline: title,
                     link: URL(string: "https://wire.example.test/\(id)"), publishedAt: now)
    }
}

private actor SuspendedHeadlineRenderGate {
    private enum Timeout: Error { case waitingForRequest }
    private var requests: [(
        voiceID: ApprovedReadingVoiceID,
        outputURL: URL,
        continuation: CheckedContinuation<ArticleNarrationAudio, Error>
    )] = []

    var count: Int { requests.count }

    func wait(voiceID: ApprovedReadingVoiceID, outputURL: URL) async throws -> ArticleNarrationAudio {
        try await withCheckedThrowingContinuation { continuation in
            requests.append((voiceID, outputURL, continuation))
        }
    }

    func waitForCount(_ expected: Int) async throws {
        for _ in 0..<100 {
            if requests.count >= expected { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw Timeout.waitingForRequest
    }

    func resumeFirst() {
        guard !requests.isEmpty else { return }
        let request = requests.removeFirst()
        request.continuation.resume(returning: ArticleNarrationAudio(
            audioURL: request.outputURL, duration: 1,
            voiceRevision: ArticleNarrationCoordinator.voiceRevision(for: request.voiceID)))
    }
}

@MainActor
private final class NarrationTestSpeaker: BulletinSpeaking {
    private(set) var textCalls = 0
    private(set) var bulletinCalls = 0
    func speak(_ text: String, playbackVolume: Float, finished: @escaping @MainActor () -> Void) -> Bool {
        textCalls += 1
        return true
    }
    func speak(_ bulletin: Bulletin, playbackVolume: Float, finished: @escaping @MainActor () -> Void) -> Bool {
        bulletinCalls += 1
        return true
    }
    func stop() {}
}

@MainActor
private final class NarrationTestAudioPlayer: WiltedMacHeadlineAudioPlaying {
    private(set) var playCalls = 0
    private(set) var stopCalls = 0
    private(set) var url: URL?
    private(set) var volume: Float?
    func play(url: URL, volume: Float, finished: @escaping @MainActor () -> Void) -> Bool {
        playCalls += 1
        self.url = url
        self.volume = volume
        return true
    }
    func stop() { stopCalls += 1 }
}
