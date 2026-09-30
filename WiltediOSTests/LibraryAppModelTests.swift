import Foundation
import WiltedDomain
import WiltedLibrary
import XCTest
@testable import WiltediOS

/// Drives `LibraryAppModel` against the in-memory transport: a "mac" writer publishes,
/// a "phone" reader fetches.
@MainActor
final class LibraryAppModelTests: XCTestCase {
    private let server = InMemoryLibraryServer(writerDeviceID: "mac")
    private lazy var mac = InMemoryLibraryTransport(deviceID: "mac", server: server)
    private var versions: [LibraryRecordKey: UInt64] = [:]
    private var localSeq: UInt64 = 0
    /// 2023-11-14 22:13:20 UTC.
    private let checkpointDate = Date(timeIntervalSince1970: 1_700_000_000)

    private func id(_ raw: String) -> ItemID { try! ItemID(rawValue: raw) }

    private func makeModel(store: any LibraryStore = InMemoryLibraryStore()) -> LibraryAppModel {
        LibraryAppModel(
            transport: InMemoryLibraryTransport(deviceID: "phone", server: server),
            store: store, deviceID: "phone", preferences: UserDefaults(suiteName: "library-app-model-tests")!, timeZone: TimeZone(identifier: "UTC")!)
    }

    private func entry(_ raw: String, title: String, show: String = "show", duration: Double? = 1_800,
                       removal: LibraryRemoval = .none) throws -> LibraryEntry {
        try LibraryEntry(id: id(raw), kind: .podcastEpisode, sourceID: id(show), title: title, summary: "",
                         publishedAt: Date(timeIntervalSince1970: 1_600_000_000), durationSeconds: duration, removal: removal)
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

    private func macPublish(_ raw: String, position: Double, playing: Bool = false, epoch: Int = 1,
                            device: String = "mac", channel: PlaybackChannel = .progress) async throws {
        await server.setClock(checkpointDate)
        let record = try DevicePlaybackPosition(
            deviceID: device, entryID: id(raw), revision: RevisionID(rawValue: "rev-1"),
            positionSeconds: position, isPlaying: playing, epoch: epoch)
        try await InMemoryLibraryTransport(deviceID: device, server: server).publish(record, as: channel)
    }

    private func seedQueue(slots: [(String, Double)]) async throws {
        var changes: [LibraryChange] = [.source(LibrarySource(id: id("show"), kind: .podcastFeed, title: "The Show"))]
        for (raw, key) in slots {
            changes.append(.entry(try entry(raw, title: "Title \(raw)")))
            changes.append(.slot(try QueueSlot(entryID: id(raw), sortKey: key)))
        }
        try await macPush(changes)
    }

    func testRowsFollowQueueSlotOrderNotArrivalOrder() async throws {
        try await seedQueue(slots: [("a", 2), ("b", 0), ("c", 1)])
        try await macPush([.entry(try entry("unqueued", title: "Not queued"))])
        let model = makeModel()
        await model.refresh()
        XCTAssertEqual(model.queued.map(\.id.rawValue), ["b", "c", "a"])
        XCTAssertEqual(model.queued.first?.title, "Title b")
        XCTAssertEqual(model.queued.first?.showTitle, "The Show")
        XCTAssertEqual(model.queued.first?.durationText, "30:00")
        XCTAssertNil(model.errorMessage)
        XCTAssertNotNil(model.lastSynchronizedAt)
    }

    func testReorderOnMacReordersRowsAfterRefresh() async throws {
        try await seedQueue(slots: [("a", 0), ("b", 1)])
        let model = makeModel()
        await model.refresh()
        XCTAssertEqual(model.queued.map(\.id.rawValue), ["a", "b"])
        try await macPush([.slot(try QueueSlot(entryID: id("a"), sortKey: 5))])
        await model.refresh()
        XCTAssertEqual(model.queued.map(\.id.rawValue), ["b", "a"])
    }

    func testPausedOnMacLabelUsesLastCheckpoint() async throws {
        try await seedQueue(slots: [("a", 0), ("b", 1)])
        try await macPublish("a", position: 754)
        let model = makeModel()
        await model.refresh()
        XCTAssertEqual(model.queued.first?.checkpointText, "Paused on Mac at 12:34 (as of 22:13)")
        XCTAssertNil(model.queued.last?.checkpointText)
        XCTAssertEqual(model.checkpoints[id("a")]?.record.positionSeconds, 754)
    }

    func testCheckpointIgnoresThisDeviceAndPrefersHigherEpoch() async throws {
        try await seedQueue(slots: [("a", 0)])
        try await macPublish("a", position: 60, epoch: 1)
        try await macPublish("a", position: 3_725, epoch: 2, device: "other")
        try await macPublish("a", position: 999, epoch: 9, device: "phone")
        let model = makeModel()
        await model.refresh()
        XCTAssertEqual(model.queued.first?.checkpointText, "Paused on Mac at 1:02:05 (as of 22:13)")
    }

    func testNowPlayingRecordShowsPlayingLabel() async throws {
        try await seedQueue(slots: [("a", 0)])
        try await macPublish("a", position: 30, playing: true, channel: .nowPlaying)
        let model = makeModel()
        await model.refresh()
        XCTAssertEqual(model.queued.first?.checkpointText, "Playing on Mac at 00:30 (as of 22:13)")
    }

    func testRemovalStatesRenderAndMoveOutOfTheQueue() async throws {
        try await seedQueue(slots: [("keep", 0), ("retire", 1), ("dismiss", 2), ("lingering", 3)])
        let model = makeModel()
        await model.refresh()
        XCTAssertEqual(model.queued.map(\.id.rawValue), ["keep", "retire", "dismiss", "lingering"])
        XCTAssertTrue(model.queued.allSatisfy { $0.removalText == nil })

        try await macPush([
            .removal(entryID: id("retire"), state: .retired), .slotRemoved(entryID: id("retire")),
            .removal(entryID: id("dismiss"), state: .dismissed), .slotRemoved(entryID: id("dismiss")),
            .removal(entryID: id("lingering"), state: .retired),
        ])
        await model.refresh()
        XCTAssertEqual(model.queued.map(\.id.rawValue), ["keep", "lingering"])
        XCTAssertEqual(model.queued.last?.removal, .retired)
        XCTAssertEqual(model.queued.last?.removalText, "Retired on Mac")

        try await macPush([.removal(entryID: id("retire"), state: .none), .slot(try QueueSlot(entryID: id("retire"), sortKey: 9))])
        await model.refresh()
        XCTAssertEqual(model.queued.map(\.id.rawValue), ["keep", "lingering", "retire"])
        XCTAssertNil(model.queued.last?.removalText)
    }

    func testSilentPushReportsWhetherTheLibraryChanged() async throws {
        try await seedQueue(slots: [("a", 0)])
        let model = makeModel()
        await model.refresh()
        let unchanged = await model.handleSilentPush()
        XCTAssertFalse(unchanged)
        try await macPush([.slot(try QueueSlot(entryID: id("a"), sortKey: 3))])
        try await macPush([.entry(try entry("b", title: "Later")), .slot(try QueueSlot(entryID: id("b"), sortKey: 4))])
        let changed = await model.handleSilentPush()
        XCTAssertTrue(changed)
        XCTAssertEqual(model.queued.map(\.id.rawValue), ["a", "b"])
    }

    func testConcurrentRefreshesShareOneRun() async throws {
        try await seedQueue(slots: [("a", 0)])
        let model = makeModel()
        async let first: Void = model.refresh()
        async let second: Void = model.refresh()
        _ = await (first, second)
        XCTAssertEqual(model.queued.count, 1)
        XCTAssertFalse(model.isRefreshing)
    }

    func testUnavailableTransportSurfacesAReasonAndKeepsRowsEmpty() async {
        let model = LibraryAppModel(transport: UnavailableLibraryTransport(reason: "iCloud sync is off."), deviceID: "phone")
        await model.refresh()
        XCTAssertEqual(model.errorMessage, "iCloud sync is off.")
        XCTAssertTrue(model.queued.isEmpty)
        XCTAssertFalse(model.isRefreshing)
    }

    func testFileStoreKeepsContentAndCursorTogetherAcrossLaunches() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("library-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("library-state.json")
        try await seedQueue(slots: [("a", 0), ("b", 1)])
        let first = makeModel(store: FileLibraryStore(url: url))
        await first.refresh()

        let reopened = FileLibraryStore(url: url)
        XCTAssertNotNil(reopened.initialCursor)
        let state = await reopened.state()
        XCTAssertEqual(state.cursor, reopened.initialCursor)
        XCTAssertEqual(state.content.queue.map(\.entryID.rawValue), ["a", "b"])
        let second = makeModel(store: reopened)
        await second.refresh()
        XCTAssertEqual(second.queued.map(\.id.rawValue), ["a", "b"])

        reopened.discard()
        XCTAssertNil(FileLibraryStore(url: url).initialCursor)
    }

    func testDeviceIDIsCreatedOnceAndStable() throws {
        let suite = "library-tests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let first = LibraryEnvironment.stableDeviceID(defaults: defaults)
        XCTAssertTrue(first.hasPrefix("iphone-"))
        XCTAssertEqual(LibraryEnvironment.stableDeviceID(defaults: defaults), first)
    }
}
