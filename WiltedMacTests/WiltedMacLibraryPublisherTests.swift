import Foundation
import WiltedDomain
import WiltedLibrary
import XCTest
@testable import WiltedMac

private actor FakeStateSource: LibraryStateSource {
    private(set) var reads = 0
    private var state: LibraryStateSnapshot

    init(_ state: LibraryStateSnapshot = LibraryStateSnapshot()) { self.state = state }

    func set(_ state: LibraryStateSnapshot) { self.state = state }

    func currentState() async throws -> LibraryStateSnapshot {
        reads += 1
        return state
    }
}

private actor FakeIntentSink: LibraryIntentSink {
    struct Rejected: Error {}
    private(set) var received: [String] = []
    private var failing = false

    func setFailing(_ failing: Bool) { self.failing = failing }

    func receive(_ intent: LibraryIntent) async throws {
        if failing { throw Rejected() }
        received.append(intent.id)
    }
}

final class WiltedMacLibraryPublisherTests: XCTestCase {
    private func id(_ name: String) -> ItemID { try! ItemID(rawValue: "item-\(name)") }

    private func episode(_ name: String, title: String? = nil, removal: LibraryRemoval = .none) -> LibraryEntry {
        try! LibraryEntry(
            id: id(name), kind: .podcastEpisode, sourceID: id("feed"), title: title ?? "Episode \(name)",
            summary: "", publishedAt: Date(timeIntervalSince1970: 1_000), removal: removal
        )
    }

    private func state(
        _ episodes: [LibraryEntry], queue: [String] = [], listening: [ListeningRecord] = [],
        playback: DevicePlaybackPosition? = nil
    ) -> LibraryStateSnapshot {
        LibraryStateSnapshot(
            feeds: [LibrarySource(id: id("feed"), kind: .podcastFeed, title: "Feed")],
            episodes: episodes, queue: queue.map(id), listening: listening, currentPlayback: playback
        )
    }

    private func position(_ name: String, seconds: Double = 42) -> DevicePlaybackPosition {
        try! DevicePlaybackPosition(
            deviceID: "mac", entryID: id(name), revision: try! RevisionID(rawValue: "rev-\(name)"),
            positionSeconds: seconds, isPlaying: false, epoch: 1
        )
    }

    private func makeServer() -> InMemoryLibraryServer { InMemoryLibraryServer(writerDeviceID: "mac") }

    private func publisher(
        _ source: FakeStateSource, server: InMemoryLibraryServer, sink: FakeIntentSink = FakeIntentSink(),
        enabled: Bool = true
    ) -> WiltedMacLibraryPublisher {
        WiltedMacLibraryPublisher(
            source: source, transport: InMemoryLibraryTransport(deviceID: "mac", server: server),
            sink: sink, isEnabled: enabled
        )
    }

    func testFlagIsOffUnlessExactlyOne() {
        XCTAssertFalse(WiltedMacLibraryPublisher.isEnabled(in: [:]))
        XCTAssertFalse(WiltedMacLibraryPublisher.isEnabled(in: ["WILTED_LIBRARY_SYNC": "0"]))
        XCTAssertFalse(WiltedMacLibraryPublisher.isEnabled(in: ["WILTED_LIBRARY_SYNC": "true"]))
        XCTAssertTrue(WiltedMacLibraryPublisher.isEnabled(in: ["WILTED_LIBRARY_SYNC": "1"]))
    }

    func testDisabledPublisherTouchesNothing() async throws {
        let server = makeServer()
        let source = FakeStateSource(state([episode("a")], queue: ["a"], playback: position("a")))
        let report = try await publisher(source, server: server, enabled: false).sync()
        let reads = await source.reads
        let published = await server.currentSnapshot
        XCTAssertEqual(report, .disabled)
        XCTAssertEqual(reads, 0)
        XCTAssertEqual(published, LibrarySnapshot())
    }

    func testFirstSyncPublishesStateInQueueOrder() async throws {
        let server = makeServer()
        let done = ListeningRecord(itemID: id("c"), completedAt: Date(timeIntervalSince1970: 5), updatedAt: Date(timeIntervalSince1970: 5), deviceID: "mac")
        let source = FakeStateSource(state(
            [episode("a"), episode("b"), episode("c")], queue: ["b", "a", "ghost", "b"], listening: [done]
        ))
        let report = try await publisher(source, server: server).sync()
        let snapshot = await server.currentSnapshot
        XCTAssertEqual(report.acknowledged, report.pushed)
        XCTAssertEqual(snapshot.queue.map(\.entryID), [id("b"), id("a")])
        XCTAssertEqual(Set(snapshot.entries.keys), [id("a"), id("b"), id("c")])
        XCTAssertEqual(snapshot.sources.count, 1)
        XCTAssertEqual(snapshot.listening[id("c")], done)
    }

