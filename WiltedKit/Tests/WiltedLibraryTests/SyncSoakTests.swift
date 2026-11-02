import Foundation
import os
import WiltedDomain
import XCTest
@testable import WiltedLibrary

/// A virtual-clock 24-hour soak of the sync tick against `InMemoryLibraryTransport` with a
/// throttling fault injector. Verifies that idle hours stay within the hourly request budgets,
/// that throttling pauses transport calls for the required Retry-After window, and that recovery
/// happens within Retry-After plus probe backoff and cadence interval.
final class SyncSoakTests: XCTestCase {
    /// A scheduled interval during which transport calls throw rate-limiting pressure errors.
    struct ThrottleWindow: Sendable {
        let start: Date
        let end: Date
        let retryAfter: TimeInterval
    }

    /// Wraps a transport to count logical calls per virtual hour and inject transient pressure
    /// errors with Retry-After during scheduled throttle windows.
    final class ThrottlingFaultInjector: LibraryTransport, @unchecked Sendable {
        private let inner: any LibraryTransport
        private let clock: @Sendable () -> Date
        private let startTime: Date
        private let windows: [ThrottleWindow]
        private let lock = NSLock()

        private var callTimestamps: [Date] = []
        private var hourlyCalls: [Int: Int] = [:]
        private var failures: [(at: Date, retryAfter: TimeInterval, window: ThrottleWindow)] = []
        private var successes: [Date] = []

        init(
            wrapping inner: any LibraryTransport,
            startTime: Date,
            windows: [ThrottleWindow],
            clock: @escaping @Sendable () -> Date
        ) {
            self.inner = inner
            self.startTime = startTime
            self.windows = windows
            self.clock = clock
        }

        private func intercept() throws {
            let now = clock()
            lock.lock()
            defer { lock.unlock() }
            callTimestamps.append(now)
            let hour = max(0, Int(now.timeIntervalSince(startTime) / 3600))
            hourlyCalls[hour, default: 0] += 1

            for window in windows {
                if now >= window.start && now < window.end {
                    failures.append((at: now, retryAfter: window.retryAfter, window: window))
                    let error = NSError(
                        domain: "CKErrorDomain",
                        code: 7,
                        userInfo: ["CKRetryAfter": NSNumber(value: window.retryAfter)]
                    )
                    throw error
                }
            }
            successes.append(now)
        }

        func count(forHour hour: Int) -> Int {
            lock.withLock { hourlyCalls[hour] ?? 0 }
        }

        func allCallTimestamps() -> [Date] {
            lock.withLock { callTimestamps }
        }

        func allFailures() -> [(at: Date, retryAfter: TimeInterval, window: ThrottleWindow)] {
            lock.withLock { failures }
        }

        func allSuccesses() -> [Date] {
            lock.withLock { successes }
        }

