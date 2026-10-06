import AppIntents
import Foundation
import WiltedDomain
import WiltedLibrary
import WiltedPlayback
import XCTest
@testable import WiltediOS

/// Time left, speed and the sleep timer: the enums Siri speaks, the intent shells, and the real target
/// acting on a real `LibraryPlayer`, `LibrarySettingsStore` and `SleepTimer`.
@MainActor
final class VoiceStateTests: XCTestCase {
    private var savedProvider: (@MainActor () async -> (any VoiceCommandTarget)?)!
    private var scratch: URL!
    private let suite = "voice-state-tests"

    override func setUp() async throws {
        savedProvider = VoiceRuntime.provider
        UserDefaults(suiteName: suite)!.removePersistentDomain(forName: suite)
        scratch = FileManager.default.temporaryDirectory.appendingPathComponent("voice-state-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        VoiceRuntime.provider = savedProvider
        UserDefaults(suiteName: suite)!.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: scratch)
    }

    // MARK: enums

    func testSpeedOptionsAreExactlyThePlayersRatesAndThePlannersSpeeds() {
        XCTAssertEqual(SpeedOption.allCases.map(\.rate), PlaybackSpeeds.all)
        XCTAssertEqual(Set(SpeedOption.caseDisplayRepresentations.keys), Set(SpeedOption.allCases), "every speed has a spoken title")
    }

    func testSleepOptionsMapToPlannerRequestsAndEveryOneHasATitle() {
        XCTAssertEqual(SleepTimerOption.off.request, .off)
        XCTAssertEqual(SleepTimerOption.thirty.request, .minutes(30))
        XCTAssertEqual(Set(SleepTimerOption.caseDisplayRepresentations.keys), Set(SleepTimerOption.allCases))
        XCTAssertEqual(SleepTimerOption.endOfEpisode.request, .endOfEpisode)
        for option in SleepTimerOption.allCases where option != .off && option != .endOfEpisode {
            let planned = VoiceCommandPlanner.plan(
                .sleepTimer(option.request), snapshot: VoiceSnapshot(downloaded: [], knownShowTitles: [], nowPlaying: nowPlaying()))
            XCTAssertEqual(planned.action, .startSleepTimer(minutes: option.rawValue), "\(option) must be a timer the planner accepts")
        }
    }

    // MARK: intent shells

    private func nowPlaying() -> VoiceNowPlaying {
        VoiceNowPlaying(
            episode: VoiceEpisode(id: try! ItemID(rawValue: "e1"), title: "Tide Pools", showTitle: "Short Wave"),
            isPlaying: true, canMarkCompleted: false, position: 0, duration: 1_800, rate: 1)
    }

    private func install() -> RecordingTarget {
        let target = RecordingTarget(snapshot: VoiceSnapshot(downloaded: [], knownShowTitles: [], nowPlaying: nowPlaying()))
        VoiceRuntime.provider = { target }
        return target
    }

    func testTimeLeftIntentSpeaksTheRemainingTime() async throws {
        let target = install()
        let result = try await TimeLeftIntent().perform()
        XCTAssertEqual(target.performed, [.none])
        XCTAssertTrue(String(describing: result).contains("About 30 minutes left."), "\(result)")
    }

    func testSetSpeedIntentSendsTheChosenRate() async throws {
        let target = install()
        let intent = SetSpeedIntent()
        intent.speed = .oneAndAHalf
        _ = try await intent.perform()
        XCTAssertEqual(target.performed, [.setSpeed(1.5)])
    }

    func testSleepTimerIntentStartsAndCancels() async throws {
        let target = install()
        let intent = SleepTimerIntent()
        intent.option = .fortyFive
        _ = try await intent.perform()
        intent.option = .off
        _ = try await intent.perform()
        XCTAssertEqual(target.performed, [.startSleepTimer(minutes: 45), .cancelSleepTimer])
    }

    // MARK: the real target

