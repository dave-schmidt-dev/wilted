import CryptoKit
import Foundation
import WiltedDomain
import WiltedLibrary
import WiltedPlayback
import XCTest
@testable import WiltediOS

/// An engine whose loads can be made to fail, to prove a load failure keeps the system handlers.
private final class LaunchFakeEngine: ListenerAudioEngine, @unchecked Sendable {
    struct LoadError: Error {}
    var failsLoads = false
    var duration = 600.0
    var currentTime = 0.0
    var isPlaying = false
    func load(url: URL) throws { if failsLoads { throw LoadError() } }
    func play() -> Bool { isPlaying = true; return true }
    func pause() { isPlaying = false }
}

/// The system transport commands as a car or Bluetooth device sends them. iOS relaunches a killed app in
/// the background for such a command and drops it unless a handler is registered by then, so these tests
/// drive the handler the player registered, over a real runtime, library and cache, with no window scene.
@MainActor
final class LibraryRemoteCommandLaunchTests: XCTestCase {
    @MainActor private struct Rig {
        let runtime: LibraryRuntime
        let remote: RuntimeFakeRemote
        let session: RuntimeFakeSession
        let engine: LaunchFakeEngine
        var player: LibraryPlayer { runtime.player }
        var model: LibraryAppModel { runtime.model }
    }

    private var scratch: URL!
    private let payload = Data((0..<2_000).map { UInt8($0 % 251) })

