import CryptoKit
import Foundation
import WiltedDomain
import WiltedLibrary
import WiltedPlayback
import XCTest
@testable import WiltediOS

// MARK: - Doubles (internal so Settings tests can reuse the rig)

final class InterruptionEngine: ListenerAudioEngine, LibraryRateAdjustable, @unchecked Sendable {
    private let lock = NSLock()
    private var _time = 0.0
    private var _playing = false
    var duration = 600.0
    var rate: Float = 1
    var currentTime: Double {
        get { lock.withLock { _time } }
        set { lock.withLock { _time = newValue } }
    }
    var isPlaying: Bool {
        get { lock.withLock { _playing } }
        set { lock.withLock { _playing = newValue } }
    }
    func load(url: URL) throws {}
    func load(url: URL, completionGeneration: UInt64) throws { currentTime = 0 }
    func play() -> Bool { isPlaying = true; return true }
    func pause() { isPlaying = false }
    func installCompletionHandler(_ handler: @escaping @Sendable (UInt64) -> Void) {}
}

final class InterruptionSession: ListenerAudioSession, @unchecked Sendable {
    private(set) var activations = 0
    private(set) var deactivations = 0
    func activate() throws { activations += 1 }
    func deactivate() { deactivations += 1 }
}

final class InterruptionNowPlaying: ListenerNowPlaying, @unchecked Sendable {
    private(set) var infos: [ListenerNowPlayingInfo] = []
    func update(title: String, duration: Double, position: Double, rate: Double) {}
    func update(_ info: ListenerNowPlayingInfo) { infos.append(info) }
    func clear() {}
}

@MainActor final class InterruptionRemote: LibraryRemoteCommands {
    private(set) var handler: (@MainActor (LibraryRemoteCommand) -> Bool)?
    func install(handler: @escaping @MainActor (LibraryRemoteCommand) -> Bool) { self.handler = handler }
}

@MainActor final class InterruptionEvents: LibrarySessionEvents {
    private var handler: (@MainActor (LibrarySessionEvent) -> Void)?
    func observe(_ handler: @escaping @MainActor (LibrarySessionEvent) -> Void) { self.handler = handler }
    func send(_ event: LibrarySessionEvent) { handler?(event) }
}

/// Never speaks: records what it was asked and finishes only when a test says so.
@MainActor final class StubSpeaker: LibrarySpeaking {
    var canStart = true
    var canSpeakBulletins = true
    var expectedPlaybackDuration: TimeInterval?
    private(set) var spoken: [String] = []
    private(set) var spokenBulletins: [Bulletin] = []
    private(set) var preparedBulletins: [Bulletin] = []
    private(set) var preparedAudioRefreshes = 0
    private(set) var stops = 0
    var bulletinAudioIssueMessage: String?
    private(set) var bulletinAudioRetries: [Bulletin] = []
    private var finish: (@MainActor () -> Void)?

    func prepare(_ bulletin: Bulletin) { preparedBulletins.append(bulletin) }
    func refreshPreparedAudio() async { preparedAudioRefreshes += 1 }
    func bulletinAudioIssue(for bulletin: Bulletin) -> String? { bulletinAudioIssueMessage }
    func retryBulletinAudio(_ bulletin: Bulletin) {
        bulletinAudioRetries.append(bulletin)
        bulletinAudioIssueMessage = nil
    }
    func canSpeak(_ bulletin: Bulletin) -> Bool { canSpeakBulletins }

    func speak(_ bulletin: Bulletin, onFinish: @escaping @MainActor () -> Void) -> Bool {
        spokenBulletins.append(bulletin)
        return speak(bulletin.text, onFinish: onFinish)
    }

    func speak(_ text: String, onFinish: @escaping @MainActor () -> Void) -> Bool {
        guard canStart else { return false }
        spoken.append(text)
        finish = onFinish
        return true
    }
    func stop() { stops += 1; finish = nil }
    func completeSpeech() { let callback = finish; finish = nil; callback?() }
}

final class StubMonitor: LibraryAlertMonitoring, @unchecked Sendable {
    private let lock = NSLock()
    private var _events: [String] = []
    var events: [String] { lock.withLock { _events } }
    func record(_ event: String) { lock.withLock { _events.append(event) } }
    func start() async { record("start") }
    func stop() async { record("stop") }
    func setCoordinates(lat: Double, lon: Double) async { record("coords \(lat),\(lon)") }
    func clearCoordinates() async { record("clear") }
    var activeAlertIDs: Set<String> { [] }
}

actor InterruptionWatchdogRecorder {
    private var durations: [Duration] = []
    func record(_ duration: Duration) { durations.append(duration) }
    func first() -> Duration? { durations.first }
}