    private struct Rig {
        let target: LibraryVoiceTarget
        let player: LibraryPlayer
        let engine: VoiceFakeEngine
        let settings: LibrarySettingsStore
        let timer: SleepTimer
        let defaults: UserDefaults
    }

    private func makeRig(timer: SleepTimer = SleepTimer()) -> Rig {
        let defaults = UserDefaults(suiteName: suite)!
        let engine = VoiceFakeEngine()
        let player = LibraryPlayer(
            engine: engine, session: VoiceFakeSession(), nowPlaying: VoiceFakeNowPlaying(),
            remoteCommands: VoiceFakeRemote(), sessionEvents: VoiceFakeEvents(), tickInterval: .seconds(3600))
        let server = InMemoryLibraryServer(writerDeviceID: "mac")
        let model = LibraryAppModel(
            transport: InMemoryLibraryTransport(deviceID: "phone", server: server), deviceID: "phone",
            mediaCache: FileMediaCache(rootURL: scratch.appendingPathComponent("cache")),
            preferences: defaults, now: { Date(timeIntervalSince1970: 1_000) }, timeZone: TimeZone(identifier: "UTC")!)
        let settings = LibrarySettingsStore(defaults: defaults)
        model.attachPlayer(player)
        return Rig(
            target: LibraryVoiceTarget(model: model, player: player, settings: settings, sleepTimer: timer),
            player: player, engine: engine, settings: settings, timer: timer, defaults: defaults)
    }

    private func load(_ rig: Rig, autoplay: Bool = true) {
        let item = LibraryPlayer.Item(
            entryID: try! ItemID(rawValue: "e1"), title: "Tide Pools", showTitle: "Short Wave",
            fileURL: scratch.appendingPathComponent("a.m4a"))
        rig.player.start(item, at: 100, autoplay: autoplay)
    }

    func testSnapshotCarriesPositionDurationAndRateOfTheLoadedEpisode() async {
        let rig = makeRig()
        load(rig)
        rig.player.setRate(1.5)
        let playing = await rig.target.voiceSnapshot().nowPlaying
        XCTAssertEqual(playing?.position, 100)
        XCTAssertEqual(playing?.duration, 600)
        XCTAssertEqual(playing?.rate, 1.5)
        let snapshot = await rig.target.voiceSnapshot()
        let plan = VoiceCommandPlanner.plan(.timeLeft, snapshot: snapshot)
        XCTAssertEqual(plan.dialog, "About 6 minutes left.", "500 seconds at 1.5x is 333 seconds, 5.5 minutes rounded")
    }

    func testSetSpeedChangesTheLoadedEpisodeAndTheAppSetting() async {
        let rig = makeRig()
        load(rig)
        let outcome = await rig.target.perform(.setSpeed(1.5))
        XCTAssertEqual(outcome, .done)
        XCTAssertEqual(rig.player.rate, 1.5)
        XCTAssertEqual(rig.engine.rate, 1.5)
        XCTAssertEqual(rig.settings.defaultSpeed, 1.5)
        XCTAssertEqual(LibrarySettingsStore(defaults: rig.defaults).defaultSpeed, 1.5, "the speed survives a relaunch like the Settings one")
    }

    func testSetSpeedWithNothingLoadedStillSetsTheDefault() async {
        let rig = makeRig()
        let outcome = await rig.target.perform(.setSpeed(0.75))
        XCTAssertEqual(outcome, .done)
        XCTAssertEqual(rig.settings.defaultSpeed, 0.75)
        rig.player.apply(rig.settings.playback)
        load(rig)
        XCTAssertEqual(rig.player.rate, 0.75, "the next episode starts at the spoken speed")
    }

    func testSleepTimerPausesThePlayerWhenItExpires() async {
        let clockStart = ContinuousClock.now
        var current = clockStart
        let timer = SleepTimer(now: { current }, sleep: { current = current.advanced(by: $0) })
        let rig = makeRig(timer: timer)
        load(rig)
        XCTAssertTrue(rig.player.isPlaying)
        let started = await rig.target.perform(.startSleepTimer(minutes: 20))
        XCTAssertEqual(started, .done)
        XCTAssertTrue(timer.isActive)
        await timer.settle()
        XCTAssertFalse(rig.player.isPlaying, "the timer paused playback")
        XCTAssertEqual(rig.player.status, .paused)
    }

