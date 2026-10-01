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

    /// Larder: a, b, c in that order. Not queued, so not on the phone: fresh (New), old (retired), gone (dismissed).
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

    /// The Mac offering ready audio for `raw`, which is what puts a queued row on the phone.
    private func offerAudio(_ raw: String) async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("decision-audio-\(UUID().uuidString)")
        try Data([1, 2, 3]).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let offer = try LibraryMediaOffer(
            entryID: id(raw), revisionID: RevisionID(rawValue: "rev-1"),
            contentHash: MediaHash.prefix + String(repeating: "0", count: 64), byteCount: 3, mediaType: "audio/mp4")
        try await mac.publishMedia(offer: offer, fileURL: file)
    }

    private func makeModel() -> LibraryAppModel {
        let clock = clock
        UserDefaults(suiteName: "library-decision-tests")!.removePersistentDomain(forName: "library-decision-tests")
        return LibraryAppModel(
            transport: InMemoryLibraryTransport(deviceID: "phone", server: server), deviceID: "phone",
            decisionTiming: LibraryDecisionTiming(confirmationTimeout: 60, pollInterval: .seconds(3_600), pendingPollInterval: .seconds(3_600)),
            preferences: UserDefaults(suiteName: "library-decision-tests")!,
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

    // MARK: eligibility

    func testOnlyQueuedRowsExistAndNewOrRemovedEntriesNeverAppear() async throws {
        try await seed()
        let model = makeModel()
        await model.refresh()
        XCTAssertEqual(ids(model.queued), ["a", "b", "c"])
    }

    func testRemoveFromLarderIsOfferedOnEveryRowAndMarkDoneOnlyOnAStartedOne() async throws {
        try await seed()
        try await startedOnMac("a")
        let model = makeModel()
        await model.refresh()
        XCTAssertEqual(model.decisionActions(for: model.queued[0]), [.removeFromLarder, .markDone])
        XCTAssertEqual(model.decisionActions(for: model.queued[1]), [.removeFromLarder])
    }

    func testAnIneligibleDecisionSendsNothing() async throws {
        try await seed()
        let model = makeModel()
        await model.refresh()
        await model.decide(.markDone, entryID: id("b"))  // not started
        await model.decide(.removeFromLarder, entryID: id("fresh"))  // not on the phone's list
        await model.decide(.removeFromLarder, entryID: id("gone"))   // dismissed on the Mac
        let sent = try await intents()
        XCTAssertTrue(sent.isEmpty)
        XCTAssertTrue(model.decisions.isEmpty)
    }

    // MARK: optimistic apply

    func testRemoveFromLarderRemovesTheRowAtOnceAndSendsAnIntent() async throws {
        try await seed()
        let model = makeModel()
        await model.refresh()
        await model.decide(.removeFromLarder, entryID: id("b"))
        XCTAssertEqual(ids(model.queued), ["a", "c"])
        XCTAssertEqual(model.decisionStatus(for: id("b")), .waiting)
        let sent = try await intents()
        XCTAssertEqual(sent.map(\.action), [.removeFromLarder(entryID: id("b"))])
        XCTAssertEqual(sent.first?.deviceID, "phone")
        XCTAssertTrue(model.decisions.first?.isSent == true)
    }

    func testRemoveFromLarderAndMarkDoneRemoveRowsAndASecondDecisionIsIgnored() async throws {
        try await seed()
        try await startedOnMac("b")
        let model = makeModel()
        await model.refresh()
        await model.decide(.removeFromLarder, entryID: id("a"))
        await model.decide(.markDone, entryID: id("b"))
        XCTAssertEqual(ids(model.queued), ["c"])
        // A second decision for an entry with one in flight is ignored.
        await model.decide(.removeFromLarder, entryID: id("a"))
        let count = try await intents().count
        XCTAssertEqual(count, 2)
    }

    func testEpisodesStartedOnTheMacListFirst() async throws {
        try await seed()
        for raw in ["a", "b", "c"] { try await offerAudio(raw) }
        try await startedOnMac("c")
        let model = makeModel()
        await model.refresh()
        XCTAssertEqual(ids(model.visibleRows), ["c", "a", "b"], "a position synced from the Mac pins the episode first")
    }

    func testACompletedEpisodeIsNeverPinnedAndTheNewestPlayLeads() async throws {
        try await seed()
        for raw in ["a", "b", "c"] { try await offerAudio(raw) }
        try await startedOnMac("a", position: 20)
        try await startedOnMac("b", position: 40)
        try await macPush([.listening(ListeningRecord(
            itemID: id("a"), completedAt: Date(timeIntervalSince1970: 1_700_000_000), updatedAt: Date(timeIntervalSince1970: 1_700_000_000),
            deviceID: "mac"))])
        let model = makeModel()
        await model.refresh()
        XCTAssertEqual(Set(model.progress.keys), [id("b")], "a completed episode does not count as in progress")
        XCTAssertEqual(ids(model.visibleRows), ["b", "c", "a"], "in progress first, completed last")
    }

    func testSiriListsAndShowsPutInProgressFirstToo() async throws {
        try await seed()
        for raw in ["a", "b", "c"] { try await offerAudio(raw) }
        try await startedOnMac("b")
        let model = makeModel()
        await model.refresh()
        for raw in ["a", "b", "c"] { model.media[id(raw)] = .onPhone }
        let snapshot = await LibraryVoiceTarget(model: model, player: LibraryPlayer.live()).voiceSnapshot()
        XCTAssertEqual(snapshot.downloaded.map(\.id.rawValue), ["b", "a", "c"])
        XCTAssertEqual(VoiceCommandPlanner.plan(.playNext(show: nil), snapshot: snapshot).action, .play(id("b")))
    }

    func testAppliedOutcomeHoldsTheDisplayUntilThePublishCatchesUp() async throws {
        try await seed()
        let model = makeModel()
        await model.refresh()
        await model.decide(.removeFromLarder, entryID: id("b"))
        let intent = try await firstIntent()
        try await macAnswers(intent, applied: true)
        await model.refresh() // outcome seen, publish not yet
        XCTAssertEqual(model.decisionStatus(for: id("b")), .confirming)
        XCTAssertEqual(ids(model.queued), ["a", "c"])
        try await macPush([.slotRemoved(entryID: id("b"))])
        await model.refresh() // publish confirms
        XCTAssertNil(model.decisionStatus(for: id("b")))
        XCTAssertTrue(model.decisions.isEmpty)
        XCTAssertEqual(ids(model.queued), ["a", "c"])
    }

    func testPublishThatMatchesConfirmsBeforeAnyOutcome() async throws {
        try await seed()
        let model = makeModel()
        await model.refresh()
        await model.decide(.removeFromLarder, entryID: id("b"))
        try await macPush([.slotRemoved(entryID: id("b"))])
        await model.refresh()
        XCTAssertTrue(model.decisions.isEmpty)
        XCTAssertEqual(ids(model.queued), ["a", "c"])
    }

    func testRejectionRollsBackAndSaysWhy() async throws {
        try await seed()
        let model = makeModel()
        await model.refresh()
        await model.decide(.removeFromLarder, entryID: id("b"))
        try await macAnswers(try await firstIntent(), applied: false, reason: IntentOutcome.reasonNotApplicable)
        await model.refresh()
        XCTAssertEqual(ids(model.queued), ["a", "b", "c"])
        XCTAssertTrue(model.decisions.isEmpty)
        XCTAssertEqual(model.decisionStatus(for: id("b")), .failed(LibraryAppModel.rejectionText(IntentOutcome.reasonNotApplicable)))
        // The next decision clears the notice.
        await model.decide(.removeFromLarder, entryID: id("b"))
        XCTAssertEqual(model.decisionStatus(for: id("b")), .waiting)
    }

    func testAContradictingPublishDropsTheOptimisticState() async throws {
        try await seed()
        let model = makeModel()
        await model.refresh()
        await model.decide(.removeFromLarder, entryID: id("b"))
        try await macPush([.slot(try QueueSlot(entryID: id("b"), sortKey: 9))]) // the Mac did something else
        await model.refresh()
        XCTAssertTrue(model.decisions.isEmpty)
        XCTAssertNil(model.decisionStatus(for: id("b")))
        XCTAssertEqual(ids(model.queued), ["a", "c", "b"])
    }

    func testUnansweredDecisionRevertsAfterSixtySecondsStaysQueuedAndCanBeCancelled() async throws {
        try await seed()
        let model = makeModel()
        await model.refresh()
        await model.decide(.removeFromLarder, entryID: id("b"))
        clock.advance(59)
        await model.refresh()
        XCTAssertEqual(model.decisionStatus(for: id("b")), .waiting)
        XCTAssertEqual(ids(model.queued), ["a", "c"])

        clock.advance(2)
        await model.refresh()
        XCTAssertEqual(model.decisionStatus(for: id("b")), .pendingOnMac)
        XCTAssertTrue(LibraryDecisionStatus.pendingOnMac.text.hasPrefix("Pending on Mac"))
        XCTAssertEqual(ids(model.queued), ["a", "b", "c"], "the display reverts")
        XCTAssertEqual(model.decisionActions(for: try XCTUnwrap(model.queued.first { $0.id == id("b") })), [], "no second decision on top of a pending one")
        let stillQueued = try await intents().count
        XCTAssertEqual(stillQueued, 1)

        // A late answer resumes the confirmed display.
        try await macAnswers(try await firstIntent(), applied: true)
        await model.refresh()
        XCTAssertEqual(model.decisionStatus(for: id("b")), .confirming)
        XCTAssertEqual(ids(model.queued), ["a", "c"])

        // Cancelling only drops local tracking.
        model.cancelDecision(entryID: id("b"))
        XCTAssertNil(model.decisionStatus(for: id("b")))
        XCTAssertEqual(ids(model.queued), ["a", "b", "c"])
    }

    func testCancelFromPendingOnMacDropsTracking() async throws {
        try await seed()
        let model = makeModel()
        await model.refresh()
        await model.decide(.removeFromLarder, entryID: id("b"))
        clock.advance(61)
        await model.refresh()
        XCTAssertEqual(model.decisionStatus(for: id("b")), .pendingOnMac)
        model.cancelDecision(entryID: id("b"))
        XCTAssertTrue(model.decisions.isEmpty)
        XCTAssertEqual(ids(model.queued), ["a", "b", "c"])
    }

    func testOutcomesForOtherDevicesAreIgnored() async throws {
        try await seed()
        let model = makeModel()
        await model.refresh()
        await model.decide(.removeFromLarder, entryID: id("b"))
        let mine = try await firstIntent()
        let foreign = try LibraryIntent(id: mine.id, deviceID: "tablet", createdAt: clock.now, action: mine.action)
        try await macAnswers(foreign, applied: false)
        await model.refresh()
        XCTAssertEqual(model.decisionStatus(for: id("b")), .waiting)
    }

    func testAccountRecoveryClearsDecisions() async throws {
        try await seed()
        let model = makeModel()
        await model.refresh()
        await model.decide(.removeFromLarder, entryID: id("b"))
        model.discardDecisionsAfterAccountChange()
        XCTAssertTrue(model.decisions.isEmpty)
        XCTAssertTrue(model.decisionNotices.isEmpty)
    }
}