@MainActor final class InterruptionLocationManager: LibraryLocationManaging {
    var authorization: LibraryLocationAuthorization = .authorized
    var onAuthorizationChange: (() -> Void)?
    var onFix: ((Double, Double, Date) -> Void)?
    var onFailure: (() -> Void)?
    private(set) var fixRequests = 0
    func requestWhenInUseAuthorization() {}
    func requestOneShotFix() { fixRequests += 1 }
}

func interruptionBulletin(_ id: String = "headline-1", kind: BulletinKind = .headline) -> Bulletin {
    try! Bulletin(
        id: id, kind: kind, text: "Spoken text for \(id).", severity: .extreme,
        issuedAt: Date(timeIntervalSinceNow: -60), expiresAt: Date(timeIntervalSinceNow: 3600))
}

// MARK: - Rig

@MainActor
struct InterruptionRig {
    let player: LibraryPlayer
    let engine: InterruptionEngine
    let session: InterruptionSession
    let nowPlaying: InterruptionNowPlaying
    let remote: InterruptionRemote
    let events: InterruptionEvents
    let speaker: StubSpeaker
    let previewSpeaker: StubSpeaker
    let playingPreviewSpeaker: StubSpeaker
    let controller: LibraryInterruptionController
    let location: InterruptionLocationManager
    let monitor: StubMonitor
    let monitorsMade: () -> Int
    let adBreakSeams: () -> [Double]
    let item = LibraryPlayer.Item(
        entryID: try! ItemID(rawValue: "entry-1"), title: "Episode One", showTitle: "Show",
        fileURL: URL(fileURLWithPath: "/nonexistent/interruption-test.mp3"))

    /// Starts `item` at `position` and waits until the controller knows its revision.
    func play(at position: Double = 42) async {
        XCTAssertTrue(player.start(item, at: position))
        for _ in 0..<200 where !controller.hasRevision { try? await Task.sleep(for: .milliseconds(5)) }
        XCTAssertTrue(controller.hasRevision)
        player.position = position
    }

    func crossAdBreak(to position: Double? = nil) {
        let target = position ?? ((adBreakSeams().first { $0 > player.position } ?? player.position) + 0.25)
        engine.currentTime = target
        player.position = target
    }
}

@MainActor
func makeInterruptionRig(
    channel: LibraryBulletins?, defaults: UserDefaults, tick: Duration = .seconds(3600),
    foreground: Bool = true,
    speaker suppliedSpeaker: StubSpeaker? = nil,
    adBreakSeams seams: [Double] = [42.5],
    adBreakSeamProvider: (() -> [Double])? = nil,
    sleep: @escaping @Sendable (Duration) async throws -> Void = { _ in
        try await Task.sleep(for: .seconds(3600))
    }
) -> InterruptionRig {
    let engine = InterruptionEngine(), session = InterruptionSession(), nowPlaying = InterruptionNowPlaying()
    let remote = InterruptionRemote(), events = InterruptionEvents(), speaker = suppliedSpeaker ?? StubSpeaker()
    let previewSpeaker = StubSpeaker(), playingPreviewSpeaker = StubSpeaker()
    let player = LibraryPlayer(
        engine: engine, session: session, nowPlaying: nowPlaying, remoteCommands: remote,
        sessionEvents: events, tickInterval: tick)
    let location = InterruptionLocationManager()
    let monitor = StubMonitor()
    var made = 0
    let revision = try! RevisionID(rawValue: "rev-1")
    let adBreakSeams = { adBreakSeamProvider?() ?? seams }
    let controller = LibraryInterruptionController(
        player: player,
        dependencies: .init(
            speaker: speaker, previewSpeaker: previewSpeaker, playingPreviewSpeaker: playingPreviewSpeaker,
            preferences: LibraryInterruptionPreferences(defaults: defaults),
            fetchBulletins: { channel },
            makeMonitor: { _ in made += 1; return monitor },
            location: LibraryLocationProvider(manager: location),
            adBreakSeams: { _, _ in adBreakSeams() },
            revision: { _ in revision },
            isForeground: { foreground }, sleep: sleep))
    return InterruptionRig(
        player: player, engine: engine, session: session, nowPlaying: nowPlaying, remote: remote, events: events,
        speaker: speaker, previewSpeaker: previewSpeaker, playingPreviewSpeaker: playingPreviewSpeaker,
        controller: controller, location: location, monitor: monitor, monitorsMade: { made },
        adBreakSeams: adBreakSeams)
}

func headlineChannel(alerts: Bool = false) -> LibraryBulletins {
    try! LibraryBulletins(alertsEnabled: alerts, headlinesEnabled: true, headlines: [interruptionBulletin()])
}