    override func setUp() async throws {
        scratch = FileManager.default.temporaryDirectory.appendingPathComponent("remote-launch-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    override func tearDown() async throws { try? FileManager.default.removeItem(at: scratch) }

    private func id(_ raw: String) -> ItemID { try! ItemID(rawValue: raw) }

    /// A runtime over a library persisted on disk, with audio cached for the `onPhone` episodes. Episodes
    /// are published one second apart in `queued` order. The runtime is built but not prepared.
    private func makeRig(queued: [String], onPhone: Set<String>) async throws -> Rig {
        let suite = "wilted.remote.launch.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }

        let server = InMemoryLibraryServer(writerDeviceID: "mac")
        let mac = InMemoryLibraryTransport(deviceID: "mac", server: server, verifiedOwnerToken: "fixture-owner")
        let show = LibrarySource(id: id("show"), kind: .podcastFeed, title: "The Show")
        var changes: [LibraryChange] = [.source(show)]
        for (index, raw) in queued.enumerated() {
            changes.append(.entry(try LibraryEntry(
                id: id(raw), kind: .podcastEpisode, sourceID: show.id, title: "Episode \(raw)", summary: "",
                publishedAt: Date(timeIntervalSince1970: 1_600_000_000 + Double(index)), durationSeconds: 1_800)))
            changes.append(.slot(try QueueSlot(entryID: id(raw), sortKey: Double(index))))
        }
        _ = try await mac.push(changes: changes.enumerated().map {
            PendingLibraryChange(localSeq: UInt64($0.offset + 1), change: $0.element, baseVersion: 0)
        })

        let storeURL = scratch.appendingPathComponent("state/library-state.json")
        let cache = FileMediaCache(rootURL: scratch.appendingPathComponent("cache"))
        let online = LibraryAppModel(
            transport: InMemoryLibraryTransport(deviceID: "phone", server: server, verifiedOwnerToken: "fixture-owner"),
            store: FileLibraryStore(url: storeURL), deviceID: "phone", mediaCache: cache, preferences: defaults)
        await online.refresh()
        for raw in onPhone { try await adopt(raw, into: cache) }

        let remote = RuntimeFakeRemote(), session = RuntimeFakeSession(), engine = LaunchFakeEngine()
        let player = LibraryPlayer(
            engine: engine, session: session, nowPlaying: RuntimeFakeNowPlaying(), remoteCommands: remote,
            sessionEvents: RuntimeFakeEvents(), tickInterval: .seconds(3600))
        let model = LibraryAppModel(
            transport: UnavailableLibraryTransport(reason: "no signal"), store: FileLibraryStore(url: storeURL),
            deviceID: "phone", mediaCache: cache, preferences: defaults)
        let runtime = LibraryRuntime(
            model: model, player: player, settings: LibrarySettingsStore(defaults: defaults),
            pushHandler: RuntimeFakePushHandler())
        return Rig(runtime: runtime, remote: remote, session: session, engine: engine)
    }

    private func adopt(_ raw: String, into cache: FileMediaCache) async throws {
        let incoming = scratch.appendingPathComponent("incoming-\(raw).mp4")
        try payload.write(to: incoming)
        let hash = MediaHash.prefix + SHA256.hash(data: payload).map { String(format: "%02x", $0) }.joined()
        _ = try await PreparedMediaFixture.adopt(into: cache, verifiedFile: incoming,
            for: try PreparedMediaFixture.certified(LibraryMediaOffer(
                entryID: id(raw), revisionID: try RevisionID(rawValue: "rev-\(raw)"), contentHash: hash,
                byteCount: Int64(payload.count), mediaType: "audio/mp4", durationSeconds: 60)), owner: "fixture-owner")
    }

    /// A position saved for `raw` at `seconds` on the server clock, as the Mac's checkpoint would be.
    private func seed(_ raw: String, position: Double, at seconds: TimeInterval, in model: LibraryAppModel) throws {
        model.handoffState.ownPositions[id(raw)] = ObservedPlayback(
            record: try DevicePlaybackPosition(
                deviceID: "mac", entryID: id(raw), revision: try RevisionID(rawValue: "rev-\(raw)"),
                positionSeconds: position, isPlaying: false, epoch: 1),
            serverModifiedAt: Date(timeIntervalSince1970: seconds))
        model.refreshProgress()
    }

    private func loadedItem(_ raw: String, _ rig: Rig) async throws -> LibraryPlayer.Item {
        let entries = await rig.model.mediaCache.cachedEntries()
        let cached = try XCTUnwrap(entries[id(raw)])
        return LibraryPlayer.Item(entryID: id(raw), title: "Episode \(raw)", showTitle: "The Show", fileURL: cached.url)
    }

    private func waitUntil(_ condition: @escaping @MainActor () -> Bool, file: StaticString = #filePath, line: UInt = #line) async {
        for _ in 0..<500 where !condition() { try? await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(condition(), file: file, line: line)
    }

    private func handler(_ rig: Rig, file: StaticString = #filePath, line: UInt = #line) throws -> @MainActor (LibraryRemoteCommand) -> Bool {
        try XCTUnwrap(rig.remote.handler, "the system command handlers must be registered", file: file, line: line)
    }

    // MARK: Registered at launch, kept with nothing loaded

    func testBootstrapRegistersHandlersBeforeAnythingLoads() async throws {
        let rig = try await makeRig(queued: ["a"], onPhone: ["a"])
        XCTAssertNil(rig.remote.handler)

        rig.runtime.bootstrapBackgroundEntryPoints()

        _ = try handler(rig)
        XCTAssertNil(rig.player.item)
        XCTAssertFalse(rig.model.localStateLoaded, "registering handlers loads nothing")
        XCTAssertEqual(rig.session.activations, 0, "registering handlers never takes the audio session")
    }

    func testPrepareRegistersHandlersWithNothingLoaded() async throws {
        let rig = try await makeRig(queued: ["a"], onPhone: ["a"])

        await rig.runtime.prepare()

        _ = try handler(rig)
        XCTAssertNil(rig.player.item, "prepare never loads an episode on its own")
        XCTAssertEqual(rig.session.activations, 0)
    }

    func testBootstrapThenPrepareKeepsTheLaunchTimeHandler() async throws {
        let rig = try await makeRig(queued: ["a"], onPhone: ["a"])
        rig.runtime.bootstrapBackgroundEntryPoints()
        let first = try handler(rig)

        await rig.runtime.prepare()
        rig.runtime.bootstrapBackgroundEntryPoints()
        let item = try await loadedItem("a", rig)
        XCTAssertTrue(rig.player.remoteCommandsInstalled)
        // The handler is the one registered at launch: loading an episode does not replace it.
        XCTAssertTrue(rig.player.start(item))
        XCTAssertTrue(first(.pause), "the launch-time handler still drives the loaded episode")
        XCTAssertEqual(rig.player.status, .paused)
    }

    func testStopAndInvalidationLeaveHandlersRegistered() async throws {
        let rig = try await makeRig(queued: ["a"], onPhone: ["a"])
        await rig.runtime.prepare()
        let item = try await loadedItem("a", rig)

        XCTAssertTrue(rig.player.start(item))
        rig.player.stop()
        XCTAssertNil(rig.player.item)
        _ = try handler(rig)

        XCTAssertTrue(rig.player.start(item))
        rig.player.invalidateLoadedItem()
        XCTAssertNil(rig.player.item)
        _ = try handler(rig)
    }

    func testLoadFailureLeavesHandlersRegistered() async throws {
        let rig = try await makeRig(queued: ["a"], onPhone: ["a"])
        await rig.runtime.prepare()
        let item = try await loadedItem("a", rig)
        rig.engine.failsLoads = true

        XCTAssertFalse(rig.player.start(item))

        XCTAssertNil(rig.player.item)
        XCTAssertEqual(rig.player.status, .failed(LibraryStartFailure.unreadableFile.playerReason))
        _ = try handler(rig)
    }

    // MARK: Play with nothing loaded resumes from the library

    func testIdlePlayResumesTheNewestInProgressOnPhoneEpisode() async throws {
        let rig = try await makeRig(queued: ["a", "b", "c", "d"], onPhone: ["a", "b", "c"])
        await rig.runtime.prepare()
        try seed("a", position: 100, at: 1_000, in: rig.model)
        try seed("b", position: 200, at: 2_000, in: rig.model)
        // The newest play of all is an episode that is not on the phone: it is not an option.
        try seed("d", position: 300, at: 3_000, in: rig.model)

        XCTAssertTrue(try handler(rig)(.play))
        await waitUntil { rig.player.isPlaying }

        XCTAssertEqual(rig.player.item?.entryID, id("b"))
        XCTAssertEqual(rig.player.position, 200, accuracy: 0.001, "it resumes where that episode was left")
        XCTAssertEqual(rig.session.activations, 1)
    }

    func testIdlePlayWithNothingInProgressStartsTheFirstOnPhoneEpisodeInPlayOrder() async throws {
        let rig = try await makeRig(queued: ["a", "b", "c"], onPhone: ["b", "c"])
        await rig.runtime.prepare()

        XCTAssertTrue(try handler(rig)(.play))
        await waitUntil { rig.player.isPlaying }

        XCTAssertEqual(rig.player.item?.entryID, id("b"), "a is not on the phone; b is the oldest published that is")
        XCTAssertEqual(rig.player.position, 0)
    }

    func testIdlePlaySkipsCompletedEpisodes() async throws {
        let rig = try await makeRig(queued: ["a", "b"], onPhone: ["a", "b"])
        await rig.runtime.prepare()
        try seed("a", position: 1_800, at: 1_000, in: rig.model)
        XCTAssertNotNil(rig.model.finished[id("a")], "a was played to its end")

        XCTAssertTrue(try handler(rig)(.play))
        await waitUntil { rig.player.isPlaying }

        XCTAssertEqual(rig.player.item?.entryID, id("b"))
    }

    func testIdleTogglePlayPauseResumesLikePlay() async throws {
        let rig = try await makeRig(queued: ["a", "b"], onPhone: ["a", "b"])
        await rig.runtime.prepare()
        try seed("b", position: 50, at: 1_000, in: rig.model)

        XCTAssertTrue(try handler(rig)(.togglePlayPause))
        await waitUntil { rig.player.isPlaying }

        XCTAssertEqual(rig.player.item?.entryID, id("b"))
    }

    func testIdlePlayFailsWhenNothingIsOnThePhone() async throws {
        let rig = try await makeRig(queued: ["a", "b"], onPhone: [])
        await rig.runtime.prepare()

        XCTAssertFalse(try handler(rig)(.play))
        XCTAssertFalse(try handler(rig)(.togglePlayPause))
        await settleOnClock(.milliseconds(50))

        XCTAssertNil(rig.player.item)
        XCTAssertEqual(rig.session.activations, 0)
    }

    func testIdlePlayFailsWhenEveryOnPhoneEpisodeIsCompleted() async throws {
        let rig = try await makeRig(queued: ["a", "b"], onPhone: ["a", "b"])
        await rig.runtime.prepare()
        try seed("a", position: 1_800, at: 1_000, in: rig.model)
        try seed("b", position: 1_800, at: 2_000, in: rig.model)

        XCTAssertFalse(try handler(rig)(.play), "a finished episode is never restarted from the car")
        await settleOnClock(.milliseconds(50))

        XCTAssertNil(rig.player.item)
        XCTAssertEqual(rig.session.activations, 0)
    }

    func testPlayBeforeTheLibraryLoadsWaitsForPrepareThenResumes() async throws {
        let rig = try await makeRig(queued: ["a", "b"], onPhone: ["a", "b"])
        rig.runtime.bootstrapBackgroundEntryPoints()
        XCTAssertFalse(rig.model.localStateLoaded, "a background launch for this command has loaded nothing yet")

        XCTAssertTrue(try handler(rig)(.play), "the handler answers at once; the resume finishes later")
        await waitUntil { rig.player.isPlaying }

        XCTAssertTrue(rig.model.localStateLoaded)
        XCTAssertEqual(rig.player.item?.entryID, id("a"))
    }

    func testPlayBeforeTheLibraryLoadsWithNothingOnThePhoneStartsNothing() async throws {
        let rig = try await makeRig(queued: ["a"], onPhone: [])
        rig.runtime.bootstrapBackgroundEntryPoints()

        XCTAssertTrue(try handler(rig)(.play))
        await waitUntil { rig.model.localStateLoaded }
        await settleOnClock(.milliseconds(50))

        XCTAssertNil(rig.player.item)
        XCTAssertEqual(rig.session.activations, 0)
    }

    func testTwoPressesBeforeTheEpisodeLoadsStartItOnce() async throws {
        let rig = try await makeRig(queued: ["a", "b"], onPhone: ["a", "b"])
        await rig.runtime.prepare()
        let send = try handler(rig)

        XCTAssertTrue(send(.play))
        XCTAssertTrue(send(.play))
        await waitUntil { rig.player.isPlaying }
        await settleOnClock(.milliseconds(50))

        XCTAssertEqual(rig.player.item?.entryID, id("a"))
        XCTAssertTrue(rig.player.isPlaying)
        XCTAssertEqual(rig.session.activations, 1)
    }

    // MARK: Commands that need a loaded episode

    func testCommandsThatNeedAnEpisodeFailWithNothingLoaded() async throws {
        let rig = try await makeRig(queued: ["a"], onPhone: ["a"])
        await rig.runtime.prepare()
        let send = try handler(rig)

        XCTAssertFalse(send(.pause))
        XCTAssertFalse(send(.skipForward(30)))
        XCTAssertFalse(send(.skipBackward(15)))
        XCTAssertFalse(send(.seek(to: 60)))
        XCTAssertFalse(send(.setRate(1.5)))
        XCTAssertFalse(send(.beginSeeking(.forward)))
        XCTAssertFalse(send(.endSeeking(.forward)))
        await settleOnClock(.milliseconds(50))

        XCTAssertNil(rig.player.item, "none of them may start an episode")
        XCTAssertEqual(rig.session.activations, 0)
    }

    func testLoadedEpisodeCommandsStillDriveTheTransport() async throws {
        let rig = try await makeRig(queued: ["a"], onPhone: ["a"])
        await rig.runtime.prepare()
        let item = try await loadedItem("a", rig)
        XCTAssertTrue(rig.player.start(item, at: 100))
        let send = try handler(rig)

        XCTAssertTrue(send(.pause))
        XCTAssertEqual(rig.player.status, .paused)
        XCTAssertTrue(send(.skipForward(30)))
        XCTAssertEqual(rig.player.position, 130)
        XCTAssertTrue(send(.skipBackward(15)))
        XCTAssertEqual(rig.player.position, 115)
        XCTAssertTrue(send(.seek(to: 500)))
        XCTAssertEqual(rig.player.position, 500)
        XCTAssertTrue(send(.play))
        await waitUntil { rig.player.isPlaying }
        XCTAssertTrue(send(.togglePlayPause))
        XCTAssertEqual(rig.player.status, .paused)
    }
}
