import Foundation
import WiltedDomain
import WiltedLibrary
import XCTest
@testable import WiltedMac

/// Serves a scripted ready revision and counts lookups; never touches a store.
final class ScriptedAudioSource: WiltedMacReadyAudioSource, @unchecked Sendable {
    private let lock = NSLock()
    private var audio: [ItemID: WiltedMacReadyAudio] = [:]
    private var queue: Set<ItemID> = []
    private var lookups = 0

    func set(_ entryID: ItemID, _ value: WiltedMacReadyAudio?) { lock.withLock { audio[entryID] = value } }
    /// Puts the entry on, or takes it off, the scripted Larder queue.
    func setQueued(_ entryID: ItemID, _ queued: Bool) {
        lock.withLock { if queued { queue.insert(entryID) } else { queue.remove(entryID) } }
    }

    func preparedQueuedAudio() async throws -> [ItemID: WiltedMacReadyAudio] {
        lock.withLock { audio.filter { queue.contains($0.key) } }
    }
    var lookupCount: Int { lock.withLock { lookups } }

    func readyAudio(for entryID: ItemID) async throws -> WiltedMacReadyAudio? {
        lock.withLock { lookups += 1; return audio[entryID] }
    }
}

final class MutableClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date
    init(_ start: Date) { current = start }
    var now: Date { lock.withLock { current } }
    func advance(_ seconds: TimeInterval) { lock.withLock { current = current.addingTimeInterval(seconds) } }
}

/// Records each requested sleep and returns only when the test releases it.
private actor SleepGate {
    private(set) var requested: [Duration] = []
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func sleep(_ duration: Duration) async throws {
        requested.append(duration)
        await withCheckedContinuation { waiters.append($0) }
        try Task.checkCancellation()
    }

    func release() { let pending = waiters; waiters = []; pending.forEach { $0.resume() } }
}

private actor IntentCollector: LibraryIntentSink {
    private(set) var received: [String] = []
    func receive(_ intent: LibraryIntent) async throws { received.append(intent.id) }
}

@MainActor
final class WiltedMacMediaServiceTests: XCTestCase {
    let macID = "mac-test"
    let phoneID = "iphone-a"
    let tabletID = "ipad-b"

    func id(_ raw: String) throws -> ItemID { try ItemID(rawValue: raw) }

    func makeAudio(_ directory: URL, revision: String, bytes: Int = 4_096) throws -> WiltedMacReadyAudio {
        let file = directory.appendingPathComponent("\(revision).m4a")
        try Data(repeating: UInt8(revision.utf8.last ?? 1), count: bytes).write(to: file)
        return WiltedMacReadyAudio(
            revisionID: try RevisionID(rawValue: revision), contentHash: try MediaHash.sha256(fileAt: file),
            byteCount: Int64(bytes), mediaType: "audio/mp4", durationSeconds: 60, fileURL: file
        )
    }

    struct Rig {
        let server: InMemoryLibraryServer
        let mac: InMemoryLibraryTransport
        let phone: InMemoryLibraryTransport
        let source: ScriptedAudioSource
        let clock: MutableClock
        let directory: URL
    }

    func rig(_ name: String) -> Rig {
        let server = InMemoryLibraryServer(writerDeviceID: macID)
        return Rig(
            server: server, mac: InMemoryLibraryTransport(deviceID: macID, server: server),
            phone: InMemoryLibraryTransport(deviceID: phoneID, server: server), source: ScriptedAudioSource(),
            clock: MutableClock(Date(timeIntervalSince1970: 1_800_000_000)), directory: wiltedTemporaryDirectory(name)
        )
    }

    func runtime(_ rig: Rig) -> WiltedMacInboundRuntime {
        let clock = rig.clock
        return WiltedMacInboundRuntime(
            source: rig.source, transport: rig.mac, directory: rig.directory,
            isPlaying: { false }, now: { clock.now }
        )
    }

    func request(_ rig: Rig, _ entry: ItemID, from device: String, intentID: String) throws -> LibraryIntent {
        try LibraryIntent.requestMedia(entryID: entry, deviceID: device, createdAt: rig.clock.now, id: intentID)
    }

    func cached(_ rig: Rig, _ entry: ItemID, _ revision: String, from device: String, intentID: String) throws -> LibraryIntent {
        try LibraryIntent.mediaCached(
            entryID: entry, revisionID: try RevisionID(rawValue: revision), deviceID: device, createdAt: rig.clock.now, id: intentID
        )
    }