// MARK: - Tests

@MainActor
final class LibraryPlayerInterruptionTests: XCTestCase {
    private let suite = "library-interruption-tests"
    private var defaults: UserDefaults!

    override func setUp() async throws {
        defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
    }

    override func tearDown() async throws { defaults.removePersistentDomain(forName: suite) }

    func testHeadlineAndExtremeAlertWaitForPreparedAdBreakWithoutTranscriptCues() async {
        let rig = makeInterruptionRig(channel: headlineChannel(alerts: true), defaults: defaults)
        await rig.play(at: 42)
        await rig.controller.syncTick()
        XCTAssertEqual(rig.speaker.preparedAudioRefreshes, 1)
        XCTAssertEqual(rig.speaker.preparedBulletins.map(\.id), ["headline-1"])
        let urgentAlert = try! Bulletin(
            id: "alert-urgent", kind: .alert, text: "Spoken text for alert-urgent.", severity: .extreme,
            issuedAt: Date(timeIntervalSinceNow: -600), expiresAt: Date(timeIntervalSinceNow: 3_600))
        rig.controller.alertArrived(urgentAlert)
        XCTAssertEqual(rig.speaker.preparedBulletins.map(\.id), ["headline-1", "alert-urgent"])

        XCTAssertTrue(rig.speaker.spoken.isEmpty, "channel arrival and extreme severity never interrupt playback")
        XCTAssertTrue(rig.engine.isPlaying)
        rig.crossAdBreak()

        XCTAssertEqual(rig.speaker.spoken, ["Spoken text for alert-urgent."])
        XCTAssertTrue(rig.player.isHoldingForSpeech)
        rig.speaker.completeSpeech()
        XCTAssertEqual(rig.speaker.spoken, ["Spoken text for alert-urgent.", "Spoken text for headline-1."])
    }

    func testSeekingAcrossAnAdSeamDoesNotTriggerSpeechOrConsumeThatSeam() async {
        let rig = makeInterruptionRig(
            channel: headlineChannel(), defaults: defaults, adBreakSeams: [42.5, 80])
        await rig.play(at: 42)
        await rig.controller.syncTick()
        rig.player.skipForward()
        XCTAssertEqual(rig.player.position, 72)
        XCTAssertTrue(rig.speaker.spoken.isEmpty, "a seek across a prepared cut is not an ad-break arrival")

        rig.crossAdBreak(to: 79.5)
        XCTAssertTrue(rig.speaker.spoken.isEmpty)
        rig.crossAdBreak(to: 80.25)
        XCTAssertEqual(rig.speaker.spoken, ["Spoken text for headline-1."])
    }

    func testZeroSecondAdSeamRequiresInitialForwardPlaybackAndIsNotReplayedAfterResumeOrSeek() async {
        let rig = makeInterruptionRig(channel: headlineChannel(), defaults: defaults, adBreakSeams: [0])
        await rig.play(at: 0)
        await rig.controller.syncTick()
        XCTAssertTrue(rig.speaker.spoken.isEmpty, "opening at zero does not start a batch")

        rig.crossAdBreak(to: 0.25)
        XCTAssertEqual(rig.speaker.spoken, ["Spoken text for headline-1."],
                       "continuous forward playback from the actual start crosses the zero seam")
        rig.speaker.completeSpeech()

        rig.player.pause()
        XCTAssertTrue(rig.player.play())
        rig.crossAdBreak(to: 0.5)
        XCTAssertEqual(rig.speaker.spoken.count, 1, "resuming does not replay a start seam")

        rig.player.seek(to: 0)
        rig.crossAdBreak(to: 0.25)
        XCTAssertEqual(rig.speaker.spoken.count, 1, "seeking back to zero does not replay a start seam")
    }

    func testZeroSecondAdSeamLoadedAfterPlaybackPassedItDoesNotTriggerLate() async {
        var preparedSeams: [Double] = []
        let rig = makeInterruptionRig(
            channel: headlineChannel(), defaults: defaults, adBreakSeams: [],
            adBreakSeamProvider: { preparedSeams })
        await rig.play(at: 0)
        await rig.controller.syncTick()
        rig.crossAdBreak(to: 0.25)
        preparedSeams = [0]
        rig.crossAdBreak(to: 0.5)

        XCTAssertTrue(rig.speaker.spoken.isEmpty, "a late transcript load does not announce a passed cut")
    }