    func testUnchangedStateSendsNothingAndChangesSendOnlyTheDelta() async throws {
        let server = makeServer()
        let source = FakeStateSource(state([episode("a"), episode("b")], queue: ["a", "b"]))
        let pub = publisher(source, server: server)
        _ = try await pub.sync()
        let unchanged = try await pub.sync()
        XCTAssertEqual(unchanged.pushed, 0)

        await source.set(state([episode("a", removal: .retired), episode("b")], queue: ["b"]))
        let delta = try await pub.sync()
        let snapshot = await server.currentSnapshot
        XCTAssertEqual(delta.pushed, 3, "retire removal, slot removal for a, slot key move for b")
        XCTAssertEqual(snapshot.entries[id("a")]?.removal, .retired)
        XCTAssertEqual(snapshot.queue.map(\.entryID), [id("b")])
    }

    func testRestartedPublisherResumesFromServerStateWithoutConflicts() async throws {
        let server = makeServer()
        let source = FakeStateSource(state([episode("a")], queue: ["a"]))
        _ = try await publisher(source, server: server).sync()

        let restarted = try await publisher(source, server: server).sync()
        XCTAssertEqual(restarted.pushed, 0)
        XCTAssertEqual(restarted.conflicts, 0)

        await source.set(state([episode("a", title: "Renamed")], queue: ["a"]))
        let edited = try await publisher(source, server: server).sync()
        XCTAssertEqual(edited.acknowledged, 1)
        XCTAssertEqual(edited.conflicts, 0)
    }

    func testConflictAdoptsServerVersionAndSucceedsOnNextPass() async throws {
        let server = makeServer()
        let sourceA = FakeStateSource(state([episode("a")]))
        let first = publisher(sourceA, server: server)
        _ = try await first.sync()

        let sourceB = FakeStateSource(state([episode("a", title: "From B")]))
        _ = try await publisher(sourceB, server: server).sync()

        await sourceA.set(state([episode("a", title: "From A")]))
        let conflicted = try await first.sync()
        XCTAssertEqual(conflicted.conflicts, 1)
        XCTAssertEqual(conflicted.acknowledged, 0)

        let retried = try await first.sync()
        let snapshot = await server.currentSnapshot
        XCTAssertEqual(retried.acknowledged, 1)
        XCTAssertEqual(snapshot.entries[id("a")]?.title, "From A")
    }

    func testCurrentPlaybackPublishesOncePerChange() async throws {
        let server = makeServer()
        let source = FakeStateSource(state([episode("a")], playback: position("a")))
        let pub = publisher(source, server: server)
        let first = try await pub.sync()
        let again = try await pub.sync()
        let records = try await InMemoryLibraryTransport(deviceID: "phone", server: server).fetchDeviceRecords()
        XCTAssertTrue(first.playbackPublished)
        XCTAssertFalse(again.playbackPublished)
        XCTAssertEqual(records.nowPlaying.map(\.record), [position("a")])
        XCTAssertEqual(records.progress.map(\.record), [position("a")])

        await source.set(state([episode("a")], playback: position("a", seconds: 90)))
        let moved = try await pub.sync()
        XCTAssertTrue(moved.playbackPublished)
    }

    func testIntentsReachTheSinkOnceAndAFailedDeliveryIsRetried() async throws {
        let server = makeServer()
        let sink = FakeIntentSink()
        let source = FakeStateSource(state([episode("a")]))
        let pub = publisher(source, server: server, sink: sink)
        let phone = InMemoryLibraryTransport(deviceID: "phone", server: server)
        try await phone.send(intent: LibraryIntent.requestMedia(entryID: id("a"), deviceID: "phone", id: "intent-1"))

        await sink.setFailing(true)
        let failed = try await pub.sync()
        XCTAssertEqual(failed.intentFailures, 1)
        XCTAssertEqual(failed.intentsDelivered, 0)

        await sink.setFailing(false)
        let delivered = try await pub.sync()
        let redelivered = try await pub.sync()
        let received = await sink.received
        XCTAssertEqual(delivered.intentsDelivered, 1)
        XCTAssertEqual(redelivered.intentsDelivered, 0)
        XCTAssertEqual(received, ["intent-1"])
    }
}