    func eventually(_ what: String, _ condition: () async -> Bool) async throws {
        for _ in 0..<200 {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Timed out waiting for \(what)")
    }

    // MARK: Ready and notReady

    func testReadyRequestUploadsTheVerifiedRevisionAndTheOfferMatches() async throws {
        let rig = rig("media-ready")
        let entry = try id("episode-ready")
        let audio = try makeAudio(rig.directory, revision: "rev-1")
        rig.source.set(entry, audio)
        let runtime = runtime(rig)

        await runtime.consume(try request(rig, entry, from: phoneID, intentID: "r-1"))

        let offers = try await rig.phone.mediaOffers()
        let offer = try XCTUnwrap(offers.first)
        XCTAssertEqual(offer.state, .ready)
        XCTAssertEqual(offer.revisionID, audio.revisionID)
        XCTAssertEqual(offer.contentHash, audio.contentHash)
        XCTAssertEqual(offer.byteCount, audio.byteCount)
        let delivered = try await rig.phone.fetchMedia(offer) { _ in }
        defer { try? FileManager.default.removeItem(at: delivered) }
        XCTAssertEqual(try MediaHash.sha256(fileAt: delivered), audio.contentHash)
        let holding = await runtime.service.isHolding(entryID: entry, revisionID: audio.revisionID)
        XCTAssertTrue(holding)
    }

    func testNoReadyRevisionPublishesNotReadyWithoutUploading() async throws {
        let rig = rig("media-not-ready")
        let entry = try id("episode-pending")
        let runtime = runtime(rig)

        await runtime.consume(try request(rig, entry, from: phoneID, intentID: "r-2"))

        let offers = try await rig.phone.mediaOffers()
        let offer = try XCTUnwrap(offers.first)
        XCTAssertEqual(offer.state, .notReady)
        XCTAssertNil(offer.revisionID)
        XCTAssertEqual(offer.byteCount, 0)
        XCTAssertEqual(rig.source.lookupCount, 1)
        let held = await runtime.service.accountedAssetCount
        XCTAssertEqual(held, 0)
    }

    func testAMissingOrChangedFileIsAnsweredNotReady() async throws {
        let rig = rig("media-bad-file")
        let entry = try id("episode-broken")
        var audio = try makeAudio(rig.directory, revision: "rev-9")
        audio.byteCount += 1
        rig.source.set(entry, audio)
        let runtime = runtime(rig)

        await runtime.consume(try request(rig, entry, from: phoneID, intentID: "r-bad"))

        let offers = try await rig.phone.mediaOffers()
        let offer = try XCTUnwrap(offers.first)
        XCTAssertEqual(offer.state, .notReady)
    }

    func testAnIntentOlderThanSevenDaysIsIgnored() async throws {
        let rig = rig("media-stale")
        let entry = try id("episode-stale")
        rig.source.set(entry, try makeAudio(rig.directory, revision: "rev-1"))
        let runtime = runtime(rig)
        let stale = try LibraryIntent.requestMedia(
            entryID: entry, deviceID: phoneID, createdAt: rig.clock.now.addingTimeInterval(-8 * 24 * 3600), id: "old"
        )

        await runtime.consume(stale)

        let offers = try await rig.phone.mediaOffers()
        XCTAssertTrue(offers.isEmpty)
        XCTAssertEqual(rig.source.lookupCount, 0)
    }

    // MARK: Ledger

    func testDuplicateIntentAcrossARestartIsAppliedOnce() async throws {
        let rig = rig("media-restart")
        let entry = try id("episode-once")
        rig.source.set(entry, try makeAudio(rig.directory, revision: "rev-1"))
        let intent = try request(rig, entry, from: phoneID, intentID: "same-id")

        await runtime(rig).consume(intent)
        XCTAssertEqual(rig.source.lookupCount, 1)

        // A new process: fresh runtime over the same on-disk ledger sees the intent again.
        let restarted = runtime(rig)
        await restarted.consume(intent)
        XCTAssertEqual(rig.source.lookupCount, 1)
        let known = await restarted.ledger.contains("same-id")
        XCTAssertTrue(known)
    }

    func testLedgerPrunesEntriesPastRetention() async throws {
        let clock = MutableClock(Date(timeIntervalSince1970: 1_800_000_000))
        let url = wiltedTemporaryDirectory("ledger-prune").appendingPathComponent("ledger.json")
        let ledger = WiltedMacIntentLedger(fileURL: url) { clock.now }
        let first = try await ledger.recordIfNew("old")
        let again = try await ledger.recordIfNew("old")
        XCTAssertTrue(first)
        XCTAssertFalse(again)

        clock.advance(WiltedMacIntentLedger.retention + 60)
        let dropped = try await ledger.prune()
        XCTAssertEqual(dropped, 1)
        let reloaded = WiltedMacIntentLedger(fileURL: url) { clock.now }
        let count = await reloaded.count
        XCTAssertEqual(count, 0)
    }

    // MARK: Ack and TTL cleanup

    func testAssetIsWithdrawnOnlyAfterEveryRequesterAcked() async throws {
        let rig = rig("media-acks")
        let entry = try id("episode-shared")
        rig.source.set(entry, try makeAudio(rig.directory, revision: "rev-1"))
        let runtime = runtime(rig)
        await runtime.consume(try request(rig, entry, from: phoneID, intentID: "a-1"))
        await runtime.consume(try request(rig, entry, from: tabletID, intentID: "a-2"))
        XCTAssertEqual(rig.source.lookupCount, 2)

        await runtime.consume(try cached(rig, entry, "rev-1", from: phoneID, intentID: "a-3"))
        var offers = try await rig.phone.mediaOffers()
        XCTAssertEqual(offers.count, 1, "one requester has not acked yet")

        await runtime.consume(try cached(rig, entry, "rev-1", from: tabletID, intentID: "a-4"))
        offers = try await rig.phone.mediaOffers()
        XCTAssertTrue(offers.isEmpty)
        let held = await runtime.service.accountedAssetCount
        XCTAssertEqual(held, 0)
    }

    func testANewRevisionKeepsTheOldAccountingWithoutWithdrawingTheNewAsset() async throws {
        let rig = rig("media-revisions")
        let entry = try id("episode-updated")
        rig.source.set(entry, try makeAudio(rig.directory, revision: "rev-1"))
        let runtime = runtime(rig)
        await runtime.consume(try request(rig, entry, from: phoneID, intentID: "v-1"))

        rig.source.set(entry, try makeAudio(rig.directory, revision: "rev-2"))
        await runtime.consume(try request(rig, entry, from: tabletID, intentID: "v-2"))
        let held = await runtime.service.accountedAssetCount
        XCTAssertEqual(held, 2, "each revision is accounted separately")

        // The phone acks the old revision: its books close, the new asset stays.
        await runtime.consume(try cached(rig, entry, "rev-1", from: phoneID, intentID: "v-3"))
        var offers = try await rig.phone.mediaOffers()
        XCTAssertEqual(offers.first?.revisionID?.rawValue, "rev-2")
        let stillHeld = await runtime.service.accountedAssetCount
        XCTAssertEqual(stillHeld, 1)

        await runtime.consume(try cached(rig, entry, "rev-2", from: tabletID, intentID: "v-4"))
        offers = try await rig.phone.mediaOffers()
        XCTAssertTrue(offers.isEmpty)
    }

    func testAnAckForAnUnknownRevisionChangesNothing() async throws {
        let rig = rig("media-unknown-ack")
        let entry = try id("episode-held")
        rig.source.set(entry, try makeAudio(rig.directory, revision: "rev-1"))
        let runtime = runtime(rig)
        await runtime.consume(try request(rig, entry, from: phoneID, intentID: "u-1"))

        await runtime.consume(try cached(rig, entry, "rev-other", from: phoneID, intentID: "u-2"))

        let offers = try await rig.phone.mediaOffers()
        XCTAssertEqual(offers.count, 1)
    }

    func testAssetExpiresAfterSevenDaysWithoutAcks() async throws {
        let rig = rig("media-ttl")
        let entry = try id("episode-ttl")
        rig.source.set(entry, try makeAudio(rig.directory, revision: "rev-1"))
        let runtime = runtime(rig)
        await runtime.consume(try request(rig, entry, from: phoneID, intentID: "t-1"))

        rig.clock.advance(WiltedMacMediaService.timeToLive - 60)
        await runtime.service.sweepExpired()
        var offers = try await rig.phone.mediaOffers()
        XCTAssertEqual(offers.count, 1, "not yet seven days")

        rig.clock.advance(120)
        await runtime.service.sweepExpired()
        offers = try await rig.phone.mediaOffers()
        XCTAssertTrue(offers.isEmpty)
    }

    func testAccountingSurvivesARestart() async throws {
        let rig = rig("media-accounting-restart")
        let entry = try id("episode-durable")
        rig.source.set(entry, try makeAudio(rig.directory, revision: "rev-1"))
        await runtime(rig).consume(try request(rig, entry, from: phoneID, intentID: "d-1"))

        let restarted = runtime(rig)
        await restarted.consume(try cached(rig, entry, "rev-1", from: phoneID, intentID: "d-2"))

        let offers = try await rig.phone.mediaOffers()
        XCTAssertTrue(offers.isEmpty)
    }

    // MARK: Poller

    func testPollerCadenceFollowsPlaybackWithAnInjectedClock() async throws {
        let rig = rig("poller-cadence")
        let gate = SleepGate()
        let playing = LockedFlag()
        let poller = WiltedMacInboundPoller(
            transport: rig.mac, sink: IntentCollector(), isPlaying: { playing.value },
            sleep: { try await gate.sleep($0) }
        )
        await poller.start()

        try await eventually("first sleep") { await gate.requested.count == 1 }
        var requested = await gate.requested
        XCTAssertEqual(requested, [.seconds(30)], "idle Mac waits 30 s")

        playing.value = true
        await gate.release()
        try await eventually("second sleep") { await gate.requested.count == 2 }
        requested = await gate.requested
        XCTAssertEqual(requested, [.seconds(30), .seconds(5)], "playing Mac waits 5 s")

        playing.value = false
        await gate.release()
        try await eventually("third sleep") { await gate.requested.count == 3 }
        requested = await gate.requested
        XCTAssertEqual(requested.last, .seconds(30))
        await poller.stop()
        await gate.release()
    }

    func testPollerDeliversIntentsDiscoversOnceAndRunsMaintenanceEachCycle() async throws {
        let rig = rig("poller-deliver")
        try await rig.phone.send(intent: LibraryIntent.requestMedia(entryID: try id("e-1"), deviceID: phoneID, id: "p-1"))
        let sink = IntentCollector()
        let counters = Counters()
        let poller = WiltedMacInboundPoller(
            transport: rig.mac, sink: sink, isPlaying: { false },
            discover: { _ = counters.bump("discover") }, maintenance: { _ = counters.bump("maintenance") },
            sleep: { _ in }
        )

        await poller.pollNow()
        await poller.pollNow()

        let received = await sink.received
        XCTAssertEqual(received, ["p-1", "p-1"], "the sink, not the poller, dedupes")
        XCTAssertEqual(counters.count("discover"), 1)
        XCTAssertEqual(counters.count("maintenance"), 2)
        let cycles = await poller.cycleCount
        XCTAssertEqual(cycles, 2)
    }

    func testDiscoveryRepeatsPeriodicallySoALatePeerIsHeard() async throws {
        let rig = rig("poller-rediscover")
        let counters = Counters()
        let poller = WiltedMacInboundPoller(
            transport: rig.mac, sink: IntentCollector(), isPlaying: { false },
            discover: { _ = counters.bump("discover") },
            sleep: { _ in }
        )

        for _ in 0..<(WiltedMacInboundPoller.rediscoverEveryCycles + 1) { await poller.pollNow() }

        XCTAssertEqual(counters.count("discover"), 2, "startup scan plus one periodic rescan")
    }

    func testDiscoveryFailureIsRetriedUntilItSucceeds() async throws {
        let rig = rig("poller-discover-retry")
        let counters = Counters()
        let poller = WiltedMacInboundPoller(
            transport: rig.mac, sink: IntentCollector(), isPlaying: { false },
            discover: {
                if counters.bump("discover") == 1 { throw NSError(domain: "offline", code: 1) }
            },
            sleep: { _ in }
        )

        await poller.pollNow()
        let failure = await poller.lastFailure
        XCTAssertNotNil(failure)
        await poller.pollNow()
        await poller.pollNow()

        XCTAssertEqual(counters.count("discover"), 2)
        let recovered = await poller.lastFailure
        XCTAssertNil(recovered)
    }
}

private final class LockedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false
    var value: Bool {
        get { lock.withLock { flag } }
        set { lock.withLock { flag = newValue } }
    }
}

private final class Counters: @unchecked Sendable {
    private let lock = NSLock()
    private var counts: [String: Int] = [:]
    @discardableResult func bump(_ name: String) -> Int { lock.withLock { counts[name, default: 0] += 1; return counts[name] ?? 0 } }
    func count(_ name: String) -> Int { lock.withLock { counts[name] ?? 0 } }
}
