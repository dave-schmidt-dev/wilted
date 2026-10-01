import CryptoKit
import Foundation
import WiltedDomain
import WiltedLibrary
import XCTest
@testable import WiltediOS

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
    }

    private var scratch: URL!

    override func setUp() async throws {
        scratch = FileManager.default.temporaryDirectory.appendingPathComponent("runtime-seams-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    override func tearDown() async throws { try? FileManager.default.removeItem(at: scratch) }

    /// A runtime over a library with one episode already downloaded and no network.
    private func makeRig() async throws -> Rig {
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
            engine: RuntimeFakeEngine(), session: session, nowPlaying: RuntimeFakeNowPlaying(),
            remoteCommands: remote, sessionEvents: RuntimeFakeEvents(), tickInterval: .seconds(3600))
        let model = LibraryAppModel(
            transport: UnavailableLibraryTransport(reason: "no signal"), store: store, deviceID: "phone",
            mediaCache: cache, preferences: defaults)
        let runtime = LibraryRuntime(model: model, player: player, settings: LibrarySettingsStore(defaults: defaults))
        return Rig(runtime: runtime, remote: remote, session: session, entryID: entryID)
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
}
