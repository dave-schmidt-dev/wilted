import Foundation
import WiltedDomain
import XCTest
@testable import WiltedLibrary

private final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var time: TimeInterval
    init(_ start: TimeInterval = 1_000) { time = start }
    var now: Date { lock.withLock { Date(timeIntervalSince1970: time) } }
    func advance(_ seconds: TimeInterval) { lock.withLock { time += seconds } }
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func bump() { lock.withLock { value += 1 } }
    var count: Int { lock.withLock { value } }
}

private final class ChangeLog: @unchecked Sendable {
    private let lock = NSLock()
    private var states: [TransportGateState?] = []
    func record(_ state: TransportGateState?) { lock.withLock { states.append(state) } }
    var all: [TransportGateState?] { lock.withLock { states } }
}

/// The CloudKit adapter's error, as it prints: the shape `TransportPressureClassifier` reads.
private enum FakeCloudKitError: Error {
    case cloudKit(code: Int, message: String)
}

final class TransportPressureClassifierTests: XCTestCase {
    func testRateLimitCarriesTheServersWait() {
        let error = FakeCloudKitError.cloudKit(
            code: 7, message: "Operation throttled by previous server http 429 reply. Retry after 6.8 seconds. (Other operations may be affected)")
        XCTAssertEqual(TransportPressureClassifier.classify(error), TransportPressure(kind: .rateLimited, retryAfter: 6.8))
    }

    func testServiceUnavailableWithoutAWaitIsStillPressure() {
        let error = FakeCloudKitError.cloudKit(code: 6, message: "The operation couldn’t be completed. (CKErrorDomain error 6.)")
        XCTAssertEqual(TransportPressureClassifier.classify(error), TransportPressure(kind: .serviceUnavailable, retryAfter: nil))
    }

    func testAZoneBusyReplyIsRateLimiting() {
        XCTAssertEqual(TransportPressureClassifier.classify(FakeCloudKitError.cloudKit(code: 23, message: "busy"))?.kind, .rateLimited)
    }

    func testACloudKitErrorDomainErrorUsesItsRetryAfterKey() {
        let error = NSError(domain: "CKErrorDomain", code: 7, userInfo: ["CKErrorRetryAfterKey": NSNumber(value: 12.5)])
        XCTAssertEqual(TransportPressureClassifier.classify(error), TransportPressure(kind: .rateLimited, retryAfter: 12.5))
    }

    func testOtherErrorsAreNotPressure() {
        XCTAssertNil(TransportPressureClassifier.classify(FakeCloudKitError.cloudKit(code: 3, message: "offline")))
        XCTAssertNil(TransportPressureClassifier.classify(FakeCloudKitError.cloudKit(code: 14, message: "conflict")))
        XCTAssertNil(TransportPressureClassifier.classify(LibraryTransportError.transport("nope")))
        XCTAssertNil(TransportPressureClassifier.classify(TransportThrottled(retryAt: Date())))
    }
}

/// Uses the same concrete actor forwarding shape as the phone's scripted media transport.
private struct ConcreteOwnerForwardingTransport: LibraryTransport {
    let inner: InMemoryLibraryTransport
    func verifiedOwnerToken() async -> String? { await inner.verifiedOwnerToken() }
    func operationGeneration() async -> UInt64 { await inner.operationGeneration() }
    func fetchChanges(since token: LibraryChangeToken?) async throws -> LibraryChangeBatch { try await inner.fetchChanges(since: token) }
    func push(changes: [PendingLibraryChange]) async throws -> LibraryPushResult { try await inner.push(changes: changes) }
    func send(intent: LibraryIntent) async throws { try await inner.send(intent: intent) }
    func listIntents() async throws -> [LibraryIntent] { try await inner.listIntents() }
    func publish(_ record: DevicePlaybackPosition, as channel: PlaybackChannel) async throws { try await inner.publish(record, as: channel) }
    func fetchDeviceRecords() async throws -> LibraryDeviceRecords { try await inner.fetchDeviceRecords() }
    func commitFetchedState(_ token: LibraryChangeToken?) async throws { try await inner.commitFetchedState(token) }
    func commitSentState(_ token: LibraryChangeToken?) async throws { try await inner.commitSentState(token) }
}

