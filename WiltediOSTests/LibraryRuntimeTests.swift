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
    private(set) var clears = 0
    func clear() { clears += 1 }
}

@MainActor final class RuntimeFakeRemote: LibraryRemoteCommands {
    private(set) var skipIntervals: (back: TimeInterval, forward: TimeInterval)?
    private(set) var skipCalls = 0
    private(set) var handler: (@MainActor (LibraryRemoteCommand) -> Bool)?
    func install(handler: @escaping @MainActor (LibraryRemoteCommand) -> Bool) { self.handler = handler }
    func uninstall() { handler = nil }
    func setSkipIntervals(back: TimeInterval, forward: TimeInterval) { skipIntervals = (back, forward); skipCalls += 1 }
}

@MainActor final class RuntimeFakeEvents: LibrarySessionEvents {
    func observe(_ handler: @escaping @MainActor (LibrarySessionEvent) -> Void) {}
}

@MainActor final class RuntimeHeldWatchSession: WatchSessionProtocol {
    let isSupported = true
    var activationState: WatchSessionActivationState = .notActivated
    let isPaired = true
    let isWatchAppInstalled = true
    weak var delegate: (any WatchSessionDelegate)?
    var contexts: [[String: Any]] = []
    func activate() {
        activationState = .activated
        delegate?.watchSessionDidActivate()
    }
    func updateApplicationContext(_ context: [String: Any]) throws { contexts.append(context) }
}

@MainActor
final class LibraryRuntimeTests: XCTestCase {
    private struct Rig {
        let runtime: LibraryRuntime
        let remote: RuntimeFakeRemote
        let session: RuntimeFakeSession
        let defaults: UserDefaults
        let nowPlaying: RuntimeFakeNowPlaying
    }

    private var localFile = URL(fileURLWithPath: "/nonexistent/wilted-runtime-test.mp3")
    private var item: LibraryPlayer.Item { LibraryPlayer.Item(
        entryID: try! ItemID(rawValue: "entry-1"), title: "Episode", showTitle: "Show",
        fileURL: localFile) }

    private func makeRig() async -> Rig {
        let suite = "wilted.runtime.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        let remote = RuntimeFakeRemote(), session = RuntimeFakeSession()
        let nowPlaying = RuntimeFakeNowPlaying()
        let player = LibraryPlayer(
            engine: RuntimeFakeEngine(), session: session, nowPlaying: nowPlaying,
            remoteCommands: remote, sessionEvents: RuntimeFakeEvents(), tickInterval: .seconds(3600))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("runtime-audio-\(UUID())")
        let bytes = Data([1, 2, 3, 4])
        let incoming = root.appendingPathComponent("incoming")
        try! FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try! bytes.write(to: incoming)
        let hash = try! MediaHash.sha256(fileAt: incoming)
        let server = InMemoryLibraryServer(writerDeviceID: "fixture-mac")
        let mac = InMemoryLibraryTransport(deviceID: "fixture-mac", server: server, verifiedOwnerToken: "fixture-owner")
        let showID = try! ItemID(rawValue: "show")
        let acceptedEntry = try! LibraryEntry(id: item.entryID, kind: .podcastEpisode, sourceID: showID,
            title: item.title, summary: "", publishedAt: Date(timeIntervalSince1970: 1_000), durationSeconds: 600)
        _ = try! await mac.push(changes: [
            PendingLibraryChange(localSeq: 1, change: .source(LibrarySource(id: showID, kind: .podcastFeed, title: "Show")), baseVersion: 0),
            PendingLibraryChange(localSeq: 2, change: .entry(acceptedEntry), baseVersion: 0),
            PendingLibraryChange(localSeq: 3, change: .slot(try! QueueSlot(entryID: item.entryID, sortKey: 0)), baseVersion: 0)])
        let phone = InMemoryLibraryTransport(deviceID: "fixture-phone", server: server, verifiedOwnerToken: "fixture-owner")
        let store = FileLibraryStore(url: root.appendingPathComponent("library-state.json"))
        try! await PreparedMediaFixture.bootstrap(store, transport: phone)
        let cache = FileMediaCache(rootURL: root)
        let offer = try! PreparedMediaFixture.certified(LibraryMediaOffer(
            entryID: item.entryID, revisionID: RevisionID(rawValue: "rev-1"), contentHash: hash,
            byteCount: Int64(bytes.count), mediaType: "audio/mp4", durationSeconds: 600))
        localFile = try! await PreparedMediaFixture.adopt(into: cache, verifiedFile: incoming, for: offer, owner: "fixture-owner")
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let model = LibraryAppModel(
            transport: UnavailableLibraryTransport(reason: "test"), store: store, deviceID: "phone",
            mediaCache: cache, preferences: defaults)
        let runtime = LibraryRuntime(model: model, player: player, settings: LibrarySettingsStore(defaults: defaults))
        return Rig(runtime: runtime, remote: remote, session: session, defaults: defaults, nowPlaying: nowPlaying)
    }

