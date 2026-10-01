import Foundation
import WiltedDomain
import WiltedLibrary
import XCTest
@testable import WiltedMac

/// Counts each server call the Mac makes, by the method that makes it.
private final class CallCounts: @unchecked Sendable {
    private let lock = NSLock()
    private var counts: [String: Int] = [:]
    private var times: [String: [Date]] = [:]
    func bump(_ name: String, at date: Date = Date()) { lock.withLock { counts[name, default: 0] += 1; times[name, default: []].append(date) } }
    func count(_ name: String) -> Int { lock.withLock { counts[name] ?? 0 } }
    var total: Int { lock.withLock { counts.values.reduce(0, +) } }
    func calls(_ name: String) -> [Date] { lock.withLock { times[name] ?? [] } }
}

private struct CountingTransport: LibraryTransport {
    let inner: InMemoryLibraryTransport
    let counts: CallCounts
    let now: @Sendable () -> Date
    /// Throws this once, from the next `poll`.
    let failure: FailureOnce?

    func fetchChanges(since token: LibraryChangeToken?) async throws -> LibraryChangeBatch {
        counts.bump("fetchChanges", at: now()); return try await inner.fetchChanges(since: token)
    }
    func push(changes: [PendingLibraryChange]) async throws -> LibraryPushResult {
        counts.bump("push", at: now()); return try await inner.push(changes: changes)
    }
    func send(intent: LibraryIntent) async throws { counts.bump("send", at: now()); try await inner.send(intent: intent) }
    func listIntents() async throws -> [LibraryIntent] { counts.bump("listIntents", at: now()); return try await inner.listIntents() }
    func publish(_ record: DevicePlaybackPosition, as channel: PlaybackChannel) async throws {
        counts.bump("publish", at: now()); try await inner.publish(record, as: channel)
    }
    func fetchDeviceRecords() async throws -> LibraryDeviceRecords {
        counts.bump("fetchDeviceRecords", at: now()); return try await inner.fetchDeviceRecords()
    }
    func poll(_ options: LibraryPollOptions) async throws -> LibraryPollResult {
        counts.bump("poll", at: now())
        try failure?.throwIfArmed()
        return try await inner.poll(options)
    }
}

private final class FailureOnce: @unchecked Sendable {
    struct Limited: Error, CustomStringConvertible {
        var description: String { "cloudKit(code: 7, message: \"Retry after 120 seconds\")" }
    }
    private let lock = NSLock()
    private var armed = false
    func arm() { lock.withLock { armed = true } }
    func throwIfArmed() throws {
        let fire = lock.withLock { () -> Bool in defer { armed = false }; return armed }
        if fire { throw Limited() }
    }
}

private actor NullSink: LibraryIntentSink {
    func receive(_ intent: LibraryIntent) async throws {}
}

