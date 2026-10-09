import CryptoKit
import Foundation
import SwiftUI
import UIKit
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

    func testLongStorageValueUsesFullWidthBelowLabel() throws {
        let summaries = [LibraryCacheSummary(episodeCount: 123_456, byteCount: 3_000_000_000_000), LibraryCacheSummary()]
        for width: CGFloat in [320, 390] {
            for scheme in [ColorScheme.light, .dark] {
                for summary in summaries {
                    let expected = LibrarySettingsFormat.storage(count: summary.episodeCount, bytes: summary.byteCount)
                    let capture = try PhoneLayoutCapture(LibraryStorageSummaryView(summary: summary), width: width, scheme: scheme)
                    let attachment = XCTAttachment(image: capture.image)
                    attachment.name = "storage-\(summary.episodeCount == 0 ? "none" : "long")-\(Int(width))-\(scheme == .dark ? "dark" : "light")"
                    attachment.lifetime = .keepAlways
                    add(attachment)
                    let label = try XCTUnwrap(capture.line(containing: "Downloaded audio"), "Shipping Storage label must render: \(capture.text)")
                    let value = try XCTUnwrap(capture.line(containing: expected),
                        "The complete value must occupy one deliberate line: \(capture.text)")
                    // Vision uses a bottom-left origin: the value must be below the label.
                    XCTAssertLessThanOrEqual(value.maxY, label.minY,
                        "Storage deliberately stacks its full-width value below the label")
                    XCTAssertGreaterThanOrEqual(value.minX, 0)
                    XCTAssertLessThanOrEqual(value.maxX, 1)

                }
            }
        }
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

    // MARK: cards

    func testAboutCardListsTheVersionAndNoDeviceIDRow() {
        let rows = LibrarySettingsFormat.aboutRows(version: "0.2.8 (7)")
        XCTAssertEqual(rows.map(\.identifier), [LibrarySettingsFormat.versionIdentifier])
        XCTAssertEqual(rows.map(\.label), ["Version"])
        XCTAssertFalse(rows.contains { $0.identifier == LibrarySettingsFormat.deviceIdentifier },
                       "the device ID moves out of About into Diagnostics")
    }

    func testDiagnosticsDisclosureKeepsTheDeviceIDCopyable() {
        let rows = LibrarySettingsFormat.diagnosticsRows(deviceID: "phone-123", syncDetail: nil)
        XCTAssertEqual(rows.map(\.identifier), [LibrarySettingsFormat.deviceIdentifier])
        XCTAssertEqual(rows.first?.label, "Device")
        XCTAssertEqual(rows.first?.value, "phone-123")
        XCTAssertEqual(rows.first?.isCopyable, true, "the device ID stays copyable")
    }

    func testSyncDetailShowsInlineOnlyForAnErrorAndOtherwiseWaitsInDiagnostics() {
        let fetched = LibrarySettingsFormat.sync(
            isRefreshing: false, quarantined: false, error: nil, lastRefresh: Date())
        XCTAssertFalse(LibrarySettingsFormat.showsSyncDetailInline(fetched))
        let fetchedRows = LibrarySettingsFormat.diagnosticsRows(deviceID: "phone", syncDetail: fetched.detail)
        XCTAssertEqual(fetchedRows.map(\.identifier),
                       [LibrarySettingsFormat.deviceIdentifier, LibrarySettingsFormat.syncDetailIdentifier])

        let failure = LibrarySettingsFormat.sync(
            isRefreshing: false, quarantined: false, error: "The library could not be fetched.", lastRefresh: nil)
        XCTAssertTrue(LibrarySettingsFormat.showsSyncDetailInline(failure))
        XCTAssertEqual(failure.detail, "The library could not be fetched.")
    }

    // MARK: model seam

    private let server = InMemoryLibraryServer(writerDeviceID: "mac")
    private lazy var mediaPhone = InMemoryLibraryTransport(deviceID: "phone", server: server, verifiedOwnerToken: "fixture-owner")
    private lazy var mediaMirror = FileLibraryStore(url: scratch.appendingPathComponent("media-mirror.json"))
    private var mediaFixtureSequence: UInt64 = 0
    private func id(_ raw: String) -> ItemID { try! ItemID(rawValue: raw) }

    private func makeModel(cache: FileMediaCache) async throws -> LibraryAppModel {
        try await PreparedMediaFixture.bootstrap(mediaMirror, transport: mediaPhone)
        let model = LibraryAppModel(transport: mediaPhone, store: mediaMirror, deviceID: "phone",
            mediaCache: cache, preferences: defaults, timeZone: TimeZone(identifier: "UTC")!)
        await model.loadLocalState()
        return model
    }

    private func cacheEpisode(_ cache: FileMediaCache, _ raw: String, bytes: Int) async throws {
        let mac = InMemoryLibraryTransport(deviceID: "mac", server: server, verifiedOwnerToken: "fixture-owner")
        let showID = id("show")
        var changes: [LibraryChange] = []
        if mediaFixtureSequence == 0 {
            changes.append(.source(LibrarySource(id: showID, kind: .podcastFeed, title: "Show")))
        }
        changes.append(.entry(try LibraryEntry(id: id(raw), kind: .podcastEpisode, sourceID: showID,
            title: raw, summary: "", publishedAt: Date(timeIntervalSince1970: 1_000), durationSeconds: 60)))
        changes.append(.slot(try QueueSlot(entryID: id(raw), sortKey: Double(mediaFixtureSequence))))
        let pending = changes.map { change in
            mediaFixtureSequence += 1
            return PendingLibraryChange(localSeq: mediaFixtureSequence, change: change, baseVersion: 0)
        }
        let pushed = try await mac.push(changes: pending)
        XCTAssertTrue(pushed.failures.isEmpty)
        try await PreparedMediaFixture.bootstrap(mediaMirror, transport: mediaPhone)
        let data = Data(repeating: 7, count: bytes)
        let hash = MediaHash.prefix + SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let offer = try PreparedMediaFixture.certified(LibraryMediaOffer(
            entryID: id(raw), revisionID: try RevisionID(rawValue: "rev-\(raw)"), contentHash: hash,
            byteCount: Int64(bytes), mediaType: "audio/mp4", durationSeconds: 60))
        let file = scratch.appendingPathComponent(UUID().uuidString)
        try data.write(to: file)
        _ = try await PreparedMediaFixture.adopt(into: cache, verifiedFile: file, for: offer, owner: "fixture-owner")
    }

    func testCacheSummaryCountsEpisodesAndBytes() async throws {
        let cache = FileMediaCache(rootURL: scratch.appendingPathComponent("cache"))
        let model = try await makeModel(cache: cache)
        let empty = await model.cacheSummary()
        XCTAssertEqual(empty, LibraryCacheSummary())
        try await cacheEpisode(cache, "a", bytes: 1_000)
        try await cacheEpisode(cache, "b", bytes: 2_500)
        let summary = await model.cacheSummary()
        XCTAssertEqual(summary, LibraryCacheSummary(episodeCount: 2, byteCount: 3_500))
        let withoutPlaying = await model.cacheSummary(excluding: id("b"))
        XCTAssertEqual(withoutPlaying, LibraryCacheSummary(episodeCount: 1, byteCount: 1_000))
    }

    func testHeldStorageSummaryAndExplicitClearCountRetainedBytesWithoutGrantingPlayback() async throws {
        let cache = FileMediaCache(rootURL: scratch.appendingPathComponent("held-cache"))
        try await cacheEpisode(cache, "a", bytes: 1_000)
        try await cacheEpisode(cache, "b", bytes: 2_500)
        let model = try await makeModel(cache: cache)
        let certified = await cache.cachedEntries()
        let first = try XCTUnwrap(certified[id("a")])
        let second = try XCTUnwrap(certified[id("b")])
        XCTAssertEqual(certified.count, 2, "the storage regression starts with actual admitted audio")

        try await mediaMirror.quarantine()
        await model.loadLocalState()
        XCTAssertTrue(model.accountQuarantined)
        let heldInventory = await cache.cachedEntries()
        XCTAssertTrue(heldInventory.isEmpty, "held audio remains playback-inert")
        let firstPlayable = await cache.verifies(first)
        let secondPlayable = await cache.verifies(second)
        XCTAssertFalse(firstPlayable)
        XCTAssertFalse(secondPlayable)
        let admission = await cache.admission(entryID: id("a"), ownerToken: "fixture-owner",
            libraryScope: LibraryAppModel.mediaLibraryScope, transportGeneration: 0)
        XCTAssertNil(admission)
        XCTAssertEqual(try Data(contentsOf: first.url), Data(repeating: 7, count: 1_000))
        XCTAssertEqual(try Data(contentsOf: second.url), Data(repeating: 7, count: 2_500))
        XCTAssertTrue(FileManager.default.fileExists(atPath: first.url.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: second.url.path))
        let heldSummary = await model.cacheSummary()
        XCTAssertEqual(heldSummary, LibraryCacheSummary(episodeCount: 2, byteCount: 3_500))
        let excludingKept = await model.cacheSummary(excluding: id("b"))
        XCTAssertEqual(excludingKept, LibraryCacheSummary(episodeCount: 1, byteCount: 1_000))

        let removed = await model.removeAllDownloadedAudio(keeping: id("b"))
        XCTAssertEqual(removed, 1, "explicit clear removes retained audio even while admission is held")
        XCTAssertFalse(FileManager.default.fileExists(atPath: first.url.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: second.url.path))
        let keptSummary = await model.cacheSummary()
        XCTAssertEqual(keptSummary, LibraryCacheSummary(episodeCount: 1, byteCount: 2_500))
        let stillHeld = await cache.cachedEntries()
        XCTAssertTrue(stillHeld.isEmpty, "storage accounting never grants playable inventory")
        let rest = await model.removeAllDownloadedAudio(keeping: nil)
        XCTAssertEqual(rest, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: second.url.path))
        let emptySummary = await model.cacheSummary()
        XCTAssertEqual(emptySummary, LibraryCacheSummary())
        let afterClear = await cache.admission(entryID: id("b"), ownerToken: "fixture-owner",
            libraryScope: LibraryAppModel.mediaLibraryScope, transportGeneration: 0)
        XCTAssertNil(afterClear)
    }

    func testRemoveAllKeepsTheEpisodePlayingNow() async throws {
        let cache = FileMediaCache(rootURL: scratch.appendingPathComponent("cache"))
        try await cacheEpisode(cache, "a", bytes: 1_000)
        try await cacheEpisode(cache, "b", bytes: 1_000)
        try await cacheEpisode(cache, "c", bytes: 1_000)
        let model = try await makeModel(cache: cache)
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
