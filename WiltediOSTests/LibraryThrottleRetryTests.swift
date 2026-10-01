import Foundation
import WiltedDomain
import WiltedLibrary
import XCTest
@testable import WiltediOS

/// A transport that forwards to the in-memory one and lets a test script the next `fetchChanges`
/// (refuse with an error, or hold the call open so the retry can be seen while it is in flight).
private final class FetchScript: @unchecked Sendable {
    private let lock = NSLock()
    private var errors: [any Error] = []
    private var holdNext = false
    private var offline = false
    private var held: CheckedContinuation<Void, Never>?
    private(set) var fetches = 0

    /// Every read fails with a plain transport error (not iCloud pressure) while this is on.
    func setOffline(_ on: Bool) { lock.withLock { offline = on } }
    func checkOnline() throws {
        if lock.withLock({ offline }) { throw LibraryTransportError.transport("offline") }
    }
    func failNext(_ error: any Error) { lock.withLock { errors.append(error) } }
    func holdNextFetch() { lock.withLock { holdNext = true } }
    var isHolding: Bool { lock.withLock { held != nil } }
    func release() {
        let continuation = lock.withLock { () -> CheckedContinuation<Void, Never>? in
            defer { held = nil }
            return held
        }
        continuation?.resume()
    }

    func beforeFetch() async throws {
        let error: (any Error)? = lock.withLock {
            fetches += 1
            return errors.isEmpty ? nil : errors.removeFirst()
        }
        let shouldHold = lock.withLock { () -> Bool in defer { holdNext = false }; return holdNext }
        if shouldHold {
            await withCheckedContinuation { continuation in lock.withLock { held = continuation } }
        }
        if let error { throw error }
    }
}

private struct ScriptedTransport: LibraryTransport {
    let base: InMemoryLibraryTransport
    let script: FetchScript

    func operationGeneration() async -> UInt64 { await base.operationGeneration() }
    func fetchChanges(since token: LibraryChangeToken?) async throws -> LibraryChangeBatch {
        try script.checkOnline()
        try await script.beforeFetch()
        return try await base.fetchChanges(since: token)
    }
    func push(changes: [PendingLibraryChange]) async throws -> LibraryPushResult { try await base.push(changes: changes) }
    func send(intent: LibraryIntent) async throws { try await base.send(intent: intent) }
    func listIntents() async throws -> [LibraryIntent] { try await base.listIntents() }
    func publishIntentOutcome(_ outcome: IntentOutcome) async throws { try await base.publishIntentOutcome(outcome) }
    func intentOutcomes() async throws -> [IntentOutcome] { try await base.intentOutcomes() }
    func publish(_ record: DevicePlaybackPosition, as channel: PlaybackChannel) async throws { try await base.publish(record, as: channel) }
    func fetchDeviceRecords() async throws -> LibraryDeviceRecords {
        try script.checkOnline()
        return try await base.fetchDeviceRecords()
    }
    func publishMedia(offer: LibraryMediaOffer, fileURL: URL) async throws { try await base.publishMedia(offer: offer, fileURL: fileURL) }
    func mediaOffers() async throws -> [LibraryMediaOffer] {
        try script.checkOnline()
        return try await base.mediaOffers()
    }
    func fetchMedia(_ offer: LibraryMediaOffer, progress: @escaping MediaProgressHandler) async throws -> URL {
        try await base.fetchMedia(offer, progress: progress)
    }
    func removeMedia(entryID: ItemID) async throws { try await base.removeMedia(entryID: entryID) }
    func publishStats(_ stats: LibraryStats) async throws { try await base.publishStats(stats) }
    func readStats() async throws -> LibraryStats? { try await base.readStats() }
    func publishTranscript(_ transcript: LibraryTranscript) async throws { try await base.publishTranscript(transcript) }
    func transcript(entryID: ItemID, revisionID: RevisionID) async throws -> LibraryTranscript? {
        try await base.transcript(entryID: entryID, revisionID: revisionID)
    }
    func removeTranscript(entryID: ItemID) async throws { try await base.removeTranscript(entryID: entryID) }
    func commitFetchedState(_ token: LibraryChangeToken?) async throws { try await base.commitFetchedState(token) }
    func commitSentState(_ token: LibraryChangeToken?) async throws { try await base.commitSentState(token) }
}

/// The retry sleep, which a test fires by hand after moving the clock.
private final class ManualSleep: @unchecked Sendable {
    private let lock = NSLock()
    private var waiting: [CheckedContinuation<Void, any Error>] = []
    private(set) var requested: [TimeInterval] = []

    var pending: Int { lock.withLock { waiting.count } }

    func sleep(_ seconds: TimeInterval) async throws {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                lock.withLock {
                    requested.append(seconds)
                    waiting.append(continuation)
                }
            }
        } onCancel: {
            let all = lock.withLock { () -> [CheckedContinuation<Void, any Error>] in defer { waiting = [] }; return waiting }
            all.forEach { $0.resume(throwing: CancellationError()) }
        }
    }

    func fire() {
        let all = lock.withLock { () -> [CheckedContinuation<Void, any Error>] in defer { waiting = [] }; return waiting }
        all.forEach { $0.resume() }
    }
}

