import Foundation
import WiltedDomain
import WiltedLibrary
import XCTest
@testable import WiltediOS

private final class DecisionClock: @unchecked Sendable {
    private let lock = NSLock()
    private var time: TimeInterval = 1_700_000_000
    var now: Date { lock.withLock { Date(timeIntervalSince1970: time) } }
    func advance(_ seconds: TimeInterval) { lock.withLock { time += seconds } }
}

/// Drives the phone's decision actions against the in-memory transport, with a "mac" writer that
/// publishes state and answers intents. No CloudKit and no real waiting.
@MainActor
final class LibraryDecisionModelTests: XCTestCase {
    private let server = InMemoryLibraryServer(writerDeviceID: "mac")
    private lazy var mac = InMemoryLibraryTransport(deviceID: "mac", server: server)
    private let clock = DecisionClock()
    private var versions: [LibraryRecordKey: UInt64] = [:]
    private var localSeq: UInt64 = 0

    private func id(_ raw: String) -> ItemID { try! ItemID(rawValue: raw) }

    private func entry(_ raw: String, removal: LibraryRemoval = .none, kind: LibraryKind = .podcastEpisode) throws -> LibraryEntry {
        try LibraryEntry(
            id: id(raw), kind: kind, sourceID: id("show"), title: "Title \(raw)", summary: "",
            publishedAt: Date(timeIntervalSince1970: 1_600_000_000), durationSeconds: 600, removal: removal,
            removedAt: removal == .none ? nil : Date(timeIntervalSince1970: 1_650_000_000))
    }

    private func macPush(_ changes: [LibraryChange]) async throws {
        let pending = changes.map { change -> PendingLibraryChange in
            localSeq += 1
            return PendingLibraryChange(localSeq: localSeq, change: change, baseVersion: versions[change.key] ?? 0)
        }
        let result = try await mac.push(changes: pending)
        XCTAssertTrue(result.failures.isEmpty)
        for ack in result.acknowledged { versions[ack.key] = ack.version }
    }

    /// New: fresh. Larder: a, b, c in that order. Retired: old. Dismissed: gone.
    private func seed() async throws {
        try await macPush([
            .source(LibrarySource(id: id("show"), kind: .podcastFeed, title: "The Show")),
            .entry(try entry("fresh")), .entry(try entry("a")), .entry(try entry("b")), .entry(try entry("c")),
            .entry(try entry("old", removal: .retired)), .entry(try entry("gone", removal: .dismissed)),
            .entry(try entry("article", kind: "article")),
            .slot(try QueueSlot(entryID: id("a"), sortKey: 0)),
            .slot(try QueueSlot(entryID: id("b"), sortKey: 1)),
            .slot(try QueueSlot(entryID: id("c"), sortKey: 2)),
        ])
    }

    private func makeModel() -> LibraryAppModel {
        let clock = clock
        return LibraryAppModel(
            transport: InMemoryLibraryTransport(deviceID: "phone", server: server), deviceID: "phone",
            decisionTiming: LibraryDecisionTiming(confirmationTimeout: 60, pollInterval: .seconds(3_600), pendingPollInterval: .seconds(3_600)),
            now: { clock.now }, timeZone: TimeZone(identifier: "UTC")!)
    }

    private func startedOnMac(_ raw: String, position: Double = 30) async throws {
        let record = try DevicePlaybackPosition(
            deviceID: "mac", entryID: id(raw), revision: RevisionID(rawValue: "rev-1"), positionSeconds: position, isPlaying: false, epoch: 1)
        try await mac.publish(record, as: .progress)
    }

    private func intents() async throws -> [LibraryIntent] { try await mac.listIntents() }

    private func firstIntent() async throws -> LibraryIntent {
        let all = try await intents()
        return try XCTUnwrap(all.first)
    }