    func testCancelledSleepTimerLeavesPlaybackAlone() async {
        let rig = makeRig(timer: SleepTimer(now: { .now }, sleep: { _ in try? await Task.sleep(for: .seconds(3600)) }))
        load(rig)
        _ = await rig.target.perform(.startSleepTimer(minutes: 20))
        XCTAssertTrue(rig.timer.isActive)
        let cancelled = await rig.target.perform(.cancelSleepTimer)
        XCTAssertEqual(cancelled, .done)
        XCTAssertFalse(rig.timer.isActive)
        XCTAssertTrue(rig.player.isPlaying)
    }

    // MARK: end of episode

    func testEndOfEpisodeHoldsBackAutoContinueOnceAndTheTimerOffClearsIt() async {
        let rig = makeRig()
        var reports: [Bool] = []
        rig.player.onFinished = { _, autoPlayNext in reports.append(autoPlayNext) }
        load(rig)
        let armed = await rig.target.perform(.stopAfterEpisode)
        XCTAssertEqual(armed, .done)
        XCTAssertTrue(rig.player.stopsAfterCurrentItem)
        rig.engine.finishNaturally()
        await Task.yield()
        XCTAssertEqual(reports, [false], "the end is reported with auto-play off, so the next episode does not start")
        XCTAssertFalse(rig.player.stopsAfterCurrentItem, "used once")

        load(rig)
        rig.engine.finishNaturally()
        await Task.yield()
        XCTAssertEqual(reports, [false, true], "the next end auto-continues again")

        load(rig)
        _ = await rig.target.perform(.stopAfterEpisode)
        let off = await rig.target.perform(.cancelSleepTimer)
        XCTAssertEqual(off, .done)
        rig.engine.finishNaturally()
        await Task.yield()
        XCTAssertEqual(reports.last, true, "off cancels the end-of-episode stop")
    }

    func testMinutesAndStopReplaceEachOther() async {
        let rig = makeRig(timer: SleepTimer(now: { .now }, sleep: { _ in try? await Task.sleep(for: .seconds(3600)) }))
        load(rig)
        _ = await rig.target.perform(.stopAfterEpisode)
        _ = await rig.target.perform(.startSleepTimer(minutes: 10))
        XCTAssertFalse(rig.player.stopsAfterCurrentItem)
        XCTAssertTrue(rig.timer.isActive)
        _ = await rig.target.perform(.stopAfterEpisode)
        XCTAssertFalse(rig.timer.isActive)
        XCTAssertTrue(rig.player.stopsAfterCurrentItem)
        rig.player.stop()
        XCTAssertFalse(rig.player.stopsAfterCurrentItem, "stopping playback drops it")
    }

    func testEndOfEpisodeBelongsToTheEpisodeItWasSetOn() async {
        let rig = makeRig()
        load(rig)
        _ = await rig.target.perform(.stopAfterEpisode)
        let same = LibraryPlayer.Item(
            entryID: try! ItemID(rawValue: "e1"), title: "Tide Pools", showTitle: "Short Wave",
            fileURL: scratch.appendingPathComponent("a.m4a"))
        rig.player.start(same, at: 0)
        XCTAssertTrue(rig.player.stopsAfterCurrentItem, "restarting the same episode keeps it")
        let other = LibraryPlayer.Item(
            entryID: try! ItemID(rawValue: "e2"), title: "Chips", showTitle: "Planet Money",
            fileURL: scratch.appendingPathComponent("b.m4a"))
        rig.player.start(other, at: 0)
        XCTAssertFalse(rig.player.stopsAfterCurrentItem, "playing a different episode drops it")
    }
}
