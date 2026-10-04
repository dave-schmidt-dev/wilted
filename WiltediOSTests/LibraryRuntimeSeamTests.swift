import CryptoKit
import Foundation
import WiltedDomain
import WiltedLibrary
import WiltedListener
import XCTest
@testable import WiltediOS

/// An engine the system refuses to start, for the CarPlay failure path.
private final class RefusingEngine: ListenerAudioEngine, @unchecked Sendable {
    var duration = 600.0
    var currentTime = 0.0
    var isPlaying = false
    func load(url: URL) throws {}
    func load(url: URL, completionGeneration: UInt64) throws {}
    func play() -> Bool { false }
    func pause() {}
    func installCompletionHandler(_ handler: @escaping @Sendable (UInt64) -> Void) {}
}

/// The seams between the phone window scene, the CarPlay scene and Siri, which all share
/// `LibraryRuntime.shared`: one prepare, no early audio session, and a phone scene that coming
/// and going never stops what the car is playing.
@MainActor
final class LibraryRuntimeSeamTests: XCTestCase {
    private struct Rig {
        let runtime: LibraryRuntime
        let remote: RuntimeFakeRemote
        let session: RuntimeFakeSession
        let entryID: ItemID
        let gate: GatedMediaCache
    }

    @MainActor private final class CarCounts {
        var opened = 0
        var completions = 0
    }

    /// What one CarPlay row press did: its outcome, how often it opened Now Playing, the failures it
    /// presented, and how often it completed the template handler.
    private struct CarPress {
        var outcome: LibraryStartOutcome?
        var nowPlayingOpened = 0
        var failures: [LibraryStartFailure] = []
        var completions = 0
    }

    private var scratch: URL!