    func testBulletinsArrivingDuringABatchWaitForTheFollowingAdBreak() async {
        let rig = makeInterruptionRig(
            channel: headlineChannel(alerts: true), defaults: defaults, adBreakSeams: [42.5, 80])
        await rig.play(at: 42)
        await rig.controller.syncTick()
        rig.crossAdBreak()
        XCTAssertEqual(rig.speaker.spoken, ["Spoken text for headline-1."])

        rig.controller.alertArrived(interruptionBulletin("alert-1", kind: .alert))
        rig.speaker.completeSpeech()
        XCTAssertEqual(rig.speaker.spoken, ["Spoken text for headline-1."])
        XCTAssertFalse(rig.player.isHoldingForSpeech)

        rig.crossAdBreak(to: 79.5)
        rig.crossAdBreak(to: 80.25)
        XCTAssertEqual(rig.speaker.spoken, ["Spoken text for headline-1.", "Spoken text for alert-1."])
    }

    func testDisablingSpokenBulletinsDropsTheQueuedBatchBeforeTheNextBreak() async {
        let rig = makeInterruptionRig(channel: headlineChannel(alerts: true), defaults: defaults)
        await rig.play(at: 42)
        await rig.controller.syncTick()
        LibraryInterruptionPreferences(defaults: defaults).speaks = false
        rig.crossAdBreak()

        XCTAssertTrue(rig.speaker.spoken.isEmpty)
        XCTAssertFalse(rig.player.isHoldingForSpeech)
        XCTAssertTrue(rig.engine.isPlaying)
    }

    func testTestBulletinUsesTheSpeakerOnceWithoutChangingPlayerState() {
        let rig = makeInterruptionRig(channel: nil, defaults: defaults)
        let position = rig.player.position
        let status = rig.player.status
        let activations = rig.session.activations

        rig.controller.speakTestBulletin()

        XCTAssertEqual(rig.previewSpeaker.spoken, ["This is a test bulletin."])
        XCTAssertTrue(rig.speaker.spoken.isEmpty, "the live bulletin speaker remains untouched")
        XCTAssertEqual(rig.player.position, position)
        XCTAssertEqual(rig.player.status, status)
        XCTAssertFalse(rig.player.isHoldingForSpeech)
        XCTAssertEqual(rig.session.activations, activations)
        XCTAssertEqual(rig.speaker.stops, 0)
    }

    func testTestBulletinUsesThePlayingSessionWithoutPausingTheEpisode() async {
        let rig = makeInterruptionRig(channel: nil, defaults: defaults)
        await rig.play(at: 42)
        let activations = rig.session.activations

        rig.controller.speakTestBulletin()

        XCTAssertEqual(rig.playingPreviewSpeaker.spoken, ["This is a test bulletin."])
        XCTAssertEqual(rig.previewSpeaker.spoken, [])
        XCTAssertEqual(rig.speaker.spoken, [])
        XCTAssertTrue(rig.player.status == .playing)
        XCTAssertTrue(rig.engine.isPlaying)
        XCTAssertEqual(rig.player.position, 42)
        XCTAssertEqual(rig.session.activations, activations)
    }

    func testPlaybackResumesAtTheStoredPositionAfterSkip() async {
        let rig = makeInterruptionRig(channel: headlineChannel(), defaults: defaults)
        await rig.play(at: 42)
        await rig.controller.syncTick()
        XCTAssertFalse(rig.player.isHoldingForSpeech, "a newly synced headline waits for an ad break")
        rig.crossAdBreak()
        XCTAssertEqual(rig.speaker.spoken, ["Spoken text for headline-1."])
        XCTAssertTrue(rig.player.isHoldingForSpeech)
        XCTAssertEqual(rig.player.status, .playing)
        XCTAssertFalse(rig.engine.isPlaying)
        XCTAssertEqual(rig.nowPlaying.infos.last?.title, "News headline")
        rig.player.skipSpeech()
        XCTAssertFalse(rig.player.isHoldingForSpeech)
        XCTAssertTrue(rig.engine.isPlaying)
        XCTAssertEqual(rig.engine.currentTime, 42.75)
        XCTAssertEqual(rig.player.position, 42.75)
        XCTAssertEqual(rig.speaker.stops, 1 + 1, "stopped before speaking and once more for the skip")
        XCTAssertEqual(rig.nowPlaying.infos.last?.title, "Episode One")
    }