final class TransportGateTests: XCTestCase {
    func testConcreteOwnerForwardingPreservesIdentityAndInvalidationGeneration() async {
        let server = InMemoryLibraryServer(writerDeviceID: "mac")
        let inner = InMemoryLibraryTransport(deviceID: "phone", server: server, verifiedOwnerToken: "configured-owner")
        let forwarding = ConcreteOwnerForwardingTransport(inner: inner)
        let wrapped = ThrottledLibraryTransport(wrapping: forwarding, gate: TransportGate())
        let paths: [(String, any LibraryTransport)] = [("actor existential", inner), ("forwarding existential", forwarding), ("throttled wrapper", wrapped)]
        let concreteOwner = await inner.verifiedOwnerToken()
        let concreteGeneration = await inner.operationGeneration()
        let forwardedOwner = await forwarding.verifiedOwnerToken()
        let forwardedGeneration = await forwarding.operationGeneration()
        XCTAssertEqual(concreteOwner, "configured-owner", "Concrete actor must read its configured owner")
        XCTAssertEqual(concreteGeneration, 0)
        XCTAssertEqual(forwardedOwner, "configured-owner", "Concrete forwarding must not select the nil protocol default")
        XCTAssertEqual(forwardedGeneration, 0)
        for (name, transport) in paths {
            let owner = await transport.verifiedOwnerToken()
            let generation = await transport.operationGeneration()
            XCTAssertEqual(owner, "configured-owner", name)
            XCTAssertEqual(generation, 0, name)
        }
        await inner.invalidateOperations()
        let invalidatedOwner = await inner.verifiedOwnerToken()
        let invalidatedGeneration = await inner.operationGeneration()
        let invalidatedForwardedOwner = await forwarding.verifiedOwnerToken()
        let invalidatedForwardedGeneration = await forwarding.operationGeneration()
        XCTAssertNil(invalidatedOwner)
        XCTAssertEqual(invalidatedGeneration, 1, "Concrete actor must expose the actual invalidation generation")
        XCTAssertNil(invalidatedForwardedOwner)
        XCTAssertEqual(invalidatedForwardedGeneration, 1, "Forwarding must not select the zero protocol default")
        for (name, transport) in paths {
            let owner = await transport.verifiedOwnerToken()
            let generation = await transport.operationGeneration()
            XCTAssertNil(owner, name)
            XCTAssertEqual(generation, 1, name)
        }
    }

    func testPublicationMethodsForwardReceiptAndBatchProvenance() async throws {
        let server = InMemoryLibraryServer(writerDeviceID: "mac")
        let inner = InMemoryLibraryTransport(deviceID: "mac", server: server, verifiedOwnerToken: "owner")
        let wrapped = ThrottledLibraryTransport(wrapping: inner, gate: TransportGate())
        let value = try LibraryPublication(id: "p", publishedAt: Date(timeIntervalSince1970: 1), writerDeviceID: "mac")
        try await wrapped.publishPublication(value)
        let seen = try await wrapped.readPublication()
        let batch = try await wrapped.fetchChanges(since: nil)
        XCTAssertEqual(seen, value)
        XCTAssertEqual(batch.observedPublication, value)
        XCTAssertEqual(batch.provenance?.ownerToken, "owner")
        let owner = await wrapped.verifiedOwnerToken()
        XCTAssertEqual(owner, "owner")
    }

    func testPressureGateBlocksPublicationReadAndWriteBeforeReachingServer() async throws {
        let clock = TestClock()
        let gate = gate(clock)
        _ = await attempt(gate, calls: Counter(), failing: limited)
        let server = InMemoryLibraryServer(writerDeviceID: "mac")
        let inner = InMemoryLibraryTransport(deviceID: "mac", server: server)
        let wrapped = ThrottledLibraryTransport(wrapping: inner, gate: gate)
        let value = try LibraryPublication(id: "p", publishedAt: Date(), writerDeviceID: "mac")
        do { try await wrapped.publishPublication(value); XCTFail("closed gate published") }
        catch { XCTAssertTrue(error is TransportThrottled) }
        do { _ = try await wrapped.readPublication(); XCTFail("closed gate read") }
        catch { XCTAssertTrue(error is TransportThrottled) }
        let stored = try await inner.readPublication()
        XCTAssertNil(stored)
    }
    private let limited = FakeCloudKitError.cloudKit(code: 7, message: "throttled. Retry after 1.5 seconds.")

    private func gate(_ clock: TestClock, log: ChangeLog = ChangeLog()) -> TransportGate {
        TransportGate(clock: { clock.now }, onChange: { log.record($0) })
    }

    private func attempt(_ gate: TransportGate, calls: Counter, failing error: Error? = nil) async -> Error? {
        do {
            try await gate.run { calls.bump(); if let error { throw error } }
            return nil
        } catch { return error }
    }

