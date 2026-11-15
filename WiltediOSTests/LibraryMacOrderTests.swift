import CryptoKit
import Foundation
import WiltedDomain
import WiltedLibrary
import WiltedPlayback
import XCTest
@testable import WiltediOS

/// Mac order in the list, model and runtime: rows arrive in the Mac's queue order, completed rows
/// list last, visible and play-order rows follow the choice, and runtime synchronizes settings without a queue hop.
@MainActor
final class LibraryMacOrderTests: XCTestCase {
    private let server = InMemoryLibraryServer(writerDeviceID: "mac")
    private lazy var mac = InMemoryLibraryTransport(deviceID: "mac", server: server, verifiedOwnerToken: "fixture-owner")
    private let suite = "library-mac-order-tests-\(UUID().uuidString)"
    private var scratch: URL!
    private var versions: [LibraryRecordKey: UInt64] = [:]
    private var localSeq: UInt64 = 0
    private let payload = Data((0..<20_000).map { UInt8($0 % 251) })

    override func setUp() async throws {
        UserDefaults(suiteName: suite)!.removePersistentDomain(forName: suite)
        scratch = FileManager.default.temporaryDirectory.appendingPathComponent("library-mac-order-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        UserDefaults(suiteName: suite)!.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: scratch)
    }

    private func id(_ raw: String) -> ItemID { try! ItemID(rawValue: raw) }
    private func ids(_ rows: [LibraryRow]) -> [String] { rows.map(\.id.rawValue) }

    private func row(
        _ raw: String, title: String? = nil, show: String = "Show",
        kind: LibraryKind = .podcastEpisode, published: TimeInterval = 1_000,
        duration: Double? = 600, completedAt: Date? = nil, summary: String = ""
    ) -> LibraryRow {
        var r = LibraryRow(
            id: id(raw), title: title ?? raw, showTitle: show,
            durationText: duration.map(LibraryClockFormat.duration), durationSeconds: duration,
            removal: .none, publishedAt: Date(timeIntervalSince1970: published), removalText: nil,
            checkpointText: nil)
        r.kind = kind
        r.completedAt = completedAt
        r.summary = summary
        return r
    }

    private func makeModel(preferences: UserDefaults? = nil, cache: FileMediaCache? = nil) -> LibraryAppModel {
        LibraryAppModel(
            transport: InMemoryLibraryTransport(deviceID: "phone", server: server, verifiedOwnerToken: "fixture-owner"),
            store: FileLibraryStore(url: scratch.appendingPathComponent("mirror-" + UUID().uuidString + ".json")),
            deviceID: "phone",
            mediaCache: cache ?? FileMediaCache(rootURL: scratch.appendingPathComponent("cache")),
            mediaTiming: LibraryMediaTiming(pollInterval: .milliseconds(5), offerTimeout: .seconds(5), watchdog: .seconds(30)),
            preferences: preferences ?? UserDefaults(suiteName: suite)!,
            timeZone: TimeZone(identifier: "UTC")!)
    }

    /// A model whose `raws` sit in the real media cache, so a later refresh keeps them on the phone.
    private func makeModelWithDownloaded(_ raws: [String]) async throws -> LibraryAppModel {
        let phone = InMemoryLibraryTransport(deviceID: "phone", server: server, verifiedOwnerToken: "fixture-owner")
        let mirror = FileLibraryStore(url: scratch.appendingPathComponent("mirror-" + UUID().uuidString + ".json"))
        try await PreparedMediaFixture.bootstrap(mirror, transport: phone)
        let cache = FileMediaCache(rootURL: scratch.appendingPathComponent("cache-" + UUID().uuidString))
        for raw in raws {
            let file = scratch.appendingPathComponent(UUID().uuidString)
            try payload.write(to: file)
            let certified = try PreparedMediaFixture.certified(LibraryMediaOffer(
                entryID: id(raw), revisionID: RevisionID(rawValue: "rev-1"),
                contentHash: PreparedMediaFixture.hash(payload),
                byteCount: Int64(payload.count), mediaType: "audio/mp4", durationSeconds: 600))
            try await mac.publishMedia(offer: certified, fileURL: file)
            _ = try await PreparedMediaFixture.adopt(into: cache, verifiedFile: file, for: certified, owner: "fixture-owner")
        }
        let model = LibraryAppModel(
            transport: phone, store: mirror, deviceID: "phone", mediaCache: cache,
            mediaTiming: LibraryMediaTiming(pollInterval: .milliseconds(5), offerTimeout: .seconds(5), watchdog: .seconds(30)),
            preferences: UserDefaults(suiteName: suite)!,
            timeZone: TimeZone(identifier: "UTC")!)
        await model.refresh()
        return model
    }

    private func macPush(_ changes: [LibraryChange]) async throws {
        let pending = changes.map { change -> PendingLibraryChange in
            localSeq += 1
            return PendingLibraryChange(localSeq: localSeq, change: change, baseVersion: versions[change.key] ?? 0)
        }
        let result = try await mac.push(changes: pending)
        XCTAssertTrue(result.failures.isEmpty)
        for ack in result.acknowledged { versions[ack.key] = ack.version }
    }

    private func seed(_ raws: [String], showID: String = "show", showTitle: String = "The Show") async throws {
        var changes: [LibraryChange] = [.source(LibrarySource(id: id(showID), kind: .podcastFeed, title: showTitle))]
        for (index, raw) in raws.enumerated() {
            changes.append(.entry(try LibraryEntry(
                id: id(raw), kind: .podcastEpisode, sourceID: id(showID), title: "Title \(raw)", summary: "Notes about \(raw)",
                publishedAt: Date(timeIntervalSince1970: 1_600_000_000 + Double(index)), durationSeconds: 600,
                artworkRef: "https://example.com/\(raw).jpg")))
            changes.append(.slot(try QueueSlot(entryID: id(raw), sortKey: Double(index))))
        }
        try await macPush(changes)
    }

    private func offer(_ raw: String) async throws {
        let file = scratch.appendingPathComponent(UUID().uuidString)
        try payload.write(to: file)
        let digest = MediaHash.prefix + SHA256.hash(data: payload).map { String(format: "%02x", $0) }.joined()
        try await mac.publishMedia(
            offer: try PreparedMediaFixture.certified(LibraryMediaOffer(
                entryID: id(raw), revisionID: RevisionID(rawValue: "rev-1"), contentHash: digest,
                byteCount: Int64(payload.count), mediaType: "audio/mp4", durationSeconds: 600)),
            fileURL: file)
    }

    // MARK: - Pure Listing Tests

    func testRowsInMacOrderKeepsArrivingOrderWithInProgressInPlaceAndCompletedLast() {
        let r1 = row("1", title: "First")
        let r2 = row("2", title: "Second")
        let r3 = row("3", title: "Third")
        let r4 = row("4", title: "Fourth", completedAt: Date(timeIntervalSince1970: 2_000))
        let r5 = row("5", title: "Fifth")
        let allRows = [r4, r1, r2, r3, r5] // r4 is completed and arrives first

        let offered = Set(allRows.map(\.id))
        let progress = [id("2"): EpisodeProgress(positionSeconds: 120, lastPlayedAt: Date(timeIntervalSince1970: 3_000))]
        let finished = [id("5"): Date(timeIntervalSince1970: 2_500)]

        let result = LibraryListing.rows(
            allRows, offered: offered, onPhone: [], filter: .all, query: "",
            progress: progress, finished: finished, order: .mac)

        // Uncompleted: r1, r2 (in-progress kept in place at index 1), r3.
        // Completed: r4 (completedAt), r5 (finished dictionary), kept in arriving order last.
        XCTAssertEqual(ids(result), ["1", "2", "3", "4", "5"])
    }

    func testRowsInMacOrderAppliesFilterKindAndQuery() {
        let r1 = row("1", title: "Swift Guide", show: "Tech", kind: .podcastEpisode, summary: "iOS notes")
        let r2 = row("2", title: "Article Deep Dive", show: "News", kind: .article, summary: "Swift syntax")
        let r3 = row("3", title: "Audio Novel", show: "Books", kind: .audiobook, summary: "Story")
        let allRows = [r1, r2, r3]
        let offered = Set([id("1"), id("2"), id("3")])
        let onPhone = Set([id("1")])

        // Filter: onPhone vs available
        let phoneOnly = LibraryListing.rows(allRows, offered: offered, onPhone: onPhone, filter: .onPhone, query: "", order: .mac)
        XCTAssertEqual(ids(phoneOnly), ["1"])

        let availableOnly = LibraryListing.rows(allRows, offered: offered, onPhone: onPhone, filter: .available, query: "", order: .mac)
        XCTAssertEqual(ids(availableOnly), ["2", "3"])

        // Kind filter
        let podcastsOnly = LibraryListing.rows(allRows, offered: offered, onPhone: onPhone, filter: .all, kind: .podcasts, query: "", order: .mac)
        XCTAssertEqual(ids(podcastsOnly), ["1"])

        let articlesOnly = LibraryListing.rows(allRows, offered: offered, onPhone: onPhone, filter: .all, kind: .articles, query: "", order: .mac)
        XCTAssertEqual(ids(articlesOnly), ["2"])

        // Query matching summary, title or show
        let querySummary = LibraryListing.rows(allRows, offered: offered, onPhone: onPhone, filter: .all, query: "syntax", order: .mac)
        XCTAssertEqual(ids(querySummary), ["2"])

        let queryTitle = LibraryListing.rows(allRows, offered: offered, onPhone: onPhone, filter: .all, query: "Guide", order: .mac)
        XCTAssertEqual(ids(queryTitle), ["1"])

        let queryShow = LibraryListing.rows(allRows, offered: offered, onPhone: onPhone, filter: .all, query: "Books", order: .mac)
        XCTAssertEqual(ids(queryShow), ["3"])
    }

    func testRowsWithDefaultOrderEqualsPlayOrder() {
        let r1 = row("1", title: "Old Not Started", published: 100)
        let r2 = row("2", title: "New In Progress", published: 500)
        let allRows = [r1, r2]
        let offered = Set([id("1"), id("2")])
        let progress = [id("2"): EpisodeProgress(positionSeconds: 60, lastPlayedAt: Date(timeIntervalSince1970: 2_000))]

        let defaultCall = LibraryListing.rows(allRows, offered: offered, onPhone: [], filter: .all, query: "", progress: progress)
        let playOrderCall = LibraryListing.rows(allRows, offered: offered, onPhone: [], filter: .all, query: "", progress: progress, order: .playOrder)
        let macOrderCall = LibraryListing.rows(allRows, offered: offered, onPhone: [], filter: .all, query: "", progress: progress, order: .mac)

        // In play order: in-progress episode r2 precedes unstarted r1.
        XCTAssertEqual(ids(defaultCall), ["2", "1"])
        XCTAssertEqual(ids(defaultCall), ids(playOrderCall))
        // In mac order: queue arrival order [r1, r2] is preserved.
        XCTAssertEqual(ids(macOrderCall), ["1", "2"])
    }

    // MARK: - Model Order Tests

    func testModelVisibleRowsAndPlayOrderRowsFollowQueueOrderInMacOrder() async throws {
        try await seed(["1", "2", "3"])
        let model = try await makeModelWithDownloaded(["1", "2", "3"])
        XCTAssertEqual(model.preparedIDs.onPhone, Set(["1", "2", "3"].map(id)))

        // Make "2" in-progress so play order would put "2" first
        try await InMemoryLibraryTransport(deviceID: "mac", server: server, verifiedOwnerToken: "fixture-owner").publish(
            try DevicePlaybackPosition(
                deviceID: "mac", entryID: id("2"), revision: RevisionID(rawValue: "rev-1"),
                positionSeconds: 150, isPlaying: false, epoch: 1),
            as: .progress)
        await model.refresh()

        // Default listOrder is .playOrder: "2" lists first
        XCTAssertEqual(model.listOrder, .playOrder)
        XCTAssertEqual(ids(model.visibleRows), ["2", "1", "3"])
        XCTAssertEqual(ids(model.playOrderRows), ["2", "1", "3"])

        // In .mac listOrder: visibleRows and playOrderRows both follow queue order
        model.listOrder = .mac
        XCTAssertEqual(ids(model.visibleRows), ["1", "2", "3"])
        XCTAssertEqual(ids(model.playOrderRows), ["1", "2", "3"])
    }

    func testRebuiltQueueWithChangedSlotOrderChangesPlayOrderRows() async throws {
        try await seed(["1", "2", "3"])
        let model = try await makeModelWithDownloaded(["1", "2", "3"])
        XCTAssertEqual(model.preparedIDs.onPhone, Set(["1", "2", "3"].map(id)))

        model.listOrder = .mac
        XCTAssertEqual(ids(model.playOrderRows), ["1", "2", "3"])

        // Mac reorders queue slots: "3", "1", "2"
        let reorderedSlots: [LibraryChange] = [
            .slot(try QueueSlot(entryID: id("3"), sortKey: 0)),
            .slot(try QueueSlot(entryID: id("1"), sortKey: 1)),
            .slot(try QueueSlot(entryID: id("2"), sortKey: 2)),
        ]
        try await macPush(reorderedSlots)
        await model.refresh()

        XCTAssertEqual(ids(model.playOrderRows), ["3", "1", "2"])
        XCTAssertEqual(ids(model.visibleRows), ["3", "1", "2"])
    }

    func testRetainedDisplaySnapshotInAnotherOrderFollowsCurrentQueueOrderInMacOrder() async throws {
        try await seed(["1", "2", "3"])
        for raw in ["1", "2", "3"] { try await offer(raw) }
        let model = makeModel()
        await model.refresh()

        model.listOrder = .mac
        // Retained display snapshot presents rows in reversed order, plus an extra unqueued row
        let extraRow = row("extra", title: "Unqueued")
        model.completedDisplayRows = [row("3"), row("2"), extraRow, row("1")]

        // In .mac, visibleRows orders rows by index in logicalQueued; rows not in it keep relative order last
        XCTAssertEqual(ids(model.visibleRows), ["1", "2", "3", "extra"])
    }

    // MARK: - Persistence and Setting Tests

    func testMacOrderPersistsAndReloadsAndUnknownStoredValueReadsAsPlayOrder() {
        let defaults = UserDefaults(suiteName: suite)!
        let store = LibrarySettingsStore(defaults: defaults)
        store.listSort = .macOrder

        let reopened = LibrarySettingsStore(defaults: defaults)
        XCTAssertEqual(reopened.listSort, .macOrder)

        // Unknown string falls back to .playOrder
        defaults.set("futureCustomOrder", forKey: LibrarySettingsStore.listSortKey)
        let fallback = LibrarySettingsStore(defaults: defaults)
        XCTAssertEqual(fallback.listSort, .playOrder)

        // Non-string falls back to .playOrder
        defaults.set(42, forKey: LibrarySettingsStore.listSortKey)
        let nonStringFallback = LibrarySettingsStore(defaults: defaults)
        XCTAssertEqual(nonStringFallback.listSort, .playOrder)
    }

    // MARK: - Organization and Cue Tests

    func testOrganizeLeavesRowsAsTheyArriveForMacOrder() {
        let arriving = [row("c", title: "Cherry", show: "Fruit"), row("a", title: "Apple", show: "Tech"), row("b", title: "Banana", show: "Fruit")]

        // No grouping: single section with rows in arriving order
        let sections = LibraryListing.organize(arriving, sort: .macOrder, group: .none)
        XCTAssertEqual(sections.count, 1)
        XCTAssertNil(sections[0].title)
        XCTAssertEqual(ids(sections[0].rows), ["c", "a", "b"])

        // Group by feed: feeds ordered by first row appearance, rows inside keep arriving order
        let grouped = LibraryListing.organize(arriving, sort: .macOrder, group: .feed)
        XCTAssertEqual(grouped.map(\.title), ["Fruit", "Tech"])
        XCTAssertEqual(grouped.map { ids($0.rows) }, [["c", "b"], ["a"]])
    }

    func testToolbarSortCueLabelAndActiveStateForMacOrder() {
        let cueNoGroup = LibraryToolbar.sortCue(sort: .macOrder, group: .none)
        XCTAssertEqual(cueNoGroup.label, "Sort: Mac order")
        XCTAssertTrue(cueNoGroup.isActive)
        XCTAssertEqual(cueNoGroup.symbol, "arrow.up.arrow.down.circle.fill")

        let cueFeedGroup = LibraryToolbar.sortCue(sort: .macOrder, group: .feed)
        XCTAssertEqual(cueFeedGroup.label, "Mac order · Feed")
        XCTAssertTrue(cueFeedGroup.isActive)
        XCTAssertEqual(cueFeedGroup.symbol, "arrow.up.arrow.down.circle.fill")

        let cuePlayOrder = LibraryToolbar.sortCue(sort: .playOrder, group: .none)
        XCTAssertEqual(cuePlayOrder.label, "Sort and group")
        XCTAssertFalse(cuePlayOrder.isActive)
        XCTAssertEqual(cuePlayOrder.symbol, "arrow.up.arrow.down.circle")
    }

    func testOrderNoteReturnsTheThreeTexts() {
        XCTAssertNil(LibraryToolbar.orderNote(sort: .playOrder))
        XCTAssertEqual(
            LibraryToolbar.orderNote(sort: .macOrder),
            "Mac order, as last synced. Playback and Next follow it.")
        XCTAssertEqual(
            LibraryToolbar.orderNote(sort: .newest),
            "Sorted by Newest. Playback and Next still follow the play order.")
        XCTAssertEqual(
            LibraryToolbar.orderNote(sort: .oldest),
            "Sorted by Oldest. Playback and Next still follow the play order.")
        XCTAssertEqual(
            LibraryToolbar.orderNote(sort: .shortest),
            "Sorted by Shortest. Playback and Next still follow the play order.")
        XCTAssertEqual(
            LibraryToolbar.orderNote(sort: .title),
            "Sorted by Title. Playback and Next still follow the play order.")
    }

    // MARK: - Runtime Immediate Subscription Tests

    func testRuntimeSubscribesToSettingsListSortImmediatelyAndWithoutQueueHop() {
        let runtimeSuite = "wilted.macorder.runtime.\(UUID().uuidString)"
        let runtimeDefaults = UserDefaults(suiteName: runtimeSuite)!
        addTeardownBlock { UserDefaults(suiteName: runtimeSuite)?.removePersistentDomain(forName: runtimeSuite) }
        runtimeDefaults.set(LibrarySortOption.macOrder.rawValue, forKey: LibrarySettingsStore.listSortKey)

        let settings = LibrarySettingsStore(defaults: runtimeDefaults)
        XCTAssertEqual(settings.listSort, .macOrder)

        let model = makeModel(preferences: runtimeDefaults)
        XCTAssertEqual(model.listOrder, .playOrder, "model default is playOrder before runtime init binds")

        let player = LibraryPlayer(
            engine: RuntimeFakeEngine(), session: RuntimeFakeSession(), nowPlaying: RuntimeFakeNowPlaying(),
            remoteCommands: RuntimeFakeRemote(), sessionEvents: RuntimeFakeEvents(), tickInterval: .seconds(3600))
        let runtime = LibraryRuntime(model: model, player: player, settings: settings)

        // Must have .mac before prepare() is called
        XCTAssertEqual(runtime.model.listOrder, .mac)

        // Setting listSort to .newest updates listOrder to .playOrder synchronously without run loop hop
        settings.listSort = .newest
        XCTAssertEqual(runtime.model.listOrder, .playOrder)
    }
}
