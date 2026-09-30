import Foundation
import WiltedDomain
import XCTest
@testable import WiltedLibrary

/// Shared controllable wall clock; the in-memory server's clock is kept equal to it.
private final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var time: TimeInterval
    init(_ start: TimeInterval = 1_000) { time = start }
    var now: Date { lock.withLock { Date(timeIntervalSince1970: time) } }
    func set(_ value: TimeInterval) { lock.withLock { time = value } }
}

/// Records the delays `settleCheck()` asks for.
private final class SleepLog: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [TimeInterval] = []
    func record(_ value: TimeInterval) { lock.withLock { values.append(value) } }
    var all: [TimeInterval] { lock.withLock { values } }
}

/// Models propagation lag: fetches return nothing until `catchUp()`.
private final class LagSwitch: @unchecked Sendable {
    private let lock = NSLock()
    private var lagging = true
    var isLagging: Bool { lock.withLock { lagging } }
    func catchUp() { lock.withLock { lagging = false } }
}

private struct LaggingTransport: LibraryTransport {
    let base: InMemoryLibraryTransport
    let lag: LagSwitch
    func fetchChanges(since token: LibraryChangeToken?) async throws -> LibraryChangeBatch { try await base.fetchChanges(since: token) }
    func push(changes: [PendingLibraryChange]) async throws -> LibraryPushResult { try await base.push(changes: changes) }
    func send(intent: LibraryIntent) async throws { try await base.send(intent: intent) }
    func listIntents() async throws -> [LibraryIntent] { try await base.listIntents() }
    func publish(_ record: DevicePlaybackPosition, as channel: PlaybackChannel) async throws {
        try await base.publish(record, as: channel)
    }
    func fetchDeviceRecords() async throws -> LibraryDeviceRecords {
        lag.isLagging ? LibraryDeviceRecords() : try await base.fetchDeviceRecords()
    }
}

final class HandoffCoordinatorTests: XCTestCase {
    private let entry = try! ItemID(rawValue: "item-" + String(repeating: "a", count: 64))
    private let revisionA = try! RevisionID(rawValue: "rev-a")
    private let revisionB = try! RevisionID(rawValue: "rev-b")

    private struct Env {
        let clock: TestClock
        let server: InMemoryLibraryServer
        let sleeps = SleepLog()

        func transport(_ device: String) -> InMemoryLibraryTransport { InMemoryLibraryTransport(deviceID: device, server: server) }

        func coordinator(_ device: String, over transport: (any LibraryTransport)? = nil) -> HandoffCoordinator {
            let clock = clock
            let sleeps = sleeps
            return HandoffCoordinator(
                transport: transport ?? self.transport(device), deviceID: device,
                clock: { clock.now }, sleep: { sleeps.record($0) })
        }

        func advance(to time: TimeInterval) async {
            clock.set(time)
            await server.setClock(clock.now)
        }
    }

    private func makeEnv() async -> Env {
        let env = Env(clock: TestClock(), server: InMemoryLibraryServer(writerDeviceID: "mac"))
        await env.advance(to: 1_000)
        return env
    }

    private func record(_ device: String, epoch: Int, playing: Bool = true, position: Double = 100,
                        revision: RevisionID? = nil) throws -> DevicePlaybackPosition {
        try DevicePlaybackPosition(deviceID: device, entryID: entry, revision: revision ?? revisionA,
                                   positionSeconds: position, isPlaying: playing, epoch: epoch)
    }

    private func nowPlaying(_ env: Env, _ device: String) async throws -> ObservedPlayback? {
        try await env.transport("reader").fetchDeviceRecords().nowPlaying.first { $0.record.deviceID == device }
    }

