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

/// Parks one real transport round until the test has started its joining pull.
private actor PhoneRoundBarrier {
    private var entered: XCTestExpectation?
    private var release: CheckedContinuation<Void, Never>?

    func arm(_ expectation: XCTestExpectation) { entered = expectation }

    func parkIfArmed() async {
        guard let entered else { return }
        self.entered = nil
        await withCheckedContinuation { continuation in
            release = continuation
            entered.fulfill()
        }
    }

    func finish() {
        entered = nil
        release?.resume()
        release = nil
    }
}

/// Acknowledges actual timer registration. Clock movement waits for the round to
/// complete and install its next nap instead of assuming a finite settle is enough.
private final class PhoneTimerBarrier: @unchecked Sendable {
    private let lock = NSLock()
    private var deadline: Date?
    private var exactExpected: [(Date, XCTestExpectation)] = []
    private var strictlyAfterExpected: [(Date, XCTestExpectation)] = []

    func installed(deadline: Date) {
        let ready = lock.withLock { () -> [XCTestExpectation] in
            self.deadline = deadline
            let ready = exactExpected.filter { $0.0 == deadline }.map { $0.1 }
                + strictlyAfterExpected.filter { deadline > $0.0 }.map { $0.1 }
            exactExpected.removeAll { $0.0 == deadline }
            strictlyAfterExpected.removeAll { deadline > $0.0 }
            return ready
        }
        ready.forEach { $0.fulfill() }
    }

    func registration(at deadline: Date) -> XCTestExpectation {
        let event = XCTestExpectation(description: "tick installed nap until \(deadline)")
        let ready = lock.withLock { () -> Bool in
            if self.deadline == deadline { return true }
            exactExpected.append((deadline, event))
            return false
        }
        if ready { event.fulfill() }
        return event
    }

    /// The next timer belongs to a round that has not completed yet. Its deadline must be after
    /// the nap that woke the round, but depends on the actual completion time.
    func registration(after deadline: Date) -> XCTestExpectation {
        let event = XCTestExpectation(description: "tick installed nap after \(deadline)")
        let ready = lock.withLock { () -> Bool in
            if let current = self.deadline, current > deadline { return true }
            strictlyAfterExpected.append((deadline, event))
            return false
        }
        if ready { event.fulfill() }
        return event
    }
}

private struct CountingPhoneTransport: LibraryTransport {
    let inner: InMemoryLibraryTransport
    let calls: PhoneCalls
    /// Throws a Retry-After rate limit from the next `poll` while armed.
    let limit: PhoneLimit
    let roundBarrier: PhoneRoundBarrier

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
        await roundBarrier.parkIfArmed()
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
        let roundBarrier: PhoneRoundBarrier
        let timerBarrier: PhoneTimerBarrier
    }

    private let entry = try! ItemID(rawValue: "item-a")

    private func makeRig() async throws -> Rig {
        let time = VirtualTime()
        let calls = PhoneCalls()
        let limit = PhoneLimit()
        let roundBarrier = PhoneRoundBarrier()
        let timerBarrier = PhoneTimerBarrier()
        let server = InMemoryLibraryServer(writerDeviceID: "mac")
        let transport = CountingPhoneTransport(
            inner: InMemoryLibraryTransport(deviceID: "phone", server: server), calls: calls, limit: limit,
            roundBarrier: roundBarrier)
        UserDefaults(suiteName: "library-phone-tick-tests")!.removePersistentDomain(forName: "library-phone-tick-tests")
        let model = LibraryAppModel(
            transport: transport, deviceID: "phone",
            handoffTiming: LibraryHandoffTiming(
                observeInterval: SyncCadence.tickInterval, sleep: { seconds in
                    try await time.sleep(seconds, registered: { deadline in
                        timerBarrier.installed(deadline: deadline)
                    })
                }, settleSleep: { _ in }),
            preferences: UserDefaults(suiteName: "library-phone-tick-tests")!,
            now: { time.now }, timeZone: TimeZone(identifier: "UTC")!,
            throttleSleep: { try await time.sleep($0) })
        await model.sceneBecameActive()
        await model.start()
        return Rig(model: model, time: time, calls: calls, limit: limit, server: server,
                   roundBarrier: roundBarrier, timerBarrier: timerBarrier)
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

    func testAlreadyCancelledSleepNeverRegistersALiveTimer() async {
        for seconds in [0.0, 30.0] {
            let time = VirtualTime()
            let gate = AsyncStream<Void>.makeStream()
            let finished = expectation(description: "already-cancelled sleep throws at \(seconds) seconds")
            let sleeper = Task {
                // Cancelling this task ends the stream before sleep starts, so
                // onCancel runs before continuation registration, deterministically.
                for await _ in gate.stream { break }
                do {
                    try await time.sleep(seconds)
                    XCTFail("already-cancelled sleep returned success")
                } catch is CancellationError {
                    // The cancelled nap cannot later wake a timer round.
                } catch { XCTFail("unexpected sleep error: \(error)") }
                finished.fulfill()
            }
            sleeper.cancel()
            gate.continuation.finish()
            let result = await XCTWaiter.fulfillment(of: [finished], timeout: 5)
            XCTAssertEqual(result, .completed, "cancelled sleeper must finish without advancing virtual time")
            // Only a broken fixture needs this cleanup; do not leave its waiter alive.
            if result != .completed { await time.advance(by: seconds) }
            await sleeper.value
        }
    }

    private func waitFor(_ event: XCTestExpectation) async {
        let result = await XCTWaiter.fulfillment(of: [event], timeout: 5)
        XCTAssertEqual(result, .completed, event.expectationDescription)
    }

    func testPullsRestartTheTimerAndAPullDuringARoundJoinsIt() async throws {
        let rig = try await makeRig()
        let tick = try XCTUnwrap(rig.model.tickState.tick)
        let initialNap = rig.timerBarrier.registration(at: rig.time.now.addingTimeInterval(30))
        await waitFor(initialNap)
        await rig.time.advance(by: 20)
        let before = rig.calls.count("poll")
        let entered = expectation(description: "first pull is inside its transport round")
        await rig.roundBarrier.arm(entered)
        let first = Task { await rig.model.pullToRefresh() }
        await waitFor(entered)
        let joinedBefore = await tick.joinedRefreshCount
        let second = Task { await tick.refreshNow() }
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(5))
        while await tick.joinedRefreshCount == joinedBefore, clock.now < deadline {
            await Task.yield()
        }
        let joined = await tick.joinedRefreshCount
        XCTAssertEqual(joined, joinedBefore + 1, "the second pull joined the parked round")
        await rig.roundBarrier.finish()
        await first.value
        let outcome = await second.value
        XCTAssertEqual(outcome, .joined)
        XCTAssertEqual(rig.calls.count("poll") - before, 1, "a pull during a round joins it")
        let restartedDeadline = rig.time.now.addingTimeInterval(30)
        let restartedNap = rig.timerBarrier.registration(at: restartedDeadline)
        await waitFor(restartedNap)
        let afterPull = rig.calls.count("poll")
        await rig.time.advance(by: 25)
        XCTAssertEqual(rig.calls.count("poll"), afterPull, "the pull restarted the 30 s timer")
        let nextNap = rig.timerBarrier.registration(after: restartedDeadline)
        await rig.time.advance(by: 10)
        await waitFor(nextNap)
        XCTAssertEqual(rig.calls.count("poll"), afterPull + 1)
        await tick.stop()
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