    func testBackoffGrowsDoublesAndIsCapped() {
        let waits = (1...12).map { TransportGate.delay(failures: $0, retryAfter: nil) }
        XCTAssertEqual(Array(waits.prefix(4)), [5, 10, 20, 40])
        XCTAssertEqual(waits.last, SyncCadence.backoffCap)
        XCTAssertEqual(waits, waits.sorted())
    }

    func testTheServersLongerWaitWinsOverTheBackoff() {
        XCTAssertEqual(TransportGate.delay(failures: 1, retryAfter: 30), 30)
        XCTAssertEqual(TransportGate.delay(failures: 1, retryAfter: 1.5), SyncCadence.backoffBase)
    }

    func testAPressureReplyClosesTheGateSoLaterCallsSendNothing() async {
        let clock = TestClock()
        let gate = gate(clock)
        let calls = Counter()
        _ = await attempt(gate, calls: calls, failing: limited)
        for _ in 0..<5 {
            let error = await attempt(gate, calls: calls)
            XCTAssertTrue(error is TransportThrottled)
        }
        XCTAssertEqual(calls.count, 1, "closed gate: the five later calls never reached the transport")
    }

    func testEveryCallerSharesTheOneGate() async {
        let clock = TestClock()
        let gate = gate(clock)
        let poller = Counter(), publisher = Counter(), handoff = Counter()
        _ = await attempt(gate, calls: poller, failing: limited)
        _ = await attempt(gate, calls: publisher)
        _ = await attempt(gate, calls: handoff)
        XCTAssertEqual([poller.count, publisher.count, handoff.count], [1, 0, 0])
    }

    func testAfterTheWaitOneProbeGoesThroughAndSuccessReopens() async {
        let clock = TestClock()
        let log = ChangeLog()
        let gate = gate(clock, log: log)
        let calls = Counter()
        _ = await attempt(gate, calls: calls, failing: limited)
        clock.advance(SyncCadence.backoffBase + 0.1)
        let probe = await attempt(gate, calls: calls)
        XCTAssertNil(probe)
        XCTAssertEqual(calls.count, 2)
        let after = await gate.state
        XCTAssertNil(after)
        XCTAssertEqual(log.all.count, 2)
        XCTAssertNil(log.all.last ?? nil)
    }

    func testFailedProbesBackOffLongerAndSuccessResetsTheCount() async {
        let clock = TestClock()
        let gate = gate(clock)
        let calls = Counter()
        var gaps: [TimeInterval] = []
        for _ in 0..<3 {
            _ = await attempt(gate, calls: calls, failing: limited)
            let state = await gate.state
            gaps.append(state!.retryAt.timeIntervalSince(clock.now))
            clock.advance(gaps.last! + 0.1)
        }
        XCTAssertEqual(gaps, [5, 10, 20])
        let recovered = await attempt(gate, calls: calls)
        XCTAssertNil(recovered)
        _ = await attempt(gate, calls: calls, failing: limited)
        let restarted = await gate.state
        XCTAssertEqual(restarted?.consecutiveFailures, 1)
        XCTAssertEqual(restarted?.retryAt.timeIntervalSince(clock.now), 5)
    }

    func testWhileAProbeIsInFlightOtherCallersStillWait() async {
        let clock = TestClock()
        let gate = gate(clock)
        let calls = Counter()
        _ = await attempt(gate, calls: calls, failing: limited)
        clock.advance(6)
        let gateForProbe = gate
        let probe = Task { try await gateForProbe.run { calls.bump(); try await Task.sleep(for: .milliseconds(200)) } }
        try? await Task.sleep(for: .milliseconds(50))
        let second = await attempt(gate, calls: calls)
        XCTAssertTrue(second is TransportThrottled)
        _ = try? await probe.value
        XCTAssertEqual(calls.count, 2)
    }

    func testASuccessFromARequestAdmittedBeforeTheClosureDoesNotReopenTheGate() async throws {
        let clock = TestClock()
        let gate = gate(clock)
        let calls = Counter()
        let slow = Task { try await gate.run { calls.bump(); try await Task.sleep(for: .milliseconds(200)) } }
        try await Task.sleep(for: .milliseconds(50))
        _ = await attempt(gate, calls: calls, failing: limited)
        try await slow.value
        let state = await gate.state
        XCTAssertNotNil(state, "the earlier request's success is stale: the closure stands")
        let next = await attempt(gate, calls: calls)
        XCTAssertTrue(next is TransportThrottled)
    }

