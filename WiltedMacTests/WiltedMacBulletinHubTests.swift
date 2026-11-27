import Foundation
import XCTest
@testable import WiltedMac
import WiltedDomain
import WiltedLibrary
import WiltedProducer
@testable import WiltedWeather

@MainActor
final class HubFakeLocationManager: WiltedLocationManaging {
    var authorization: WiltedLocationAuthorization = .denied
    var onAuthorizationChange: (() -> Void)?
    var onFix: ((Double, Double) -> Void)?
    var onFailure: (() -> Void)?
    func requestPermission() {}
    func requestOneFix() {}
}

@MainActor
final class HubFakeWiFi: WiltedWiFiPowerReading {
    var isPoweredOn = true
}

/// A speaker that never makes a sound.
@MainActor
private final class HubSilentSpeaker: BulletinSpeaking {
    func speak(_ text: String, playbackVolume: Float, finished: @escaping @MainActor () -> Void) -> Bool { false }
    func stop() {}
}

@MainActor
private final class HubStartingSpeaker: BulletinSpeaking {
    private(set) var texts: [String] = []
    private(set) var bulletins: [Bulletin] = []
    private var completion: (@MainActor () -> Void)?

    func speak(_ text: String, playbackVolume: Float, finished: @escaping @MainActor () -> Void) -> Bool {
        texts.append(text)
        completion = finished
        return true
    }

    func speak(_ bulletin: Bulletin, playbackVolume: Float,
               finished: @escaping @MainActor () -> Void) -> Bool {
        guard bulletin.kind == .headline || bulletin.kind == .alert else { return false }
        bulletins.append(bulletin)
        return speak(bulletin.text, playbackVolume: playbackVolume, finished: finished)
    }

    func stop() { completion = nil }
    func finish() { completion?(); completion = nil }
}

@MainActor
private final class HubStableRoute: MacAudioRouteSource {
    func start(changed: @escaping @MainActor () -> Void) -> Bool { true }
    func currentRoute() -> MacAudioRoute? { MacAudioRoute(device: 1) }
    func stop() {}
}

/// Counts requests and fails each one, so a running monitor shows up as calls and a stopped one as none.
final class HubCountingSource: NWSAlertSource, @unchecked Sendable {
    struct Failure: Error {}
    private let lock = NSLock()
    private var value = 0
    private var response: NWSAlertsResponse?
    var calls: Int { lock.withLock { value } }

    func setResponse(_ response: NWSAlertsResponse) { lock.withLock { self.response = response } }

    func activeAlerts(lat: Double, lon: Double) async throws -> NWSAlertsResponse {
        let response = lock.withLock { () -> NWSAlertsResponse? in
            value += 1
            return self.response
        }
        if let response { return response }
        throw Failure()
    }
}

/// The hub that turns on spoken interruptions and runs the alert monitor, against a real
/// non-fixture model with scripted playback, a fake location and a source that counts calls.
@MainActor
final class WiltedMacBulletinHubTests: XCTestCase {
    private struct Rig {
        let library: AccountingLibrary
        let model: WiltedMacModel
        let hub: WiltedMacBulletinHub
        let source: HubCountingSource
    }

    private func makeRig(
        speaker: any BulletinSpeaking = HubSilentSpeaker(),
        narration: WiltedMacHeadlineNarration? = nil,
        weatherNarration: WiltedMacWeatherAlertNarration? = nil
    ) async throws -> Rig {
        let library = try await AccountingLibrary.make(in: wiltedTemporaryDirectory("bulletin-hub"))
        let model = library.model
        _ = library.installScriptedPlayback(on: model)
        let source = HubCountingSource()
        let producerHarness = BulletinProducerHarness()
        let provider = WiltedLocationProvider(manager: HubFakeLocationManager(), wifi: HubFakeWiFi())
        let hub = WiltedMacBulletinHub(
            model: model, location: provider, makeSpeaker: { speaker },
            makeRouteSource: { HubStableRoute() }, makeAlertSource: { _ in source },
            producerFactory: { producerHarness.producer() },
            makeHeadlineNarration: { narration ?? WiltedMacHeadlineNarration() },
            makeWeatherAlertNarration: { weatherNarration ?? WiltedMacWeatherAlertNarration() })
        model.installBulletinHubForTesting(hub)
        if narration != nil || weatherNarration != nil {
            model.selectReadingVoice(ApprovedReadingVoiceID.caseyKasem.rawValue)
        }
        return Rig(library: library, model: model, hub: hub, source: source)
    }