    func testNowPlayingHeadlineTracksTheSpokenCandidateAndRetainsItAfterSpeech() async throws {
        let now = Date()
        let earlier = try Bulletin(
            id: "headline:older-story", kind: .headline, text: "Example Dispatch: The older story",
            severity: .unknown, issuedAt: now.addingTimeInterval(-3_600), expiresAt: now.addingTimeInterval(3_600),
            storyID: "older-story", publisherID: "example-dispatch", publisherName: "Example Dispatch",
            headline: "The older story", link: URL(string: "https://example.com/older-story"),
            publishedAt: now.addingTimeInterval(-3_600))
        let newer = try Bulletin(
            id: "headline:newer-story", kind: .headline, text: "Newer Daily: The newer story",
            severity: .unknown, issuedAt: now, expiresAt: now.addingTimeInterval(3_600),
            storyID: "newer-story", publisherID: "newer-daily", publisherName: "Newer Daily",
            headline: "The newer story", link: URL(string: "https://example.com/newer-story"), publishedAt: now)
        // The newer candidate remains in the channel, but the first normal headline is the one read.
        let channel = try LibraryBulletins(
            alertsEnabled: false, headlinesEnabled: true, headlines: [earlier, newer], updatedAt: now)
        let rig = makeInterruptionRig(channel: channel, defaults: defaults)
        await rig.play(at: 42)
        await rig.controller.syncTick()
        XCTAssertFalse(rig.player.isHoldingForSpeech)
        XCTAssertNil(rig.controller.nowPlayingHeadline)
        rig.crossAdBreak()
        XCTAssertEqual(rig.speaker.spoken, ["Example Dispatch: The older story"])
        XCTAssertEqual(rig.controller.activeSpokenHeadline?.headline, "The older story")
        XCTAssertEqual(rig.controller.activeSpokenHeadline?.publisherName, "Example Dispatch")
        XCTAssertEqual(rig.controller.activeSpokenHeadline?.link?.absoluteString, "https://example.com/older-story")
        XCTAssertEqual(rig.controller.nowPlayingHeadline?.storyID, "older-story")

        rig.speaker.completeSpeech()

        XCTAssertEqual(rig.speaker.spoken, ["Example Dispatch: The older story", "Newer Daily: The newer story"])
        XCTAssertEqual(rig.controller.activeSpokenHeadline?.storyID, "newer-story")
        XCTAssertEqual(rig.controller.lastSpokenHeadline?.storyID, "newer-story")
        XCTAssertEqual(rig.controller.nowPlayingHeadline?.headline, "The newer story")
        XCTAssertEqual(rig.controller.nowPlayingHeadline?.publisherName, "Newer Daily")
        XCTAssertEqual(rig.controller.nowPlayingHeadline?.link?.absoluteString, "https://example.com/newer-story")

        rig.speaker.completeSpeech()

        XCTAssertNil(rig.controller.activeSpokenHeadline)
        XCTAssertEqual(rig.controller.lastSpokenHeadline?.storyID, "newer-story")
        XCTAssertEqual(rig.controller.nowPlayingHeadline?.headline, "The newer story")
    }

    func testFinishedSpeechRestoresAndResumes() async {
        let rig = makeInterruptionRig(channel: headlineChannel(), defaults: defaults)
        await rig.play(at: 42)
        await rig.controller.syncTick()
        rig.crossAdBreak()
        rig.speaker.completeSpeech()
        XCTAssertFalse(rig.player.isHoldingForSpeech)
        XCTAssertTrue(rig.engine.isPlaying)
        XCTAssertEqual(rig.player.position, 42.75)
    }

    func testMediaInterruptionAfterHeadlineResumesFromPostBulletinPosition() async throws {
        let rig = makeInterruptionRig(channel: headlineChannel(), defaults: defaults)
        let journalURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("interruption-resume-\(UUID().uuidString).log")
        defer { try? FileManager.default.removeItem(at: journalURL) }
        rig.player.journal = LibraryJournal(url: journalURL)
        await rig.play(at: 42)
        await rig.controller.syncTick()
        rig.crossAdBreak()
        rig.speaker.completeSpeech()
        rig.engine.currentTime = 48
        rig.player.refreshPosition()

        rig.events.send(.interruptionBegan)
        XCTAssertEqual(rig.player.status, .paused)
        XCTAssertEqual(rig.player.position, 48)
        rig.events.send(.interruptionEnded(shouldResume: true))

        XCTAssertEqual(rig.player.status, .playing)
        XCTAssertTrue(rig.engine.isPlaying)
        XCTAssertEqual(rig.engine.currentTime, 48)

        let journal = try String(contentsOf: journalURL, encoding: .utf8)
        XCTAssertTrue(journal.contains("bulletin-resume outcome=started"))
        XCTAssertTrue(journal.contains("audio-session event=interruption-began"))
        XCTAssertTrue(journal.contains("audio-session event=interruption-ended should-resume=true resume-requested=true"))
        XCTAssertFalse(journal.contains("Spoken text for headline-1"), "journal records outcomes, never bulletin content")
    }