        func operationGeneration() async -> UInt64 { await inner.operationGeneration() }
        func verifiedOwnerToken() async -> String? { await inner.verifiedOwnerToken() }
        func verifyOwner() async throws {
            try intercept()
            try await inner.verifyOwner()
        }
        func fetchChanges(since token: LibraryChangeToken?) async throws -> LibraryChangeBatch {
            try intercept()
            return try await inner.fetchChanges(since: token)
        }
        func push(changes: [PendingLibraryChange]) async throws -> LibraryPushResult {
            try intercept()
            return try await inner.push(changes: changes)
        }
        func send(intent: LibraryIntent) async throws {
            try intercept()
            try await inner.send(intent: intent)
        }
        func listIntents() async throws -> [LibraryIntent] {
            try intercept()
            return try await inner.listIntents()
        }
        func publishIntentOutcome(_ outcome: IntentOutcome) async throws {
            try intercept()
            try await inner.publishIntentOutcome(outcome)
        }
        func intentOutcomes() async throws -> [IntentOutcome] {
            try intercept()
            return try await inner.intentOutcomes()
        }
        func publish(_ record: DevicePlaybackPosition, as channel: PlaybackChannel) async throws {
            try intercept()
            try await inner.publish(record, as: channel)
        }
        func fetchDeviceRecords() async throws -> LibraryDeviceRecords {
            try intercept()
            return try await inner.fetchDeviceRecords()
        }
        func publish(_ records: [(record: DevicePlaybackPosition, channel: PlaybackChannel)]) async throws {
            try intercept()
            try await inner.publish(records)
        }
        func poll(_ options: LibraryPollOptions) async throws -> LibraryPollResult {
            try intercept()
            return try await inner.poll(options)
        }
        func publishMedia(offer: LibraryMediaOffer, fileURL: URL) async throws {
            try intercept()
            try await inner.publishMedia(offer: offer, fileURL: fileURL)
        }
        func mediaOffers() async throws -> [LibraryMediaOffer] {
            try intercept()
            return try await inner.mediaOffers()
        }
        func fetchMedia(_ offer: LibraryMediaOffer, progress: @escaping MediaProgressHandler) async throws -> URL {
            try intercept()
            return try await inner.fetchMedia(offer, progress: progress)
        }
        func removeMedia(entryID: ItemID) async throws {
            try intercept()
            try await inner.removeMedia(entryID: entryID)
        }
        func publishStats(_ stats: LibraryStats) async throws {
            try intercept()
            try await inner.publishStats(stats)
        }
        func readStats() async throws -> LibraryStats? {
            try intercept()
            return try await inner.readStats()
        }
        func publishBulletins(_ bulletins: LibraryBulletins) async throws {
            try intercept()
            try await inner.publishBulletins(bulletins)
        }
        func fetchBulletins() async throws -> LibraryBulletins? {
            try intercept()
            return try await inner.fetchBulletins()
        }
        func publishPublication(_ publication: LibraryPublication) async throws {
            try intercept()
            try await inner.publishPublication(publication)
        }
        func readPublication() async throws -> LibraryPublication? {
            try intercept()
            return try await inner.readPublication()
        }
        func publishTranscript(_ transcript: LibraryTranscript) async throws {
            try intercept()
            try await inner.publishTranscript(transcript)
        }
        func transcript(entryID: ItemID, revisionID: RevisionID) async throws -> LibraryTranscript? {
            try intercept()
            return try await inner.transcript(entryID: entryID, revisionID: revisionID)
        }
        func removeTranscript(entryID: ItemID) async throws {
            try intercept()
            try await inner.removeTranscript(entryID: entryID)
        }
        func announceDevice(_ announcement: LibraryDeviceAnnouncement) async throws {
            try intercept()
            try await inner.announceDevice(announcement)
        }
        func fetchDeviceDirectory() async throws -> LibraryDeviceDirectory? {
            try intercept()
            return try await inner.fetchDeviceDirectory()
        }
        func publishDeviceLink(_ link: LibraryDeviceLink) async throws {
            try intercept()
            try await inner.publishDeviceLink(link)
        }
        func fetchDeviceLink() async throws -> LibraryDeviceLink? {
            try intercept()
            return try await inner.fetchDeviceLink()
        }
        func commitFetchedState(_ token: LibraryChangeToken?) async throws {
            try await inner.commitFetchedState(token)
        }
        func commitSentState(_ token: LibraryChangeToken?) async throws {
            try await inner.commitSentState(token)
        }
    }