/// The Mac's cadence rule: one sync round per 30 s, one batched read in it, and a rate limit that
/// holds the whole tick. Time is virtual; the server is the in-memory reference.
@MainActor
final class WiltedMacSyncRoundTests: XCTestCase {
    private struct Rig {
        let time = VirtualTime()
        let counts = CallCounts()
        let server = InMemoryLibraryServer(writerDeviceID: "mac-test")
        let failure = FailureOnce()
        var gate: TransportGate!
        var transport: ThrottledLibraryTransport!
        var poller: WiltedMacInboundPoller!
        var rounds: Counter!
    }

    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0
        func bump() { lock.withLock { value += 1 } }
        var count: Int { lock.withLock { value } }
    }

    private func makeRig() -> Rig {
        var rig = Rig()
        let time = rig.time
        rig.gate = TransportGate(clock: { time.now })
        let inner = InMemoryLibraryTransport(deviceID: "mac-test", server: rig.server)
        let counting = CountingTransport(inner: inner, counts: rig.counts, now: { time.now }, failure: rig.failure)
        rig.transport = ThrottledLibraryTransport(wrapping: counting, gate: rig.gate)
        rig.rounds = Counter()
        let rounds = rig.rounds!
        rig.poller = WiltedMacInboundPoller(
            transport: rig.transport, sink: NullSink(), deviceID: "mac-test", gate: rig.gate,
            publishRound: { rounds.bump() },
            clock: { time.now }, sleep: { try await time.sleep($0.timeInterval) })
        return rig
    }

    func testAnIdleRoundIsOneBatchedReadAndNothingElse() async throws {
        let rig = makeRig()
        await rig.poller.pollNow()
        XCTAssertEqual(rig.counts.count("poll"), 1)
        XCTAssertEqual(rig.counts.total, 1, "intents and playback records share the one read")
        XCTAssertEqual(rig.rounds.count, 1, "the Mac's own writes run inside the round")
    }

    func testTenIdleMinutesAreAtMostOneRoundPerThirtySeconds() async throws {
        let rig = makeRig()
        await rig.poller.start()
        await rig.time.advance(by: 600)
        let polls = rig.counts.calls("poll")
        XCTAssertEqual(polls.count, 21, "one at start, then every 30 s")
        let gaps = zip(polls.dropFirst(), polls).map { $0.timeIntervalSince($1) }
        XCTAssertTrue(gaps.allSatisfy { $0 >= 29.999 }, "no round starts sooner than 30 s after the last: \(gaps)")
        XCTAssertEqual(rig.counts.total, polls.count, "nothing but the round talks to the server")
        XCTAssertLessThanOrEqual(Double(rig.counts.total) / 10, 2.1, "idle ops per minute")
        await rig.poller.stop()
    }

    func testARateLimitHoldsTheWholeTickForTheRetryAfter() async throws {
        let rig = makeRig()
        await rig.poller.start()
        await rig.time.advance(by: 31)
        XCTAssertEqual(rig.counts.count("poll"), 2)
        rig.failure.arm()
        await rig.time.advance(by: 30)
        XCTAssertEqual(rig.counts.count("poll"), 3, "this round met the limit")
        let before = rig.counts.total
        await rig.time.advance(by: 100)
        XCTAssertEqual(rig.counts.total, before, "the server asked for 120 s, so nothing is sent for 120 s")
        await rig.time.advance(by: 25)
        XCTAssertEqual(rig.counts.count("poll"), 4, "the first round after the wait is the probe")
        await rig.poller.stop()
    }

    func testAPullDuringARoundJoinsItAndAPullWhileLimitedSendsNothing() async throws {
        let rig = makeRig()
        await rig.poller.start()
        await rig.time.advance(by: 5)
        async let first = rig.poller.refreshNow()
        async let second = rig.poller.refreshNow()
        _ = await (first, second)
        XCTAssertLessThanOrEqual(rig.counts.count("poll"), 2, "two pulls cost at most one extra round")

        rig.failure.arm()
        await rig.time.advance(by: 30)
        let before = rig.counts.total
        let outcome = await rig.poller.refreshNow()
        if case .throttled? = outcome {} else { XCTFail("a pull while the gate is closed shows the retry state, got \(String(describing: outcome))") }
        XCTAssertEqual(rig.counts.total, before)
        await rig.poller.stop()
    }

    func testThePlayingCheckpointAndStatisticsDoNotRunTheirOwnTimers() throws {
        let controller = try String(contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("WiltedMac/ViewModel/WiltedMacModel+LibrarySync.swift"), encoding: .utf8)
        XCTAssertTrue(controller.contains("relaysIntents: false"), "the publisher does not read intents a second time")
        XCTAssertFalse(controller.contains("_ = lifetimeStatistics"), "the listening clock does not wake the publisher")
        XCTAssertTrue(controller.contains("publishRound:"), "the Mac's writes ride the sync round")
    }

    func testRescanIsRareOnceAPeerIsKnown() {
        XCTAssertEqual(WiltedMacInboundPoller.rediscoverEveryCycles, 4)
        XCTAssertEqual(WiltedMacInboundPoller.rediscoverEveryCyclesWithPeers, 40)
    }
}

private extension Duration {
    var timeInterval: TimeInterval { Double(components.seconds) + Double(components.attoseconds) / 1e18 }
}