    private func macAnswers(_ intent: LibraryIntent, applied: Bool, reason: String = IntentOutcome.reasonNotApplicable) async throws {
        let outcome = applied
            ? try IntentOutcome.applied(for: intent, at: clock.now)
            : try IntentOutcome.rejected(for: intent, reason: reason, at: clock.now)
        try await mac.publishIntentOutcome(outcome)
    }

    private func ids(_ rows: [LibraryRow]) -> [String] { rows.map(\.id.rawValue) }

    // MARK: sections and eligibility

    func testNewSectionHoldsLiveUnqueuedPodcastEpisodesOnly() async throws {
        try await seed()
        let model = makeModel()
        await model.refresh()
        XCTAssertEqual(ids(model.new), ["fresh"])
        XCTAssertEqual(ids(model.queued), ["a", "b", "c"])
        XCTAssertEqual(Set(ids(model.removed)), ["old", "gone"])
    }

    func testKeepAndSkipAreOfferedOnlyInNewAndNeverOnLarderRows() async throws {
        try await seed()
        try await startedOnMac("a")
        let model = makeModel()
        await model.refresh()
        let fresh = try XCTUnwrap(model.new.first)
        XCTAssertEqual(model.decisionActions(for: fresh, in: .new), [.keep, .skip])
        for row in model.queued {
            let actions = model.decisionActions(for: row, in: .larder)
            XCTAssertFalse(actions.contains(.keep) || actions.contains(.skip), "\(row.id) offers a feed decision")
        }
        // Mark done only for the started row; Restore only for the retired one.
        XCTAssertEqual(model.decisionActions(for: model.queued[0], in: .larder), [.markDone])
        XCTAssertEqual(model.decisionActions(for: model.queued[1], in: .larder), [])
        XCTAssertEqual(model.decisionActions(for: try XCTUnwrap(model.removed.first { $0.id.rawValue == "old" }), in: .removed), [.restore])
        XCTAssertEqual(model.decisionActions(for: try XCTUnwrap(model.removed.first { $0.id.rawValue == "gone" }), in: .removed), [])
    }

    func testAnIneligibleDecisionSendsNothing() async throws {
        try await seed()
        let model = makeModel()
        await model.refresh()
        await model.decide(.keep, entryID: id("a"))      // already queued
        await model.decide(.markDone, entryID: id("b"))  // not started
        await model.decide(.restore, entryID: id("gone")) // dismissed, not retired
        let sent = try await intents()
        XCTAssertTrue(sent.isEmpty)
        XCTAssertTrue(model.decisions.isEmpty)
    }

    // MARK: optimistic apply

    func testKeepMovesTheEpisodeToTheEndOfTheLarderAtOnceAndSendsAnIntent() async throws {
        try await seed()
        let model = makeModel()
        await model.refresh()
        await model.decide(.keep, entryID: id("fresh"))
        XCTAssertEqual(ids(model.queued), ["a", "b", "c", "fresh"])
        XCTAssertTrue(model.new.isEmpty)
        XCTAssertEqual(model.decisionStatus(for: id("fresh")), .waiting)
        let sent = try await intents()
        XCTAssertEqual(sent.map(\.action), [.keep(entryID: id("fresh"))])
        XCTAssertEqual(sent.first?.deviceID, "phone")
        XCTAssertTrue(model.decisions.first?.isSent == true)
    }

    func testSkipMarkDoneAndRestoreMoveRowsBetweenSections() async throws {
        try await seed()
        try await startedOnMac("b")
        let model = makeModel()
        await model.refresh()
        await model.decide(.skip, entryID: id("fresh"))
        await model.decide(.markDone, entryID: id("b"))
        await model.decide(.restore, entryID: id("old"))
        XCTAssertEqual(ids(model.queued), ["a", "c"])
        XCTAssertEqual(Set(ids(model.removed)), ["fresh", "b", "gone"])
        XCTAssertEqual(ids(model.new), ["old"])
        // A second decision for an entry with one in flight is ignored.
        await model.decide(.keep, entryID: id("old"))
        let count = try await intents().count
        XCTAssertEqual(count, 3)
    }

