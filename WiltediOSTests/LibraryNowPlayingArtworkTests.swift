import CryptoKit
import Foundation
import ImageIO
import MediaPlayer
import UIKit
import WiltedDomain
import WiltedLibrary
import WiltedListener
import XCTest
@testable import WiltediOS

private final class RecordingNowPlaying: ListenerNowPlaying, @unchecked Sendable {
    private(set) var infos: [ListenerNowPlayingInfo] = []
    func update(title: String, duration: Double, position: Double, rate: Double) {}
    func update(_ info: ListenerNowPlayingInfo) { infos.append(info) }
    func clear() {}
}

private final class RateEngine: ListenerAudioEngine, LibraryRateAdjustable, @unchecked Sendable {
    var duration = 600.0
    var currentTime = 0.0
    var isPlaying = false
    var rate: Float = 1
    func load(url: URL) throws {}
    func load(url: URL, completionGeneration: UInt64) throws {}
    func play() -> Bool { isPlaying = true; return true }
    func pause() { isPlaying = false }
    func installCompletionHandler(_ handler: @escaping @Sendable (UInt64) -> Void) {}
}

@MainActor
final class LibraryNowPlayingArtworkTests: XCTestCase {
    private var scratch: URL!
    private let artworkURL = URL(string: "https://example.com/cover.png")!

    override func setUp() async throws {
        scratch = FileManager.default.temporaryDirectory.appendingPathComponent("now-playing-art-\(UUID().uuidString)")
    }

    override func tearDown() async throws { try? FileManager.default.removeItem(at: scratch) }

    private func png(side: Int) -> Data {
        UIGraphicsImageRenderer(size: CGSize(width: side, height: side), format: {
            let format = UIGraphicsImageRendererFormat(); format.scale = 1; return format
        }()).pngData { context in
            UIColor.green.setFill()
            context.fill(CGRect(x: 0, y: 0, width: side, height: side))
        }
    }

    private func item(artwork: URL? = nil) -> LibraryPlayer.Item {
        LibraryPlayer.Item(
            entryID: try! ItemID(rawValue: "entry-1"), title: "Episode", showTitle: "Show",
            fileURL: URL(fileURLWithPath: "/nonexistent/art.mp3"), artworkURL: artwork)
    }

    private func player(
        _ nowPlaying: RecordingNowPlaying, cache: LibraryArtworkCache? = nil, engine: RateEngine = RateEngine()
    ) -> LibraryPlayer {
        LibraryPlayer(
            engine: engine, session: RuntimeFakeSession(), nowPlaying: nowPlaying, remoteCommands: RuntimeFakeRemote(),
            sessionEvents: RuntimeFakeEvents(), artwork: cache, tickInterval: .seconds(3600))
    }

    // MARK: rate shown on Now Playing

    /// The CarPlay start path: a cached episode started with autoplay on a locked phone. What the system
    /// receives while it plays carries the chosen speed under both rate keys, and the session was
    /// activated first.
    func testTheDictionaryPublishedWhenCarPlayStartsAnEpisodeCarriesTheSpeed() throws {
        let recorder = RecordingNowPlaying()
        let session = RuntimeFakeSession()
        let player = LibraryPlayer(
            engine: RateEngine(), session: session, nowPlaying: recorder, remoteCommands: RuntimeFakeRemote(),
            sessionEvents: RuntimeFakeEvents(), artwork: nil, tickInterval: .seconds(3600))
        player.apply(LibraryPlaybackPreferences(defaultSpeed: 1.5, skipBackSeconds: 15, skipForwardSeconds: 30))
        XCTAssertTrue(player.start(item(), at: 30))
        let payload = MediaPlayerNowPlaying.payload(for: try XCTUnwrap(recorder.infos.last))
        XCTAssertEqual(payload[MPNowPlayingInfoPropertyPlaybackRate] as? Double, 1.5)
        XCTAssertEqual(payload[MPNowPlayingInfoPropertyDefaultPlaybackRate] as? Double, 1.5)
        XCTAssertEqual(payload[MPNowPlayingInfoPropertyElapsedPlaybackTime] as? Double, 30, "it starts where the resume position says")
        XCTAssertEqual(session.activations, 1, "play() activates the session on the CarPlay path too")
        player.refreshPosition()
        XCTAssertEqual(recorder.infos.last?.rate, 1.5, "a position refresh while playing never republishes 0x")
    }