    func testNextTrackAdvancesAsBeforeWhenNothingIsSpokenAndSkipsOnlyWhileSpeaking() async throws {
        let rig = makeInterruptionRig(channel: headlineChannel(), defaults: defaults, adBreakSeams: [40.5])
        await rig.play(at: 10)
        let handler = try XCTUnwrap(rig.remote.handler)
        XCTAssertTrue(handler(.skipForward(30)))
        XCTAssertEqual(rig.player.position, 40, "next-track outside speech moves on as before")
        await rig.controller.syncTick()
        XCTAssertFalse(rig.player.isHoldingForSpeech)
        rig.crossAdBreak(to: 40.75)
        XCTAssertTrue(rig.player.isHoldingForSpeech)
        XCTAssertTrue(handler(.skipForward(30)))
        XCTAssertFalse(rig.player.isHoldingForSpeech)
        XCTAssertEqual(rig.player.position, 40.75, "while speaking it skips the bulletin and does not seek")
        XCTAssertTrue(rig.engine.isPlaying)
    }

    func testRouteLossDuringSpeechLeavesPlaybackPausedAtTheCheckpoint() async {
        let rig = makeInterruptionRig(channel: headlineChannel(), defaults: defaults)
        await rig.play(at: 42)
        await rig.controller.syncTick()
        rig.crossAdBreak()
        XCTAssertTrue(rig.player.isHoldingForSpeech)
        rig.events.send(.routeLost)
        XCTAssertEqual(rig.player.status, .paused)
        XCTAssertFalse(rig.player.isHoldingForSpeech)
        XCTAssertFalse(rig.engine.isPlaying)
        XCTAssertEqual(rig.player.position, 42.75)
        XCTAssertEqual(rig.engine.currentTime, 42.75)
        XCTAssertEqual(rig.speaker.stops, 2)
    }

    func testSpeechThatCannotStartIsRetriedAtTheNextBreak() async {
        let rig = makeInterruptionRig(
            channel: headlineChannel(), defaults: defaults, adBreakSeams: [42.5, 80])
        rig.speaker.canStart = false
        await rig.play(at: 42)
        await rig.controller.syncTick()
        rig.crossAdBreak()
        XCTAssertFalse(rig.player.isHoldingForSpeech)
        XCTAssertEqual(rig.player.status, .playing)
        XCTAssertTrue(rig.engine.isPlaying)
        XCTAssertEqual(rig.player.position, 42.75)
        XCTAssertNil(rig.controller.nowPlayingHeadline, "a failed speech start is not shown as a story read")

        rig.speaker.canStart = true
        rig.crossAdBreak(to: 79.5)
        rig.crossAdBreak(to: 80.25)
        XCTAssertEqual(rig.speaker.spoken, ["Spoken text for headline-1."],
                       "a failed start is not marked read and remains queued for the next break")
        XCTAssertEqual(rig.controller.activeSpokenHeadline?.id, "headline-1")
    }

    func testUnavailablePreparedAudioLeavesPlaybackRunningAndRequeuesStory() async {
        let rig = makeInterruptionRig(
            channel: headlineChannel(), defaults: defaults, adBreakSeams: [42.5, 80])
        rig.speaker.canSpeakBulletins = false
        await rig.play(at: 42)
        await rig.controller.syncTick()
        rig.crossAdBreak()

        XCTAssertEqual(rig.player.status, .playing)
        XCTAssertFalse(rig.player.isHoldingForSpeech)
        XCTAssertTrue(rig.engine.isPlaying)
        XCTAssertEqual(rig.player.position, 42.75, "an unavailable story must not rewind playback to the seam")
        XCTAssertTrue(rig.speaker.spokenBulletins.isEmpty)

        rig.speaker.canSpeakBulletins = true
        rig.crossAdBreak(to: 79.5)
        rig.crossAdBreak(to: 80.25)
        XCTAssertEqual(rig.speaker.spokenBulletins.map(\.id), ["headline-1"])
        XCTAssertTrue(rig.player.isHoldingForSpeech)
    }

    func testMediaInterruptionDuringBulletinResumesOnlyWhenSystemAllows() async {
        let rig = makeInterruptionRig(channel: headlineChannel(), defaults: defaults)
        await rig.play(at: 42)
        await rig.controller.syncTick()
        rig.crossAdBreak()
        XCTAssertTrue(rig.player.isHoldingForSpeech)

        rig.events.send(.interruptionBegan)
        XCTAssertEqual(rig.player.status, .paused)
        XCTAssertFalse(rig.player.isHoldingForSpeech)
        XCTAssertEqual(rig.speaker.stops, 2)
        rig.events.send(.interruptionEnded(shouldResume: true))
        XCTAssertEqual(rig.player.status, .playing)
        XCTAssertTrue(rig.engine.isPlaying)
        XCTAssertEqual(rig.engine.currentTime, 42.75)

        rig.events.send(.interruptionBegan)
        rig.events.send(.interruptionEnded(shouldResume: false))
        XCTAssertEqual(rig.player.status, .paused, "a later media interruption obeys iOS's no-resume decision")
        XCTAssertFalse(rig.engine.isPlaying)
    }