    func testTakeoverEpochIsMaxSeenPlusOneAndPublishesBothChannels() async throws {
        let env = await makeEnv()
        try await env.transport("mac").publish(record("mac", epoch: 3), as: .nowPlaying)
        try await env.transport("old").publish(record("old", epoch: 1), as: .progress)
        let phone = env.coordinator("phone")
        let epoch = try await phone.takeover(entryID: entry, revision: revisionA, positionSeconds: 42)
        XCTAssertEqual(epoch, 4)
        let records = try await env.transport("phone").fetchDeviceRecords()
        let both = [records.nowPlaying, records.progress].compactMap { $0.first { $0.record.deviceID == "phone" } }
        XCTAssertEqual(both.count, 2)
        for observed in both {
            XCTAssertEqual(observed.record.epoch, 4)
            XCTAssertEqual(observed.record.positionSeconds, 42)
            XCTAssertTrue(observed.record.isPlaying)
            XCTAssertEqual(observed.record.publishedAt, env.clock.now)
        }
        let firstEver = try await env.coordinator("fresh").takeover(entryID: entry, revision: revisionA, positionSeconds: 0)
        XCTAssertEqual(firstEver, 5)
    }

    func testSimultaneousTakeoverLeavesExactlyOneWinnerOnceBothObserve() async throws {
        let env = await makeEnv()
        let lag = LagSwitch()
        let mac = env.coordinator("mac", over: LaggingTransport(base: env.transport("mac"), lag: lag))
        let phone = env.coordinator("phone", over: LaggingTransport(base: env.transport("phone"), lag: lag))
        let macEpoch = try await mac.takeover(entryID: entry, revision: revisionA, positionSeconds: 10)
        await env.advance(to: 1_001)
        let phoneEpoch = try await phone.takeover(entryID: entry, revision: revisionA, positionSeconds: 12)
        XCTAssertEqual(macEpoch, phoneEpoch, "neither had observed the other")
        lag.catchUp()
        let macDecision = try await mac.observe()
        let phoneDecision = try await phone.observe()
        XCTAssertEqual(macDecision, .relinquish(to: "phone"))
        XCTAssertEqual(phoneDecision, .keepPlaying)
        let macRelinquished = await mac.hasRelinquished
        let phoneRelinquished = await phone.hasRelinquished
        XCTAssertTrue(macRelinquished)
        XCTAssertFalse(phoneRelinquished)
    }

    func testSameInstantTakeoverBreaksTieByDeviceID() async throws {
        let env = await makeEnv()
        let lag = LagSwitch()
        let mac = env.coordinator("mac", over: LaggingTransport(base: env.transport("mac"), lag: lag))
        let phone = env.coordinator("phone", over: LaggingTransport(base: env.transport("phone"), lag: lag))
        try await mac.takeover(entryID: entry, revision: revisionA, positionSeconds: 0)
        try await phone.takeover(entryID: entry, revision: revisionA, positionSeconds: 0)
        lag.catchUp()
        let macDecision = try await mac.observe()
        let phoneDecision = try await phone.observe()
        XCTAssertEqual([macDecision, phoneDecision], [.relinquish(to: "phone"), .keepPlaying])
    }

    func testLaterTakeoverRelinquishesEarlierDevice() async throws {
        let env = await makeEnv()
        let mac = env.coordinator("mac")
        try await mac.takeover(entryID: entry, revision: revisionA, positionSeconds: 10)
        let stillPlaying = try await mac.observe()
        XCTAssertEqual(stillPlaying, .keepPlaying)
        await env.advance(to: 1_003)
        let phoneEpoch = try await env.coordinator("phone").takeover(entryID: entry, revision: revisionA, positionSeconds: 12)
        XCTAssertEqual(phoneEpoch, 2)
        let macDecision = try await mac.observe()
        XCTAssertEqual(macDecision, .relinquish(to: "phone"))
    }

    func testStaleEpochRecordIsIgnored() async throws {
        let env = await makeEnv()
        let mac = env.coordinator("mac")
        try await env.transport("phone").publish(record("phone", epoch: 2), as: .nowPlaying)
        let epoch = try await mac.takeover(entryID: entry, revision: revisionA, positionSeconds: 5)
        XCTAssertEqual(epoch, 3)
        await env.advance(to: 1_002)
        try await env.transport("phone").publish(record("phone", epoch: 2, position: 900), as: .nowPlaying)
        let decision = try await mac.observe()
        XCTAssertEqual(decision, .keepPlaying)
    }