    /// Virtual-clock 24-hour soak asserting hourly limits under both Mac (30 s) and phone (300 s)
    /// cadences, zero transport calls during Retry-After, and recovery bounded by Retry-After plus backoff.
    func testTwentyFourHourSyncSoakWithThrottlingFaultsAndCadenceSwitch() async throws {
        let startWall = Date()
        let startTime = Date(timeIntervalSince1970: 1_000_000)
        let time = VirtualTime(start: startTime)
        let gate = TransportGate(clock: { time.now }, jitter: { _ in 0 })

        // Window 1: in Hour 3 (Mac cadence, 30 s tick), 130 s duration, Retry-After 60 s.
        // Causes 3 consecutive pressure replies (at t=11400, t=11460, t=11525).
        let window1 = ThrottleWindow(
            start: startTime.addingTimeInterval(3 * 3600 + 600),
            end: startTime.addingTimeInterval(3 * 3600 + 730),
            retryAfter: 60
        )
        // Window 2: in Hour 16 (phone idle cadence, 300 s tick), 100 s duration, Retry-After 60 s.
        let window2 = ThrottleWindow(
            start: startTime.addingTimeInterval(16 * 3600),
            end: startTime.addingTimeInterval(16 * 3600 + 100),
            retryAfter: 60
        )
        let windows = [window1, window2]

        let server = InMemoryLibraryServer(writerDeviceID: "mac")
        let inner = InMemoryLibraryTransport(deviceID: "mac", server: server)
        let faultInjector = ThrottlingFaultInjector(
            wrapping: inner,
            startTime: startTime,
            windows: windows,
            clock: { time.now }
        )
        let throttled = ThrottledLibraryTransport(wrapping: faultInjector, gate: gate)

        let rounds = OSAllocatedUnfairLock(initialState: 0)
        let tick = SyncTick(
            interval: SyncCadence.tickInterval,
            gate: gate,
            clock: { time.now },
            sleep: { try await time.sleep($0) }
        ) { trigger in
            let round = rounds.withLock { $0 += 1; return $0 }
            let plan = SyncTick.RoundPlan.plan(for: trigger, round: round)
            var options: LibraryPollOptions = [.deviceRecords]
            if plan.readsOffers { options.insert(.offers) }
            if plan.forcesOffers { options.insert(.forceOffers) }
            options.insert(.intents)
            _ = try? await throttled.poll(options)
        }

        await tick.start()

        for hour in 0..<24 {
            if hour == 12 {
                await tick.setInterval(SyncCadence.phoneIdleInterval)
            }
            await time.advance(by: 3600)
        }

        await tick.stop()
        await time.settle()

        // 1. Wall time constraint: whole 24 h soak runs in under 10 s wall time.
        let wallElapsed = Date().timeIntervalSince(startWall)
        XCTAssertLessThan(wallElapsed, 10.0, "24 h soak must run in under 10 s wall time")

        // 2. Hourly call count assertions.
        // Mac cadence (hours 0..<12, tickInterval = 30 s):
        for h in 0..<12 {
            let count = faultInjector.count(forHour: h)
            XCTAssertLessThanOrEqual(
                count,
                SyncCadence.macIdleRequestsPerHour,
                "Hour \(h) must not exceed macIdleRequestsPerHour"
            )
            if h != 3 {
                XCTAssertEqual(
                    count,
                    SyncCadence.macIdleRequestsPerHour,
                    "Idle hour \(h) must equal macIdleRequestsPerHour"
                )
            } else {
                XCTAssertLessThan(
                    count,
                    SyncCadence.macIdleRequestsPerHour,
                    "Throttled hour 3 must make fewer calls than macIdleRequestsPerHour"
                )
            }
        }

        // Phone idle cadence (hours 12..<24, phoneIdleInterval = 300 s):
        for h in 12..<24 {
            let count = faultInjector.count(forHour: h)
            XCTAssertLessThanOrEqual(
                count,
                SyncCadence.phoneIdleRequestsPerHour,
                "Hour \(h) must not exceed phoneIdleRequestsPerHour"
            )
            // Hour 12 holds the switch from the 30 s cadence, so its first round waits a whole idle interval.
            if h != 12, h != 16 {
                XCTAssertEqual(
                    count,
                    SyncCadence.phoneIdleRequestsPerHour,
                    "Idle hour \(h) must equal phoneIdleRequestsPerHour"
                )
            }
        }

        // 3. Throttle Window assertions: no call reaches the transport before Retry-After.
        let allFailures = faultInjector.allFailures()
        let w1Failures = allFailures.filter { $0.window.start == window1.start }
        XCTAssertGreaterThanOrEqual(w1Failures.count, 2, "Window 1 must trigger multiple throttling failures")

        for i in 0..<(w1Failures.count - 1) {
            let current = w1Failures[i]
            let next = w1Failures[i + 1]
            let gap = next.at.timeIntervalSince(current.at)
            XCTAssertGreaterThanOrEqual(
                gap,
                current.retryAfter,
                "No call may reach the transport before Retry-After during throttle window"
            )
        }

        // 4. Recovery assertions: next successful call happens within Retry-After + extraWait + one tick.
        let allSuccesses = faultInjector.allSuccesses()

        // Window 1 recovery:
        let w1Success = try XCTUnwrap(
            allSuccesses.first { $0 >= window1.end },
            "Expected a successful call after Window 1 ended"
        )
        let w1LastFailure = try XCTUnwrap(w1Failures.last)
        let w1ExtraWait = TransportGate.extraWait(failures: w1Failures.count)
        let w1ExpectedMax = w1LastFailure.at.addingTimeInterval(
            window1.retryAfter + w1ExtraWait + SyncCadence.tickInterval
        )
        XCTAssertLessThanOrEqual(
            w1Success,
            w1ExpectedMax,
            "Recovery after Window 1 must happen within Retry-After + extraWait + one tick"
        )
        XCTAssertGreaterThanOrEqual(
            w1Success,
            w1LastFailure.at.addingTimeInterval(window1.retryAfter + w1ExtraWait),
            "Recovery cannot occur before the gate reopens"
        )

        // Window 2 recovery:
        let w2Failures = allFailures.filter { $0.window.start == window2.start }
        XCTAssertGreaterThanOrEqual(w2Failures.count, 1, "Window 2 must produce at least one throttling failure")

        let w2Success = try XCTUnwrap(
            allSuccesses.first { $0 >= window2.end },
            "Expected a successful call after Window 2 ended"
        )
        let w2LastFailure = try XCTUnwrap(w2Failures.last)
        let w2ExtraWait = TransportGate.extraWait(failures: w2Failures.count)
        let w2ExpectedMax = w2LastFailure.at.addingTimeInterval(
            window2.retryAfter + w2ExtraWait + SyncCadence.phoneIdleInterval
        )
        XCTAssertLessThanOrEqual(
            w2Success,
            w2ExpectedMax,
            "Recovery after Window 2 must happen within Retry-After + extraWait + one tick"
        )
        XCTAssertGreaterThanOrEqual(
            w2Success,
            w2LastFailure.at.addingTimeInterval(window2.retryAfter + w2ExtraWait),
            "Recovery cannot occur before the gate reopens"
        )
    }