    private func set(_ model: WiltedMacModel, interruptions: Bool, alerts: Bool = true) {
        model.updateAutomationSettings { current in
            current.updatingReports {
                $0.interruptionsEnabled = interruptions
                $0.alertsEnabled = alerts
                $0.typedLatitude = 38.9
                $0.typedLongitude = -77.0
            }
        }
    }

    func testInterruptionsOffAttachNothingAndStartNoMonitor() async throws {
        let rig = try await makeRig()
        rig.model.playEpisode(rig.library.episodes[0])
        await rig.model.waitForPlaybackOperationForTesting()
        rig.hub.reconcile()
        XCTAssertTrue(rig.model.isPlaying)
        XCTAssertFalse(rig.hub.interruptionsAreAttached)
        XCTAssertFalse(rig.hub.alertMonitorIsRunning)
        XCTAssertEqual(rig.source.calls, 0)
    }

    func testAlertMonitorRunsOnlyWhilePlayingWithAlertsOnAndStopsWhenPaused() async throws {
        let rig = try await makeRig()
        set(rig.model, interruptions: true)
        XCTAssertTrue(rig.hub.interruptionsAreAttached, "turning interruptions on attaches the player")
        XCTAssertFalse(rig.model.isPlaying)
        XCTAssertFalse(rig.hub.alertMonitorIsRunning, "no monitor while paused")
        XCTAssertEqual(rig.source.calls, 0, "no request while paused")

        rig.model.playEpisode(rig.library.episodes[0])
        await rig.model.waitForPlaybackOperationForTesting()
        await WiltedMacHeadless.eventually("the monitor starts once playing") { rig.hub.alertMonitorIsRunning }
        await WiltedMacHeadless.eventually("the monitor asks for alerts at the Mac's location") { rig.source.calls > 0 }
        XCTAssertFalse(rig.hub.readiness.lines.contains(.weather),
                       "saved coordinates work even though the system location permission is denied")
        XCTAssertFalse(rig.hub.readiness.lines.contains(.locationDenied))

        rig.model.pausePlayback()
        await rig.model.waitForPlaybackOperationForTesting()
        await WiltedMacHeadless.eventually("the monitor stops when paused") { !rig.hub.alertMonitorIsRunning }
        XCTAssertTrue(rig.hub.interruptionsAreAttached, "the player stays attached while paused")
        set(rig.model, interruptions: false)
    }

    func testTurningAlertsOffStopsTheMonitorAndTurningInterruptionsOffDetaches() async throws {
        let rig = try await makeRig()
        set(rig.model, interruptions: true)
        rig.model.playEpisode(rig.library.episodes[0])
        await rig.model.waitForPlaybackOperationForTesting()
        await WiltedMacHeadless.eventually("the monitor starts") { rig.hub.alertMonitorIsRunning }

        set(rig.model, interruptions: true, alerts: false)
        XCTAssertFalse(rig.hub.alertMonitorIsRunning, "alerts off stops the monitor")
        XCTAssertTrue(rig.hub.interruptionsAreAttached, "headlines still speak")

        set(rig.model, interruptions: true, alerts: true)
        await WiltedMacHeadless.eventually("alerts on again restarts it") { rig.hub.alertMonitorIsRunning }

        set(rig.model, interruptions: false)
        XCTAssertFalse(rig.hub.interruptionsAreAttached)
        XCTAssertFalse(rig.hub.alertMonitorIsRunning)
        XCTAssertFalse(rig.model.playback?.interruptionsEnabled ?? true)
    }

