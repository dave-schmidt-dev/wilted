import AVFoundation
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
    func uninstall() { handler = nil }
}

@MainActor final class InterruptionEvents: LibrarySessionEvents {
    private var handler: (@MainActor (LibrarySessionEvent) -> Void)?
    func observe(_ handler: @escaping @MainActor (LibrarySessionEvent) -> Void) { self.handler = handler }
    func send(_ event: LibrarySessionEvent) { handler?(event) }
}

/// Never speaks: records what it was asked and finishes only when a test says so.
@MainActor final class StubSpeaker: LibrarySpeaking {
    var canStart = true
    private(set) var spoken: [String] = []
    private(set) var stops = 0
    private var finish: (@MainActor () -> Void)?
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
    let controller: LibraryInterruptionController
    let location: InterruptionLocationManager
    let monitor: StubMonitor
    let monitorsMade: () -> Int
    let item = LibraryPlayer.Item(
        entryID: try! ItemID(rawValue: "entry-1"), title: "Episode One", showTitle: "Show",
        fileURL: URL(fileURLWithPath: "/nonexistent/interruption-test.mp3"))

    /// Starts `item` at `position` and waits until the controller knows its revision.
    func play(at position: Double = 42) async {
        XCTAssertTrue(player.start(item, at: position))
        for _ in 0..<200 where !controller.hasRevision { try? await Task.sleep(for: .milliseconds(5)) }
        XCTAssertTrue(controller.hasRevision)
    }
}