    func testReorderIsOptimisticEntryRelativeAndFollowsTheMovedList() async throws {
        try await seed()
        let model = makeModel()
        await model.refresh()
        await model.reorderQueued(fromOffsets: IndexSet(integer: 2), toOffset: 0) // c to the front
        XCTAssertEqual(ids(model.queued), ["c", "a", "b"])
        await model.reorderQueued(fromOffsets: IndexSet(integer: 1), toOffset: 3) // a to after b
        XCTAssertEqual(ids(model.queued), ["c", "b", "a"])
        let sent = try await intents().map(\.action)
        XCTAssertEqual(sent, [.reorder(entryID: id("c"), afterEntryID: nil), .reorder(entryID: id("a"), afterEntryID: id("b"))])
    }

    func testReorderRequestConversion() {
        let q = ["a", "b", "c", "d"].map(id)
        XCTAssertTrue(LibraryReorder.requests(queue: q, from: IndexSet(integer: 1), to: 1).isEmpty)
        XCTAssertTrue(LibraryReorder.requests(queue: q, from: IndexSet(integer: 1), to: 2).isEmpty)
        let down = LibraryReorder.requests(queue: q, from: IndexSet(integer: 0), to: 3)
        XCTAssertEqual(down.map(\.entryID), [id("a")])
        XCTAssertEqual(down.map(\.afterEntryID), [id("c")])
        let front = LibraryReorder.requests(queue: q, from: IndexSet(integer: 3), to: 0)
        XCTAssertEqual(front.map(\.afterEntryID), [nil])
        let pair = LibraryReorder.requests(queue: q, from: IndexSet([0, 1]), to: 4)
        XCTAssertEqual(pair.map(\.entryID), [id("a"), id("b")])
        XCTAssertEqual(pair.map(\.afterEntryID), [id("d"), id("a")])
    }

    // MARK: confirmation, rejection, contradiction, timeout

    func testAppliedOutcomeHoldsTheDisplayUntilThePublishCatchesUp() async throws {
        try await seed()
        let model = makeModel()
        await model.refresh()
        await model.decide(.keep, entryID: id("fresh"))
        let intent = try await firstIntent()
        try await macAnswers(intent, applied: true)
        await model.refresh() // outcome seen, publish not yet
        XCTAssertEqual(model.decisionStatus(for: id("fresh")), .confirming)
        XCTAssertEqual(ids(model.queued), ["a", "b", "c", "fresh"])
        try await macPush([.slot(try QueueSlot(entryID: id("fresh"), sortKey: 3))])
        await model.refresh() // publish confirms
        XCTAssertNil(model.decisionStatus(for: id("fresh")))
        XCTAssertTrue(model.decisions.isEmpty)
        XCTAssertEqual(ids(model.queued), ["a", "b", "c", "fresh"])
    }

    func testPublishThatMatchesConfirmsBeforeAnyOutcome() async throws {
        try await seed()
        let model = makeModel()
        await model.refresh()
        await model.decide(.skip, entryID: id("fresh"))
        try await macPush([.removal(entryID: id("fresh"), state: .retired)])
        await model.refresh()
        XCTAssertTrue(model.decisions.isEmpty)
        XCTAssertTrue(ids(model.removed).contains("fresh"))
    }

    func testRejectionRollsBackAndSaysWhy() async throws {
        try await seed()
        let model = makeModel()
        await model.refresh()
        await model.decide(.keep, entryID: id("fresh"))
        try await macAnswers(try await firstIntent(), applied: false, reason: IntentOutcome.reasonUnknownEntry)
        await model.refresh()
        XCTAssertEqual(ids(model.new), ["fresh"])
        XCTAssertEqual(ids(model.queued), ["a", "b", "c"])
        XCTAssertTrue(model.decisions.isEmpty)
        XCTAssertEqual(model.decisionStatus(for: id("fresh")), .failed(LibraryAppModel.rejectionText(IntentOutcome.reasonUnknownEntry)))
        // The next decision clears the notice.
        await model.decide(.skip, entryID: id("fresh"))
        XCTAssertEqual(model.decisionStatus(for: id("fresh")), .waiting)
    }