    private func waitUntil(_ condition: @escaping @MainActor () -> Bool, file: StaticString = #filePath, line: UInt = #line) async {
        for _ in 0..<200 where !condition() { try? await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(condition(), file: file, line: line)
    }

    func testRawWatchHoldBeginsOnActuallyAdmittedLoadedPlayer() async throws {
        let rig = try await preparedQueuedRig()
        let player = rig.runtime.player, model = rig.runtime.model
        defer { player.stop() }
        let cachedEntries = await model.mediaCache.cachedEntries()
        let cached = try XCTUnwrap(cachedEntries[item.entryID])
        XCTAssertEqual(cached.url, player.item?.fileURL)
        XCTAssertEqual(try Data(contentsOf: cached.url), Data([1, 2, 3, 4]))
        let verified = await model.mediaCache.verifies(cached)
        XCTAssertTrue(verified, "the actual owner-bound prepared cache admits these exact bytes")
        let target = LibraryVoiceTarget(model: model, player: player, settings: rig.runtime.settings)
        player.pause()
        let resumed = await target.perform(.resume)
        XCTAssertEqual(resumed, .done)
        XCTAssertTrue(player.isPlaying, "the production target actually resumed this admitted loaded item")
        player.seek(to: 100)
        let forward = await target.perform(.skipForward)
        XCTAssertEqual(forward, .done)
        XCTAssertEqual(player.position, 130)
        let backward = await target.perform(.skipBack)
        XCTAssertEqual(backward, .done)
        XCTAssertEqual(player.position, 115)

        let session = RuntimeHeldWatchSession()
        let bridge = WatchBridge(session: session, target: target,
            source: LibraryWatchSource(model: model, player: player))
        bridge.start()
        await bridge.settlePendingPublish()
        let context = try XCTUnwrap(session.contexts.last)
        let snapshotData = try XCTUnwrap(context[WatchLinkCodec.snapshotKey] as? Data)
        let snapshot = try XCTUnwrap(JSONSerialization.jsonObject(with: snapshotData) as? [String: Any])
        let playing = try XCTUnwrap(snapshot["nowPlaying"] as? [String: Any])
        XCTAssertEqual(playing["episodeID"] as? String, item.entryID.rawValue)
        // These explicitly unsupported baseline fences are rejected wire inputs, not cache permission.
        // Once the additive fields ship, this same request echoes the real encoded source fences.
        let controlSessionID = snapshot["controlSessionID"] as? String
            ?? "00000000-0000-4000-8000-000000000001"
        let seekSessionID = playing["seekSessionID"] as? String
            ?? "unsupported-before-watch-seek-capability"
        let request = try JSONSerialization.data(withJSONObject: [
            "version": 1,
            "action": ["type": "seek", "phase": "begin", "direction": "forward",
                       "holdID": UUID().uuidString, "episodeID": item.entryID.rawValue,
                       "controlSessionID": controlSessionID, "seekSessionID": seekSessionID]
        ])
        var reply: [String: Any] = [:]
        bridge.watchSessionDidReceiveMessage([WatchLinkCodec.commandKey: request]) { reply = $0 }
        await waitUntil { !reply.isEmpty }
        await player.admissionTask?.value
        print("watch.hold.raw.reply ok=\(String(describing: reply[WatchBridge.okKey])) reason=\(String(describing: reply[WatchBridge.reasonKey]))")
        XCTAssertEqual(reply[WatchBridge.okKey] as? Bool, true, "the real admitted bridge must accept held forward seeking")
        XCTAssertTrue(player.isRemoteSeeking)
        let start = player.position
        XCTAssertTrue(player.remoteSeekStep(elapsed: 2))
        XCTAssertEqual(player.position, start + 16, accuracy: 0.0001, "the existing player owns the continuous8x seek")
        session.delegate = nil
    }

    func testStartWiresPlayerToModelWithoutAnyScene() async {
        let rig = await makeRig()
        XCTAssertNil(rig.runtime.player.onListened)
        await rig.runtime.start()
        XCTAssertNotNil(rig.runtime.player.onListened, "the model drives the player's listening stats once started")
    }

    func testPrepareWiresThePlayerWithoutWaitingForTheSync() async {
        let rig = await makeRig()
        await rig.runtime.prepare()
        XCTAssertNotNil(rig.runtime.player.onListened)
        XCTAssertNil(rig.runtime.model.lastSynchronizedAt, "prepare must not run the network sync")
        await rig.runtime.prepare()
    }

    func testStartAppliesSettingsAndFollowsChanges() async {
        let rig = await makeRig()
        await rig.runtime.start()
        XCTAssertEqual(rig.remote.skipIntervals?.back, TimeInterval(LibrarySettingsStore.defaultSkipBack))
        rig.runtime.settings.skipBackSeconds = 45
        await waitUntil { rig.remote.skipIntervals?.back == 45 }
    }

    func testStartIsSharedBetweenCallers() async {
        let rig = await makeRig()
        let runtime = rig.runtime
        let first = Task { @MainActor in await runtime.start() }
        let second = Task { @MainActor in await runtime.start() }
        await first.value
        await second.value
        await rig.runtime.start()
        XCTAssertNotNil(rig.runtime.player.onListened)
    }

    func testPlayerStopsWhenItsFileLeavesThePhone() async {
        let rig = await makeRig()
        await rig.runtime.start()
        rig.runtime.model.media[item.entryID] = .onPhone
        XCTAssertTrue(rig.runtime.player.start(item))
        rig.runtime.model.media[item.entryID] = .available
        await waitUntil { rig.runtime.player.status != .playing }
        XCTAssertNil(rig.runtime.player.item)
    }

    private func preparedQueuedRig() async throws -> Rig {
        let rig = await makeRig()
        await rig.runtime.prepare()
        let model = rig.runtime.model
        let preparedContext = await model.mediaContext()
        let context = try XCTUnwrap(preparedContext)
        let current = await model.mediaContextIsCurrent(context, entryID: item.entryID)
        XCTAssertTrue(current, "the offline positive entry matches its actually committed mirror")
        XCTAssertEqual(model.media[item.entryID], .onPhone)
        await withCheckedContinuation { continuation in DispatchQueue.main.async { continuation.resume() } }
        XCTAssertTrue(rig.runtime.player.start(item))
        return rig
    }

    func testDirectPhoneToggleCannotResumeAfterLocalFileDisappears() async throws {
        let rig = try await preparedQueuedRig()
        rig.runtime.player.pause()
        try FileManager.default.removeItem(at: item.fileURL)
        rig.runtime.player.togglePlayPause()
        await waitUntil { rig.runtime.player.item == nil }
        XCTAssertFalse(rig.runtime.player.isPlaying)
    }

    func testDirectSeekCannotResumeHeldAudioAfterSameSizeCorruption() async throws {
        let rig = try await preparedQueuedRig()
        XCTAssertTrue(rig.runtime.player.handle(.beginSeeking(.forward)))
        await waitUntil { rig.runtime.player.isRemoteSeeking }
        try Data([4, 3, 2, 1]).write(to: item.fileURL)
        rig.runtime.player.seek(to: 150)
        await waitUntil { rig.runtime.player.item == nil }
        XCTAssertFalse(rig.runtime.player.isPlaying)
        XCTAssertFalse(rig.runtime.player.isRemoteSeeking)
    }

    func testDirectSkipCannotResumeHeldAudioAfterLocalFileDisappears() async throws {
        let rig = try await preparedQueuedRig()
        XCTAssertTrue(rig.runtime.player.handle(.beginSeeking(.backward)))
        await waitUntil { rig.runtime.player.isRemoteSeeking }
        try FileManager.default.removeItem(at: item.fileURL)
        rig.runtime.player.skipForward()
        await waitUntil { rig.runtime.player.item == nil }
        XCTAssertFalse(rig.runtime.player.isPlaying)
        XCTAssertFalse(rig.runtime.player.isRemoteSeeking)
    }

    func testRetainedRemoteCannotResumeMissingLocalBytes() async throws {
        let rig = try await preparedQueuedRig()
        rig.runtime.player.pause()
        try FileManager.default.removeItem(at: item.fileURL)
        let installed = try XCTUnwrap(rig.remote.handler)
        _ = installed(.play)
        await waitUntil { rig.runtime.player.item == nil }
        XCTAssertFalse(rig.runtime.player.isPlaying)
        XCTAssertNil(rig.runtime.player.item)
    }

    func testQueueRemovalImmediatelyInvalidatesSystemRemoteResumeAndNowPlaying() async throws {
        let rig = try await preparedQueuedRig()
        let installed = try XCTUnwrap(rig.remote.handler)
        await rig.runtime.model.decide(.removeFromLarder, entryID: item.entryID)
        XCTAssertNil(rig.runtime.player.item, "full queue emission invalidates without waiting for another run-loop turn")
        XCTAssertFalse(installed(.play))
        XCTAssertNil(rig.remote.handler)
        XCTAssertGreaterThan(rig.nowPlaying.clears, 0)
        XCTAssertEqual(rig.runtime.model.media[item.entryID], .onPhone)
    }

    func testMediaLossImmediatelyInvalidatesSystemRemoteResume() async throws {
        let rig = try await preparedQueuedRig()
        let installed = try XCTUnwrap(rig.remote.handler)
        rig.runtime.model.media[item.entryID] = .available
        XCTAssertNil(rig.runtime.player.item, "emitted media value must be used before Published storage changes")
        XCTAssertFalse(installed(.play))
        XCTAssertNil(rig.remote.handler)
    }

    func testSearchAndFilterDoNotInvalidateFullyQueuedOnPhonePlayback() async throws {
        let rig = try await preparedQueuedRig()
        defer { rig.runtime.player.stop() }
        rig.runtime.model.searchText = "nothing matches"
        rig.runtime.model.filter = .available
        XCTAssertTrue(rig.runtime.model.visibleRows.isEmpty)
        XCTAssertEqual(rig.runtime.player.item, item)
        XCTAssertTrue(rig.runtime.player.isPlaying)
        rig.runtime.player.pause()
        XCTAssertTrue(rig.runtime.player.handle(.play))
        await waitUntil { rig.runtime.player.isPlaying }
    }

    func testSharedIsReplaceableAndStable() async {
        let rig = await makeRig()
        let original = LibraryRuntime.shared
        LibraryRuntime.shared = rig.runtime
        addTeardownBlock { @MainActor in LibraryRuntime.shared = original }
        XCTAssertTrue(LibraryRuntime.shared === rig.runtime)
        XCTAssertTrue(LibraryRuntime.shared.player === LibraryRuntime.shared.player)
    }
    private func sendHeldWire(_ phase: String, id: UUID, bridge: WatchBridge,
                              context: [String: Any]) async throws -> [String: Any] {
        let data = try XCTUnwrap(context[WatchLinkCodec.snapshotKey] as? Data)
        let snapshot = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let playing = try XCTUnwrap(snapshot["nowPlaying"] as? [String: Any])
        let action: [String: Any] = ["type": "seek", "phase": phase, "direction": "forward",
            "holdID": id.uuidString, "episodeID": try XCTUnwrap(playing["episodeID"] as? String),
            "controlSessionID": try XCTUnwrap(snapshot["controlSessionID"] as? String),
            "seekSessionID": try XCTUnwrap(playing["seekSessionID"] as? String)]
        let request = try JSONSerialization.data(withJSONObject: ["version": 1, "action": action])
        var reply: [String: Any] = [:]
        bridge.watchSessionDidReceiveMessage([WatchLinkCodec.commandKey: request]) { reply = $0 }
        await waitUntil { !reply.isEmpty }
        return reply
    }

    func testWatchLeaseRenewalExpiryAndStaleEndUseActuallyAdmittedPlayer() async throws {
        let rig = try await preparedQueuedRig(); let player = rig.runtime.player
        defer { player.stop() }
        let session = RuntimeHeldWatchSession(), target = LibraryVoiceTarget(model: rig.runtime.model, player: player)
        var uptime = 100.0
        var waits: [CheckedContinuation<Void, Error>] = []
        let bridge = WatchBridge(session: session, target: target,
            source: LibraryWatchSource(model: rig.runtime.model, player: player),
            seekLeaseNow: { uptime }, seekLeaseSleep: { seconds in
                XCTAssertEqual(seconds, 2.5)
                try await withCheckedThrowingContinuation { waits.append($0) }
            })
        defer { for wait in waits { wait.resume() }; waits = []; session.delegate = nil }
        bridge.start(); await bridge.settlePendingPublish()
        let context = try XCTUnwrap(session.contexts.last), first = UUID(), second = UUID()
        let begin = try await sendHeldWire("begin", id: first, bridge: bridge, context: context)
        XCTAssertEqual(begin[WatchBridge.okKey] as? Bool, true); XCTAssertTrue(player.isRemoteSeeking)
        let position = player.position
        let renew = try await sendHeldWire("renew", id: first, bridge: bridge, context: context)
        XCTAssertEqual(renew[WatchBridge.okKey] as? Bool, true)
        XCTAssertEqual(player.position, position, "renewal extends lease without moving or reissuing transport")
        let replacement = try await sendHeldWire("begin", id: second, bridge: bridge, context: context)
        XCTAssertEqual(replacement[WatchBridge.okKey] as? Bool, true)
        let staleEnd = try await sendHeldWire("end", id: first, bridge: bridge, context: context)
        XCTAssertEqual(staleEnd[WatchBridge.okKey] as? Bool, false); XCTAssertTrue(player.isRemoteSeeking)
        await waitUntil { !waits.isEmpty }
        uptime += 3
        let pending = waits; waits = []; for wait in pending { wait.resume() }
        await waitUntil { !player.isRemoteSeeking }
        await waitUntil { player.isPlaying }
        XCTAssertEqual(player.item?.entryID, item.entryID)
    }

    func testWatchEndAfterActualCacheLossCannotResumeHeldAudio() async throws {
        let rig = try await preparedQueuedRig(); let player = rig.runtime.player
        defer { player.stop() }
        let session = RuntimeHeldWatchSession()
        let bridge = WatchBridge(session: session,
            target: LibraryVoiceTarget(model: rig.runtime.model, player: player),
            source: LibraryWatchSource(model: rig.runtime.model, player: player))
        bridge.start(); await bridge.settlePendingPublish()
        let context = try XCTUnwrap(session.contexts.last), hold = UUID()
        let begin = try await sendHeldWire("begin", id: hold, bridge: bridge, context: context)
        XCTAssertEqual(begin[WatchBridge.okKey] as? Bool, true)
        XCTAssertTrue(player.isRemoteSeeking)
        try FileManager.default.removeItem(at: item.fileURL)
        let end = try await sendHeldWire("end", id: hold, bridge: bridge, context: context)
        XCTAssertEqual(end[WatchBridge.okKey] as? Bool, false)
        XCTAssertFalse(player.isRemoteSeeking); XCTAssertFalse(player.isPlaying); XCTAssertNil(player.item)
        session.delegate = nil
    }

    func testOwnedPhoneHoldReleaseRestoresActualAdmittedPlayingState() async throws {
        let rig = try await preparedQueuedRig(); let player = rig.runtime.player
        defer { player.stop() }
        player.seek(to: 100)
        let session = try XCTUnwrap(player.seekSessionID), id = UUID()
        let began = await player.beginOwnedSeeking(.backward, holdID: id, sessionID: session)
        XCTAssertTrue(began); XCTAssertTrue(player.isRemoteSeeking)
        XCTAssertTrue(player.remoteSeekStep(elapsed: 1))
        XCTAssertEqual(player.position, 92)
        // A direction replacement retains the original playing restoration state.
        let nextID = UUID()
        let replacement = await player.beginOwnedSeeking(.forward, holdID: nextID, sessionID: session)
        XCTAssertTrue(replacement)
        XCTAssertTrue(player.remoteSeekStep(elapsed: 1))
        let ended = await player.endOwnedSeeking(.forward, holdID: nextID, sessionID: session)
        XCTAssertTrue(ended); XCTAssertFalse(player.isRemoteSeeking); XCTAssertTrue(player.isPlaying)
    }

    func testWatchInactiveCancelsHoldAndRejectsOldSessionWire() async throws {
        let rig = try await preparedQueuedRig(); let player = rig.runtime.player
        defer { player.stop() }
        let session = RuntimeHeldWatchSession()
        let bridge = WatchBridge(session: session,
            target: LibraryVoiceTarget(model: rig.runtime.model, player: player),
            source: LibraryWatchSource(model: rig.runtime.model, player: player))
        bridge.start(); await bridge.settlePendingPublish()
        let context = try XCTUnwrap(session.contexts.last), id = UUID()
        let began = try await sendHeldWire("begin", id: id, bridge: bridge, context: context)
        XCTAssertEqual(began[WatchBridge.okKey] as? Bool, true)
        bridge.watchSessionDidBecomeInactive()
        await waitUntil { !player.isRemoteSeeking }
        let stale = try await sendHeldWire("renew", id: id, bridge: bridge, context: context)
        XCTAssertEqual(stale[WatchBridge.okKey] as? Bool, false)
        session.delegate = nil
    }

}
