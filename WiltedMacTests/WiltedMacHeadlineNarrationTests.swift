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
                    voiceRevision: ArticleNarrationCoordinator.shortTextVoiceRevision(for: voiceID))
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
        XCTAssertEqual(player.volume, BulletinSpeechGain.measuredAudioVolume(forPlaybackVolume: 0.7))
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
                    voiceRevision: ArticleNarrationCoordinator.shortTextVoiceRevision(for: voiceID))
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
        XCTAssertEqual(revision, ArticleNarrationCoordinator.shortTextVoiceRevision(for: .caseyKasem))
        XCTAssertNotNil(narrator.audioURL(for: bulletin, accountIdentity: "owner-a"))
        XCTAssertNil(narrator.audioURL(for: bulletin, accountIdentity: "owner-b"))

        narrator.update(current: [], newlyPublished: [], enabled: true,
                        selectedVoice: .caseyKasem, accountIdentity: "owner-a", isEligible: { _ in true })
        XCTAssertNotNil(narrator.audioURL(for: bulletin, accountIdentity: "owner-a"),
                        "a channel refresh does not discard an eligible rendered bulletin")
        XCTAssertEqual(narrator.state(for: "story-1"),
                       .ready(storyID: "story-1", bulletinID: bulletin.id, voiceID: .caseyKasem,
                              voiceRevision: ArticleNarrationCoordinator.shortTextVoiceRevision(for: .caseyKasem)))
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

    func testMultipleHeadlinesStayReadyAcrossChannelRefreshesUntilSpoken() async throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let first = try makeHeadline(id: "batch-1", title: "Council approves night service", now: now)
        let second = try makeHeadline(id: "batch-2", title: "Transit board meets today", now: now.addingTimeInterval(10))
        let third = try makeHeadline(id: "batch-3", title: "New bridge opens Friday", now: now.addingTimeInterval(20))
        let fourth = try makeHeadline(id: "batch-4", title: "Library extends weekend hours", now: now.addingTimeInterval(30))
        var heardIDs = Set<String>()
        let rendered = WeatherRenderCapture()
        let narrator = WiltedMacHeadlineNarration(
            render: { text, voiceID, outputURL in
                await rendered.record(text)
                try Data(repeating: 0x39, count: 128).write(to: outputURL)
                return ArticleNarrationAudio(
                    audioURL: outputURL, duration: 1,
                    voiceRevision: ArticleNarrationCoordinator.shortTextVoiceRevision(for: voiceID))
            }, availability: { _ in .available }, now: { now })
        defer { narrator.shutdown() }
        let eligible: @MainActor (Bulletin) -> Bool = { !heardIDs.contains($0.id) }

        narrator.update(current: [first, second, third], newlyPublished: [first, second, third], enabled: true,
                        selectedVoice: .caseyKasem, accountIdentity: "owner-a", isEligible: eligible)
        for _ in 0..<100 where narrator.readyBulletins.count < 3 {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(narrator.readyBulletins.map(\.id), [first.id, second.id, third.id])

        narrator.update(current: [third, fourth], newlyPublished: [fourth], enabled: true,
                        selectedVoice: .caseyKasem, accountIdentity: "owner-a", isEligible: eligible)
        for _ in 0..<100 where narrator.readyBulletins.count < 4 {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(narrator.readyBulletins.map(\.id), [first.id, second.id, third.id, fourth.id],
                       "channel refreshes retain earlier still-eligible ready audio")

        narrator.didStart(first)
        heardIDs.insert(first.id)
        narrator.update(current: [first, fourth], newlyPublished: [first], enabled: true,
                        selectedVoice: .caseyKasem, accountIdentity: "owner-a", isEligible: eligible)
        XCTAssertNil(narrator.audioURL(for: first, accountIdentity: "owner-a"),
                     "a started headline cannot be queued again on a later refresh")
        XCTAssertEqual(narrator.readyBulletins.map(\.id), [second.id, third.id, fourth.id])
        let renderedTexts = await rendered.texts
        XCTAssertEqual(renderedTexts, [first.text, second.text, third.text, fourth.text])
    }

    func testUnpreparedBulletinsAndUntypedTextNeverFallBackToSystemVoice() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let headline = try makeHeadline(id: "story-2", title: "Transit board meets today", now: now)
        let alert = try makeAlert(id: "alert-unprepared", text: "A warning is active.", now: now)
        let audio = NarrationTestAudioPlayer()
        let speaker = WiltedMacHeadlineBulletinSpeaker(
            audioURL: { _ in nil }, audioPlayer: audio)

        XCTAssertFalse(speaker.speak(headline, playbackVolume: 0.8, finished: {}))
        XCTAssertFalse(speaker.speak(alert, playbackVolume: 0.8, finished: {}))
        XCTAssertFalse(speaker.speak("Untyped bulletin", playbackVolume: 0.8, finished: {}),
                       "untyped text without a selected voice cannot be spoken")
        XCTAssertEqual(audio.playCalls, 0)
    }

    func testWeatherAlertMustBePreparedBeforeTheSpeakerCanPlayIt() async throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let alert = try makeAlert(id: "alert-ready", text: "A weather warning is active.", now: now)
        let gate = SuspendedHeadlineRenderGate()
        let narration = WiltedMacWeatherAlertNarration(
            render: { _, voiceID, outputURL in
                try Data(repeating: 0x4b, count: 128).write(to: outputURL)
                return try await gate.wait(voiceID: voiceID, outputURL: outputURL)
            }, availability: { _ in .available }, now: { now })
        defer { narration.shutdown() }
        narration.update(current: [alert], enabled: true, selectedVoice: .caseyKasem)

        XCTAssertNil(narration.audioURL(for: alert))
        try await gate.waitForCount(1)
        XCTAssertTrue(narration.readyBulletins.isEmpty, "an alert is withheld while local audio renders")

        let audio = NarrationTestAudioPlayer()
        let speaker = WiltedMacHeadlineBulletinSpeaker(
            audioURL: { narration.audioURL(for: $0) }, audioPlayer: audio,
            selectedVoice: { .caseyKasem })
        XCTAssertFalse(speaker.speak(alert, playbackVolume: 0.4, finished: {}))

        await gate.resumeFirst()
        for _ in 0..<100 where narration.audioURL(for: alert) == nil {
            try await Task.sleep(for: .milliseconds(10))
        }
        let url = try XCTUnwrap(narration.audioURL(for: alert))

        XCTAssertTrue(speaker.speak(alert, playbackVolume: 0.4, finished: {}))
        XCTAssertEqual(audio.url, url)
        XCTAssertEqual(audio.volume, BulletinSpeechGain.measuredAudioVolume(forPlaybackVolume: 0.4))
    }

    func testWeatherAlertsArePreparedInSeverityOrderAndRenderFailuresAreNotReady() async throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let minor = try makeAlert(id: "alert-minor", text: "Minor alert", severity: .minor, now: now)
        let extreme = try makeAlert(id: "alert-extreme", text: "Extreme alert", severity: .extreme,
                                    now: now.addingTimeInterval(1))
        let rendered = WeatherRenderCapture()
        let narration = WiltedMacWeatherAlertNarration(
            render: { text, voiceID, outputURL in
                await rendered.record(text)
                try Data(repeating: 0x5c, count: 128).write(to: outputURL)
                return ArticleNarrationAudio(
                    audioURL: outputURL, duration: 1,
                    voiceRevision: ArticleNarrationCoordinator.shortTextVoiceRevision(for: voiceID))
            }, availability: { _ in .available }, now: { now })
        defer { narration.shutdown() }

        narration.update(current: [minor, extreme], enabled: true, selectedVoice: .wolfmanJack)
        for _ in 0..<100 where narration.readyBulletins.count < 2 {
            try await Task.sleep(for: .milliseconds(10))
        }
        let renderOrder = await rendered.texts
        XCTAssertEqual(renderOrder, [extreme.text, minor.text])
        XCTAssertEqual(narration.readyBulletins.map(\.id), [extreme.id, minor.id])

        let failed = try makeAlert(id: "alert-failed", text: "Cannot render", now: now)
        let invalid = WiltedMacWeatherAlertNarration(
            render: { _, voiceID, _ in
                ArticleNarrationAudio(
                    audioURL: URL(fileURLWithPath: "/private/tmp/not-the-requested-output.m4a"), duration: 1,
                    voiceRevision: ArticleNarrationCoordinator.shortTextVoiceRevision(for: voiceID))
            }, availability: { _ in .available }, now: { now })
        defer { invalid.shutdown() }
        invalid.update(current: [failed], enabled: true, selectedVoice: .caseyKasem)
        try await Task.sleep(for: .milliseconds(40))
        XCTAssertNil(invalid.audioURL(for: failed), "a wrong output path is not ready for delivery")
        XCTAssertTrue(invalid.readyBulletins.isEmpty)
    }

    func testExpiredWeatherAlertCancelsItsLocalRender() async throws {
        let alert = try makeAlert(id: "alert-expiring", text: "Expiring alert", expiresAfter: 0.12)
        let narration = WiltedMacWeatherAlertNarration(
            render: { text, voiceID, outputURL in
                try await Task.sleep(for: .seconds(2))
                try Data(repeating: 0x6d, count: 128).write(to: outputURL)
                return ArticleNarrationAudio(
                    audioURL: outputURL, duration: 1,
                    voiceRevision: ArticleNarrationCoordinator.shortTextVoiceRevision(for: voiceID))
            }, availability: { _ in .available })
        defer { narration.shutdown() }
        narration.update(current: [alert], enabled: true, selectedVoice: .caseyKasem)

        try await Task.sleep(for: .milliseconds(300))
        XCTAssertNil(narration.audioURL(for: alert))
        XCTAssertTrue(narration.readyBulletins.isEmpty)
    }

    func testSettingsTestBulletinUsesSelectedVoiceAndCompletesOnWrongOutput() async throws {
        let library = try await AccountingLibrary.make(in: wiltedTemporaryDirectory("local-test-bulletin"))
        addTeardownBlock { await library.model.close() }
        let player = NarrationTestAudioPlayer()
        let capture = WeatherRenderCapture()
        library.model.selectReadingVoice(ApprovedReadingVoiceID.paulHarvey.rawValue)
        let hub = WiltedMacBulletinHub(
            model: library.model, makeHeadlineAudioPlayer: { player },
            renderShortTextNarration: { text, voiceID, _ in
                await capture.record("\(voiceID.rawValue):\(text)")
                return ArticleNarrationAudio(
                    audioURL: URL(fileURLWithPath: "/private/tmp/wrong-test-bulletin-output.m4a"), duration: 1,
                    voiceRevision: ArticleNarrationCoordinator.shortTextVoiceRevision(for: voiceID))
            })
        defer { hub.shutdown() }

        XCTAssertTrue(hub.playTestBulletin())
        XCTAssertTrue(hub.testBulletinIsActive)
        for _ in 0..<100 where hub.testBulletinIsActive {
            try await Task.sleep(for: .milliseconds(10))
        }
        let calls = await capture.texts
        XCTAssertEqual(calls, ["\(ApprovedReadingVoiceID.paulHarvey.rawValue):\(WiltedMacBulletinHub.testBulletinText)"])
        XCTAssertFalse(hub.testBulletinIsActive, "an invalid local render completes and releases the Settings button")
        XCTAssertEqual(player.playCalls, 0)
    }

    func testSettingsTestBulletinCompletesWhenRenderedFileIsMissing() async throws {
        let library = try await AccountingLibrary.make(in: wiltedTemporaryDirectory("missing-test-bulletin"))
        addTeardownBlock { await library.model.close() }
        let player = NarrationTestAudioPlayer()
        library.model.selectReadingVoice(ApprovedReadingVoiceID.paulHarvey.rawValue)
        let hub = WiltedMacBulletinHub(
            model: library.model, makeHeadlineAudioPlayer: { player },
            renderShortTextNarration: { _, voiceID, outputURL in
                ArticleNarrationAudio(
                    audioURL: outputURL, duration: 1,
                    voiceRevision: ArticleNarrationCoordinator.shortTextVoiceRevision(for: voiceID))
            })
        defer { hub.shutdown() }

        XCTAssertTrue(hub.playTestBulletin())
        await WiltedMacHeadless.eventually("missing test-bulletin audio completes") { !hub.testBulletinIsActive }
        XCTAssertEqual(player.playCalls, 0)
    }

    private func makeHeadline(id: String, title: String, now: Date) throws -> Bulletin {
        try Bulletin(id: "headline:\(id)", kind: .headline, text: "City Wire. \(title)",
                     issuedAt: now, expiresAt: now.addingTimeInterval(3_600), storyID: id,
                     publisherID: "wire", publisherName: "City Wire", headline: title,
                     link: URL(string: "https://wire.example.test/\(id)"), publishedAt: now)
    }

    private func makeAlert(
        id: String, text: String, severity: BulletinSeverity = .extreme,
        now: Date = Date(timeIntervalSince1970: 1_800_000_000), expiresAfter: TimeInterval = 3_600
    ) throws -> Bulletin {
        try Bulletin(id: id, kind: .alert, text: text, severity: severity,
                     issuedAt: now, expiresAt: now.addingTimeInterval(expiresAfter))
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
            voiceRevision: ArticleNarrationCoordinator.shortTextVoiceRevision(for: request.voiceID)))
    }
}

private actor WeatherRenderCapture {
    private(set) var texts: [String] = []
    func record(_ text: String) { texts.append(text) }
}

@MainActor
private final class NarrationTestAudioPlayer: WiltedMacHeadlineAudioPlaying {
    private(set) var playCalls = 0
    private(set) var stopCalls = 0
    private(set) var url: URL?
    private(set) var volume: Float?
    private var completion: (@MainActor () -> Void)?
    func play(url: URL, volume: Float, finished: @escaping @MainActor () -> Void) -> Bool {
        playCalls += 1
        self.url = url
        self.volume = volume
        completion = finished
        return true
    }
    func stop() { stopCalls += 1; completion = nil }
    func finish() { let finished = completion; completion = nil; finished?() }
}
