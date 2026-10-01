import AVFoundation
import CryptoKit
import Foundation
import WiltedDomain
import WiltedLibrary
import XCTest
@testable import WiltediOS

/// Each voice intent's `perform()` against the real `LibraryRuntime` a cold launch builds: a
/// library persisted on disk, a real audio file in the media cache, the real audio engine, and a
/// transport with no network. Nothing is faked between the intent and the player except the
/// system session, Now Playing and remote-command hooks, which need a device.
@MainActor
final class VoiceRealRuntimeTests: XCTestCase {
    private struct Rig {
        let runtime: LibraryRuntime
        let engine: LibraryAudioEngine
    }

    private var scratch: URL!
    private var savedShared: LibraryRuntime!
    private var savedProvider: (@MainActor () async -> (any VoiceCommandTarget)?)!
    private let clipSeconds = 100

    override func setUp() async throws {
        scratch = FileManager.default.temporaryDirectory.appendingPathComponent("voice-real-runtime-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        savedShared = LibraryRuntime.shared
        savedProvider = VoiceRuntime.provider
    }

    override func tearDown() async throws {
        LibraryRuntime.shared = savedShared
        VoiceRuntime.provider = savedProvider
        try? FileManager.default.removeItem(at: scratch)
    }

    private func defaults() -> UserDefaults {
        let suite = "wilted.voice.real.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        return defaults
    }

    /// A silent 8 kHz mono 8-bit WAV: a real file the engine decodes, about 800 KB.
    private func wavData(seconds: Int) -> Data {
        let rate = 8_000, bytes = rate * seconds
        var data = Data()
        func le32(_ value: Int) { withUnsafeBytes(of: UInt32(value).littleEndian) { data.append(contentsOf: $0) } }
        func le16(_ value: Int) { withUnsafeBytes(of: UInt16(value).littleEndian) { data.append(contentsOf: $0) } }
        data.append(contentsOf: Array("RIFF".utf8)); le32(36 + bytes)
        data.append(contentsOf: Array("WAVEfmt ".utf8)); le32(16); le16(1); le16(1); le32(rate); le32(rate); le16(1); le16(8)
        data.append(contentsOf: Array("data".utf8)); le32(bytes)
        data.append(Data(repeating: 128, count: bytes))
        return data
    }

    /// Lays the library down the way a synced launch leaves it (on disk), then returns the runtime a
    /// later cold launch builds: same files, no network, nothing synced.
    private func coldRuntime(
        episodes: [(raw: String, title: String, published: Double)], onPhone: Set<String>
    ) async throws -> Rig {
        let id = { (raw: String) in try! ItemID(rawValue: raw) }
        let server = InMemoryLibraryServer(writerDeviceID: "mac")
        let mac = InMemoryLibraryTransport(deviceID: "mac", server: server)
        let show = LibrarySource(id: id("show"), kind: .podcastFeed, title: "The Show")
        var changes: [LibraryChange] = [.source(show)]
        for (index, spec) in episodes.enumerated() {
            changes.append(.entry(try LibraryEntry(
                id: id(spec.raw), kind: .podcastEpisode, sourceID: show.id, title: spec.title, summary: "",
                publishedAt: Date(timeIntervalSince1970: spec.published), durationSeconds: Double(clipSeconds))))
            changes.append(.slot(try QueueSlot(entryID: id(spec.raw), sortKey: Double(index))))
        }
        let pending = changes.enumerated().map { PendingLibraryChange(localSeq: UInt64($0.offset + 1), change: $0.element, baseVersion: 0) }
        _ = try await mac.push(changes: pending)

        let storeURL = scratch.appendingPathComponent("state/library-state.json")
        let cacheRoot = scratch.appendingPathComponent("cache")
        let cache = FileMediaCache(rootURL: cacheRoot)
        let online = LibraryAppModel(
            transport: InMemoryLibraryTransport(deviceID: "phone", server: server),
            store: FileLibraryStore(url: storeURL), deviceID: "phone", mediaCache: cache, preferences: defaults())
        await online.refresh()

        let clip = wavData(seconds: clipSeconds)
        let hash = MediaHash.prefix + SHA256.hash(data: clip).map { String(format: "%02x", $0) }.joined()
        for spec in episodes where onPhone.contains(spec.raw) {
            let file = scratch.appendingPathComponent("incoming-\(spec.raw).wav")
            try clip.write(to: file)
            let offer = try LibraryMediaOffer(
                entryID: id(spec.raw), revisionID: RevisionID(rawValue: "rev-\(spec.raw)"), contentHash: hash,
                byteCount: Int64(clip.count), mediaType: "audio/wav", durationSeconds: Double(clipSeconds))
            _ = try await cache.adopt(verifiedFile: file, for: offer)
        }

        let engine = LibraryAudioEngine()
        let player = LibraryPlayer(
            engine: engine, session: VoiceFakeSession(), nowPlaying: VoiceFakeNowPlaying(), remoteCommands: VoiceFakeRemote(),
            sessionEvents: VoiceFakeEvents(), tickInterval: .seconds(3600))
        let prefs = defaults()
        let model = LibraryAppModel(
            transport: UnavailableLibraryTransport(reason: "no signal"), store: FileLibraryStore(url: storeURL),
            deviceID: "phone", mediaCache: FileMediaCache(rootURL: cacheRoot), preferences: prefs)
        let runtime = LibraryRuntime(model: model, player: player, settings: LibrarySettingsStore(defaults: prefs))
        LibraryRuntime.shared = runtime
        return Rig(runtime: runtime, engine: engine)
    }

    private let library: [(raw: String, title: String, published: Double)] = [
        ("ep-a", "Gold Rush", 1_600_000_000), ("ep-b", "Chips", 1_700_000_000), ("ep-c", "Tide Pools", 1_650_000_000),
    ]

    func testPlayNextOnAColdRuntimeStartsTheFirstDownloadedEpisodeInTheRealEngine() async throws {
        let rig = try await coldRuntime(episodes: library, onPhone: ["ep-b", "ep-c"])
        XCTAssertTrue(rig.runtime.model.queued.isEmpty, "nothing is loaded until an intent prepares the runtime")

        _ = try await PlayNextEpisodeIntent().perform()

        XCTAssertEqual(rig.runtime.player.item?.entryID.rawValue, "ep-c", "the first of the play order (oldest published); ep-a is not on the phone")
        XCTAssertTrue(rig.runtime.player.isPlaying)
        XCTAssertTrue(rig.engine.isPlaying, "the real engine is producing audio, not just the model's flag")
        XCTAssertEqual(rig.engine.duration, Double(clipSeconds), accuracy: 0.5)
    }

    func testPauseResumeSkipAndRestartMoveTheRealEngine() async throws {
        let rig = try await coldRuntime(episodes: library, onPhone: ["ep-a"])
        _ = try await PlayNextEpisodeIntent().perform()
        XCTAssertTrue(rig.engine.isPlaying)

        _ = try await PauseEpisodeIntent().perform()
        XCTAssertFalse(rig.engine.isPlaying)
        XCTAssertFalse(rig.runtime.player.isPlaying)

        _ = try await SkipForwardIntent().perform()
        XCTAssertEqual(rig.engine.currentTime, 30, accuracy: 2, "the default skip forward is 30 s from near the start")
        _ = try await SkipBackIntent().perform()
        XCTAssertEqual(rig.engine.currentTime, 15, accuracy: 2, "then 15 s back")
        XCTAssertFalse(rig.engine.isPlaying, "skipping does not resume")

        _ = try await ResumeEpisodeIntent().perform()
        XCTAssertTrue(rig.engine.isPlaying)

        _ = try await RestartEpisodeIntent().perform()
        XCTAssertLessThan(rig.engine.currentTime, 2, "restart returns to the start")
        XCTAssertTrue(rig.engine.isPlaying, "and plays")
    }

    func testPlayEpisodeAndPlayLatestPickFromTheDownloadedSet() async throws {
        let rig = try await coldRuntime(episodes: library, onPhone: ["ep-a", "ep-b", "ep-c"])

        let named = PlayEpisodeIntent()
        named.episode = EpisodeEntity(VoiceEpisode(id: try ItemID(rawValue: "ep-c"), title: "Tide Pools", showTitle: "The Show"))
        _ = try await named.perform()
        XCTAssertEqual(rig.runtime.player.item?.entryID.rawValue, "ep-c")
        XCTAssertTrue(rig.engine.isPlaying)

        _ = try await PlayLatestIntent().perform()
        XCTAssertEqual(rig.runtime.player.item?.entryID.rawValue, "ep-b", "newest published, not Larder order")
        XCTAssertTrue(rig.engine.isPlaying)
    }

    func testAnEpisodeNotOnThePhoneIsNeverStartedAndNothingIsDownloaded() async throws {
        let rig = try await coldRuntime(episodes: library, onPhone: ["ep-a"])

        let named = PlayEpisodeIntent()
        named.episode = EpisodeEntity(VoiceEpisode(id: try ItemID(rawValue: "ep-b"), title: "Chips", showTitle: "The Show"))
        _ = try await named.perform()
        XCTAssertNil(rig.runtime.player.item, "Chips is in the Larder but not downloaded, so Siri does not play it or fetch it")
        XCTAssertFalse(rig.engine.isPlaying)
        XCTAssertNil(rig.runtime.model.media[try ItemID(rawValue: "ep-b")].flatMap { $0 == .onPhone ? $0 : nil })
    }

    func testWithNothingDownloadedTheIntentsSpeakAndPlayNothing() async throws {
        let rig = try await coldRuntime(episodes: library, onPhone: [])
        _ = try await PlayNextEpisodeIntent().perform()
        _ = try await PlayLatestIntent().perform()
        _ = try await PauseEpisodeIntent().perform()
        XCTAssertNil(rig.runtime.player.item)
        XCTAssertFalse(rig.engine.isPlaying)
    }

    func testWhatsPlayingAndListDownloadedSpeakFromTheRealLibrary() async throws {
        let rig = try await coldRuntime(episodes: library, onPhone: ["ep-a", "ep-c"])
        let listed = try await VoiceCommandRunner.run(.listDownloaded, on: await VoiceRuntime.target()) { _ in }
        XCTAssertEqual(listed, "2 episodes on your phone: Gold Rush, Tide Pools.")
        let idle = try await VoiceCommandRunner.run(.whatsPlaying, on: await VoiceRuntime.target()) { _ in }
        XCTAssertEqual(idle, "Nothing is playing.")

        _ = try await PlayNextEpisodeIntent().perform()
        let playing = try await VoiceCommandRunner.run(.whatsPlaying, on: await VoiceRuntime.target()) { _ in }
        XCTAssertEqual(playing, "Gold Rush, from The Show.")
        XCTAssertTrue(rig.engine.isPlaying)
    }

    func testShortcutParametersRefreshWhenAnEpisodeIsDownloadedOrRemoved() async throws {
        let rig = try await coldRuntime(episodes: library, onPhone: ["ep-b"])
        await rig.runtime.prepare()
        let model = rig.runtime.model
        var updates = 0
        let refresher = ShortcutParameterRefresher(update: { updates += 1 })
        let subscription = ShortcutParameterRefresher.observe(model, refresher: refresher)
        defer { subscription.cancel() }
        XCTAssertEqual(updates, 1, "the shows and the one downloaded episode are told to Siri once")

        model.media[try ItemID(rawValue: "ep-c")] = .onPhone
        XCTAssertEqual(updates, 2, "a newly downloaded episode refreshes the episode phrases")
        model.media[try ItemID(rawValue: "ep-c")] = .available
        XCTAssertEqual(updates, 3, "removing the download refreshes them again")
        model.media[try ItemID(rawValue: "ep-c")] = .requested(since: Date())
        XCTAssertEqual(updates, 3, "a state change that leaves the downloaded set alone does not")
    }
}