    func testWeatherAlertIsPreRenderedBeforeBecomingAvailableToPlayback() async throws {
        let gate = HubWeatherRenderGate()
        let narration = WiltedMacWeatherAlertNarration(
            render: { _, voiceID, outputURL in
                try Data(repeating: 0x58, count: 128).write(to: outputURL)
                return try await gate.wait(voiceID: voiceID, outputURL: outputURL)
            }, availability: { _ in .available })
        defer { narration.shutdown() }
        let speaker = HubStartingSpeaker()
        let rig = try await makeRig(speaker: speaker, weatherNarration: narration)
        rig.model.selectHeadlineVoice(.paulHarvey)
        rig.model.selectWeatherVoice(.wolfmanJack)
        let now = Date()
        let issuedAlert = NWSAlert(
            id: "local-weather-ready", event: "Special Marine Warning", areaDesc: "Hawk Channel",
            severity: "Severe", urgency: "Immediate", certainty: "Likely",
            description: "Conditions over the water are dangerous.",
            instruction: "Stay low or go below, and make sure everyone is wearing life jackets.",
            sent: now, effective: now, onset: now, expires: now.addingTimeInterval(3_600),
            ends: now.addingTimeInterval(3_600))
        rig.source.setResponse(NWSAlertsResponse(alerts: [issuedAlert], pollInterval: 3_600))
        set(rig.model, interruptions: true)
        rig.model.playEpisode(rig.library.episodes[0])
        await rig.model.waitForPlaybackOperationForTesting()
        await WiltedMacHeadless.eventually("the alert monitor starts") { rig.hub.alertMonitorIsRunning }

        let alert = try XCTUnwrap(AlertMonitor.bulletin(for: issuedAlert, now: now))
        try await gate.waitForCount(1)
        let renderVoices = await gate.voices()
        XCTAssertEqual(renderVoices, [.wolfmanJack], "weather uses its independent voice setting")
        XCTAssertTrue(speaker.bulletins.isEmpty, "the player cannot receive an unprepared weather alert")
        XCTAssertNil(rig.model.speakingBulletin)

        await gate.resumeFirst()
        await WiltedMacHeadless.eventually("weather audio finishes local rendering") {
            narration.readyBulletins.contains(where: { $0.id == alert.id })
        }
        XCTAssertTrue(speaker.bulletins.isEmpty, "the hub waits for an actual ad-break signal")
        XCTAssertNil(rig.model.speakingBulletin)
        XCTAssertTrue(rig.model.playback?.adBreakReached() == true,
                      "a ready weather alert starts at the next ad-break snapshot")
        XCTAssertEqual(speaker.bulletins.map(\.id), [alert.id])

        let spokenAlert = try XCTUnwrap(speaker.bulletins.last)
        XCTAssertEqual(rig.hub.lastSpokenWeatherAlert, spokenAlert,
                       "only a bulletin accepted by the speaker is retained")
        speaker.finish()
        await WiltedMacHeadless.eventually("the transient player alert clears after speech") {
            rig.model.speakingBulletin == nil
        }
        XCTAssertNil(rig.model.speakingBulletin, "the player banner remains transient")
        XCTAssertEqual(rig.hub.lastSpokenWeatherAlert, spokenAlert,
                       "Reports can reopen the original after speech completes")
        let reports = WiltedMacReportsCard(
            model: rig.model, location: rig.hub.location, startsExpanded: true)
        let reportText = try WiltedMacHeadless.recognizedText(
            reports, size: CGSize(width: 1_000, height: 1_400)).joined(separator: " ")
        XCTAssertTrue(reportText.contains("Last weather alert"), reportText)
        let original = try WiltedMacHeadless.recognizedText(
            WiltedMacLastWeatherAlertDetails(bulletin: spokenAlert),
            size: CGSize(width: 620, height: 560)).joined(separator: " ")
        XCTAssertTrue(original.contains("Stay low or go below"), original)
        XCTAssertTrue(original.contains("Affected areas: Hawk Channel"), original)
        set(rig.model, interruptions: false)
    }

    func testTurningWeatherOffDiscardsACompletedLateRender() async throws {
        let gate = HubWeatherRenderGate()
        let narration = WiltedMacWeatherAlertNarration(
            render: { _, voiceID, outputURL in
                try Data(repeating: 0x59, count: 128).write(to: outputURL)
                return try await gate.wait(voiceID: voiceID, outputURL: outputURL)
            }, availability: { _ in .available })
        defer { narration.shutdown() }
        let speaker = HubStartingSpeaker()
        let rig = try await makeRig(speaker: speaker, weatherNarration: narration)
        set(rig.model, interruptions: true)
        rig.model.playEpisode(rig.library.episodes[0])
        await rig.model.waitForPlaybackOperationForTesting()
        await WiltedMacHeadless.eventually("the alert monitor starts") { rig.hub.alertMonitorIsRunning }

        let now = Date()
        let alert = try Bulletin(
            id: "local-weather-off", kind: .alert, text: "A severe weather warning is active.",
            severity: .extreme, issuedAt: now, expiresAt: now.addingTimeInterval(3_600))
        rig.hub.receive(alert: alert)
        try await gate.waitForCount(1)
        set(rig.model, interruptions: true, alerts: false)
        XCTAssertFalse(rig.hub.alertMonitorIsRunning)
        await gate.resumeFirst()
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertTrue(speaker.bulletins.isEmpty, "an alert rendered after alerts were turned off is discarded")
        XCTAssertTrue(narration.readyBulletins.isEmpty)
        set(rig.model, interruptions: false)
    }