    func testDeadDeviceIsTreatedAsPausedAtItsRecordedPosition() async throws {
        let env = await makeEnv()
        let phone = env.coordinator("phone")
        try await phone.takeover(entryID: entry, revision: revisionA, positionSeconds: 100)
        let mac = env.coordinator("mac")

        await env.advance(to: 1_010)
        let live = try await mac.resumeTarget(localRevision: { [revisionA] _ in revisionA })
        guard case .resume(let alive) = live else { return XCTFail("expected resume, got \(live)") }
        XCTAssertEqual(alive.positionSeconds, 110, accuracy: 1e-9)
        XCTAssertTrue(alive.wasPlaying)

        await env.advance(to: 1_000 + SyncCadence.staleAfter + 5)
        let dead = try await mac.resumeTarget(localRevision: { [revisionA] _ in revisionA })
        guard case .resume(let stale) = dead else { return XCTFail("expected resume, got \(dead)") }
        XCTAssertEqual(stale.positionSeconds, 100, accuracy: 1e-9)
        XCTAssertFalse(stale.wasPlaying)
        XCTAssertEqual(stale.sourceDeviceID, "phone")
    }

    func testDeadDeviceWithHigherEpochDoesNotForceRelinquish() async throws {
        for (observeAt, expected) in [(1_010.0, HandoffDecision.relinquish(to: "phone")), (1_000 + SyncCadence.staleAfter + 10, .keepPlaying)] {
            let env = await makeEnv()
            let lag = LagSwitch()
            let mac = env.coordinator("mac", over: LaggingTransport(base: env.transport("mac"), lag: lag))
            try await mac.takeover(entryID: entry, revision: revisionA, positionSeconds: 0)
            try await env.transport("phone").publish(record("phone", epoch: 9), as: .nowPlaying)
            lag.catchUp()
            await env.advance(to: observeAt)
            let decision = try await mac.observe()
            XCTAssertEqual(decision, expected, "observed \(observeAt - 1_000) s after the phone's last record")
        }
    }

    func testPausedHigherEpochDeviceDoesNotForceRelinquish() async throws {
        let env = await makeEnv()
        let lag = LagSwitch()
        let mac = env.coordinator("mac", over: LaggingTransport(base: env.transport("mac"), lag: lag))
        try await mac.takeover(entryID: entry, revision: revisionA, positionSeconds: 0)
        await env.advance(to: 1_001)
        let phone = env.coordinator("phone", over: LaggingTransport(base: env.transport("phone"), lag: lag))
        try await phone.takeover(entryID: entry, revision: revisionA, positionSeconds: 0)
        try await phone.paused(at: 3)
        lag.catchUp()
        let decision = try await mac.observe()
        XCTAssertEqual(decision, .keepPlaying)
    }

    func testRevisionMismatchNeedsMedia() async throws {
        let env = await makeEnv()
        try await env.coordinator("phone").takeover(entryID: entry, revision: revisionB, positionSeconds: 30)
        let mac = env.coordinator("mac")
        let mismatch = try await mac.resumeTarget(localRevision: { [revisionA] _ in revisionA })
        XCTAssertEqual(mismatch, .needsMedia(entryID: entry, revision: revisionB))
        let missing = try await mac.resumeTarget(localRevision: { _ in nil })
        XCTAssertEqual(missing, .needsMedia(entryID: entry, revision: revisionB))
        let match = try await mac.resumeTarget(localRevision: { [revisionB] _ in revisionB })
        guard case .resume(let resume) = match else { return XCTFail("expected resume, got \(match)") }
        XCTAssertEqual(resume.revision, revisionB)
        let alone = try await env.coordinator("phone").resumeTarget(localRevision: { [revisionB] _ in revisionB })
        XCTAssertEqual(alone, .nothing, "a device never resumes from its own record")
    }

