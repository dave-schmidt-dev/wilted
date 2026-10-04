import Foundation
import WiltedDomain
import WiltedLibrary
import WiltedProducer
import XCTest
@testable import WiltedMac

/// Holds the publisher's baseline read, mid-pass, until the test releases it.
private actor PublisherPassGate {
    private var held = false
    private var released = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    var isHeld: Bool { held }

    func hold() async {
        held = true
        if !released { await withCheckedContinuation { waiters.append($0) } }
    }

    func release() {
        released = true
        let waiting = waiters
        waiters.removeAll()
        waiting.forEach { $0.resume() }
    }
}

/// Counts the server calls only a publisher pass makes.
private final class PublisherPassCalls: @unchecked Sendable {
    private let lock = NSLock()
    private var counts: [String: Int] = [:]

    func bump(_ name: String) { lock.withLock { counts[name, default: 0] += 1 } }
    func count(_ name: String) -> Int { lock.withLock { counts[name] ?? 0 } }
    /// The baseline read, the push and the statistics write.
    var total: Int { lock.withLock { counts.values.reduce(0, +) } }
}

/// The in-memory reference transport, with the publisher's first server read held on a gate.
private struct HeldPublisherTransport: LibraryTransport {
    let inner: InMemoryLibraryTransport
    let gate: PublisherPassGate
    let calls: PublisherPassCalls

    func fetchChanges(since token: LibraryChangeToken?) async throws -> LibraryChangeBatch {
        calls.bump("fetchChanges")
        await gate.hold()
        return try await inner.fetchChanges(since: token)
    }
    func push(changes: [PendingLibraryChange]) async throws -> LibraryPushResult {
        calls.bump("push")
        return try await inner.push(changes: changes)
    }
    func publishStats(_ stats: LibraryStats) async throws {
        calls.bump("publishStats")
        try await inner.publishStats(stats)
    }
    func readStats() async throws -> LibraryStats? { try await inner.readStats() }
    func send(intent: LibraryIntent) async throws { try await inner.send(intent: intent) }
    func listIntents() async throws -> [LibraryIntent] { try await inner.listIntents() }
    func publish(_ record: DevicePlaybackPosition, as channel: PlaybackChannel) async throws {
        try await inner.publish(record, as: channel)
    }
    func fetchDeviceRecords() async throws -> LibraryDeviceRecords { try await inner.fetchDeviceRecords() }
    func poll(_ options: LibraryPollOptions) async throws -> LibraryPollResult { try await inner.poll(options) }
    func commitFetchedState(_ token: LibraryChangeToken?) async throws { try await inner.commitFetchedState(token) }
    func commitSentState(_ token: LibraryChangeToken?) async throws { try await inner.commitSentState(token) }
}

/// What the quit path looked like at the moments the assertions care about.
@MainActor
private final class LibraryJoinProbe {
    var closeBegan = false
    var callsAtClose: Int?
    var passCountAtReply: Int?
    var callsAtReply: Int?
    var repliedAt: ContinuousClock.Instant?
    var shutdownJoined = false
}

/// A normal quit that lands while the library publisher is mid-pass joins that pass inside the
/// 10 s termination budget and starts no pass afterwards; a pass that never finishes still lets
/// the quit proceed, because the coordinator bounds the network join (Task 5.0, Task 3.3).
@MainActor
final class WiltedMacTerminationLibraryJoinTests: XCTestCase {
    private struct Rig {
        let model: WiltedMacModel
        let controller: WiltedMacLibrarySyncController
        let gate: PublisherPassGate
        let calls: PublisherPassCalls
        let probe: LibraryJoinProbe
        let journal: WiltedMacTerminationJournal
        let replies: TerminationReplies
    }

    func testQuitDuringPublisherPassJoinsItWithinBudgetAndStartsNoNewPass() async throws {
        let rig = try await makeRig("termination-library-join")
        let budget = WiltedMacTerminationCoordinator.localBudget
        let coordinator = makeCoordinator(rig, budget: budget)

        let started = ContinuousClock.now
        XCTAssertEqual(coordinator.shouldTerminate(), .terminateLater)
        try await waitFor("the network step began closing the controller") { rig.probe.closeBegan }
        // While the pass is held, more triggers arrive; none may start a pass after close began.
        rig.controller.requestPublish()
        let heldRound = Task { await rig.controller.tickRound() }
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertTrue(rig.replies.values.isEmpty, "the quit must not reply while the in-flight pass is held")
        XCTAssertEqual(coordinator.state, .draining)
        XCTAssertEqual(rig.controller.passCount, 0, "the in-flight pass is still held")
        XCTAssertEqual(rig.calls.total, rig.probe.callsAtClose, "no publish starts while close is joining")

        let released = ContinuousClock.now
        await rig.gate.release()
        try await waitFor("the quit replied") { !rig.replies.values.isEmpty }

        XCTAssertEqual(rig.replies.values, [true], "a joined network step approves the quit, once")
        XCTAssertEqual(coordinator.state, .approved)
        XCTAssertNil(rig.controller.lastFailure, "the held pass itself succeeded")
        XCTAssertEqual(rig.probe.passCountAtReply, 1, "the reply waited for the in-flight pass to finish")
        let repliedAt = try XCTUnwrap(rig.probe.repliedAt)
        XCTAssertLessThan(repliedAt - released, .seconds(2), "the join completes promptly once the pass ends")
        XCTAssertLessThan(repliedAt - started, budget / 2, "the whole quit stays well inside the budget")
        XCTAssertFalse(journalEvents(rig).contains("network-join-abandoned"), "the join finished; nothing was abandoned")

        // After the join, further triggers still start nothing.
        rig.controller.requestPublish()
        await rig.controller.tickRound()
        _ = await heldRound.value
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(rig.controller.passCount, 1, "no pass runs after the joined one")
        XCTAssertEqual(rig.calls.count("fetchChanges"), 1, "only the in-flight pass read the server")
        XCTAssertEqual(rig.calls.total, rig.probe.callsAtReply, "no publish starts after the join")
        XCTAssertNil(rig.model.librarySyncController)
    }