    func testWeatherRenderFailureNeverReachesThePlayerQueue() async throws {
        let rendered = HubWeatherRenderSignal()
        let narration = WiltedMacWeatherAlertNarration(
            render: { _, voiceID, _ in
                await rendered.record()
                return ArticleNarrationAudio(
                    audioURL: URL(fileURLWithPath: "/private/tmp/not-the-requested-alert.m4a"), duration: 1,
                    voiceRevision: ArticleNarrationCoordinator.shortTextVoiceRevision(for: voiceID))
            }, availability: { _ in .available })
        defer { narration.shutdown() }
        let speaker = HubStartingSpeaker()
        let rig = try await makeRig(speaker: speaker, weatherNarration: narration)
        let now = Date()
        let issuedAlert = NWSAlert(
            id: "local-weather-failed", event: "Severe Weather Warning", areaDesc: "Washington",
            severity: "Extreme", headline: "A severe weather warning is active.",
            sent: now, expires: now.addingTimeInterval(3_600))
        rig.source.setResponse(NWSAlertsResponse(alerts: [issuedAlert], pollInterval: 3_600))
        set(rig.model, interruptions: true)
        rig.model.playEpisode(rig.library.episodes[0])
        await rig.model.waitForPlaybackOperationForTesting()
        await WiltedMacHeadless.eventually("the alert monitor starts") { rig.hub.alertMonitorIsRunning }
        try await rendered.waitForCall()

        XCTAssertTrue(narration.readyBulletins.isEmpty, "a failed local render is never a ready bulletin")
        XCTAssertFalse(rig.model.playback?.adBreakReached() ?? true,
                       "the reducer has no alert to mark spoken at this ad break")
        XCTAssertTrue(speaker.bulletins.isEmpty)
        XCTAssertNil(rig.model.speakingBulletin)
        set(rig.model, interruptions: false)
    }

    func testLegacyHeadlineBulletinIDStillBecomesTheFeaturedStory() async throws {
        let speaker = HubStartingSpeaker()
        let now = Date()
        let renderedVoices = HubVoiceRenderCapture()
        let narrator = WiltedMacHeadlineNarration(
            render: { _, voiceID, outputURL in
                await renderedVoices.record(voiceID)
                try Data(repeating: 0x39, count: 128).write(to: outputURL)
                return ArticleNarrationAudio(
                    audioURL: outputURL, duration: 1,
                    voiceRevision: ArticleNarrationCoordinator.shortTextVoiceRevision(for: voiceID))
            },
            availability: { _ in .available }, now: { now })
        defer { narrator.shutdown() }
        let rig = try await makeRig(speaker: speaker, narration: narrator)
        rig.model.selectHeadlineVoice(.wolfmanJack)
        set(rig.model, interruptions: true)
        rig.model.updateAutomationSettings { settings in
            settings.updatingReports { $0.headlinesEnabled = true }
        }
        rig.model.playEpisode(rig.library.episodes[0])
        await rig.model.waitForPlaybackOperationForTesting()
        rig.hub.reconcile()
        XCTAssertTrue(rig.hub.interruptionsAreAttached)

        let emptyChannel = try LibraryBulletins(alertsEnabled: false, headlinesEnabled: true, updatedAt: now)
        rig.hub.channelUpdated(emptyChannel)
        let unlinked = try Bulletin(
            id: "headline:unlinked-legacy", kind: .headline, text: "Example News. Unlinked legacy story",
            severity: .extreme,
            issuedAt: now, expiresAt: now.addingTimeInterval(3_600))
        rig.hub.channelUpdated(try LibraryBulletins(
            alertsEnabled: false, headlinesEnabled: true, headlines: [unlinked], updatedAt: now))
        XCTAssertTrue(speaker.texts.isEmpty, "an untyped legacy row cannot bypass production eligibility")
        XCTAssertNil(rig.hub.featuredHeadlineStoryID)

        let story = try LibraryHeadlineStory(
            id: "legacy-story", title: "Legacy story", publisherID: "example-news",
            publisherName: "Example News", link: URL(string: "https://example-news.example.test/legacy-story"),
            publishedAt: now, firstSeenAt: now, lastSeenAt: now)
        _ = try rig.model.headlineCatalogStore.mergeRecent([story], at: now)
        rig.model.headlineCatalogState.refresh(at: now)
        let legacy = try Bulletin(
            id: "headline:legacy-story", kind: .headline, text: "Example News. Legacy story", severity: .extreme,
            issuedAt: now, expiresAt: now.addingTimeInterval(3_600), storyID: story.id,
            publisherID: story.publisherID, publisherName: story.publisherName, headline: story.title,
            link: story.link, publishedAt: story.publishedAt)
        rig.hub.channelUpdated(try LibraryBulletins(
            alertsEnabled: false, headlinesEnabled: true, headlines: [legacy], updatedAt: now))
        await WiltedMacHeadless.eventually("the eligible story is ready") {
            narrator.readyBulletins.contains(where: { $0.id == legacy.id })
        }
        let voiceCalls = await renderedVoices.values()
        XCTAssertEqual(voiceCalls, [.wolfmanJack], "headlines use their own voice setting")
        XCTAssertTrue(speaker.texts.isEmpty, "a ready headline waits for an ad-break snapshot")
        XCTAssertTrue(rig.model.playback?.adBreakReached() == true)
        await WiltedMacHeadless.eventually("the eligible story is spoken and featured") {
            speaker.texts == [legacy.text] && rig.hub.featuredHeadlineStoryID == story.id
        }

        XCTAssertEqual(speaker.texts, [legacy.text])
        XCTAssertEqual(rig.hub.featuredHeadlineStoryID, "legacy-story")
        speaker.finish()
    }