    /// Verifies that pull-to-refresh while a throttle window has closed the gate sends nothing
    /// to the transport and immediately returns a throttled outcome.
    func testPullToRefreshInsideThrottleWindowReturnsThrottledWithoutReachingTransport() async throws {
        let startTime = Date(timeIntervalSince1970: 1_000_000)
        let time = VirtualTime(start: startTime)
        let gate = TransportGate(clock: { time.now }, jitter: { _ in 0 })
        let window = ThrottleWindow(start: startTime, end: startTime.addingTimeInterval(120), retryAfter: 60)
        let server = InMemoryLibraryServer(writerDeviceID: "mac")
        let inner = InMemoryLibraryTransport(deviceID: "mac", server: server)
        let faultInjector = ThrottlingFaultInjector(
            wrapping: inner,
            startTime: startTime,
            windows: [window],
            clock: { time.now }
        )
        let throttled = ThrottledLibraryTransport(wrapping: faultInjector, gate: gate)

        let tick = SyncTick(
            interval: SyncCadence.tickInterval,
            gate: gate,
            clock: { time.now },
            sleep: { try await time.sleep($0) }
        ) { _ in
            _ = try? await throttled.poll([.deviceRecords])
        }

        await tick.start()
        await time.settle()

        // The first round at t=0 hit the window and failed.
        XCTAssertEqual(faultInjector.allFailures().count, 1)
        let callsBefore = faultInjector.allCallTimestamps().count

        // At t=10, gate is closed until t=60. Pull-to-refresh must return .throttled.
        await time.advance(by: 10)
        let outcome = await tick.refreshNow()
        guard case let .throttled(state) = outcome else {
            return XCTFail("Expected throttled outcome, got \(outcome)")
        }
        XCTAssertEqual(state.kind, .rateLimited)
        XCTAssertEqual(
            faultInjector.allCallTimestamps().count,
            callsBefore,
            "Pull while gate is closed must not touch the transport"
        )

        await tick.stop()
        await time.settle()
    }
}