/// The phone retries by itself when the gate's time passes, and the banner says what it is doing:
/// waiting (a time in the future), retrying (an indicator, "Retrying now…"), then recovered (cleared)
/// or a new failure (a new future time). It never shows a time that has already gone by.
@MainActor
final class LibraryThrottleRetryTests: XCTestCase {
    private enum FakeCloudKitError: Error {
        case cloudKit(code: Int, message: String)
    }

    private final class TestClock: @unchecked Sendable {
        private let lock = NSLock()
        private var time: TimeInterval = 1_000_000
        var now: Date { lock.withLock { Date(timeIntervalSince1970: time) } }
        func advance(_ seconds: TimeInterval) { lock.withLock { time += seconds } }
    }

    private let clock = TestClock()
    private let script = FetchScript()
    private let sleeper = ManualSleep()

    private func makeModel() -> LibraryAppModel {
        let clock = clock
        let sleeper = sleeper
        let base = InMemoryLibraryTransport(deviceID: "phone", server: InMemoryLibraryServer(writerDeviceID: "mac"))
        return LibraryAppModel(
            transport: ScriptedTransport(base: base, script: script),
            deviceID: "phone", preferences: UserDefaults(suiteName: "library-throttle-retry-tests")!,
            now: { clock.now }, timeZone: TimeZone(identifier: "UTC")!,
            throttleSleep: { try await sleeper.sleep($0) })
    }