    func testAMorningReportShowsUnderAllOnlyInTheLarderKindFilter() {
        var report = WiltedMacEpisode(
            id: "report-1", title: "Morning report", feedTitle: "Morning report", summary: "",
            artworkURL: nil, releasedAt: Date(timeIntervalSince1970: 1_700_000_900), durationSeconds: 360,
            playbackSeconds: 0, downloadState: .completed, preparationState: .prepared(summary: "Report"))
        report.audiobook = WiltedMacAudiobookDetails(
            author: nil, chapters: [], sourceFormat: "report", volumeIndex: 0, volumeCount: 1)
        XCTAssertTrue(report.isReport)
        XCTAssertTrue(WiltedMacLarderKind.all.includes(report))
        XCTAssertFalse(WiltedMacLarderKind.podcasts.includes(report))
        XCTAssertFalse(WiltedMacLarderKind.audiobooks.includes(report))
        XCTAssertFalse(WiltedMacLarderKind.articles.includes(report))
        var book = report
        book.audiobook?.sourceFormat = "audio"
        XCTAssertTrue(WiltedMacLarderKind.audiobooks.includes(book), "a real book still shows under Audiobooks")
    }
}

private actor HubVoiceRenderCapture {
    private var rendered: [ApprovedReadingVoiceID] = []

    func record(_ voice: ApprovedReadingVoiceID) { rendered.append(voice) }
    func values() -> [ApprovedReadingVoiceID] { rendered }
}

private actor HubWeatherRenderGate {
    private enum Timeout: Error { case waitingForRequest }
    private var requests: [(
        voiceID: ApprovedReadingVoiceID,
        outputURL: URL,
        continuation: CheckedContinuation<ArticleNarrationAudio, Error>
    )] = []
    private var renderedVoices: [ApprovedReadingVoiceID] = []
    var count: Int { requests.count }

    func wait(voiceID: ApprovedReadingVoiceID, outputURL: URL) async throws -> ArticleNarrationAudio {
        try await withCheckedThrowingContinuation { continuation in
            renderedVoices.append(voiceID)
            requests.append((voiceID, outputURL, continuation))
        }
    }

    func voices() -> [ApprovedReadingVoiceID] { renderedVoices }

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

private actor HubWeatherRenderSignal {
    private enum Timeout: Error { case waitingForRender }
    private var calls = 0

    func record() { calls += 1 }

    func waitForCall() async throws {
        for _ in 0..<100 {
            if calls > 0 { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw Timeout.waitingForRender
    }
}