    /// CarPlay's speed button follows the remote command center, not the info dictionary: the speed
    /// command must be enabled and list the offered speeds, and a speed it sends must change the rate.
    func testTheSpeedCommandIsEnabledForCarPlayAndChangesTheRate() throws {
        let center = MPRemoteCommandCenter.shared()
        let commands = MediaPlayerLibraryRemoteCommands(center: center)
        var received: [LibraryRemoteCommand] = []
        commands.install { received.append($0); return true }
        defer { commands.uninstall() }
        XCTAssertTrue(center.changePlaybackRateCommand.isEnabled)
        XCTAssertEqual(center.changePlaybackRateCommand.supportedPlaybackRates.map(\.doubleValue), LibraryPlayer.rates)
        let recorder = RecordingNowPlaying()
        let player = player(recorder)
        player.start(item(), autoplay: true)
        XCTAssertTrue(player.handle(.setRate(1.75)))
        XCTAssertEqual(player.rate, 1.75)
        XCTAssertEqual(recorder.infos.last?.rate, 1.75)
        XCTAssertEqual(recorder.infos.last?.defaultRate, 1.75)
    }

    func testPausedNowPlayingPublishesTheChosenSpeedNotZero() {
        let recorder = RecordingNowPlaying()
        let player = player(recorder)
        player.apply(LibraryPlaybackPreferences(defaultSpeed: 1.25, skipBackSeconds: 15, skipForwardSeconds: 30))
        player.start(item(), autoplay: false)
        XCTAssertEqual(recorder.infos.last?.rate, 0, "paused is rate 0 to the system")
        XCTAssertEqual(recorder.infos.last?.defaultRate, 1.25, "the car's speed button reads this, not 0x")
        player.play()
        XCTAssertEqual(recorder.infos.last?.rate, 1.25)
        XCTAssertEqual(recorder.infos.last?.defaultRate, 1.25)
        player.pause()
        XCTAssertEqual(recorder.infos.last?.rate, 0)
        XCTAssertEqual(recorder.infos.last?.defaultRate, 1.25)
        player.setRate(1.5)
        XCTAssertEqual(recorder.infos.last?.defaultRate, 1.5, "a speed change from the car is the new chosen speed")
    }

    func testAColdStartThroughTheRuntimeBeginsAtTheSettingsSpeed() async {
        let suite = "wilted.nowplaying.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        let settings = LibrarySettingsStore(defaults: defaults)
        settings.defaultSpeed = 1.25
        let recorder = RecordingNowPlaying(), engine = RateEngine()
        let player = player(recorder, engine: engine)
        let model = LibraryAppModel(transport: UnavailableLibraryTransport(reason: "test"), deviceID: "phone", preferences: defaults)
        let runtime = LibraryRuntime(model: model, player: player, settings: settings)

        await runtime.prepare()
        XCTAssertEqual(player.rate, 1, "nothing is playing yet")
        player.start(item())
        XCTAssertEqual(player.rate, 1.25, "CarPlay and Siri start through prepare(), so they get the settings speed")
        XCTAssertEqual(engine.rate, 1.25)
        XCTAssertEqual(recorder.infos.last?.rate, 1.25)
    }

    func testNextRateStepsFromAnySpeedAndWraps() {
        XCTAssertEqual(LibraryPlayer.nextRate(after: 1.25), 1.5)
        XCTAssertEqual(LibraryPlayer.nextRate(after: 2), 0.75, "wraps from the fastest to the slowest")
        XCTAssertEqual(LibraryPlayer.nextRate(after: 1.1), 1.25, "a speed the picker lacks moves up to the next offered")
        XCTAssertEqual(LibraryPlayer.nextRate(after: 0.5), 0.75)
        XCTAssertEqual(LibraryPlayer.nextRate(after: 3), 0.75)
    }

    // MARK: artwork