    private func eventually(_ what: String, _ condition: @MainActor () -> Bool) async throws {
        for _ in 0..<300 where !condition() { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(condition(), what)
    }

    private func closeTheGate(_ model: LibraryAppModel, code: Int = 7, message: String = "Request was rate limited. Retry after 45 seconds") async throws {
        do {
            try await model.throttleGate.run { throw FakeCloudKitError.cloudKit(code: code, message: message) } as Void
        } catch {}
        try await eventually("the retry is waiting") { self.sleeper.pending == 1 }
    }

    private func time(_ date: Date) -> String { date.formatted(date: .omitted, time: .standard) }

    func testWaitingThenRetryingThenRecoveredClearsTheBanner() async throws {
        let model = makeModel()
        try await closeTheGate(model)
        let retryAt = clock.now.addingTimeInterval(45)
        XCTAssertEqual(model.throttleNotice, "iCloud is rate limiting sync. Retrying at \(time(retryAt)).", "waiting: a future time")
        XCTAssertFalse(model.throttleRetrying)
        XCTAssertEqual(try XCTUnwrap(sleeper.requested.first), 45 + LibraryAppModel.throttleWakeMargin, accuracy: 0.001)
        XCTAssertEqual(script.fetches, 0, "nothing is sent while it waits")

        clock.advance(46)
        script.holdNextFetch()
        sleeper.fire()
        try await eventually("the retry is in flight") { model.throttleRetrying && self.script.isHolding }
        XCTAssertEqual(model.throttleNotice, "iCloud is rate limiting sync. Retrying now…", "retrying: no old time")
        XCTAssertEqual(model.syncSummary.status, "Retrying")
        XCTAssertEqual(model.syncSummary.tone, .active)

        script.release()
        try await eventually("recovered") { model.throttleState == nil && !model.throttleRetrying }
        XCTAssertNil(model.throttleNotice, "recovered: the banner clears")
        XCTAssertNil(model.errorMessage)
        XCTAssertEqual(sleeper.pending, 0, "no retry stays scheduled once the gate reopens")
    }

    func testARetryICloudRefusesAgainShowsANewFutureTime() async throws {
        let model = makeModel()
        try await closeTheGate(model)
        clock.advance(46)
        script.failNext(FakeCloudKitError.cloudKit(code: 6, message: "Service unavailable"))
        script.holdNextFetch()
        sleeper.fire()
        try await eventually("retrying") { model.throttleRetrying && self.script.isHolding }
        script.release()
        try await eventually("a new closure is recorded") { model.throttleState?.consecutiveFailures == 2 }
        try await eventually("the next retry is scheduled") { self.sleeper.pending == 1 && !model.throttleRetrying }

        let retryAt = try XCTUnwrap(model.throttleState?.retryAt)
        XCTAssertGreaterThan(retryAt, clock.now, "a new time in the future")
        XCTAssertEqual(model.throttleNotice, "iCloud is temporarily unavailable. Retrying at \(time(retryAt)).")
        XCTAssertEqual(sleeper.requested.count, 2)
        XCTAssertEqual(sleeper.requested[1], retryAt.timeIntervalSince(clock.now) + LibraryAppModel.throttleWakeMargin, accuracy: 0.001)
    }

    func testARetryThatFailsForAnotherReasonIsTriedAgainLaterNotLeftWithAPastTime() async throws {
        let model = makeModel()
        try await closeTheGate(model)
        clock.advance(46)
        script.setOffline(true)
        sleeper.fire()
        try await eventually("the next attempt is scheduled") { self.sleeper.requested.count == 2 && self.sleeper.pending == 1 }

        XCTAssertFalse(model.throttleRetrying)
        XCTAssertNotNil(model.throttleState, "the gate was not reopened by an offline probe")
        let next = clock.now.addingTimeInterval(LibraryAppModel.throttleFallbackWait)
        XCTAssertEqual(model.throttleAttemptAt, next)
        XCTAssertEqual(model.throttleNotice, "iCloud is rate limiting sync. Retrying at \(time(next)).")
        XCTAssertEqual(sleeper.requested[1], LibraryAppModel.throttleFallbackWait + LibraryAppModel.throttleWakeMargin, accuracy: 0.001)

        // Back online: the second attempt succeeds and clears everything.
        script.setOffline(false)
        clock.advance(31)
        sleeper.fire()
        try await eventually("recovered") { model.throttleState == nil }
        XCTAssertNil(model.throttleNotice)
        XCTAssertNil(model.throttleAttemptAt)
    }

    func testATimePassedWithoutTheRetryRunningReadsRetryingNowNeverThePastTime() async throws {
        let model = makeModel()
        try await closeTheGate(model)
        let retryAt = clock.now.addingTimeInterval(45)
        clock.advance(50)
        let notice = try XCTUnwrap(model.throttleNotice)
        XCTAssertEqual(notice, "iCloud is rate limiting sync. Retrying now…")
        XCTAssertFalse(notice.contains(time(retryAt)), notice)
    }

    func testARefreshAtTheDueTimeShowsTheRetryWhoeverStartedIt() async throws {
        let model = makeModel()
        try await closeTheGate(model)
        clock.advance(46)
        script.holdNextFetch()
        let refresh = Task { await model.refresh() }
        try await eventually("the foreground refresh is the retry") { model.throttleRetrying && self.script.isHolding }
        script.release()
        await refresh.value
        try await eventually("recovered") { model.throttleState == nil && !model.throttleRetrying }
        XCTAssertEqual(sleeper.pending, 0, "the pending retry is cancelled when the gate reopens")
    }

    func testARefreshBeforeTheDueTimeIsNotARetry() async throws {
        let model = makeModel()
        try await closeTheGate(model)
        clock.advance(10)
        await model.refresh()
        XCTAssertFalse(model.throttleRetrying)
        XCTAssertNotNil(model.throttleState)
        XCTAssertEqual(script.fetches, 0, "the closed gate refuses it locally")
        XCTAssertEqual(sleeper.pending, 1)
    }

    // MARK: One banner

    func testARefusedRefreshWhileTheGateIsClosedLeavesExactlyOneBanner() async throws {
        let model = makeModel()
        try await closeTheGate(model)
        clock.advance(10)
        await model.refresh()
        XCTAssertNil(model.errorMessage, "no second line beside the throttle banner")
        guard case let .throttle(text, retrying)? = model.syncBanner else { return XCTFail("\(String(describing: model.syncBanner))") }
        XCTAssertTrue(text.contains("Retrying at "), text)
        XCTAssertFalse(retrying)
    }

    func testSyncStatusResolvesToOneBannerByPrecedence() {
        typealias Banner = LibrarySyncBanner
        XCTAssertNil(Banner.resolve(quarantined: false, throttleNotice: nil, retrying: false, error: nil))
        XCTAssertEqual(Banner.resolve(quarantined: false, throttleNotice: nil, retrying: false, error: "x"), .problem("x"))
        XCTAssertEqual(
            Banner.resolve(quarantined: false, throttleNotice: "wait", retrying: false, error: "x"),
            .throttle(text: "wait", retrying: false), "iCloud pushing back outranks a plain failure")
        XCTAssertEqual(
            Banner.resolve(quarantined: false, throttleNotice: "wait", retrying: true, error: nil),
            .throttle(text: "wait", retrying: true))
        XCTAssertEqual(
            Banner.resolve(quarantined: true, throttleNotice: "wait", retrying: true, error: "x"),
            .accountReview, "an account review outranks everything")
    }

    func testTheSettingsSyncCardSaysTheSameThingAsTheBanner() async throws {
        let model = makeModel()
        try await closeTheGate(model)
        XCTAssertEqual(model.syncSummary.status, "Paused")
        XCTAssertEqual(model.syncSummary.detail, model.throttleNotice)
        clock.advance(46)
        script.holdNextFetch()
        sleeper.fire()
        try await eventually("retrying") { model.throttleRetrying && self.script.isHolding }
        XCTAssertEqual(model.syncSummary.status, "Retrying")
        guard case .throttle(_, true)? = model.syncBanner else { return XCTFail("the banner shows the retry too") }
        script.release()
        try await eventually("recovered") { model.throttleState == nil }
        XCTAssertNil(model.syncBanner)
    }
}
