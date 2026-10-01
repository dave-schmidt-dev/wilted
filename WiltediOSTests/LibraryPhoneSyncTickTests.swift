import Foundation
import WiltedDomain
import WiltedLibrary
import XCTest
@testable import WiltediOS

/// Counts each server call the phone makes, by the method that makes it.
private final class PhoneCalls: @unchecked Sendable {
    private let lock = NSLock()
    private var counts: [String: Int] = [:]
    func bump(_ name: String) { lock.withLock { counts[name, default: 0] += 1 } }
    func count(_ name: String) -> Int { lock.withLock { counts[name] ?? 0 } }
    var total: Int { lock.withLock { counts.values.reduce(0, +) } }
}

private struct CountingPhoneTransport: LibraryTransport {
    let inner: InMemoryLibraryTransport
    let calls: PhoneCalls
    /// Throws a Retry-After rate limit from the next `poll` while armed.
    let limit: PhoneLimit

    func fetchChanges(since token: LibraryChangeToken?) async throws -> LibraryChangeBatch {
        calls.bump("fetchChanges"); return try await inner.fetchChanges(since: token)
    }
    func push(changes: [PendingLibraryChange]) async throws -> LibraryPushResult {
        calls.bump("push"); return try await inner.push(changes: changes)
    }
    func send(intent: LibraryIntent) async throws { calls.bump("send"); try await inner.send(intent: intent) }
    func listIntents() async throws -> [LibraryIntent] { calls.bump("listIntents"); return try await inner.listIntents() }
    func publish(_ record: DevicePlaybackPosition, as channel: PlaybackChannel) async throws {
        calls.bump("publish"); try await inner.publish(record, as: channel)
    }
    func publish(_ records: [(record: DevicePlaybackPosition, channel: PlaybackChannel)]) async throws {
        calls.bump("publish"); try await inner.publish(records)
    }
    func fetchDeviceRecords() async throws -> LibraryDeviceRecords {
        calls.bump("fetchDeviceRecords"); return try await inner.fetchDeviceRecords()
    }
    func mediaOffers() async throws -> [LibraryMediaOffer] { calls.bump("mediaOffers"); return try await inner.mediaOffers() }
    func intentOutcomes() async throws -> [IntentOutcome] { calls.bump("intentOutcomes"); return try await inner.intentOutcomes() }
    func poll(_ options: LibraryPollOptions) async throws -> LibraryPollResult {
        calls.bump("poll")
        try limit.throwIfArmed()
        return try await inner.poll(options)
    }
}

private final class PhoneLimit: @unchecked Sendable {
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

/// The phone's cadence rule: one sync tick, running only while the phone is in front or plays, one
/// batched read in each round, a decision that sends once and waits for the round, a rate limit that holds the
/// whole tick, and pulls that coalesce. Time is virtual; the server is the in-memory reference.
@MainActor
final class LibraryPhoneSyncTickTests: XCTestCase {
    private struct Rig {
        let model: LibraryAppModel
        let time: VirtualTime
        let calls: PhoneCalls
        let limit: PhoneLimit
        let server: InMemoryLibraryServer
    }

    private let entry = try! ItemID(rawValue: "item-a")

    private func makeRig() async throws -> Rig {
        let time = VirtualTime()
        let calls = PhoneCalls()
        let limit = PhoneLimit()
        let server = InMemoryLibraryServer(writerDeviceID: "mac")
        let transport = CountingPhoneTransport(
            inner: InMemoryLibraryTransport(deviceID: "phone", server: server), calls: calls, limit: limit)
        UserDefaults(suiteName: "library-phone-tick-tests")!.removePersistentDomain(forName: "library-phone-tick-tests")
        let model = LibraryAppModel(
            transport: transport, deviceID: "phone",
            handoffTiming: LibraryHandoffTiming(
                observeInterval: SyncCadence.tickInterval, sleep: { try await time.sleep($0) }, settleSleep: { _ in }),
            preferences: UserDefaults(suiteName: "library-phone-tick-tests")!,
            now: { time.now }, timeZone: TimeZone(identifier: "UTC")!,
            throttleSleep: { try await time.sleep($0) })
        await model.sceneBecameActive()
        await model.start()
        return Rig(model: model, time: time, calls: calls, limit: limit, server: server)
    }