    override func setUp() async throws {
        scratch = FileManager.default.temporaryDirectory.appendingPathComponent("runtime-seams-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    override func tearDown() async throws { try? FileManager.default.removeItem(at: scratch) }

    /// A runtime over a library with one episode already downloaded and no network.
    private func makeRig(engine: any ListenerAudioEngine = RuntimeFakeEngine()) async throws -> Rig {
        let suite = "wilted.seams.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        let entryID = try ItemID(rawValue: "item-a")
        let server = InMemoryLibraryServer(writerDeviceID: "mac")
        let mac = InMemoryLibraryTransport(deviceID: "mac", server: server)
        let show = LibrarySource(id: try ItemID(rawValue: "show"), kind: .podcastFeed, title: "The Show")
        let entry = try LibraryEntry(
            id: entryID, kind: .podcastEpisode, sourceID: show.id, title: "Episode A", summary: "",
            publishedAt: Date(timeIntervalSince1970: 1_600_000_000), durationSeconds: 1_800)
        let changes: [LibraryChange] = [.source(show), .entry(entry), .slot(try QueueSlot(entryID: entryID, sortKey: 0))]
        _ = try await mac.push(changes: changes.enumerated().map {
            PendingLibraryChange(localSeq: UInt64($0.offset + 1), change: $0.element, baseVersion: 0)
        })
        let store = InMemoryLibraryStore()
        let cache = FileMediaCache(rootURL: scratch.appendingPathComponent("cache"))
        let online = LibraryAppModel(
            transport: InMemoryLibraryTransport(deviceID: "phone", server: server), store: store, deviceID: "phone",
            mediaCache: cache, preferences: defaults)
        await online.refresh()
        let payload = Data((0..<2_000).map { UInt8($0 % 251) })
        let file = scratch.appendingPathComponent("incoming.mp4")
        try payload.write(to: file)
        let hash = MediaHash.prefix + SHA256.hash(data: payload).map { String(format: "%02x", $0) }.joined()
        _ = try await cache.adopt(
            verifiedFile: file,
            for: try LibraryMediaOffer(
                entryID: entryID, revisionID: try RevisionID(rawValue: "rev-1"), contentHash: hash,
                byteCount: Int64(payload.count), mediaType: "audio/mp4", durationSeconds: 60))

        let remote = RuntimeFakeRemote(), session = RuntimeFakeSession()
        let player = LibraryPlayer(
            engine: engine, session: session, nowPlaying: RuntimeFakeNowPlaying(),
            remoteCommands: remote, sessionEvents: RuntimeFakeEvents(), tickInterval: .seconds(3600))
        let gate = GatedMediaCache(cache)
        let model = LibraryAppModel(
            transport: UnavailableLibraryTransport(reason: "no signal"), store: store, deviceID: "phone",
            mediaCache: gate, preferences: defaults)
        let runtime = LibraryRuntime(model: model, player: player, settings: LibrarySettingsStore(defaults: defaults))
        return Rig(runtime: runtime, remote: remote, session: session, entryID: entryID, gate: gate)
    }

    private func carRow(_ rig: Rig) throws -> CarEpisodeRow {
        let list = CarEpisodeList.make(model: rig.runtime.model, playingID: nil)
        guard case let .episodes(rows) = list.content, let row = rows.first else {
            throw XCTSkip("the car list is empty: \(list.content)")
        }
        return row
    }

    func testCarPlayOnlyLaunchListsAndPlaysWithoutAnyWindowScene() async throws {
        let rig = try await makeRig()
        let original = LibraryRuntime.shared
        LibraryRuntime.shared = rig.runtime
        addTeardownBlock { @MainActor in LibraryRuntime.shared = original }

        // What the CarPlay scene does on connect: take the shared runtime and prepare it. No LibraryRoot exists.
        await LibraryRuntime.shared.prepare()
        let row = try carRow(rig)
        XCTAssertEqual(row.id, rig.entryID)

        await rig.runtime.model.playCached(row.row)
        XCTAssertEqual(rig.runtime.player.status, .playing)
        XCTAssertEqual(rig.runtime.player.item?.entryID, rig.entryID)
    }

    func testPrepareAndStartNeverActivateTheAudioSessionOnlyPlayDoes() async throws {
        let rig = try await makeRig()
        await rig.runtime.prepare()
        await rig.runtime.start()
        XCTAssertEqual(rig.session.activations, 0, "connecting a scene must not take the audio session from the car's radio")

        await rig.runtime.model.playCached(try carRow(rig).row)
        XCTAssertEqual(rig.session.activations, 1)
    }

    func testPhoneSceneGoingToBackgroundDoesNotStopCarPlayPlayback() async throws {
        let rig = try await makeRig()
        await rig.runtime.prepare()
        await rig.runtime.model.playCached(try carRow(rig).row)
        XCTAssertEqual(rig.runtime.player.status, .playing)

        // What the phone's window scene does when it is backgrounded or goes away.
        await rig.runtime.model.sceneEnteredBackground()
        XCTAssertEqual(rig.runtime.player.status, .playing)
        XCTAssertEqual(rig.runtime.player.item?.entryID, rig.entryID)
    }

    func testConcurrentScenesShareASinglePrepare() async throws {
        let rig = try await makeRig()
        let runtime = rig.runtime
        let callers = (0..<4).map { index in
            Task { @MainActor in
                if index.isMultiple(of: 2) { await runtime.prepare() } else { await runtime.start() }
            }
        }
        for caller in callers { await caller.value }
        // One prepare applies the settings once; a second would apply them again and double-subscribe.
        XCTAssertEqual(rig.remote.skipCalls, 1)
        runtime.settings.skipBackSeconds = 45
        for _ in 0..<100 where rig.remote.skipCalls < 2 { try await Task.sleep(for: .milliseconds(10)) }
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(rig.remote.skipCalls, 2, "one settings change must reach the player exactly once")
    }

    // MARK: CarPlay start ownership (Task 3.2)

    /// What `CarPlaySceneDelegate` does for a row press, with the template effects counted.
    private func pressCarRow(_ rig: Rig) async throws -> CarPress {
        let row = try carRow(rig)
        var press = CarPress()
        press.outcome = await CarRowSelection.run(
            row.row, model: rig.runtime.model, openNowPlaying: { press.nowPlayingOpened += 1 },
            presentFailure: { press.failures.append($0) }, completion: { press.completions += 1 })
        return press
    }

    /// Prototype: "CARPLAY failed and superseded callbacks do not open Now Playing" (failed half).
    func testCarPlayFailureDoesNotOpenNowPlayingAndCompletesOnce() async throws {
        let rig = try await makeRig(engine: RefusingEngine())
        await rig.runtime.prepare()
        let press = try await pressCarRow(rig)
        XCTAssertEqual(press.outcome, .failed(.engineRefused))
        XCTAssertEqual(press.nowPlayingOpened, 0)
        XCTAssertEqual(press.failures, [.engineRefused], "the failure is presented once, with Retry")
        XCTAssertEqual(press.completions, 1)
    }

    /// Prototype: "CARPLAY failed and superseded callbacks do not open Now Playing" (superseded half).
    func testCarPlaySupersededSelectionCompletesOnceWithoutOpeningNowPlaying() async throws {
        let rig = try await makeRig()
        await rig.runtime.prepare()
        // Let the prepare's own background lookups finish, so the armed hold is the press's.
        for _ in 0..<20 { await Task.yield() }
        try await Task.sleep(for: .milliseconds(100))
        let row = try carRow(rig)
        let counts = CarCounts()
        await rig.gate.arm()
        let press = Task { @MainActor in
            await CarRowSelection.run(
                row.row, model: rig.runtime.model, openNowPlaying: { counts.opened += 1 },
                presentFailure: { _ in XCTFail("a superseded press is not a failure") },
                completion: { counts.completions += 1 })
        }
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while await !rig.gate.isHeld, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        rig.runtime.player.pause()   // the system Pause while the row's file is looked up
        await rig.gate.release()

        let outcome = await press.value
        XCTAssertEqual(outcome, .superseded)
        XCTAssertEqual(counts.opened, 0)
        XCTAssertEqual(counts.completions, 1)
        XCTAssertFalse(rig.runtime.player.isPlaying, "the superseded press never starts the episode")
    }

    /// Prototype CARPLAY: the paused current row resumes and opens Now Playing.
    func testCarPlayPausedCurrentRowResumesAndOpensNowPlaying() async throws {
        let rig = try await makeRig()
        await rig.runtime.prepare()
        await rig.runtime.model.playCached(try carRow(rig).row)
        rig.runtime.player.pause()
        XCTAssertEqual(rig.runtime.player.status, .paused)

        let press = try await pressCarRow(rig)
        XCTAssertEqual(press.outcome, .resumed)
        XCTAssertEqual(press.nowPlayingOpened, 1)
        XCTAssertEqual(press.completions, 1)
        XCTAssertEqual(rig.runtime.player.status, .playing)
    }

    /// Prototype CARPLAY: pressing the playing current row opens Now Playing and never pauses it.
    func testCarPlayActiveCurrentRowOpensNowPlayingWithoutPausing() async throws {
        let rig = try await makeRig()
        await rig.runtime.prepare()
        let first = try await pressCarRow(rig)
        let again = try await pressCarRow(rig)
        XCTAssertEqual([first.outcome, again.outcome], [.started, .alreadyPlaying])
        XCTAssertEqual(first.nowPlayingOpened + again.nowPlayingOpened, 2)
        XCTAssertEqual(first.completions + again.completions, 2, "each press completes its handler once")
        XCTAssertEqual(rig.runtime.player.status, .playing, "a row press is a select, not a toggle")
    }

    #if DEBUG
    /// Positive control for the LibraryRoot fixture's live-transport spy: the live construction path
    /// (`LibraryEnvironment.makeModel`) moves the very count the UI tests assert stays 0.
    func testTheLiveModelConstructionIsWhatTheFixtureSpyCounts() throws {
        let defaults = UserDefaults.standard
        let key = LibraryEnvironment.deviceIDKey
        let saved = defaults.string(forKey: key)
        defer { if let saved { defaults.set(saved, forKey: key) } else { defaults.removeObject(forKey: key) } }
        defaults.removeObject(forKey: key)
        XCTAssertEqual(LibraryUITestFixture.liveTransportConstructions, 0)

        _ = LibraryEnvironment.makeModel(directory: scratch.appendingPathComponent("live"), isLiveAllowed: false)
        XCTAssertEqual(LibraryUITestFixture.liveTransportConstructions, 1, "the spy can read a live construction")
    }
    #endif
}
