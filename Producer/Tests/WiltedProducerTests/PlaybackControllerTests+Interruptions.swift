import Foundation
import XCTest
import WiltedDomain
import WiltedLibrary
@testable import WiltedProducer

/// A speaker that never makes a sound: it records what it was asked to say and finishes on demand.
@MainActor
final class StubSpeaker: BulletinSpeaking {
    var canStart = true
    var reentrantStop = false
    var onStop: (@MainActor () -> Void)?
    var completions: [@MainActor () -> Void] = []
    private(set) var spoken: [String] = []
    private(set) var stopCount = 0
    private var finished: (@MainActor () -> Void)?

    func speak(_ text: String, finished: @escaping @MainActor () -> Void) -> Bool {
        guard canStart else { return false }
        spoken.append(text)
        self.finished = finished
        completions.append(finished)
        return true
    }

    func stop() {
        stopCount += 1
        let done = finished
        finished = nil
        if reentrantStop { done?() }
        onStop?()
    }

    /// The speech ends by itself.
    func finishSpeaking() {
        let done = finished
        finished = nil
        done?()
    }
}

@MainActor
final class InterruptionRoute: MacAudioRouteSource {
    var route: MacAudioRoute? = MacAudioRoute(device: 10, source: 1, jackConnected: true)
    var changed: (@MainActor () -> Void)?
    var starts = 0
    var stops = 0
    var reads = 0
    var beforeRead: (@MainActor () -> Void)?
    var canRegister = true
    var monitoringAvailable = true
    func start(changed: @escaping @MainActor () -> Void) -> Bool {
        starts += 1
        self.changed = changed
        return canRegister
    }
    func currentRoute() -> MacAudioRoute? {
        reads += 1
        beforeRead?()
        return monitoringAvailable ? route : nil
    }
    func stop() { stops += 1; changed = nil }
}

@MainActor
final class InterruptionBackend: PlaybackBackend {
    var duration: TimeInterval = 42
    var currentTime: TimeInterval = 0 { didSet { afterRestore?() } }
    var afterRestore: (@MainActor () -> Void)?
    var isPlaying = false
    var rate: Float = 1
    var volume: Float = 1
    var loadedGeneration: UInt64 = 0
    var completionHandler: (@MainActor @Sendable (UInt64, Bool) -> Void)?
    var playCount = 0
    func load(url: URL) throws { loadedGeneration += 1; currentTime = 0; isPlaying = false }
    func play() -> Bool { playCount += 1; isPlaying = true; return true }
    func pause() { isPlaying = false }
    func stop() { isPlaying = false }
}

/// The wall clock the interruption engine reads, moved by hand. Sleeps never return unless the
/// test lets a long one (the speech watchdog) through.
final class TestWallClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current = Date(timeIntervalSince1970: 1_800_000_000)
    var firesWatchdog = false

    var now: Date {
        get { lock.withLock { current } }
        set { lock.withLock { current = newValue } }
    }

    var clock: PlaybackInterruptionClock {
        PlaybackInterruptionClock(
            now: { [self] in now },
            sleep: { [self] seconds in
                if seconds >= 20, firesWatchdog { return }
                try await Task.sleep(for: .seconds(3600))
            })
    }
}

@MainActor
private final class MeterClock { var now: TimeInterval = 1_000 }

@MainActor
extension PlaybackControllerTests {
    struct InterruptionRig {
        let controller: PlaybackController
        let backend: InterruptionBackend
        let route: InterruptionRoute
        let speaker: StubSpeaker
        let wall: TestWallClock
        let root: URL
    }

    func interruptionRig(
        cues: (@MainActor (ItemID, RevisionID) async -> (cues: [TranscriptCue]?, timing: TranscriptTiming))? = nil,
        firesWatchdog: Bool = false, name: String = #function
    ) async throws -> InterruptionRig {
        let path = storeURL(name)
        let store = try LocalLibraryStore(url: path)
        let (_, revision) = try fixture()
        let backend = InterruptionBackend()
        let controller = PlaybackController(store: store, backend: backend)
        try await controller.load(revision: revision, mediaURL: URL(fileURLWithPath: "/tmp/audio.m4a"))
        let speaker = StubSpeaker()
        let wall = TestWallClock()
        wall.firesWatchdog = firesWatchdog
        let route = InterruptionRoute()
        controller.enableInterruptions(speaker: speaker, waitLimit: 60, clock: wall.clock, cues: cues, routeSource: route)
        return InterruptionRig(controller: controller, backend: backend, route: route, speaker: speaker, wall: wall,
                               root: path.deletingLastPathComponent())
    }

    func bulletin(
        _ id: String, _ kind: BulletinKind = .alert, _ severity: BulletinSeverity = .extreme, at now: Date
    ) throws -> Bulletin {
        try Bulletin(id: id, kind: kind, text: "Bulletin \(id).", severity: severity,
                     issuedAt: now, expiresAt: now.addingTimeInterval(3600))
    }