    func testStatusStaysPlayingAndListeningDoesNotGrowDuringSpeechWithTheRealTimer() async throws {
        let seam = 0.15
        let rig = makeInterruptionRig(
            channel: headlineChannel(), defaults: defaults, tick: .milliseconds(10), adBreakSeams: [seam])
        var listened = 0.0
        rig.player.onListened = { wall, _ in listened += wall }
        await rig.play(at: 0)
        try await Task.sleep(for: .milliseconds(60))
        rig.engine.currentTime = 0.1
        rig.player.position = 0.1
        await rig.controller.syncTick()
        XCTAssertFalse(rig.player.isHoldingForSpeech, "the timer never starts a bulletin")
        XCTAssertGreaterThan(listened, 0)
        rig.engine.currentTime = 0.2
        rig.player.position = 0.2
        XCTAssertTrue(rig.player.isHoldingForSpeech)
        XCTAssertGreaterThanOrEqual(rig.player.position, seam, "continuous playback crossed the prepared ad seam")
        let atHold = listened
        XCTAssertGreaterThan(atHold, 0)
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(rig.player.status, .playing, "the engine-stop inference must not flip the status")
        XCTAssertEqual(listened, atHold, "speech time is not listening time")
        rig.speaker.completeSpeech()
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertGreaterThan(listened, atHold)
    }

    func testAlertMonitorStartsAtThisPhonesCoordinatesOnlyWhilePlayingWithAlertsOn() async throws {
        // Alerts off in the channel: no monitor is ever made.
        let off = makeInterruptionRig(channel: headlineChannel(alerts: false), defaults: defaults)
        await off.play()
        await off.controller.syncTick()
        await off.controller.settleMonitor()
        XCTAssertEqual(off.monitorsMade(), 0)
        XCTAssertEqual(off.location.fixRequests, 0)

        let rig = makeInterruptionRig(channel: headlineChannel(alerts: true), defaults: defaults)
        await rig.controller.syncTick()
        XCTAssertEqual(rig.monitorsMade(), 0, "nothing is playing yet")
        await rig.play()
        await rig.controller.syncTick()
        XCTAssertEqual(rig.location.fixRequests, 1)
        rig.location.onFix?(39.7456, -97.0892, Date())
        rig.controller.appBecameActive()
        await rig.controller.settleMonitor()
        XCTAssertEqual(rig.monitor.events, ["coords 39.75,-97.09", "start"])
        rig.player.pause()
        await rig.controller.settleMonitor()
        XCTAssertEqual(rig.monitor.events.suffix(2), ["stop", "clear"])
    }

    func testHandoffOwnershipAndTheSyncTickStayActiveDuringASpokenBulletin() async throws {
        let rig = try await HandoffSpeechRig.make(defaults: defaults)
        defer { try? FileManager.default.removeItem(at: rig.scratch) }
        await rig.model.waitForHandoff()
        XCTAssertTrue(rig.model.handoffState.reportedPlaying)
        XCTAssertNotNil(rig.model.tickState.tick)
        let activations = rig.rig.session.activations
        await rig.rig.controller.syncTick()
        rig.rig.crossAdBreak()
        XCTAssertTrue(rig.rig.player.isHoldingForSpeech)
        await rig.model.sceneBecameBackground()
        await rig.model.syncRound(.timer)
        await rig.model.waitForHandoff()
        XCTAssertTrue(rig.model.handoffState.reportedPlaying, "speech is a hold, not a pause")
        XCTAssertNotNil(rig.model.tickState.tick, "the tick keeps its playing cadence in the background")
        XCTAssertEqual(rig.rig.session.deactivations, 0)
        XCTAssertGreaterThanOrEqual(rig.rig.session.activations, activations)
        let record = try await rig.phoneRecord()
        XCTAssertTrue(record.isPlaying)
        XCTAssertEqual(record.positionSeconds, 42, accuracy: 1)
        rig.rig.speaker.completeSpeech()
        XCTAssertTrue(rig.model.handoffState.reportedPlaying)
    }

    func testAReportRowNamesMorningReportInsteadOfAnUnknownShow() throws {
        let id = try ItemID(rawValue: "report-1")
        let entry = try LibraryEntry(
            id: id, kind: .report, sourceID: id, title: "Morning report, Oct 10", summary: "",
            publishedAt: Date(timeIntervalSince1970: 0), durationSeconds: 240)
        XCTAssertEqual(LibraryRowBuilder.showTitle(entry, sources: [:]), "Morning report")
    }

