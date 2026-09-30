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

    func testSpeedClampsToTheRangeInFiveHundredthsSteps() {
        XCTAssertEqual(LibrarySettingsStore.clampSpeed(0.1), 0.75)
        XCTAssertEqual(LibrarySettingsStore.clampSpeed(9), 2.0)
        XCTAssertEqual(LibrarySettingsStore.clampSpeed(1.27), 1.25)
        XCTAssertEqual(LibrarySettingsStore.clampSpeed(1.33), 1.35)
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

    func testStatisticsAreUnavailableUntilTheMacPublishes() {
        let rows = LibrarySettingsFormat.statRows(nil)
        XCTAssertEqual(rows.count, 4)
        XCTAssertTrue(rows.allSatisfy { $0.value == "Unavailable" })
        XCTAssertTrue(LibrarySettingsFormat.statsScope(nil).contains("Not published yet"))
    }

    func testStatisticsUseTheMacsLabelsAndSpokenDurations() {
        let stats = LibraryStats(
            audioProcessedSeconds: 3_725, speechGeneratedSeconds: 60, confirmedAdTimeRemovedSeconds: 0,
            fasterPlaybackTimeSavedSeconds: 7_200, updatedAt: Date(timeIntervalSince1970: 1_000))
        let rows = LibrarySettingsFormat.statRows(stats)
        XCTAssertEqual(rows.map(\.label), [
            "Audio processed", "Speech generated", "Confirmed ad time removed", "Time saved at faster speeds"])
        XCTAssertEqual(rows.map(\.value), ["1 hour 2 minutes 5 seconds", "1 minute", "0 seconds", "2 hours"])
        XCTAssertEqual(rows.map(\.identifier), [
            "wilted-lifetime-audio-processed", "wilted-lifetime-speech-generated",
            "wilted-lifetime-ad-time-removed", "wilted-lifetime-speed-time-saved"])
        XCTAssertTrue(LibrarySettingsFormat.statsScope(stats).hasPrefix("This Mac. Updated"))
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
        XCTAssertEqual(LibrarySettingsFormat.sync(isRefreshing: false, quarantined: false, error: nil, lastRefresh: now).status, "Up to date")
        XCTAssertEqual(LibrarySettingsFormat.sync(isRefreshing: false, quarantined: false, error: nil, lastRefresh: nil).status, "Not synced yet")
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

    func testStatisticsStayNilUntilThePublishedRecordIsRead() async throws {
        let model = makeModel(cache: FileMediaCache(rootURL: scratch.appendingPathComponent("cache")))
        await model.refresh()
        XCTAssertNil(model.lifetimeStats)

        let published = LibraryStats(audioProcessedSeconds: 600, updatedAt: Date(timeIntervalSince1970: 5))
        try await InMemoryLibraryTransport(deviceID: "mac", server: server).publishStats(published)
        await model.refresh()
        XCTAssertEqual(model.lifetimeStats, published)
    }

    func testMacLastSeenIsTheNewestMacRecordAndIgnoresPhones() throws {
        func observed(_ device: String, at seconds: TimeInterval) throws -> ObservedPlayback {
            ObservedPlayback(
                record: try DevicePlaybackPosition(
                    deviceID: device, entryID: id("a"), revision: RevisionID(rawValue: "r"), positionSeconds: 1,
                    isPlaying: false, epoch: 1),
                serverModifiedAt: Date(timeIntervalSince1970: seconds))
        }
        let records = LibraryDeviceRecords(
            nowPlaying: [try observed("mac-1", at: 100), try observed("iphone-2", at: 900)],
            progress: [try observed("mac-1", at: 300), try observed("phone", at: 950)])
        XCTAssertEqual(LibraryAppModel.macLastSeen(from: records, excluding: "phone"), Date(timeIntervalSince1970: 300))
        XCTAssertNil(LibraryAppModel.macLastSeen(from: LibraryDeviceRecords(), excluding: "phone"))
    }
}