    func testResumeIsRateAwareAndClampedToDuration() async throws {
        let env = await makeEnv()
        let phone = env.coordinator("phone")
        try await phone.takeover(entryID: entry, revision: revisionA, positionSeconds: 100, rate: 1.5)
        await env.advance(to: 1_004)
        let mac = env.coordinator("mac")
        let target = try await mac.resumeTarget(localRevision: { [revisionA] _ in revisionA })
        guard case .resume(let resume) = target else { return XCTFail("expected resume, got \(target)") }
        XCTAssertEqual(resume.positionSeconds, 106, accuracy: 1e-9)
        XCTAssertEqual(resume.rate, 1.5)
        let clamped = try await mac.resumeTarget(localRevision: { [revisionA] _ in revisionA }, durationSeconds: { _ in 103 })
        guard case .resume(let short) = clamped else { return XCTFail("expected resume, got \(clamped)") }
        XCTAssertEqual(short.positionSeconds, 103, accuracy: 1e-9)
    }

    func testPublishesOnCadenceAndImmediatelyOnPauseSeekAndStop() async throws {
        let env = await makeEnv()
        let phone = env.coordinator("phone")
        try await phone.takeover(entryID: entry, revision: revisionA, positionSeconds: 0)

        await env.advance(to: 1_002)
        try await phone.positionUpdate(2)
        var published = try await nowPlaying(env, "phone")
        XCTAssertEqual(published?.record.positionSeconds, 0, "inside the 30 s cadence")

        await env.advance(to: 1_005)
        try await phone.positionUpdate(5)
        published = try await nowPlaying(env, "phone")
        XCTAssertEqual(published?.record.positionSeconds, 0, "still inside the cadence")

        await env.advance(to: 1_030)
        try await phone.positionUpdate(30)
        published = try await nowPlaying(env, "phone")
        XCTAssertEqual(published?.record.positionSeconds, 30)

        await env.advance(to: 1_031)
        try await phone.seeked(to: 300)
        published = try await nowPlaying(env, "phone")
        XCTAssertEqual(published?.record.positionSeconds, 300)
        XCTAssertEqual(published?.record.isPlaying, true)

        await env.advance(to: 1_032)
        try await phone.paused(at: 301)
        published = try await nowPlaying(env, "phone")
        XCTAssertEqual(published?.record.positionSeconds, 301)
        XCTAssertEqual(published?.record.isPlaying, false)

        await env.advance(to: 1_100)
        try await phone.positionUpdate(400)
        published = try await nowPlaying(env, "phone")
        XCTAssertEqual(published?.record.positionSeconds, 301, "paused sessions do not heartbeat")

        try await phone.takeover(entryID: entry, revision: revisionA, positionSeconds: 301)
        await env.advance(to: 1_101)
        try await phone.stopped(at: 350)
        published = try await nowPlaying(env, "phone")
        XCTAssertEqual(published?.record.positionSeconds, 350)
        XCTAssertEqual(published?.record.isPlaying, false)
        let epoch = await phone.epoch
        XCTAssertNil(epoch)
        let progress = try await env.transport("phone").fetchDeviceRecords().progress
        XCTAssertEqual(progress.first?.record.positionSeconds, 350)
    }

    func testRelinquishedCoordinatorStopsPublishingPlayingUpdates() async throws {
        let env = await makeEnv()
        let mac = env.coordinator("mac")
        try await mac.takeover(entryID: entry, revision: revisionA, positionSeconds: 10)
        await env.advance(to: 1_001)
        try await env.coordinator("phone").takeover(entryID: entry, revision: revisionA, positionSeconds: 12)
        let decision = try await mac.observe()
        XCTAssertEqual(decision, .relinquish(to: "phone"))
        let again = try await mac.observe()
        XCTAssertEqual(again, .relinquish(to: "phone"), "stays relinquished for later polls")
        await env.advance(to: 1_030)
        try await mac.positionUpdate(40)
        try await mac.seeked(to: 500)
        var published = try await nowPlaying(env, "mac")
        XCTAssertEqual(published?.record.positionSeconds, 10)
        try await mac.paused(at: 41)
        published = try await nowPlaying(env, "mac")
        XCTAssertEqual(published?.record.isPlaying, false)
        let phone = try await nowPlaying(env, "phone")
        XCTAssertEqual(phone?.record.isPlaying, true, "the winner is untouched")
    }