    func testPlaybackResumesAtTheStoredPositionAfterASpokenBulletin() async throws {
        let rig = try await interruptionRig()
        defer { try? FileManager.default.removeItem(at: rig.root) }
        let controller = rig.controller
        try controller.play()
        rig.backend.currentTime = 10

        controller.deliverBulletin(try bulletin("tornado", at: rig.wall.now))
        XCTAssertEqual(rig.speaker.spoken, ["Bulletin tornado."], "an extreme alert speaks at once")
        XCTAssertFalse(rig.backend.isPlaying, "program audio is held while speaking")
        XCTAssertEqual(controller.speakingBulletin?.id, "tornado")

        rig.backend.currentTime = 10.03 // drift inside the hold is not a seek
        rig.speaker.finishSpeaking()
        XCTAssertTrue(rig.backend.isPlaying, "playback resumes")
        XCTAssertEqual(rig.backend.currentTime, 10, accuracy: 0.0001, "at the position it was held at")
        XCTAssertNil(controller.speakingBulletin)
        XCTAssertTrue(controller.isPlaying)
    }

    func testAHeadlineWaitsForItsPauseBetweenCuesThenSpeaksAndResumes() async throws {
        let cues = [try TranscriptCue(startSeconds: 0, endSeconds: 11, text: "a"),
                    try TranscriptCue(startSeconds: 11.2, endSeconds: 15, text: "b"),
                    try TranscriptCue(startSeconds: 15.9, endSeconds: 20, text: "c")]
        let rig = try await interruptionRig(cues: { _, _ in (cues, .aligned) })
        defer { try? FileManager.default.removeItem(at: rig.root) }
        let controller = rig.controller
        try controller.play()
        rig.backend.currentTime = 12

        controller.deliverBulletin(try bulletin("story", .headline, .unknown, at: rig.wall.now))
        controller.interruptionTick() // looks for the pause point
        await waitUntil { controller.interruptions?.pausePoint != nil }
        controller.interruptionTick()
        XCTAssertTrue(rig.speaker.spoken.isEmpty, "mid-sentence: it keeps waiting")

        rig.backend.currentTime = 15.1 // inside the gap before the third cue
        controller.interruptionTick()
        XCTAssertEqual(rig.speaker.spoken, ["Bulletin story."])
        rig.speaker.finishSpeaking()
        XCTAssertTrue(rig.backend.isPlaying)
        XCTAssertEqual(rig.backend.currentTime, 15.1, accuracy: 0.0001)
    }

    func testAHeadlineWithNoPauseSpeaksWhenTheWaitLimitPasses() async throws {
        let rig = try await interruptionRig(cues: { _, _ in (nil, TranscriptTiming.none) })
        defer { try? FileManager.default.removeItem(at: rig.root) }
        try rig.controller.play()
        rig.controller.deliverBulletin(try bulletin("story", .headline, .unknown, at: rig.wall.now))
        rig.controller.interruptionTick()
        XCTAssertTrue(rig.speaker.spoken.isEmpty)
        rig.wall.now = rig.wall.now.addingTimeInterval(61)
        rig.controller.interruptionTick()
        XCTAssertEqual(rig.speaker.spoken, ["Bulletin story."])
    }

    func testABulletinArrivingWhilePausedIsNotSpoken() async throws {
        let rig = try await interruptionRig()
        defer { try? FileManager.default.removeItem(at: rig.root) }
        let controller = rig.controller
        XCTAssertFalse(rig.backend.isPlaying)

        controller.deliverBulletin(try bulletin("tornado", at: rig.wall.now))
        controller.interruptionTick()
        XCTAssertTrue(rig.speaker.spoken.isEmpty, "nothing is spoken over silence")
        XCTAssertFalse(rig.backend.isPlaying, "and nothing starts playing")
        XCTAssertNil(controller.speakingBulletin)

        try controller.play()
        controller.interruptionTick()
        XCTAssertEqual(rig.speaker.spoken, ["Bulletin tornado."], "it is spoken once the listener plays")
    }

    func testThePublishedStateStaysPlayingAndListeningStatisticsDoNotGrowDuringSpeech() async throws {
        let rig = try await interruptionRig()
        defer { try? FileManager.default.removeItem(at: rig.root) }
        let controller = rig.controller
        let meter = MeterClock()
        controller.listeningClock = { meter.now }
        try controller.play()
        meter.now += 5
        rig.backend.currentTime = 5

        controller.deliverBulletin(try bulletin("tornado", at: rig.wall.now))
        meter.now += 30 // speech
        XCTAssertTrue(controller.isPlaying, "the published state stays playing")
        XCTAssertTrue(controller.liveIsPlaying, "and so does the live state the sync sample reads")
        try await controller.checkpoint() // the periodic checkpoint runs mid-speech
        XCTAssertTrue(controller.isPlaying, "a checkpoint does not turn the hold into a pause")
        XCTAssertEqual(controller.explicitHoldSerial, 0, "the hold is not an explicit pause")

        rig.speaker.finishSpeaking()
        meter.now += 3
        controller.meterListening()
        XCTAssertEqual(controller.lifetimeMeter.playedSeconds, 8, accuracy: 0.0001,
                       "5 seconds before and 3 after; the 30 spoken seconds are not listening")
    }

