import Foundation
import WiltedDomain
import WiltedLibrary
import WiltedPlayback
import XCTest
@testable import WiltediOS

final class RuntimeFakeEngine: ListenerAudioEngine, @unchecked Sendable {
    var duration = 600.0
    var currentTime = 0.0
    var isPlaying = false
    func load(url: URL) throws {}
    func load(url: URL, completionGeneration: UInt64) throws {}
    func play() -> Bool { isPlaying = true; return true }
    func pause() { isPlaying = false }
    func installCompletionHandler(_ handler: @escaping @Sendable (UInt64) -> Void) {}
}

final class RuntimeFakeSession: ListenerAudioSession, @unchecked Sendable {
    private(set) var activations = 0
    func activate() throws { activations += 1 }
    func deactivate() {}
}

final class RuntimeFakeNowPlaying: ListenerNowPlaying, @unchecked Sendable {
    func update(title: String, duration: Double, position: Double, rate: Double) {}
    func clear() {}
}

@MainActor final class RuntimeFakeRemote: LibraryRemoteCommands {
    private(set) var skipIntervals: (back: TimeInterval, forward: TimeInterval)?
    private(set) var skipCalls = 0
    func install(handler: @escaping @MainActor (LibraryRemoteCommand) -> Bool) {}
    func uninstall() {}
    func setSkipIntervals(back: TimeInterval, forward: TimeInterval) { skipIntervals = (back, forward); skipCalls += 1 }
}

@MainActor final class RuntimeFakeEvents: LibrarySessionEvents {
    func observe(_ handler: @escaping @MainActor (LibrarySessionEvent) -> Void) {}
}

@MainActor
final class LibraryRuntimeTests: XCTestCase {
    private struct Rig {
        let runtime: LibraryRuntime
        let remote: RuntimeFakeRemote
        let session: RuntimeFakeSession
        let defaults: UserDefaults
    }

    private let item = LibraryPlayer.Item(
        entryID: try! ItemID(rawValue: "entry-1"), title: "Episode", showTitle: "Show",
        fileURL: URL(fileURLWithPath: "/nonexistent/wilted-runtime-test.mp3"))

    private func makeRig() -> Rig {
        let suite = "wilted.runtime.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        let remote = RuntimeFakeRemote(), session = RuntimeFakeSession()
        let player = LibraryPlayer(
            engine: RuntimeFakeEngine(), session: session, nowPlaying: RuntimeFakeNowPlaying(),
            remoteCommands: remote, sessionEvents: RuntimeFakeEvents(), tickInterval: .seconds(3600))
        let model = LibraryAppModel(
            transport: UnavailableLibraryTransport(reason: "test"), deviceID: "phone", preferences: defaults)
        let runtime = LibraryRuntime(model: model, player: player, settings: LibrarySettingsStore(defaults: defaults))
        return Rig(runtime: runtime, remote: remote, session: session, defaults: defaults)
    }

    private func waitUntil(_ condition: @escaping @MainActor () -> Bool, file: StaticString = #filePath, line: UInt = #line) async {
        for _ in 0..<200 where !condition() { try? await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(condition(), file: file, line: line)
    }

    func testStartWiresPlayerToModelWithoutAnyScene() async {
        let rig = makeRig()
        XCTAssertNil(rig.runtime.player.onListened)
        await rig.runtime.start()
        XCTAssertNotNil(rig.runtime.player.onListened, "the model drives the player's listening stats once started")
    }

    func testPrepareWiresThePlayerWithoutWaitingForTheSync() async {
        let rig = makeRig()
        await rig.runtime.prepare()
        XCTAssertNotNil(rig.runtime.player.onListened)
        XCTAssertNil(rig.runtime.model.lastSynchronizedAt, "prepare must not run the network sync")
        await rig.runtime.prepare()
    }

    func testStartAppliesSettingsAndFollowsChanges() async {
        let rig = makeRig()
        await rig.runtime.start()
        XCTAssertEqual(rig.remote.skipIntervals?.back, TimeInterval(LibrarySettingsStore.defaultSkipBack))
        rig.runtime.settings.skipBackSeconds = 45
        await waitUntil { rig.remote.skipIntervals?.back == 45 }
    }

    func testStartIsSharedBetweenCallers() async {
        let rig = makeRig()
        let runtime = rig.runtime
        let first = Task { @MainActor in await runtime.start() }
        let second = Task { @MainActor in await runtime.start() }
        await first.value
        await second.value
        await rig.runtime.start()
        XCTAssertNotNil(rig.runtime.player.onListened)
    }

    func testPlayerStopsWhenItsFileLeavesThePhone() async {
        let rig = makeRig()
        await rig.runtime.start()
        rig.runtime.model.media[item.entryID] = .onPhone
        XCTAssertTrue(rig.runtime.player.start(item))
        rig.runtime.model.media[item.entryID] = .available
        await waitUntil { rig.runtime.player.status != .playing }
        XCTAssertNil(rig.runtime.player.item)
    }

    func testSharedIsReplaceableAndStable() {
        let rig = makeRig()
        let original = LibraryRuntime.shared
        LibraryRuntime.shared = rig.runtime
        addTeardownBlock { @MainActor in LibraryRuntime.shared = original }
        XCTAssertTrue(LibraryRuntime.shared === rig.runtime)
        XCTAssertTrue(LibraryRuntime.shared.player === LibraryRuntime.shared.player)
    }
}