    func testSettleCheckWaitsThenObserves() async throws {
        let env = await makeEnv()
        let mac = env.coordinator("mac")
        try await mac.takeover(entryID: entry, revision: revisionA, positionSeconds: 0)
        await env.advance(to: 1_001)
        try await env.coordinator("phone").takeover(entryID: entry, revision: revisionA, positionSeconds: 0)
        let decision = try await mac.settleCheck()
        XCTAssertEqual(decision, .relinquish(to: "phone"))
        XCTAssertEqual(env.sleeps.all, [1])
    }

    func testStaleJudgementUsesTheClockOffsetLearnedFromOwnRecord() async throws {
        // The server clock runs an hour behind this device. Without the offset learned from
        // the device's own published record, a fresh remote record would look 1 h old.
        let env = await makeEnv()
        await env.server.setClock(env.clock.now.addingTimeInterval(-3_600))
        let mac = env.coordinator("mac")
        try await mac.takeover(entryID: entry, revision: revisionA, positionSeconds: 0)
        let alone = try await mac.observe()
        XCTAssertEqual(alone, .keepPlaying)
        env.clock.set(1_005)
        await env.server.setClock(env.clock.now.addingTimeInterval(-3_600))
        try await env.transport("phone").publish(record("phone", epoch: 5), as: .nowPlaying)
        let decision = try await mac.observe()
        XCTAssertEqual(decision, .relinquish(to: "phone"))
    }

    func testDecisionFromRecordsInHandNeedsNoFetch() async throws {
        let env = await makeEnv()
        let mac = env.coordinator("mac")
        try await mac.takeover(entryID: entry, revision: revisionA, positionSeconds: 10)
        let phone = env.coordinator("phone")
        try await phone.takeover(entryID: entry, revision: revisionA, positionSeconds: 50)
        let records = try await env.transport("mac").fetchDeviceRecords()
        let first = await mac.decision(from: records)
        XCTAssertEqual(first, .relinquish(to: "phone"))
        let second = await mac.decision(from: LibraryDeviceRecords())
        XCTAssertEqual(second, .relinquish(to: "phone"), "once relinquished it stays relinquished")
        let untouched = await phone.decision(from: records)
        XCTAssertEqual(untouched, .keepPlaying)
    }

    func testALiveDevicePublishingEveryThirtySecondsIsNeverPresumedDead() async throws {
        let env = await makeEnv()
        let phone = env.coordinator("phone")
        try await phone.takeover(entryID: entry, revision: revisionA, positionSeconds: 10)
        for tick in 1...4 {
            await env.advance(to: 1_000 + Double(tick) * SyncCadence.playingPublishInterval)
            try await phone.positionUpdate(10 + Double(tick) * 30)
            let records = try await env.transport("mac").fetchDeviceRecords()
            await env.advance(to: env.clock.now.timeIntervalSince1970 + SyncCadence.playingPublishInterval - 1)
            let live = HandoffResolver.livePlayers(records.nowPlaying, localDeviceID: "mac", now: env.clock.now)
            XCTAssertEqual(live.map(\.record.deviceID), ["phone"], "tick \(tick): 29 s after a publish it is still live")
        }
    }

    func testTheCadenceThrottlesPublishesToOnePerThirtySeconds() async throws {
        let env = await makeEnv()
        let phone = env.coordinator("phone")
        try await phone.takeover(entryID: entry, revision: revisionA, positionSeconds: 0)
        var publishedAt: [Date] = []
        for second in 1...95 {
            await env.advance(to: 1_000 + Double(second))
            try await phone.positionUpdate(Double(second))
            if let now = try await nowPlaying(env, "phone"), publishedAt.last != now.record.publishedAt {
                publishedAt.append(now.record.publishedAt ?? .distantPast)
            }
        }
        XCTAssertEqual(publishedAt.count, 4, "takeover at 0 s, then 30, 60 and 90 s")
    }
}