    func testAPressureReplyFromAnEarlierRequestDoesNotCompoundTheBackoff() async throws {
        let clock = TestClock()
        let gate = gate(clock)
        let calls = Counter()
        let failure = limited
        let slow = Task { try await gate.run { calls.bump(); try await Task.sleep(for: .milliseconds(200)); throw failure } }
        try await Task.sleep(for: .milliseconds(50))
        _ = await attempt(gate, calls: calls, failing: limited)
        _ = try? await slow.value
        let state = await gate.state
        XCTAssertEqual(state?.consecutiveFailures, 1)
    }

    func testOtherFailuresDoNotCloseTheGate() async {
        let clock = TestClock()
        let gate = gate(clock)
        let calls = Counter()
        _ = await attempt(gate, calls: calls, failing: FakeCloudKitError.cloudKit(code: 3, message: "offline"))
        let next = await attempt(gate, calls: calls)
        XCTAssertNil(next)
        XCTAssertEqual(calls.count, 2)
    }

    func testTheThrottledTransportGatesServerCallsButNotLocalCommits() async throws {
        let server = InMemoryLibraryServer(writerDeviceID: "mac")
        let clock = TestClock()
        let gate = gate(clock)
        let transport = ThrottledLibraryTransport(wrapping: InMemoryLibraryTransport(deviceID: "mac", server: server), gate: gate)
        _ = try await transport.fetchDeviceRecords()
        _ = await attempt(gate, calls: Counter(), failing: limited)
        do { _ = try await transport.fetchDeviceRecords(); XCTFail("closed gate must throw") } catch { XCTAssertTrue(error is TransportThrottled) }
        try await transport.commitFetchedState(nil)
        try await transport.commitSentState(nil)
    }
}

final class TransportGateStatusTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 10_000)

    func testTheLineSaysWhatIsHappeningAndWhen() {
        let state = TransportGateState(kind: .rateLimited, retryAt: now.addingTimeInterval(44.2), consecutiveFailures: 2)
        XCTAssertEqual(state.notice(now: now), "iCloud is rate limiting sync. Retrying in 45 s.")
    }

    func testLongWaitsAreInMinutes() {
        let state = TransportGateState(kind: .serviceUnavailable, retryAt: now.addingTimeInterval(200), consecutiveFailures: 6)
        XCTAssertEqual(state.notice(now: now), "iCloud is temporarily unavailable. Retrying in 4 min.")
    }

    func testThePastRetryTimeReadsRetryingNowNotANegativeCountdown() {
        let state = TransportGateState(kind: .rateLimited, retryAt: now.addingTimeInterval(-3), consecutiveFailures: 1)
        XCTAssertEqual(state.notice(now: now), "iCloud is rate limiting sync. Retrying now.")
    }

    func testTheLastSecondRoundsUpToOne() {
        let state = TransportGateState(kind: .rateLimited, retryAt: now.addingTimeInterval(0.2), consecutiveFailures: 1)
        XCTAssertEqual(state.notice(now: now), "iCloud is rate limiting sync. Retrying in 1 s.")
    }

    func testTheResumeTimeVariantNamesTheClockTimeOnlyWhileItIsInTheFuture() {
        let state = TransportGateState(kind: .rateLimited, retryAt: now.addingTimeInterval(30), consecutiveFailures: 1)
        let waiting = state.noticeWithResumeTime(now: now, retrying: false)
        XCTAssertTrue(waiting.hasPrefix("iCloud is rate limiting sync. Retrying at "), waiting)
        XCTAssertTrue(waiting.hasSuffix("."), waiting)
    }

    func testARetryInFlightOrDueNeverShowsATimeThatHasPassed() {
        let state = TransportGateState(kind: .serviceUnavailable, retryAt: now.addingTimeInterval(-40), consecutiveFailures: 1)
        let due = "iCloud is temporarily unavailable. Retrying now…"
        XCTAssertEqual(state.noticeWithResumeTime(now: now, retrying: false), due, "the time has passed: no past time")
        let future = TransportGateState(kind: .serviceUnavailable, retryAt: now.addingTimeInterval(30), consecutiveFailures: 1)
        XCTAssertEqual(future.noticeWithResumeTime(now: now, retrying: true), due, "in flight beats a future time")
    }

    func testALaterScheduledAttemptReplacesTheGatesOwnTime() {
        let state = TransportGateState(kind: .rateLimited, retryAt: now.addingTimeInterval(-5), consecutiveFailures: 1)
        let later = now.addingTimeInterval(10)
        let line = state.noticeWithResumeTime(now: now, retrying: false, attemptAt: later)
        XCTAssertTrue(line.contains("Retrying at "), line)
        XCTAssertTrue(line.contains(later.formatted(date: .omitted, time: .standard)), line)
    }
}
