import CryptoKit
import Foundation
import WiltedDomain
import WiltedLibrary
import WiltedPlayback
import XCTest
@testable import WiltediOS

/// The CarPlay journeys headless, over the seam `CarPlaySceneDelegate` uses: `LibraryRuntime.shared`
/// prepares with no window scene, the CarPlay list model follows the persisted library and the
/// queue, `CarRowSelection` ends a failed start exactly once, and the own-position store stays
/// readable while the phone is locked. No network and no fixture outside a temporary directory:
/// the in-memory transport and the existing seam fakes carry every journey.
@MainActor
final class CarPlayJourneyTests: XCTestCase {
    private struct Rig {
        let runtime: LibraryRuntime
        let session: RuntimeFakeSession
        let cache: FileMediaCache
        let mac: InMemoryLibraryTransport
    }

    private var scratch: URL!
    private let entryID = try! ItemID(rawValue: "item-a")
    private let otherEntryID = try! ItemID(rawValue: "item-b")
    private let revisionID = try! RevisionID(rawValue: "rev-1")
    private let payload = Data((0..<2_000).map { UInt8($0 % 251) })

    override func setUp() async throws {
        scratch = FileManager.default.temporaryDirectory.appendingPathComponent("carplay-journeys-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    override func tearDown() async throws { try? FileManager.default.removeItem(at: scratch) }

    /// A runtime over a library persisted on disk and audio cached under `scratch`, reached through
    /// the same fakes the other seam tests use. `reachable` gives the runtime's model a working
    /// in-memory transport; otherwise it is the no-signal one.
    private func makeRig(queued: [String], onPhone: Set<String>, reachable: Bool = false) async throws -> Rig {
        let suite = "wilted.carplay.journeys.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }

        let server = InMemoryLibraryServer(writerDeviceID: "mac")
        let mac = InMemoryLibraryTransport(deviceID: "mac", server: server, verifiedOwnerToken: "fixture-owner")
        let show = LibrarySource(id: try ItemID(rawValue: "show"), kind: .podcastFeed, title: "The Show")
        var changes: [LibraryChange] = [.source(show)]
        for (index, raw) in queued.enumerated() {
            let id = try ItemID(rawValue: raw)
            changes.append(.entry(try LibraryEntry(
                id: id, kind: .podcastEpisode, sourceID: show.id, title: "Episode \(raw)", summary: "",
                publishedAt: Date(timeIntervalSince1970: 1_600_000_000 + Double(index)), durationSeconds: 1_800)))
            changes.append(.slot(try QueueSlot(entryID: id, sortKey: Double(index))))
        }
        _ = try await mac.push(changes: changes.enumerated().map {
            PendingLibraryChange(localSeq: UInt64($0.offset + 1), change: $0.element, baseVersion: 0)
        })

        // One synced launch lays the library down on disk; a later launch reads it with no network.
        let storeURL = scratch.appendingPathComponent("state/library-state.json")
        let cache = FileMediaCache(rootURL: scratch.appendingPathComponent("cache"))
        let online = LibraryAppModel(
            transport: InMemoryLibraryTransport(deviceID: "phone", server: server, verifiedOwnerToken: "fixture-owner"),
            store: FileLibraryStore(url: storeURL), deviceID: "phone", mediaCache: cache, preferences: defaults)
        await online.refresh()
        for raw in onPhone {
            try await adopt(raw, into: cache)
        }

        let session = RuntimeFakeSession()
        let player = LibraryPlayer(
            engine: RuntimeFakeEngine(), session: session, nowPlaying: RuntimeFakeNowPlaying(),
            remoteCommands: RuntimeFakeRemote(), sessionEvents: RuntimeFakeEvents(), tickInterval: .seconds(3600))
        let transport: any LibraryTransport
        if reachable {
            transport = InMemoryLibraryTransport(deviceID: "phone", server: server, verifiedOwnerToken: "fixture-owner")
        } else {
            transport = UnavailableLibraryTransport(reason: "no signal")
        }
        let model = LibraryAppModel(
            transport: transport, store: FileLibraryStore(url: storeURL), deviceID: "phone", mediaCache: cache,
            preferences: defaults)
        let runtime = LibraryRuntime(model: model, player: player, settings: LibrarySettingsStore(defaults: defaults))
        return Rig(runtime: runtime, session: session, cache: cache, mac: mac)
    }

    /// Puts one verifiable file in the cache for `raw`, the way a completed download leaves it.
    private func adopt(_ raw: String, into cache: FileMediaCache) async throws {
        let incoming = scratch.appendingPathComponent("incoming-\(raw).mp4")
        try payload.write(to: incoming)
        let hash = MediaHash.prefix + SHA256.hash(data: payload).map { String(format: "%02x", $0) }.joined()
        _ = try await PreparedMediaFixture.adopt(into: cache,
            verifiedFile: incoming,
            for: try PreparedMediaFixture.certified(LibraryMediaOffer(
                entryID: try ItemID(rawValue: raw), revisionID: try RevisionID(rawValue: "rev-\(raw)"),
                contentHash: hash, byteCount: Int64(payload.count), mediaType: "audio/mp4", durationSeconds: 60)), owner: "fixture-owner")
    }

    private func carEpisodes(_ model: LibraryAppModel, playingID: ItemID? = nil) -> [CarEpisodeRow] {
        guard case let .episodes(rows) = CarEpisodeList.make(model: model, playingID: playingID).content else { return [] }
        return rows
    }

    // MARK: 1. A CarPlay-only launch has no window scene

    func testRuntimePreparesAndPlaysWithNoWindowScene() async throws {
        let rig = try await makeRig(queued: ["item-a"], onPhone: ["item-a"])
        let original = LibraryRuntime.shared
        LibraryRuntime.shared = rig.runtime
        addTeardownBlock { @MainActor in LibraryRuntime.shared = original }

        // The scene delegate's connect path: the shared runtime, with no LibraryRoot in the process.
        await LibraryRuntime.shared.prepare()
        XCTAssertTrue(LibraryRuntime.shared === rig.runtime)
        XCTAssertNotNil(rig.runtime.player.onListened, "prepare wires the model and player with no window scene")
        XCTAssertNil(rig.runtime.model.lastSynchronizedAt, "prepare lists the phone without waiting on the network")
        XCTAssertEqual(rig.session.activations, 0, "connecting must not take the audio session from the car's radio")

        let row = try XCTUnwrap(carEpisodes(rig.runtime.model).first)
        XCTAssertEqual(row.id, entryID)

        var opened = 0
        var completions = 0
        let outcome = await CarRowSelection.run(
            row.row, model: rig.runtime.model, openNowPlaying: { opened += 1 },
            presentFailure: { XCTFail("on-phone audio must start: \($0)") }, completion: { completions += 1 })
        XCTAssertEqual(outcome, .started)
        XCTAssertEqual(opened, 1)
        XCTAssertEqual(completions, 1)
        XCTAssertEqual(rig.runtime.player.item?.entryID, entryID)
        XCTAssertEqual(rig.session.activations, 1, "only the actual start activates the audio session")
    }

    // MARK: 2. An offline start lists the persisted on-phone library

    func testOfflineStartListsOnPhoneEpisodesFromThePersistedLibrary() async throws {
        let rig = try await makeRig(queued: ["item-a", "item-b"], onPhone: ["item-a"])
        await rig.runtime.prepare()

        XCTAssertNil(rig.runtime.model.lastSynchronizedAt, "the offline start never reached the network")
        XCTAssertEqual(rig.runtime.model.queued.map(\.id), [entryID, otherEntryID], "the queue came from the persisted library")
        XCTAssertEqual(rig.runtime.model.media[entryID], .onPhone)
        XCTAssertNil(rig.runtime.model.media[otherEntryID], "audio that is not on the phone stays off the car list")

        let list = CarEpisodeList.make(model: rig.runtime.model, playingID: nil)
        guard case let .episodes(rows) = list.content else { return XCTFail("expected episodes, got \(list.content)") }
        XCTAssertEqual(rows.map(\.id), [entryID])
        XCTAssertEqual(list.totalOnPhone, 1)

        let shows = CarShowList.make(
            rows: rig.runtime.model.queued, onPhone: rig.runtime.model.preparedIDs.onPhone,
            progress: rig.runtime.model.progress, finished: rig.runtime.model.finished)
        XCTAssertEqual(shows.map(\.title), ["The Show"])
        XCTAssertEqual(shows.first?.downloaded, 1)
    }

    // MARK: 3. The list rebuilds when the queue or the on-phone set changes

    func testListRebuildsWhenTheQueueOrTheOnPhoneSetChanges() async throws {
        // item-b's audio is already on the phone, but the Mac has not queued it yet.
        let rig = try await makeRig(queued: ["item-a"], onPhone: ["item-a", "item-b"], reachable: true)
        await rig.runtime.prepare()
        XCTAssertEqual(carEpisodes(rig.runtime.model).map(\.id), [entryID], "an unqueued episode never shows")

        // The queue changes: the Mac adds item-b, which is already on the phone.
        let show = LibrarySource(id: try ItemID(rawValue: "show"), kind: .podcastFeed, title: "The Show")
        let entryB = try LibraryEntry(
            id: otherEntryID, kind: .podcastEpisode, sourceID: show.id, title: "Episode item-b", summary: "",
            publishedAt: Date(timeIntervalSince1970: 1_600_000_100), durationSeconds: 1_800)
        _ = try await rig.mac.push(changes: [
            PendingLibraryChange(localSeq: 10, change: .entry(entryB), baseVersion: 0),
            PendingLibraryChange(
                localSeq: 11, change: .slot(try QueueSlot(entryID: otherEntryID, sortKey: 1)), baseVersion: 0),
        ])
        await rig.runtime.model.refresh()
        XCTAssertEqual(
            carEpisodes(rig.runtime.model).map(\.id), [entryID, otherEntryID],
            "the list rebuilt from the queue the moment the episode joined it")

        // The on-phone set changes: the audio is removed.
        await rig.runtime.model.removeFromPhone(entryID: otherEntryID)
        XCTAssertEqual(carEpisodes(rig.runtime.model).map(\.id), [entryID], "removing the audio drops the row")
    }

    // MARK: 4. A vanished audio file fails once, without hanging

    func testMissingAudioFileReportsFailureAndCompletesExactlyOnce() async throws {
        let rig = try await makeRig(queued: ["item-a"], onPhone: ["item-a"])
        await rig.runtime.prepare()
        let row = try XCTUnwrap(carEpisodes(rig.runtime.model).first)

        // The file vanishes after the list was drawn (purged or removed outside the app).
        try await rig.cache.remove(entryID: entryID)

        var opened = 0
        var failures: [LibraryStartFailure] = []
        var completions = 0
        let outcome = await CarRowSelection.run(
            row.row, model: rig.runtime.model, openNowPlaying: { opened += 1 },
            presentFailure: { failures.append($0) }, completion: { completions += 1 })

        XCTAssertEqual(outcome, .failed(.missingMedia))
        XCTAssertEqual(opened, 0, "a failure never opens Now Playing")
        XCTAssertEqual(failures, [.missingMedia], "the failure is presented once, for retry")
        XCTAssertEqual(completions, 1, "the template spinner ends exactly once: no hang, no double completion")
        let detail = try XCTUnwrap(CarPlaySceneDelegate.commandDetail(rig.runtime.model.playbackCommand, for: row))
        XCTAssertEqual(detail, "Audio isn't on this iPhone.", "the row says it in car words, without asking for the phone")
    }

    // MARK: 5. The own-position store is readable while the phone is locked

    func testOwnPositionStoreIsReadableWhileTheDeviceIsLocked() throws {
        let url = scratch.appendingPathComponent("state/own-positions.json")
        let store = LibraryOwnPositionStore(url: url)
        let record = try DevicePlaybackPosition(
            deviceID: "phone", entryID: entryID, revision: revisionID, positionSeconds: 42,
            isPlaying: false, epoch: 3, publishedAt: Date(timeIntervalSince1970: 1_700_000_000))
        store.save(.init(
            positions: [entryID: ObservedPlayback(record: record, serverModifiedAt: Date(timeIntervalSince1970: 1_700_000_000))],
            unpublished: [entryID: (position: 42, savedAt: Date(timeIntervalSince1970: 1_700_000_100))]))

        XCTAssertEqual(store.load().positions[entryID]?.record.positionSeconds, 42)
        XCTAssertEqual(store.load().unpublished[entryID]?.position, 42)

        // The simulator does not always report the class; when it does, it must be the one that
        // survives the lock screen, never a stronger one.
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard let reported = attributes[.protectionKey] else { return }
        let readable: Bool
        if let type = reported as? FileProtectionType {
            readable = type == .completeUntilFirstUserAuthentication
        } else if let raw = reported as? String {
            readable = raw == FileProtectionType.completeUntilFirstUserAuthentication.rawValue
        } else {
            readable = false
        }
        XCTAssertTrue(readable, "the own-position store carries \(reported) and would be unreadable while locked")
    }
}