    func testBulletinSpeakerSkipsWithoutVerifiedAudioAndNeverFallsBackToSystemVoice() async throws {
        let handoff = try await HandoffSpeechRig.make(defaults: defaults)
        defer { try? FileManager.default.removeItem(at: handoff.scratch) }
        let speaker = LibraryBulletinAudioSpeaker(model: handoff.model)
        let bulletin = interruptionBulletin()
        var finished = false

        speaker.prepare(bulletin)
        await speaker.refreshPreparedAudio()
        XCTAssertFalse(speaker.canSpeak(bulletin), "no verified, owner-scoped audio is cached for this bulletin")
        XCTAssertFalse(speaker.speak(bulletin) { finished = true })
        XCTAssertFalse(speaker.speak("This is a test bulletin.") { finished = true },
                       "generic preview text has no approved narration clip")
        XCTAssertFalse(finished, "unavailable audio must not announce completion or substitute system speech")
    }
}

// MARK: - Model rig

/// A phone model attached to the interruption rig's player, with the item cached and a takeover published.
@MainActor
struct HandoffSpeechRig {
    let model: LibraryAppModel
    let rig: InterruptionRig
    let mac: InMemoryLibraryTransport
    let scratch: URL

    static func make(defaults: UserDefaults) async throws -> HandoffSpeechRig {
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("interruption-model-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        let rig = makeInterruptionRig(channel: headlineChannel(), defaults: defaults)
        let server = InMemoryLibraryServer(writerDeviceID: "mac")
        let mac = InMemoryLibraryTransport(deviceID: "mac", server: server, verifiedOwnerToken: "fixture-owner")
        let phone = InMemoryLibraryTransport(deviceID: "phone", server: server, verifiedOwnerToken: "fixture-owner")
        let entryID = rig.item.entryID
        let entry = try LibraryEntry(
            id: entryID, kind: .podcastEpisode, sourceID: entryID, title: "Episode", summary: "",
            publishedAt: Date(timeIntervalSince1970: 0), durationSeconds: 600)
        _ = try await mac.push(changes: [
            PendingLibraryChange(localSeq: 1, change: .entry(entry), baseVersion: 0),
            PendingLibraryChange(localSeq: 2, change: .slot(try QueueSlot(entryID: entryID, sortKey: 0)), baseVersion: 0),
        ])
        let mirror = FileLibraryStore(url: scratch.appendingPathComponent("mirror.json"))
        try await PreparedMediaFixture.bootstrap(mirror, transport: phone)
        let cache = FileMediaCache(rootURL: scratch.appendingPathComponent("cache"))
        let payload = Data((0..<2_000).map { UInt8($0 % 251) })
        let file = scratch.appendingPathComponent("audio")
        try payload.write(to: file)
        let hash = MediaHash.prefix + SHA256.hash(data: payload).map { String(format: "%02x", $0) }.joined()
        let offer = try PreparedMediaFixture.certified(LibraryMediaOffer(
            entryID: entryID, revisionID: RevisionID(rawValue: "rev-1"), contentHash: hash,
            byteCount: Int64(payload.count), mediaType: "audio/mp4", durationSeconds: 600))
        _ = try await PreparedMediaFixture.adopt(into: cache, verifiedFile: file, for: offer, owner: "fixture-owner")
        let model = LibraryAppModel(
            transport: phone, store: mirror, deviceID: "phone", mediaCache: cache,
            handoffTiming: LibraryHandoffTiming(sleep: { _ in try await Task.sleep(for: .seconds(3600)) }, settleSleep: { _ in }),
            timeZone: TimeZone(identifier: "UTC")!)
        model.attachPlayer(rig.player)
        await model.refresh()
        let cachedEntries = await cache.cachedEntries()
        let cached = try XCTUnwrap(cachedEntries[entryID])
        let item = LibraryPlayer.Item(entryID: entryID, title: "Episode", showTitle: "Show", fileURL: cached.url)
        XCTAssertTrue(rig.player.start(item, at: 42))
        for _ in 0..<200 where !rig.controller.hasRevision { try await Task.sleep(for: .milliseconds(5)) }
        for _ in 0..<400 where !model.handoffState.reportedPlaying { try await Task.sleep(for: .milliseconds(5)) }
        rig.player.position = 42
        return HandoffSpeechRig(model: model, rig: rig, mac: mac, scratch: scratch)
    }

    func phoneRecord() async throws -> DevicePlaybackPosition {
        let records = try await mac.fetchDeviceRecords()
        return try XCTUnwrap(records.nowPlaying.first { $0.record.deviceID == "phone" }?.record)
    }
}
