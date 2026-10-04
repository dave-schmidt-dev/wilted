import CryptoKit
import Foundation
import WiltedDomain
import WiltedLibrary
import XCTest
@testable import WiltediOS

/// The phone's Settings: persisted preferences and their clamping, the statistics wording, and the
/// model seam (cache size, bulk removal that spares the playing episode, statistics refresh).
@MainActor
final class LibrarySettingsTests: XCTestCase {
    private let suite = "library-settings-tests"
    private var defaults: UserDefaults!
    private var scratch: URL!

    override func setUp() async throws {
        defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        scratch = FileManager.default.temporaryDirectory.appendingPathComponent("library-settings-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: scratch)
    }

    // MARK: store

    func testDefaultsMatchThePlayerAndTheOwnersPreference() {
        let store = LibrarySettingsStore(defaults: defaults)
        XCTAssertEqual(store.defaultSpeed, 1.25)
        XCTAssertEqual(store.skipBackSeconds, 15)
        XCTAssertEqual(store.skipForwardSeconds, 30)
        XCTAssertEqual(store.textScale, .standard)
    }

    func testSpeedClampsToTheRangeInQuarterSteps() {
        XCTAssertEqual(LibrarySettingsStore.clampSpeed(0.1), 0.5)
        XCTAssertEqual(LibrarySettingsStore.clampSpeed(9), 2.0)
        XCTAssertEqual(LibrarySettingsStore.clampSpeed(1.27), 1.25)
        XCTAssertEqual(LibrarySettingsStore.clampSpeed(1.4), 1.5)
        XCTAssertEqual(LibrarySettingsStore.clampSpeed(1.35), 1.25)
        XCTAssertEqual(LibrarySettingsStore.clampSpeed(1.05), 1.0, "an old 0.05-step value rounds to the nearest quarter")
        XCTAssertEqual(PlaybackSpeeds.step, 0.25)
        XCTAssertEqual(LibrarySettingsStore.clampSpeed(0.1), PlaybackSpeeds.all.first)
        XCTAssertEqual(LibrarySettingsStore.clampSpeed(9), PlaybackSpeeds.all.last)
        XCTAssertEqual(LibrarySettingsStore.clampSpeed(.nan), 1.25)
        XCTAssertEqual(LibrarySettingsStore.clampSpeed(.infinity), 1.25)
    }

    func testChangesPersistAcrossInstancesAndAreClampedOnWrite() {
        let store = LibrarySettingsStore(defaults: defaults)
        store.defaultSpeed = 1.75
        store.skipBackSeconds = 10
        store.skipForwardSeconds = 60
        store.textScale = .larger
        let reloaded = LibrarySettingsStore(defaults: defaults)
        XCTAssertEqual(reloaded.defaultSpeed, 1.75)
        XCTAssertEqual(reloaded.skipBackSeconds, 10)
        XCTAssertEqual(reloaded.skipForwardSeconds, 60)
        XCTAssertEqual(reloaded.textScale, .larger)

        reloaded.defaultSpeed = 12
        XCTAssertEqual(reloaded.defaultSpeed, 2.0)
        XCTAssertEqual(defaults.double(forKey: LibrarySettingsStore.speedKey), 2.0)
        reloaded.skipForwardSeconds = 58
        XCTAssertEqual(reloaded.skipForwardSeconds, 60)
    }

    func testCorruptStoredValuesFallBackInsteadOfReachingThePlayer() {
        defaults.set(99.0, forKey: LibrarySettingsStore.speedKey)
        defaults.set(-4, forKey: LibrarySettingsStore.skipBackKey)
        defaults.set("enormous", forKey: LibrarySettingsStore.textScaleKey)
        let store = LibrarySettingsStore(defaults: defaults)
        XCTAssertEqual(store.defaultSpeed, 2.0)
        XCTAssertEqual(store.skipBackSeconds, 5)
        XCTAssertEqual(store.textScale, .standard)
    }

    func testEveryOfferedSkipLengthHasAMatchingSymbolName() {
        XCTAssertEqual(LibrarySettingsStore.skipOptions, [5, 10, 15, 30, 45, 60, 75, 90])
        XCTAssertTrue(LibrarySettingsStore.skipOptions.contains(LibrarySettingsStore.defaultSkipBack))
        XCTAssertTrue(LibrarySettingsStore.skipOptions.contains(LibrarySettingsStore.defaultSkipForward))
    }

    // MARK: format

    func testPhoneStatisticsReadNoneUntilThereIsSomethingToCount() {
        let rows = LibrarySettingsFormat.phoneStatRows(LibraryPhoneStats())
        XCTAssertEqual(rows.map(\.label), ["Listening time", "Downloaded from Mac", "Time saved at faster speeds"])
        XCTAssertTrue(rows.allSatisfy { $0.value == "None" })
    }

    func testPhoneStatisticsUseSpokenDurationsAndFileSizes() {
        let rows = LibrarySettingsFormat.phoneStatRows(
            LibraryPhoneStats(listenedSeconds: 3_725, downloadedBytes: 41_200_000, savedSeconds: 7_200))
        XCTAssertEqual(rows[0].value, "1 hour 2 minutes 5 seconds")
        XCTAssertEqual(rows[1].value, ByteCountFormatter.string(fromByteCount: 41_200_000, countStyle: .file))
        XCTAssertEqual(rows[2].value, "2 hours")
    }

    func testListeningCountsRealTimeAndSavesOnlyAboveNormalSpeed() {
        let store = LibraryPhoneStatsStore(defaults: defaults)
        store.recordListening(wall: 60, rate: 1.5)
        store.recordListening(wall: 60, rate: 1)
        store.recordListening(wall: 60, rate: 0.75)
        XCTAssertEqual(store.stats.listenedSeconds, 180)
        XCTAssertEqual(store.stats.savedSeconds, 30, accuracy: 0.001)
        store.recordListening(wall: -5, rate: 2)
        store.recordListening(wall: .nan, rate: 2)
        XCTAssertEqual(store.stats.listenedSeconds, 180)
    }

    func testPhoneStatisticsSurviveARelaunch() {
        let store = LibraryPhoneStatsStore(defaults: defaults)
        store.recordListening(wall: 4, rate: 2)
        store.recordDownload(bytes: 1_000)
        store.recordDownload(bytes: 0)
        store.flush()
        let reloaded = LibraryPhoneStatsStore(defaults: defaults)
        XCTAssertEqual(reloaded.stats, LibraryPhoneStats(listenedSeconds: 4, downloadedBytes: 1_000, savedSeconds: 4))
    }

    func testStorageSpeedVersionAndSyncWording() {
        XCTAssertEqual(LibrarySettingsFormat.storage(count: 0, bytes: 0), "None")
        XCTAssertTrue(LibrarySettingsFormat.storage(count: 1, bytes: 1_000_000).hasPrefix("1 episode · "))
        XCTAssertTrue(LibrarySettingsFormat.storage(count: 3, bytes: 1_000_000).hasPrefix("3 episodes · "))
        XCTAssertEqual(LibrarySettingsFormat.speed(1.25), "1.25x")
        XCTAssertEqual(LibrarySettingsFormat.speed(2), "2x")
        XCTAssertEqual(LibrarySettingsFormat.version(["CFBundleShortVersionString": "0.2.8", "CFBundleVersion": "7"]), "0.2.8 (7)")
        XCTAssertEqual(LibrarySettingsFormat.version(nil), "Unknown")
        XCTAssertEqual(LibrarySettingsFormat.date(nil), "Not yet")

        let now = Date()
        XCTAssertEqual(LibrarySettingsFormat.sync(isRefreshing: false, quarantined: true, error: "x", lastRefresh: now).status, "Needs review")
        XCTAssertEqual(LibrarySettingsFormat.sync(isRefreshing: true, quarantined: false, error: "x", lastRefresh: now).status, "Syncing")
        XCTAssertEqual(LibrarySettingsFormat.sync(isRefreshing: false, quarantined: false, error: "x", lastRefresh: now).detail, "x")
        let paused = LibrarySettingsFormat.sync(
            isRefreshing: true, quarantined: false, error: "x", lastRefresh: now, throttleNotice: "iCloud is rate limiting sync.")
        XCTAssertEqual(paused.status, "Paused")
        XCTAssertEqual(paused.detail, "iCloud is rate limiting sync.")
        XCTAssertEqual(LibrarySettingsFormat.sync(isRefreshing: false, quarantined: false, error: nil, lastRefresh: now).status, "Fetched")
        XCTAssertEqual(LibrarySettingsFormat.sync(isRefreshing: false, quarantined: false, error: nil, lastRefresh: nil).status, "Not synced yet")

        let current = LibrarySettingsFormat.sync(isRefreshing: false, quarantined: false, error: nil, lastRefresh: now)
        XCTAssertEqual(LibrarySettingsFormat.syncLine(current, lastRefresh: now), "Fetched · \(LibrarySettingsFormat.date(now))")
        let broken = LibrarySettingsFormat.sync(isRefreshing: false, quarantined: false, error: "x", lastRefresh: now)
        XCTAssertEqual(LibrarySettingsFormat.syncLine(broken, lastRefresh: now), "Problem")
    }

    // MARK: model seam

    private let server = InMemoryLibraryServer(writerDeviceID: "mac")
    private func id(_ raw: String) -> ItemID { try! ItemID(rawValue: raw) }

    private func makeModel(cache: FileMediaCache) -> LibraryAppModel {
        LibraryAppModel(
            transport: InMemoryLibraryTransport(deviceID: "phone", server: server), deviceID: "phone",
            mediaCache: cache, preferences: defaults, timeZone: TimeZone(identifier: "UTC")!)
    }

    private func cacheEpisode(_ cache: FileMediaCache, _ raw: String, bytes: Int) async throws {
        let data = Data(repeating: 7, count: bytes)
        let hash = MediaHash.prefix + SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let offer = try LibraryMediaOffer(
            entryID: id(raw), revisionID: try RevisionID(rawValue: "rev-\(raw)"), contentHash: hash,
            byteCount: Int64(bytes), mediaType: "audio/mp4", durationSeconds: 60)
        let file = scratch.appendingPathComponent(UUID().uuidString)
        try data.write(to: file)
        _ = try await cache.adopt(verifiedFile: file, for: offer)
    }

    func testCacheSummaryCountsEpisodesAndBytes() async throws {
        let cache = FileMediaCache(rootURL: scratch.appendingPathComponent("cache"))
        let model = makeModel(cache: cache)
        let empty = await model.cacheSummary()
        XCTAssertEqual(empty, LibraryCacheSummary())
        try await cacheEpisode(cache, "a", bytes: 1_000)
        try await cacheEpisode(cache, "b", bytes: 2_500)
        let summary = await model.cacheSummary()
        XCTAssertEqual(summary, LibraryCacheSummary(episodeCount: 2, byteCount: 3_500))
        let withoutPlaying = await model.cacheSummary(excluding: id("b"))
        XCTAssertEqual(withoutPlaying, LibraryCacheSummary(episodeCount: 1, byteCount: 1_000))
    }

    func testRemoveAllKeepsTheEpisodePlayingNow() async throws {
        let cache = FileMediaCache(rootURL: scratch.appendingPathComponent("cache"))
        try await cacheEpisode(cache, "a", bytes: 1_000)
        try await cacheEpisode(cache, "b", bytes: 1_000)
        try await cacheEpisode(cache, "c", bytes: 1_000)
        let model = makeModel(cache: cache)
        await model.refresh()

        let removed = await model.removeAllDownloadedAudio(keeping: id("b"))
        XCTAssertEqual(removed, 2)
        let left = await cache.cachedEntries()
        XCTAssertEqual(Set(left.keys), [id("b")])
        XCTAssertEqual(model.mediaState(for: id("a")), .available)
        XCTAssertEqual(model.mediaState(for: id("b")), .onPhone)

        let rest = await model.removeAllDownloadedAudio(keeping: nil)
        XCTAssertEqual(rest, 1)
        let none = await cache.cachedEntries()
        XCTAssertTrue(none.isEmpty)
    }
}