    func testQuitProceedsWhenPublisherPassNeverFinishesBecauseTheJoinIsBounded() async throws {
        let rig = try await makeRig("termination-library-abandon")
        // Long enough for the local drain to leave time for the network step, short enough to stay fast.
        let budget: Duration = .milliseconds(900)
        let coordinator = makeCoordinator(rig, budget: budget)

        let started = ContinuousClock.now
        XCTAssertEqual(coordinator.shouldTerminate(), .terminateLater)
        try await waitFor("the quit replied without the pass finishing") { !rig.replies.values.isEmpty }

        XCTAssertEqual(rig.replies.values, [true], "an unfinished network join does not cancel the quit")
        XCTAssertEqual(coordinator.state, .approved)
        XCTAssertTrue(rig.probe.closeBegan, "the network step did start closing the controller")
        XCTAssertEqual(rig.probe.passCountAtReply, 0, "the quit proceeded while the pass was still held")
        let held = await rig.gate.isHeld
        XCTAssertTrue(held)
        let repliedAt = try XCTUnwrap(rig.probe.repliedAt)
        XCTAssertLessThan(repliedAt - started, budget + .seconds(1), "the bounded join gives up at the budget")
        XCTAssertTrue(journalEvents(rig).contains("network-join-abandoned"), "the timeout is the network join's")

        // The abandoned pass finishes late; the stopped controller still starts nothing new.
        await rig.gate.release()
        let probe = rig.probe
        let model = rig.model
        Task { @MainActor in
            await model.waitForLibrarySyncShutdown()
            probe.shutdownJoined = true
        }
        try await waitFor("the late pass and the controller shutdown finished") { probe.shutdownJoined }
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(rig.controller.passCount, 1, "no pass runs after the abandoned one")
        XCTAssertEqual(rig.calls.count("fetchChanges"), 1, "only the in-flight pass read the server")
    }

    // MARK: - Fixture

    private func makeRig(_ suffix: String) async throws -> Rig {
        let directory = wiltedTemporaryDirectory(suffix)
        let gate = PublisherPassGate()
        // Teardown blocks run last-in, first-out: release before the temporary state closes the model.
        addTeardownBlock { await gate.release() }
        let calls = PublisherPassCalls()
        let model = WiltedMacModel(
            arguments: [], stateDirectoryOverride: directory,
            storeBootstrap: { try LocalLibraryStore(url: $0) },
            preferences: WiltedMacTestPreferences.ephemeral()
        )
        model.startStoreBootstrap()
        await model.waitForStoreBootstrap()
        let transport = HeldPublisherTransport(
            inner: InMemoryLibraryTransport(deviceID: "mac-test", server: InMemoryLibraryServer(writerDeviceID: "mac-test")),
            gate: gate, calls: calls
        )
        XCTAssertTrue(model.startLibrarySyncIfEnabled(
            environment: ["WILTED_LIBRARY_SYNC": "1"], transport: transport, debounce: .milliseconds(10)
        ))
        // Kept strongly: stopping clears the model's association.
        let controller = try XCTUnwrap(model.librarySyncController)
        let probe = LibraryJoinProbe()
        controller.onShutdownDrain = { [probe, calls] in
            probe.closeBegan = true
            probe.callsAtClose = calls.total
        }
        try await waitFor("the first publisher pass is held mid-pass") { await gate.isHeld }
        XCTAssertEqual(controller.passCount, 0)
        let journal = WiltedMacTerminationJournal(url: directory.appendingPathComponent("termination-journal.jsonl"))
        return Rig(
            model: model, controller: controller, gate: gate, calls: calls,
            probe: probe, journal: journal, replies: TerminationReplies()
        )
    }

    /// The real model is the owner, so the quit runs the production local drain and network step.
    private func makeCoordinator(_ rig: Rig, budget: Duration) -> WiltedMacTerminationCoordinator {
        WiltedMacTerminationCoordinator(
            owner: rig.model, budget: budget, journal: rig.journal,
            reply: { [replies = rig.replies, probe = rig.probe, controller = rig.controller, calls = rig.calls] answer in
                replies.values.append(answer)
                probe.passCountAtReply = controller.passCount
                probe.callsAtReply = calls.total
                probe.repliedAt = .now
            },
            presentFailure: { failure in XCTFail("the quit was cancelled: \(failure.message)") }
        )
    }

    private func journalEvents(_ rig: Rig) -> [String] {
        guard let text = try? String(contentsOf: rig.journal.url, encoding: .utf8) else { return [] }
        return text.split(separator: "\n").compactMap { line in
            let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: String]
            return object?["event"]
        }
    }

    /// Polls with a deadline, so a regression fails the test instead of hanging the gate.
    private func waitFor(
        _ description: String, timeout: Duration = .seconds(5), _ condition: @MainActor () async -> Bool
    ) async throws {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        let met = await condition()
        XCTAssertTrue(met, "timed out waiting: \(description)")
    }
}