    func testAContradictingPublishDropsTheOptimisticState() async throws {
        try await seed()
        let model = makeModel()
        await model.refresh()
        await model.decide(.keep, entryID: id("fresh"))
        try await macPush([.removal(entryID: id("fresh"), state: .dismissed)]) // the Mac did something else
        await model.refresh()
        XCTAssertTrue(model.decisions.isEmpty)
        XCTAssertNil(model.decisionStatus(for: id("fresh")))
        XCTAssertEqual(ids(model.queued), ["a", "b", "c"])
        XCTAssertTrue(ids(model.removed).contains("fresh"))
    }

    func testUnansweredDecisionRevertsAfterSixtySecondsStaysQueuedAndCanBeCancelled() async throws {
        try await seed()
        let model = makeModel()
        await model.refresh()
        await model.decide(.keep, entryID: id("fresh"))
        clock.advance(59)
        await model.refresh()
        XCTAssertEqual(model.decisionStatus(for: id("fresh")), .waiting)
        XCTAssertEqual(ids(model.queued), ["a", "b", "c", "fresh"])

        clock.advance(2)
        await model.refresh()
        XCTAssertEqual(model.decisionStatus(for: id("fresh")), .pendingOnMac)
        XCTAssertTrue(LibraryDecisionStatus.pendingOnMac.text.hasPrefix("Pending on Mac"))
        XCTAssertEqual(ids(model.new), ["fresh"], "the display reverts")
        XCTAssertEqual(ids(model.queued), ["a", "b", "c"])
        XCTAssertEqual(model.decisionActions(for: try XCTUnwrap(model.new.first), in: .new), [], "no second decision on top of a pending one")
        let stillQueued = try await intents().count
        XCTAssertEqual(stillQueued, 1)

        // A late answer resumes the confirmed display.
        try await macAnswers(try await firstIntent(), applied: true)
        await model.refresh()
        XCTAssertEqual(model.decisionStatus(for: id("fresh")), .confirming)
        XCTAssertEqual(ids(model.queued), ["a", "b", "c", "fresh"])

        // Cancelling only drops local tracking.
        model.cancelDecision(entryID: id("fresh"))
        XCTAssertNil(model.decisionStatus(for: id("fresh")))
        XCTAssertEqual(ids(model.new), ["fresh"])
    }

    func testCancelFromPendingOnMacDropsTracking() async throws {
        try await seed()
        let model = makeModel()
        await model.refresh()
        await model.decide(.skip, entryID: id("fresh"))
        clock.advance(61)
        await model.refresh()
        XCTAssertEqual(model.decisionStatus(for: id("fresh")), .pendingOnMac)
        model.cancelDecision(entryID: id("fresh"))
        XCTAssertTrue(model.decisions.isEmpty)
        XCTAssertEqual(ids(model.new), ["fresh"])
    }

    func testOutcomesForOtherDevicesAreIgnored() async throws {
        try await seed()
        let model = makeModel()
        await model.refresh()
        await model.decide(.keep, entryID: id("fresh"))
        let mine = try await firstIntent()
        let foreign = try LibraryIntent(id: mine.id, deviceID: "tablet", createdAt: clock.now, action: mine.action)
        try await macAnswers(foreign, applied: false)
        await model.refresh()
        XCTAssertEqual(model.decisionStatus(for: id("fresh")), .waiting)
    }

    func testAccountRecoveryClearsDecisions() async throws {
        try await seed()
        let model = makeModel()
        await model.refresh()
        await model.decide(.keep, entryID: id("fresh"))
        model.discardDecisionsAfterAccountChange()
        XCTAssertTrue(model.decisions.isEmpty)
        XCTAssertTrue(model.decisionNotices.isEmpty)
    }
}