    func testAnIdlePhoneInFrontMakesAtMostAboutTwoAndAThirdRequestsAMinute() async throws {
        let rig = try await makeRig()
        let before = rig.calls.total
        await rig.time.advance(by: 600)
        let spent = rig.calls.total - before
        XCTAssertEqual(rig.calls.count("poll") - 1, 20, "one batched read per 30 s round")
        XCTAssertEqual(rig.calls.count("fetchDeviceRecords") + rig.calls.count("mediaOffers") + rig.calls.count("intentOutcomes"), 0,
                       "records, offers and outcomes ride the one read")
        XCTAssertLessThanOrEqual(Double(spent) / 10, 2.35, "idle requests per minute: \(spent) in 10 minutes")
    }

    func testABackgroundedPhoneThatIsNotPlayingMakesNoRequests() async throws {
        let rig = try await makeRig()
        await rig.model.sceneEnteredBackground()
        let before = rig.calls.total
        await rig.time.advance(by: 600)
        XCTAssertEqual(rig.calls.total, before, "the tick stops with the app out of front")
    }

    func testPullsRestartTheTimerAndAPullDuringARoundJoinsIt() async throws {
        let rig = try await makeRig()
        await rig.time.advance(by: 20)
        let before = rig.calls.count("poll")
        async let first: Void = rig.model.pullToRefresh()
        async let second: Void = rig.model.pullToRefresh()
        _ = await (first, second)
        XCTAssertLessThanOrEqual(rig.calls.count("poll") - before, 2, "two pulls cost at most one round each, never a pile")
        let afterPull = rig.calls.count("poll")
        await rig.time.advance(by: 25)
        XCTAssertEqual(rig.calls.count("poll"), afterPull, "the pull restarted the 30 s timer")
        await rig.time.advance(by: 10)
        XCTAssertEqual(rig.calls.count("poll"), afterPull + 1)
    }

    func testAPullWhileRateLimitedSendsNothingAndTheTickWaitsOutTheRetryAfter() async throws {
        let rig = try await makeRig()
        rig.limit.arm()
        await rig.time.advance(by: 31)
        XCTAssertNotNil(rig.model.throttleState, "the limit closed the shared gate")
        let held = rig.calls.total
        await rig.model.pullToRefresh()
        XCTAssertEqual(rig.calls.total, held, "a pull shows the retry state instead of firing")
        await rig.time.advance(by: 100)
        XCTAssertEqual(rig.calls.total, held, "the whole tick holds for the 120 s the server asked for")
    }

    func testADecisionSendsOnceAndItsAnswerWaitsForTheNextRound() async throws {
        let rig = try await makeRig()
        let id = entry
        try await seedStartedEpisode(rig, id)
        await rig.model.start()
        let sentBefore = rig.calls.count("send")
        await rig.model.decide(.removeFromLarder, entryID: id)
        XCTAssertEqual(rig.calls.count("send") - sentBefore, 1, "the action sends its one write at once")
        let polls = rig.calls.count("poll")
        await rig.time.advance(by: 25)
        XCTAssertEqual(rig.calls.count("poll"), polls, "no 5 s poll for the Mac's answer: it waits for the tick")
        await rig.time.advance(by: 10)
        XCTAssertEqual(rig.calls.count("poll"), polls + 1)
    }

    func testEveryPhoneSurfaceReadsTheOneCadence() {
        XCTAssertEqual(LibraryHandoffTiming().observeInterval, SyncCadence.tickInterval)
        XCTAssertEqual(LibraryMediaTiming().pollInterval, .seconds(SyncCadence.tickInterval))
        XCTAssertEqual(SyncCadence.tickInterval, 30)
    }

    /// A queued, started episode in the library, so a decision on it is offered.
    private func seedStartedEpisode(_ rig: Rig, _ id: ItemID) async throws {
        let mac = InMemoryLibraryTransport(deviceID: "mac", server: rig.server)
        let source = try ItemID(rawValue: "show")
        let changes: [LibraryChange] = [
            .source(LibrarySource(id: source, kind: .podcastFeed, title: "Show")),
            .entry(try LibraryEntry(
                id: id, kind: .podcastEpisode, sourceID: source, title: "Title", summary: "",
                publishedAt: Date(timeIntervalSince1970: 1_600_000_000), durationSeconds: 600, removal: .none, removedAt: nil)),
            .slot(try QueueSlot(entryID: id, sortKey: 0)),
        ]
        let pending = changes.enumerated().map { PendingLibraryChange(localSeq: UInt64($0.offset + 1), change: $0.element, baseVersion: 0) }
        _ = try await mac.push(changes: pending)
        let record = try DevicePlaybackPosition(
            deviceID: "mac", entryID: id, revision: RevisionID(rawValue: "rev-1"), positionSeconds: 30, isPlaying: false, epoch: 1)
        try await mac.publish(record, as: .progress)
        await rig.model.refresh()
    }
}