@MainActor
func makeInterruptionRig(
    channel: LibraryBulletins?, defaults: UserDefaults, tick: Duration = .seconds(3600),
    foreground: Bool = true
) -> InterruptionRig {
    let engine = InterruptionEngine(), session = InterruptionSession(), nowPlaying = InterruptionNowPlaying()
    let remote = InterruptionRemote(), events = InterruptionEvents(), speaker = StubSpeaker()
    let player = LibraryPlayer(
        engine: engine, session: session, nowPlaying: nowPlaying, remoteCommands: remote,
        sessionEvents: events, tickInterval: tick)
    let location = InterruptionLocationManager()
    let monitor = StubMonitor()
    var made = 0
    let revision = try! RevisionID(rawValue: "rev-1")
    let controller = LibraryInterruptionController(
        player: player,
        dependencies: .init(
            speaker: speaker, preferences: LibraryInterruptionPreferences(defaults: defaults),
            fetchBulletins: { channel },
            makeMonitor: { _ in made += 1; return monitor },
            location: LibraryLocationProvider(manager: location),
            revision: { _ in revision },
            isForeground: { foreground },
            sleep: { _ in try await Task.sleep(for: .seconds(3600)) }))
    return InterruptionRig(
        player: player, engine: engine, session: session, nowPlaying: nowPlaying, remote: remote, events: events,
        speaker: speaker, controller: controller, location: location, monitor: monitor, monitorsMade: { made })
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

    func testPlaybackResumesAtTheStoredPositionAfterSkip() async {
        let rig = makeInterruptionRig(channel: headlineChannel(), defaults: defaults)
        await rig.play(at: 42)
        await rig.controller.syncTick()
        XCTAssertEqual(rig.speaker.spoken, ["Spoken text for headline-1."])
        XCTAssertTrue(rig.player.isHoldingForSpeech)
        XCTAssertEqual(rig.player.status, .playing)
        XCTAssertFalse(rig.engine.isPlaying)
        XCTAssertEqual(rig.nowPlaying.infos.last?.title, "News headline")
        rig.player.skipSpeech()
        XCTAssertFalse(rig.player.isHoldingForSpeech)
        XCTAssertTrue(rig.engine.isPlaying)
        XCTAssertEqual(rig.engine.currentTime, 42)
        XCTAssertEqual(rig.player.position, 42)
        XCTAssertEqual(rig.speaker.stops, 1 + 1, "stopped before speaking and once more for the skip")
        XCTAssertEqual(rig.nowPlaying.infos.last?.title, "Episode One")
    }

    func testFinishedSpeechRestoresAndResumes() async {
        let rig = makeInterruptionRig(channel: headlineChannel(), defaults: defaults)
        await rig.play(at: 42)
        await rig.controller.syncTick()
        rig.speaker.completeSpeech()
        XCTAssertFalse(rig.player.isHoldingForSpeech)
        XCTAssertTrue(rig.engine.isPlaying)
        XCTAssertEqual(rig.player.position, 42)
    }

    func testNextTrackAdvancesAsBeforeWhenNothingIsSpokenAndSkipsOnlyWhileSpeaking() async throws {
        let rig = makeInterruptionRig(channel: headlineChannel(), defaults: defaults)
        await rig.play(at: 10)
        let handler = try XCTUnwrap(rig.remote.handler)
        XCTAssertTrue(handler(.skipForward(30)))
        XCTAssertEqual(rig.player.position, 40, "next-track outside speech moves on as before")
        await rig.controller.syncTick()
        XCTAssertTrue(rig.player.isHoldingForSpeech)
        XCTAssertTrue(handler(.skipForward(30)))
        XCTAssertFalse(rig.player.isHoldingForSpeech)
        XCTAssertEqual(rig.player.position, 40, "while speaking it skips the bulletin and does not seek")
        XCTAssertTrue(rig.engine.isPlaying)
    }

    func testRouteLossDuringSpeechLeavesPlaybackPausedAtTheCheckpoint() async {
        let rig = makeInterruptionRig(channel: headlineChannel(), defaults: defaults)
        await rig.play(at: 42)
        await rig.controller.syncTick()
        XCTAssertTrue(rig.player.isHoldingForSpeech)
        rig.events.send(.routeLost)
        XCTAssertEqual(rig.player.status, .paused)
        XCTAssertFalse(rig.player.isHoldingForSpeech)
        XCTAssertFalse(rig.engine.isPlaying)
        XCTAssertEqual(rig.player.position, 42)
        XCTAssertEqual(rig.engine.currentTime, 42)
        XCTAssertEqual(rig.speaker.stops, 2)
    }

    func testSpeechThatCannotStartIsDroppedAndPlaybackKeepsGoing() async {
        let rig = makeInterruptionRig(channel: headlineChannel(), defaults: defaults)
        rig.speaker.canStart = false
        await rig.play(at: 42)
        await rig.controller.syncTick()
        XCTAssertFalse(rig.player.isHoldingForSpeech)
        XCTAssertEqual(rig.player.status, .playing)
        XCTAssertTrue(rig.engine.isPlaying)
        XCTAssertEqual(rig.player.position, 42)
    }

    func testStatusStaysPlayingAndListeningDoesNotGrowDuringSpeechWithTheRealTimer() async throws {
        let rig = makeInterruptionRig(channel: headlineChannel(), defaults: defaults, tick: .milliseconds(10))
        var listened = 0.0
        rig.player.onListened = { wall, _ in listened += wall }
        await rig.play(at: 0)
        try await Task.sleep(for: .milliseconds(80))
        await rig.controller.syncTick()
        XCTAssertTrue(rig.player.isHoldingForSpeech)
        let atHold = listened
        XCTAssertGreaterThan(atHold, 0)
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(rig.player.status, .playing, "the engine-stop inference must not flip the status")
        XCTAssertEqual(listened, atHold, "speech time is not listening time")
        rig.speaker.completeSpeech()
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertGreaterThan(listened, atHold)
        XCTAssertLessThan(listened - atHold, 0.5, "the speech gap is not counted afterwards")
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

    func testLateCancelForUtteranceADoesNotFinishUtteranceB() async throws {
        let speaker = LibrarySpeechSynthesizer()
        var finishedA = false
        var finishedB = false

        XCTAssertTrue(speaker.speak("First utterance") { finishedA = true })
        let uttA = try XCTUnwrap(speaker.currentUtterance)

        XCTAssertTrue(speaker.speak("Second utterance") { finishedB = true })
        let uttB = try XCTUnwrap(speaker.currentUtterance)
        XCTAssertNotEqual(ObjectIdentifier(uttA), ObjectIdentifier(uttB))

        // Late cancel for utterance A arrives
        speaker.speechSynthesizer(AVSpeechSynthesizer(), didCancel: uttA)
        try? await Task.sleep(for: .milliseconds(50))
        XCTAssertFalse(finishedA)
        XCTAssertFalse(finishedB)

        // Utterance B finishes normally
        speaker.speechSynthesizer(AVSpeechSynthesizer(), didFinish: uttB)
        try? await Task.sleep(for: .milliseconds(50))
        XCTAssertFalse(finishedA)
        XCTAssertTrue(finishedB)
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
        return HandoffSpeechRig(model: model, rig: rig, mac: mac, scratch: scratch)
    }

    func phoneRecord() async throws -> DevicePlaybackPosition {
        let records = try await mac.fetchDeviceRecords()
        return try XCTUnwrap(records.nowPlaying.first { $0.record.deviceID == "phone" }?.record)
    }
}