    func testPublishedPayloadCarriesDefaultRateArtistAndArtwork() throws {
        let info = ListenerNowPlayingInfo(
            title: "Episode", artist: "Show", duration: 600, position: 12, rate: 0, defaultRate: 1.25, artworkData: png(side: 20))
        let payload = MediaPlayerNowPlaying.payload(for: info)
        XCTAssertEqual(payload[MPNowPlayingInfoPropertyDefaultPlaybackRate] as? Double, 1.25)
        XCTAssertEqual(payload[MPNowPlayingInfoPropertyPlaybackRate] as? Double, 0)
        XCTAssertEqual(payload[MPMediaItemPropertyArtist] as? String, "Show")
        XCTAssertNotNil(payload[MPMediaItemPropertyArtwork])
        let bare = MediaPlayerNowPlaying.payload(for: ListenerNowPlayingInfo(title: "T", duration: 1, position: 0, rate: 1, defaultRate: 1))
        XCTAssertNil(bare[MPMediaItemPropertyArtwork])
        XCTAssertNil(bare[MPMediaItemPropertyArtist])
    }

    func testPlayerPublishesCachedArtworkAndNeverFetches() {
        let downloads = Counter()
        var cache = LibraryArtworkCache(directory: scratch)
        cache.download = { _ in downloads.bump(); return nil }
        let recorder = RecordingNowPlaying()
        let player = player(recorder, cache: cache)

        player.start(item(artwork: artworkURL), autoplay: false)
        XCTAssertNil(recorder.infos.last?.artworkData, "a miss is simply no artwork")
        XCTAssertEqual(downloads.value, 0, "the playback path must never touch the network")

        XCTAssertTrue(cache.store(png(side: 40), for: artworkURL))
        player.start(item(artwork: artworkURL), autoplay: false)
        XCTAssertNotNil(recorder.infos.last?.artworkData, "an image already read this launch shows at once")
        XCTAssertEqual(recorder.infos.last?.artist, "Show")
        XCTAssertEqual(downloads.value, 0)
    }