    func testAListenerPauseDuringSpeechStopsItAndLeavesPlaybackPausedAtTheHeldPosition() async throws {
        let rig = try await interruptionRig()
        defer { try? FileManager.default.removeItem(at: rig.root) }
        let controller = rig.controller
        try controller.play()
        rig.backend.currentTime = 10
        controller.deliverBulletin(try bulletin("tornado", at: rig.wall.now))

        try await controller.pause()
        XCTAssertEqual(rig.speaker.stopCount, 1)
        XCTAssertFalse(rig.backend.isPlaying)
        XCTAssertFalse(controller.isPlaying)
        XCTAssertNil(controller.speakingBulletin)
        XCTAssertEqual(rig.backend.currentTime, 10, accuracy: 0.0001)
        rig.speaker.finishSpeaking()
        XCTAssertFalse(rig.backend.isPlaying, "a late completion does not restart audio the listener paused")
    }

    func testSkipStopsSpeechAndResumes() async throws {
        let rig = try await interruptionRig()
        defer { try? FileManager.default.removeItem(at: rig.root) }
        try rig.controller.play()
        rig.backend.currentTime = 7
        rig.controller.deliverBulletin(try bulletin("tornado", at: rig.wall.now))

        rig.controller.skipSpokenBulletin()
        XCTAssertEqual(rig.speaker.stopCount, 1)
        XCTAssertTrue(rig.backend.isPlaying)
        XCTAssertEqual(rig.backend.currentTime, 7, accuracy: 0.0001)
        XCTAssertNil(rig.controller.speakingBulletin)
    }

    func testSpeechThatCannotStartDropsTheBulletinAndKeepsPlaying() async throws {
        let rig = try await interruptionRig()
        defer { try? FileManager.default.removeItem(at: rig.root) }
        rig.speaker.canStart = false
        try rig.controller.play()
        rig.backend.currentTime = 4

        rig.controller.deliverBulletin(try bulletin("tornado", at: rig.wall.now))
        XCTAssertTrue(rig.backend.isPlaying, "playback carries on")
        XCTAssertEqual(rig.backend.currentTime, 4, accuracy: 0.0001)
        XCTAssertNil(rig.controller.speakingBulletin)
        XCTAssertTrue(rig.controller.isPlaying)
    }

    func testSpeechThatNeverEndsIsTimedOutAndPlaybackResumes() async throws {
        let rig = try await interruptionRig(firesWatchdog: true)
        defer { try? FileManager.default.removeItem(at: rig.root) }
        try rig.controller.play()
        rig.backend.currentTime = 9
        rig.controller.deliverBulletin(try bulletin("tornado", at: rig.wall.now))

        await waitUntil { rig.backend.isPlaying }
        XCTAssertTrue(rig.backend.isPlaying)
        XCTAssertEqual(rig.speaker.stopCount, 1, "the stuck speaker is stopped")
        XCTAssertNil(rig.controller.speakingBulletin)
    }

    func testChangingItemsDuringSpeechCutsTheSpeech() async throws {
        let rig = try await interruptionRig()
        defer { try? FileManager.default.removeItem(at: rig.root) }
        let controller = rig.controller
        try controller.play()
        controller.deliverBulletin(try bulletin("tornado", at: rig.wall.now))
        let (_, revision) = try fixture()

        try await controller.load(revision: revision, mediaURL: URL(fileURLWithPath: "/tmp/audio.m4a"))
        XCTAssertEqual(rig.speaker.stopCount, 1)
        XCTAssertNil(controller.speakingBulletin)
        XCTAssertFalse(rig.backend.isPlaying, "a load does not resume the old item")
    }

    func testTurningInterruptionsOffMidSpeechResumesPlayback() async throws {
        let rig = try await interruptionRig()
        defer { try? FileManager.default.removeItem(at: rig.root) }
        try rig.controller.play()
        rig.controller.deliverBulletin(try bulletin("tornado", at: rig.wall.now))

        rig.controller.disableInterruptions()
        XCTAssertFalse(rig.controller.interruptionsEnabled)
        XCTAssertTrue(rig.backend.isPlaying)
        XCTAssertNil(rig.controller.speakingBulletin)
        rig.controller.deliverBulletin(try bulletin("another", at: rig.wall.now))
        XCTAssertEqual(rig.speaker.spoken.count, 1, "nothing is spoken once off")
    }
}