    func testArtworkCachedAfterPlaybackStartedReachesNowPlayingWithoutARestart() async throws {
        let cache = LibraryArtworkCache(directory: scratch)
        let recorder = RecordingNowPlaying()
        let player = player(recorder, cache: cache)
        let late = URL(string: "https://example.com/late.png")!
        player.start(item(artwork: late))
        XCTAssertNil(recorder.infos.last?.artworkData)

        XCTAssertTrue(cache.store(png(side: 40), for: late))
        for _ in 0..<300 where recorder.infos.last?.artworkData == nil { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertNotNil(recorder.infos.last?.artworkData, "the app finished caching it mid-playback")
        player.pause()
        XCTAssertNotNil(recorder.infos.last?.artworkData, "and later publications keep it")
    }

    func testPruneDeletesArtworkOfEpisodesThatLeftTheQueue() throws {
        let cache = LibraryArtworkCache(directory: scratch)
        let kept = URL(string: "https://example.com/kept.png")!, gone = URL(string: "https://example.com/gone.png")!
        XCTAssertTrue(cache.store(png(side: 20), for: kept))
        XCTAssertTrue(cache.store(png(side: 20), for: gone))
        XCTAssertEqual(cache.prune(keeping: [kept]), 1)
        XCTAssertTrue(cache.isCached(kept))
        XCTAssertFalse(cache.isCached(gone))
    }

    // MARK: the cache

    func testStoreShrinksTheImageAndProtectsTheFile() throws {
        let cache = LibraryArtworkCache(directory: scratch)
        XCTAssertTrue(cache.store(png(side: 2_000), for: artworkURL))
        let stored = try XCTUnwrap(cache.data(for: artworkURL))
        let source = try XCTUnwrap(CGImageSourceCreateWithData(stored as CFData, nil))
        let properties = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
        XCTAssertLessThanOrEqual(properties[kCGImagePropertyPixelWidth] as? Int ?? .max, LibraryArtworkCache.maxPixels)
        let protection = try FileManager.default.attributesOfItem(atPath: cache.fileURL(for: artworkURL).path)[.protectionKey]
        #if targetEnvironment(simulator)
        _ = protection
        #else
        XCTAssertEqual(protection as? FileProtectionType, LibraryFileProtection.readableWhileLocked)
        #endif
        let source2 = try String(
            contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("WiltediOS/Library/LibraryArtworkCache.swift"), encoding: .utf8)
        XCTAssertTrue(source2.contains("LibraryFileProtection.writingOption"), "artwork must read while the phone is locked")
    }

    func testStoreRejectsNonImagesAndReadsNeverDownload() {
        let downloads = Counter()
        var cache = LibraryArtworkCache(directory: scratch)
        cache.download = { _ in downloads.bump(); return nil }
        XCTAssertFalse(cache.store(Data("not an image".utf8), for: artworkURL))
        XCTAssertNil(cache.data(for: artworkURL))
        XCTAssertNil(cache.data(for: nil))
        XCTAssertEqual(downloads.value, 0)
    }

    func testFetchDownloadsOnceAndOnlyWebAddresses() async {
        let counter = Counter()
        let image = png(side: 50)
        var cache = LibraryArtworkCache(directory: scratch)
        cache.download = { _ in counter.bump(); return image }
        let first = await cache.fetch(artworkURL)
        let second = await cache.fetch(artworkURL)
        let downloads = counter.value
        XCTAssertTrue(first)
        XCTAssertTrue(second)
        XCTAssertEqual(downloads, 1, "a cached image is not fetched again")
        let local = await cache.fetch(URL(fileURLWithPath: "/etc/hosts"))
        XCTAssertFalse(local, "only http(s) addresses are fetched")

        var failing = LibraryArtworkCache(directory: scratch.appendingPathComponent("other"))
        failing.download = { _ in nil }
        let failed = await failing.fetch(artworkURL)
        XCTAssertFalse(failed)
        XCTAssertFalse(failing.isCached(artworkURL), "a failed download leaves nothing, so it is tried again later")
    }

    func testRuntimeCachesArtworkOnlyForEpisodesOnThePhone() async throws {
        let suite = "wilted.artprefetch.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        let server = InMemoryLibraryServer(writerDeviceID: "mac")
        let mac = InMemoryLibraryTransport(deviceID: "mac", server: server)
        let show = LibrarySource(id: try ItemID(rawValue: "show"), kind: .podcastFeed, title: "Show")
        var changes: [LibraryChange] = [.source(show)]
        for (index, raw) in ["a", "b"].enumerated() {
            let id = try ItemID(rawValue: raw)
            changes.append(.entry(try LibraryEntry(
                id: id, kind: .podcastEpisode, sourceID: show.id, title: raw, summary: "",
                publishedAt: Date(timeIntervalSince1970: 1_700_000_000), durationSeconds: 60,
                artworkRef: "https://example.com/\(raw).png")))
            changes.append(.slot(try QueueSlot(entryID: id, sortKey: Double(index))))
        }
        _ = try await mac.push(changes: changes.enumerated().map {
            PendingLibraryChange(localSeq: UInt64($0.offset + 1), change: $0.element, baseVersion: 0)
        })

        let image = png(side: 30)
        var cache = LibraryArtworkCache(directory: scratch)
        cache.download = { _ in image }
        let model = LibraryAppModel(
            transport: InMemoryLibraryTransport(deviceID: "phone", server: server), deviceID: "phone", preferences: defaults)
        let runtime = LibraryRuntime(
            model: model, player: player(RecordingNowPlaying()), settings: LibrarySettingsStore(defaults: defaults), artwork: cache)
        await runtime.prepare()
        await model.refresh()
        model.media[try ItemID(rawValue: "a")] = .onPhone

        let onPhone = URL(string: "https://example.com/a.png")!, notOnPhone = URL(string: "https://example.com/b.png")!
        for _ in 0..<300 where !cache.isCached(onPhone) { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(cache.isCached(onPhone), "an episode on the phone gets its artwork cached")
        XCTAssertFalse(cache.isCached(notOnPhone), "artwork for episodes not on the phone is left alone")
    }
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.lock(); defer { lock.unlock() }; return count }
    func bump() { lock.lock(); count += 1; lock.unlock() }
}
