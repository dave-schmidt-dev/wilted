import Foundation
import SwiftData
import XCTest
import WiltedDomain
import WiltedLibrary
@testable import WiltedProducer
@testable import WiltedMac

/// Explicit owner decisions leave manual provenance that automation respects.
/// Receipt Undo restores the exact prior provenance instead of making a new choice.
///
/// Episode titles are chosen so the feed's rules contradict the owner: a
/// "Bonus" episode matches a Keep rule and is the one the owner skips, a
/// "Sponsored" episode matches a Skip rule and is the one the owner keeps or
/// restores. Without a manual record the automatic paths would reverse the
/// owner. Nothing here reads a real library.
///
/// Task 4.2's Apply to existing does not exist yet. Two paths stand in for it:
/// a real automatic refresh through the admission service, and the service's
/// re-evaluation of the feed's undecided episodes (`releaseWaitingEpisodes`,
/// plus the pure planner fed the stored decisions and the feed's rules).
@MainActor
final class ManualDecisionProvenanceTests: XCTestCase {
    // MARK: Mac entry points

    func testKeepEpisodeWritesManualKeep() async throws {
        let rig = try await makeRig(.live, title: Self.sponsored)
        rig.model.keepEpisode(try rig.episode())
        await rig.drain()
        try await assertManual(.keep, rig)
        try await assertAutomationLeavesUnchanged(rig)
    }

    func testSkipFeedEpisodeWritesManualSkip() async throws {
        let rig = try await makeRig(.live, title: Self.bonus)
        rig.model.skipFeedEpisode(try rig.episode())
        await rig.drain()
        try await assertManual(.skip, rig)
        try await assertAutomationLeavesUnchanged(rig)
    }

    func testRestoreSkippedFeedEpisodeWritesManualKeep() async throws {
        let rig = try await makeRig(.retired, title: Self.sponsored)
        try await assertNoRecord(rig)
        rig.model.restoreSkippedFeedEpisode(try rig.episode())
        await rig.drain()
        try await assertManual(.keep, rig)
        try await assertAutomationLeavesUnchanged(rig)
    }

    func testSkipEpisodeWritesManualSkip() async throws {
        let rig = try await makeRig(.kept, title: Self.bonus)
        rig.model.skipEpisode(try rig.episode(), requireStarted: false)
        await rig.drain()
        try await assertManual(.skip, rig)
        try await assertAutomationLeavesUnchanged(rig)
    }

    func testUndoSkipRestoresExactPriorPolicyDecisionWithoutPlaying() async throws {
        let rig = try await makeRig(.policyKept, title: Self.sponsored)
        let prior = try await rig.record()
        rig.model.skipEpisode(try rig.episode())
        await rig.drain()
        try await assertManual(.skip, rig)
        rig.model.undoSkipEpisode(try XCTUnwrap(rig.model.undoableSkip))
        await rig.drain()
        let restored = try await rig.record()
        XCTAssertEqual(restored, prior, "Undo restores provenance; it is not a new owner Keep choice")
        XCTAssertTrue(rig.model.podcastQueueIDs.contains(rig.itemID.rawValue))
        XCTAssertFalse(rig.model.isPlaying)
    }

    func testRestoreEpisodeFromDismissalWritesManualKeep() async throws {
        let rig = try await makeRig(.dismissed, title: Self.sponsored)
        try await assertNoRecord(rig)
        rig.model.restoreEpisode(try rig.dismissal())
        await rig.drain()
        try await assertManual(.keep, rig)
        try await assertAutomationLeavesUnchanged(rig)
    }

    func testStoreLevelRestoreEpisodeWritesManualKeep() async throws {
        let rig = try await makeRig(.dismissed, title: Self.sponsored)
        await rig.model.restoreEpisode(try rig.dismissal(), episodeID: rig.itemID, store: rig.store)
        try await assertManual(.keep, rig)
        try await assertAutomationLeavesUnchanged(rig)
    }

    // MARK: Phone intents

    func testPhoneKeepOfANewEpisodeWritesManualKeep() async throws {
        let rig = try await makeRig(.live, title: Self.sponsored)
        try await rig.phone(.keep(entryID: rig.itemID, deviceID: Self.phone))
        try await assertManual(.keep, rig)
        try await assertAutomationLeavesUnchanged(rig)
    }

    func testPhoneKeepOfAnEpisodeThePolicyKeptConvertsItToManual() async throws {
        let rig = try await makeRig(.policyKept, title: Self.sponsored)
        let before = try await rig.record()
        XCTAssertEqual(before?.source, .policy, "the control: the record starts as the policy's")
        try await rig.phone(.keep(entryID: rig.itemID, deviceID: Self.phone))
        try await assertManual(.keep, rig)
        try await assertAutomationLeavesUnchanged(rig)
    }

    func testPhoneSkipWritesManualSkip() async throws {
        let rig = try await makeRig(.live, title: Self.bonus)
        try await rig.phone(.skip(entryID: rig.itemID, deviceID: Self.phone))
        try await assertManual(.skip, rig)
        try await assertAutomationLeavesUnchanged(rig)
    }

    func testPhoneMarkDoneWritesManualSkip() async throws {
        let rig = try await makeRig(.kept, title: Self.bonus)
        try await rig.phone(.markDone(entryID: rig.itemID, deviceID: Self.phone))
        try await assertManual(.skip, rig)
        try await assertAutomationLeavesUnchanged(rig)
    }

    func testPhoneRestoreOfASkippedEpisodeWritesManualKeep() async throws {
        let rig = try await makeRig(.retired, title: Self.sponsored)
        try await assertNoRecord(rig)
        try await rig.phone(.restore(entryID: rig.itemID, deviceID: Self.phone))
        try await assertManual(.keep, rig)
        try await assertAutomationLeavesUnchanged(rig)
    }

    func testPhoneRestoreOfARemovedEpisodeWritesManualKeep() async throws {
        let rig = try await makeRig(.dismissed, title: Self.sponsored)
        try await assertNoRecord(rig)
        try await rig.phone(.restore(entryID: rig.itemID, deviceID: Self.phone))
        try await assertManual(.keep, rig)
        try await assertAutomationLeavesUnchanged(rig)
    }

    func testDismissWritesManualSkipAndSurvivesAutomation() async throws {
        let rig = try await makeRig(.live, title: Self.bonus)
        rig.model.removeEpisode(try rig.episode())
        await rig.drain()
        try await assertManual(.skip, rig)
        try await assertAutomationLeavesUnchanged(rig)
    }

    func testAlreadyRestoredDismissalWritesManualKeep() async throws {
        let rig = try await makeRig(.dismissed, title: Self.sponsored)
        let dismissal = try rig.dismissal()
        _ = try await rig.store.restoreEpisode(rig.itemID)
        await rig.model.restoreEpisode(dismissal, episodeID: rig.itemID, store: rig.store)
        try await assertManual(.keep, rig)
        try await assertAutomationLeavesUnchanged(rig)
    }

    func testPhoneRemoveWritesManualSkipIncludingAlreadyOffLarder() async throws {
        for seed in [Seed.kept, .live, .retired] {
            let rig = try await makeRig(seed, title: Self.bonus)
            try await rig.phone(.removeFromLarder(entryID: rig.itemID, deviceID: Self.phone))
            try await assertManual(.skip, rig)
            try await assertAutomationLeavesUnchanged(rig)
        }
    }

    func testPhoneUnchangedReorderConvertsPolicyKeepToManual() async throws {
        let rig = try await makeRig(.policyKept, title: Self.sponsored)
        let before = rig.model.podcastQueueIDs
        try await rig.phone(.reorder(entryID: rig.itemID, afterEntryID: nil, deviceID: Self.phone))
        XCTAssertEqual(rig.model.podcastQueueIDs, before)
        try await assertManual(.keep, rig)
        try await assertAutomationLeavesUnchanged(rig)
    }

    func testPhoneReorderRecordsOnlyMovedEntryAndSurvivesAutomation() async throws {
        let rig = try await makeRig(.policyKeptWithAnchor, title: Self.sponsored)
        let anchor = try ItemID.derivePodcastEpisode(
            feedURL: rig.feedURL, rssGUID: "anchor", enclosureURL: Self.enclosure("anchor")
        )
        try await rig.phone(.reorder(entryID: rig.itemID, afterEntryID: nil, deviceID: Self.phone))
        XCTAssertEqual(rig.model.decisionQueue, [rig.itemID, anchor])
        let anchorRecord = try await rig.store.episodeDecision(for: anchor)
        XCTAssertNil(anchorRecord, "the anchor is not the owner's Keep choice")
        try await assertManual(.keep, rig)
        try await assertAutomationLeavesUnchanged(rig)
    }

    // These are optimistic UI rollback tests, not physical save-failure
    // tests. Unsupported direct SQLite-trigger diagnostics are retained in
    // .logs/playback-lag/implementation/atomic-completion-advisor-result.txt
    // and atomicity-crash-cleanup.json. Producer qualifies actual failed saves
    // through a documented read-only ModelConfiguration after full staging.
    func testUIFailureRejectsManualFinishAndANewPhoneIntentCanRetry() async throws {
        let rig = try await makeRig(.live, title: Self.bonus)
        await rig.drain()
        let before = try await completionState(rig)
        rig.model.subscriptionWriteHookForTesting = { throw UICompletionFailure() }
        let intent = try LibraryIntent.markDone(entryID: rig.itemID, deviceID: Self.phone)
        try await rig.phone(intent)
        let outcome = await rig.book.entry(for: intent.id)?.outcome
        XCTAssertEqual(outcome?.isApplied, false)
        XCTAssertEqual(outcome?.reason, IntentOutcome.reasonFailed)
        let failed = try await completionState(rig)
        XCTAssertEqual(failed, before, "UI failure must leave every durable completion field unchanged")
        XCTAssertEqual(failed.receiptCount, 0)
        XCTAssertTrue(failed.reservations.isEmpty)
        XCTAssertEqual(rig.model.podcastOperationMessage, "\(Self.bonus) could not be marked completed.")
        XCTAssertNil(rig.model.undoableSkip)
        rig.model.subscriptionWriteHookForTesting = nil
        try await rig.phone(.markDone(entryID: rig.itemID, deviceID: Self.phone))
        try await assertManual(.skip, rig)
        try await assertAutomationLeavesUnchanged(rig)
    }

    func testPhoneLiveRestoreWritesManualKeep() async throws {
        let rig = try await makeRig(.live, title: Self.sponsored)
        try await rig.phone(.restore(entryID: rig.itemID, deviceID: Self.phone))
        try await assertManual(.keep, rig)
        try await assertAutomationLeavesUnchanged(rig)
    }

    func testPhoneRetiredSkipAndMarkDoneWriteManualSkip() async throws {
        for done in [false, true] {
            let rig = try await makeRig(.retired, title: Self.bonus)
            try await rig.phone(done
                ? .markDone(entryID: rig.itemID, deviceID: Self.phone)
                : .skip(entryID: rig.itemID, deviceID: Self.phone))
            try await assertManual(.skip, rig)
            try await assertAutomationLeavesUnchanged(rig)
        }
    }

    func testMissingProvenanceStoreRejectsLiveRestoreAndRetainsOutcomeOnReplay() async throws {
        let rig = try await makeRig(.live, title: Self.sponsored)
        let intent = try LibraryIntent.restore(entryID: rig.itemID, deviceID: Self.phone)
        rig.model.store = nil
        try await rig.phone(intent)
        let outcome = await rig.book.entry(for: intent.id)?.outcome
        XCTAssertEqual(outcome?.reason, IntentOutcome.reasonFailed)
        XCTAssertEqual(outcome?.isApplied, false)
        rig.model.store = rig.store
        try await rig.phone(intent)
        try await assertNoRecord(rig)
        let replay = await rig.book.entry(for: intent.id)?.outcome
        XCTAssertEqual(replay, outcome, "a rejected intent is not silently re-applied on replay")
    }

    func testRemoveUIFailureRollsBackAndKeepsWaitingEpisodeUnadmitted() async throws {
        let rig = try await makeRig(.kept, title: Self.bonus)
        try await rig.store.save(feedAutomationPolicy: FeedAutomationPolicy(
            autoKeep: .on, autoDownload: .off, autoPrepare: .off, keptLimit: .explicit(1)
        ), for: rig.feedID)
        _ = try await rig.model.automaticRefresh(rig.feedURL, claimingNewest: 0)
        await rig.drain()
        let waitingBefore = try await rig.store.episodeDecision(for: rig.freshID)
        XCTAssertNil(waitingBefore)
        let before = try await completionState(rig)
        rig.model.subscriptionWriteHookForTesting = { throw UICompletionFailure() }
        rig.model.removeEpisode(try rig.episode())
        await rig.drain()
        let after = try await completionState(rig)
        let waitingAfter = try await rig.store.episodeDecision(for: rig.freshID)
        XCTAssertEqual(after, before)
        XCTAssertEqual(after.receiptCount, 0)
        XCTAssertTrue(after.reservations.isEmpty)
        XCTAssertTrue(rig.model.episodeCompletionProjections.isEmpty)
        XCTAssertNil(rig.model.undoableSkip)
        XCTAssertNil(rig.model.undoableRemoval)
        XCTAssertEqual(rig.model.podcastQueueIDs, [rig.itemID.rawValue])
        XCTAssertNil(waitingAfter, "Failed UI removal frees no automatic slot")
        XCTAssertEqual(rig.model.podcastOperationMessage, "\(Self.bonus) could not be marked completed.")
    }

    func testSkipUIFailureRollsBackAbsentDecisionAndEveryDurableCompletionField() async throws {
        let rig = try await makeRig(.kept, title: Self.bonus)
        await rig.drain()
        let before = try await completionState(rig)
        rig.model.subscriptionWriteHookForTesting = { throw UICompletionFailure() }
        rig.model.skipEpisode(try rig.episode(), requireStarted: false)
        await rig.drain()
        let after = try await completionState(rig)
        XCTAssertEqual(after, before)
        XCTAssertEqual(after.receiptCount, 0)
        XCTAssertTrue(after.reservations.isEmpty)
        XCTAssertTrue(rig.model.episodeCompletionProjections.isEmpty)
        XCTAssertNil(rig.model.undoableSkip)
        XCTAssertTrue(rig.model.podcastQueueIDs.contains(rig.itemID.rawValue))
        XCTAssertEqual(rig.model.podcastOperationMessage, "\(Self.bonus) could not be marked completed.")
        try await assertNoRecord(rig)
    }

    func testUnknownLegacyCompletionUndoRefusesWithoutRewritingHistory() async throws {
        let rig = try await makeRig(.completedRetired, title: Self.sponsored)
        let before = try await rig.store.listeningState(for: rig.itemID)
        rig.model.undoSkipEpisode(try rig.episode())
        await rig.drain()
        let removal = try await rig.store.removalKind(for: rig.itemID)
        let after = try await rig.store.listeningState(for: rig.itemID)
        XCTAssertEqual(removal, .retired)
        XCTAssertEqual(after, before, "No receipt identifies a completion the Undo can safely clear")
        XCTAssertNil(rig.model.undoableSkip)
        try await assertNoRecord(rig)
    }

    func testSkipUIFailureKeepsPriorPolicyHistoryPositionAndTotalsExact() async throws {
        let rig = try await makeRig(.policyKept, title: Self.sponsored)
        let stamp = Timestamp(Date(timeIntervalSince1970: 1_700_000_000))
        try await rig.store.saveListening(PodcastListeningState(episodeID: rig.itemID,
            completedAt: stamp, lastRevisionID: Self.rollbackRevisionID, updatedAt: stamp))
        try await rig.store.save(playback: PlaybackState(itemID: rig.itemID, revisionID: Self.rollbackRevisionID,
            sessionID: "prior-progress", sequence: 1, positionSeconds: 123, durationSeconds: 600,
            completed: false, intent: .progress, deviceID: "fixture-mac", updatedAt: stamp))
        await rig.model.reloadLibraryRows()
        await rig.drain()
        let before = try await completionState(rig)
        rig.model.subscriptionWriteHookForTesting = { throw UICompletionFailure() }
        rig.model.skipEpisode(try rig.episode())
        await rig.drain()
        let after = try await completionState(rig)
        XCTAssertEqual(after, before, "The UI hook leaves genuine history, playhead, provenance and totals exact")
        XCTAssertEqual(after.receiptCount, 0)
        XCTAssertTrue(after.reservations.isEmpty)
        XCTAssertTrue(rig.model.episodeCompletionProjections.isEmpty)
        XCTAssertNil(rig.model.undoableSkip)
        XCTAssertEqual(rig.model.podcastOperationMessage, "\(Self.sponsored) could not be marked completed.")
    }

    func testRestoreAfterUnsubscribeCannotCreateAnOrphanManualKeep() async throws {
        let rig = try await makeRig(.dismissed, title: Self.sponsored)
        let dismissal = try rig.dismissal()
        _ = try await rig.store.unsubscribeFromPodcast(feedID: rig.feedID)
        let absent = try await rig.store.podcastEpisode(for: rig.itemID)
        XCTAssertNil(absent, "the fixture feed cascade really removed the episode")
        await rig.model.restoreEpisode(dismissal, episodeID: rig.itemID, store: rig.store)
        try await assertNoRecord(rig)
        XCTAssertEqual(rig.model.podcastOperationMessage,
                       "\(Self.sponsored) could not be restored because it is no longer in the library.")
    }

    func testExplicitRestoreConflictsPreserveEveryNewerDurableField() async throws {
        for changedDecision in [false, true] {
            let rig = try await makeRig(.policyKept, title: Self.sponsored)
            let stamp = Timestamp(Date(timeIntervalSince1970: 1_700_000_000))
            let mediaURL = wiltedTemporaryDirectory("restore-conflict-media").appendingPathComponent("retained.m4a")
            let bytes = Data("retained synthetic audio".utf8)
            try bytes.write(to: mediaURL)
            let revision = try AudioRevision(itemID: rig.itemID, revisionID: Self.rollbackRevisionID,
                durationSeconds: 600, byteCount: Int64(bytes.count),
                contentHash: "sha256:" + String(repeating: "a", count: 64), mediaType: "audio/mp4",
                createdAt: stamp, schemaVersion: 1)
            try await rig.store.finalizePodcastDownload(revision: revision, mediaURL: mediaURL,
                download: PodcastDownload(episodeID: rig.itemID, status: .completed,
                    bytesReceived: revision.byteCount, expectedByteCount: revision.byteCount,
                    localURL: mediaURL, contentHash: revision.contentHash, updatedAt: stamp))
            try await rig.store.save(playback: PlaybackState(itemID: rig.itemID, revisionID: Self.rollbackRevisionID,
                sessionID: "retained-progress", sequence: 1, positionSeconds: 123, durationSeconds: 600,
                completed: false, intent: .progress, deviceID: "fixture-mac", updatedAt: stamp))
            rig.model.removeEpisode(try rig.episode())
            await rig.drain()
            XCTAssertNotNil(rig.model.undoableSkip?.manualCompletionOperationID)
            let newer = Timestamp(Date().addingTimeInterval(10))
            if changedDecision {
                try await rig.store.save(episodeDecision: EpisodeDecisionRecord(episodeID: rig.itemID,
                    decision: .keep, source: .manual, decidedAt: newer))
            } else {
                try await rig.store.saveListening(PodcastListeningState(episodeID: rig.itemID,
                    completedAt: newer, lastRevisionID: Self.rollbackRevisionID, updatedAt: newer))
            }
            let before = try await completionState(rig)
            let restored = await rig.model.restoreEntry(rig.itemID)
            XCTAssertFalse(restored)
            let after = try await completionState(rig)
            XCTAssertEqual(after, before, "A real newer choice or listening fact cannot fall back to legacy unretirement")
            XCTAssertEqual(try Data(contentsOf: mediaURL), bytes)
            XCTAssertEqual(after.playback?.positionSeconds, 123)
            XCTAssertEqual(after.removal, .retired)
        }
    }

    func testOrderedReceiptRestoreRejectsHeldOldRowsAndRestoresQueueAndPlayedState() async throws {
        let rig = try await makeRig(.kept, title: Self.sponsored)
        let priorQueue = try await rig.store.podcastQueueState()
        rig.model.removeEpisode(try rig.episode())
        await rig.drain()
        XCTAssertTrue(try rig.episode().isPlayed)
        let retired = try rig.episode()
        let oldRead = BootstrapGate()
        addTeardownBlock { await oldRead.release() }
        rig.model.librarySnapshotReadBarrierForTesting = { await oldRead.hold() }
        let staleReload = Task { @MainActor in await rig.model.reloadLibraryRows() }
        await oldRead.waitUntilHeld()
        // The held read already captured terminal rows. Restore's fresh read
        // must run independently, and the old snapshot must never republish.
        rig.model.librarySnapshotReadBarrierForTesting = nil
        rig.model.restoreSkippedFeedEpisode(retired)
        await rig.drain()
        let restored = try rig.episode()
        XCTAssertNil(restored.removalKind)
        XCTAssertFalse(restored.isPlayed)
        XCTAssertEqual(rig.model.podcastQueueIDs, priorQueue.episodeIDs.map(\.rawValue))
        await oldRead.release()
        await staleReload.value
        XCTAssertNil(try rig.episode().removalKind)
        XCTAssertFalse(try rig.episode().isPlayed)
        XCTAssertEqual(rig.model.podcastQueueIDs, priorQueue.episodeIDs.map(\.rawValue))
        let queue = try await rig.store.podcastQueueState()
        XCTAssertEqual(queue, priorQueue)
        try await assertManual(.keep, rig)
        XCTAssertFalse(rig.model.isPlaying)
    }

    func testClosingBeforeOrderedRestoreCommitPreservesReceiptAndEveryDurableField() async throws {
        let rig = try await makeRig(.kept, title: Self.sponsored)
        rig.model.removeEpisode(try rig.episode())
        await rig.drain()
        let before = try await completionState(rig)
        let beforeCommit = BootstrapGate()
        addTeardownBlock { await beforeCommit.release() }
        rig.model.feedDecisionBeforeCommitForTesting = { await beforeCommit.hold() }
        rig.model.restoreSkippedFeedEpisode(try rig.episode())
        await beforeCommit.waitUntilHeld()
        let closing = Task { @MainActor in await rig.model.close() }
        for _ in 0..<50 where !rig.model.isClosingTemporaryState { await Task.yield() }
        XCTAssertTrue(rig.model.isClosingTemporaryState)
        await beforeCommit.release()
        await closing.value
        let after = try await completionState(rig)
        XCTAssertEqual(after, before)
    }

    func testRestoreAlreadyAtTargetReportsNoNewRestoration() async throws {
        let rig = try await makeRig(.live, title: Self.sponsored)
        rig.model.restoreSkippedFeedEpisode(try rig.episode())
        await rig.drain()
        XCTAssertEqual(rig.model.podcastOperationMessage, "Those episodes were already restored.")
        XCTAssertNil(try rig.episode().removalKind)
        try await assertNoRecord(rig)
    }

    // MARK: Assertions

    private func assertNoRecord(_ rig: Rig, file: StaticString = #filePath, line: UInt = #line) async throws {
        let record = try await rig.record()
        XCTAssertNil(record, "the control: nothing but the entry point may write the record", file: file, line: line)
    }

    private func assertManual(
        _ decision: EpisodeDecision, _ rig: Rig, file: StaticString = #filePath, line: UInt = #line
    ) async throws {
        let record = try await rig.record()
        XCTAssertEqual(record?.decision, decision, file: file, line: line)
        XCTAssertEqual(record?.source, .manual, file: file, line: line)
        XCTAssertNil(record?.ruleID, file: file, line: line)
    }

    /// Stands in for Apply to existing: an automatic refresh and the service's
    /// re-evaluation must leave the episode's record, removal state and Larder
    /// place exactly as the owner left them, while still admitting a fresh one.
    private func assertAutomationLeavesUnchanged(
        _ rig: Rig, file: StaticString = #filePath, line: UInt = #line
    ) async throws {
        let before = try await rig.snapshot()
        let claimed = try await rig.model.automaticRefresh(rig.feedURL, claimingNewest: 0)
        XCTAssertTrue(claimed.isEmpty, "Auto download is off, so no claim", file: file, line: line)
        await rig.model.releaseWaitingEpisodes(feedIDs: [rig.feedID.rawValue])
        await rig.drain()

        let decisions = try await rig.store.decisions(forFeed: rig.feedID)
        let manual = Dictionary(uniqueKeysWithValues: decisions.filter { $0.source == .manual }.map {
            ($0.episodeID.rawValue, $0.decision == .keep ? FeedManualDecision.keep : .skip)
        })
        let target = Self.candidate(title: rig.title, id: rig.itemID.rawValue)
        let planned = EpisodeAdmissionService.plan(
            candidates: [target], keptEpisodeIDs: [], manualDecisions: manual, rules: Self.rules,
            policy: .init(autoKeep: true, autoDownload: false, autoPrepare: false, keptLimit: nil)
        )
        XCTAssertTrue(planned.isEmpty, "the planner and rules must not re-decide a manual one", file: file, line: line)
        // The control: the same planner does reverse an episode with no manual record.
        let uncontrolled = EpisodeAdmissionService.plan(
            candidates: [target], keptEpisodeIDs: [], manualDecisions: [:], rules: Self.rules,
            policy: .init(autoKeep: true, autoDownload: false, autoPrepare: false, keptLimit: nil)
        )
        XCTAssertEqual(uncontrolled.count, 1, "rules do contradict this episode", file: file, line: line)

        let after = try await rig.snapshot()
        XCTAssertEqual(after, before, file: file, line: line)
        let fresh = try await rig.store.episodeDecision(for: rig.freshID)
        XCTAssertEqual(fresh?.source, .policy, "the refresh did run and admit the fresh episode", file: file, line: line)
    }

    private struct UICompletionFailure: Error {}
    private static let rollbackRevisionID = try! RevisionID(rawValue: "prior-rollback-revision")

    private struct CompletionState: Equatable {
        let episode: PodcastEpisode?
        let removal: PodcastEpisodeRemovalKind?
        let retiredAt: Timestamp?
        let listening: PodcastListeningState?
        let decision: EpisodeDecisionRecord?
        let queue: PodcastQueueState
        let placements: [PodcastQueueEntry]
        let playback: PlaybackState?
        let download: PodcastDownload?
        let readyRevision: AudioRevision?
        let readyURL: URL?
        let totals: LifetimeStatistics
        let receiptCount: Int
        let reservations: [ItemID: Int]
    }

    private func completionState(_ rig: Rig) async throws -> CompletionState {
        let ready = try await rig.store.readyRevision(for: rig.itemID)
        let context = ModelContext(rig.store.container)
        let receipts = try context.fetchCount(FetchDescriptor<LocalLibrarySchemaV19Models.ManualCompletionReceiptRecord>())
        return CompletionState(
            episode: try await rig.store.podcastEpisode(for: rig.itemID),
            removal: try await rig.store.removalKind(for: rig.itemID),
            retiredAt: try await rig.store.retiredAt(for: rig.itemID),
            listening: try await rig.store.listeningState(for: rig.itemID),
            decision: try await rig.store.episodeDecision(for: rig.itemID),
            queue: try await rig.store.podcastQueueState(), placements: try await rig.store.queue(),
            playback: try await rig.store.playbackState(for: rig.itemID, revisionID: Self.rollbackRevisionID),
            download: try await rig.store.download(for: rig.itemID),
            readyRevision: ready?.revision, readyURL: ready?.mediaURL,
            totals: try await rig.store.lifetimeStatistics(), receiptCount: receipts,
            reservations: try await rig.store.manualCompletionCapacityReservations())
    }

    private static func candidate(title: String, id: String) -> EpisodeAdmissionService.Candidate {
        .init(id: id, title: title, notes: nil, releasedAt: Date(timeIntervalSince1970: 1_704_086_400))
    }
}

// MARK: - Fixture

private extension ManualDecisionProvenanceTests {
    static let phone = "iphone"
    static let sponsored = "Sponsored special"
    static let bonus = "Bonus episode"
    static let guid = "target"
    static let freshGUID = "fresh"

    /// Where the target episode starts, before the entry point under test.
    enum Seed { case live, kept, policyKept, policyKeptWithAnchor, retired, completedRetired, dismissed }

    /// Skip anything "Sponsored"; keep anything "Bonus".
    static let rules: EpisodeMatchRules = {
        // The patterns are constants that pass validation.
        EpisodeMatchRules(rules: [
            .init(field: .title, includePattern: "Sponsored", action: .skip),
            .init(field: .title, includePattern: "Bonus", action: .keep)
        ])
    }()

    struct Snapshot: Equatable {
        var record: EpisodeDecisionRecord?
        var removal: PodcastEpisodeRemovalKind?
        var queue: [ItemID]
    }

    @MainActor
    struct Rig {
        let model: WiltedMacModel
        let store: LocalLibraryStore
        let feedURL: URL
        let feedID: ItemID
        let itemID: ItemID
        let freshID: ItemID
        let title: String
        let applier: WiltedMacIntentApplier
        let book: WiltedMacIntentOutcomeBook

        func episode() throws -> WiltedMacEpisode {
            try XCTUnwrap(model.episodes.first { $0.id == itemID.rawValue })
        }

        func dismissal() throws -> WiltedMacDismissedEpisode {
            try XCTUnwrap(model.dismissedEpisodes.first { $0.id == itemID.rawValue })
        }

        func record() async throws -> EpisodeDecisionRecord? { try await store.episodeDecision(for: itemID) }

        func snapshot() async throws -> Snapshot {
            Snapshot(
                record: try await record(), removal: try await store.removalKind(for: itemID),
                queue: try await store.podcastQueueState().episodeIDs.filter { $0 == itemID }
            )
        }

        func drain() async {
            for writer in Array(model.subscriptionWriteTasks.values) { await writer.value }
            await model.waitForPodcastOperations()
            await model.waitForPodcastPreparationOperationsForTesting()
        }

        /// Applies one phone intent through the real applier and the real model.
        func phone(_ intent: @autoclosure () throws -> LibraryIntent) async throws {
            try await applier.apply(try intent())
            await drain()
        }
    }

    func makeRig(_ seed: Seed, title: String) async throws -> Rig {
        let feedURL = URL(string: "https://feeds.example.test/provenance.xml")!
        let feedID = try ItemID.derivePodcastFeed(from: feedURL)
        let itemID = try ItemID.derivePodcastEpisode(
            feedURL: feedURL, rssGUID: Self.guid, enclosureURL: Self.enclosure(Self.guid)
        )
        let freshID = try ItemID.derivePodcastEpisode(
            feedURL: feedURL, rssGUID: Self.freshGUID, enclosureURL: Self.enclosure(Self.freshGUID)
        )
        let anchorURL = Self.enclosure("anchor")
        let anchorID = try ItemID.derivePodcastEpisode(feedURL: feedURL, rssGUID: "anchor", enclosureURL: anchorURL)
        let at = Timestamp(Date(timeIntervalSince1970: 1_704_000_000))
        let item: (String, String, Int) -> String = { guid, title, day in
            """
            <item><guid>\(guid)</guid><title>\(title)</title>
            <pubDate>\(Self.rfc822(Date(timeIntervalSince1970: 1_704_000_000 + Double(day) * 86_400)))</pubDate>
            <enclosure url="\(Self.enclosure(guid).absoluteString)" type="audio/mpeg" /></item>
            """
        }
        let xml = "<rss version=\"2.0\"><channel><title>Provenance</title>"
            + item(Self.guid, title, 1) + item(Self.freshGUID, "Neutral fresh", 2) + "</channel></rss>"
        let model = WiltedMacModel(
            arguments: [], stateDirectoryOverride: wiltedTemporaryDirectory("manual-provenance"),
            storeBootstrap: { url in
                let store = try LocalLibraryStore(url: url)
                try await store.save(feed: try PodcastFeed(
                    itemID: feedID, canonicalURL: feedURL, title: "Provenance", createdAt: at
                ))
                try await store.save(subscription: PodcastSubscription(feedID: feedID, subscribedAt: at))
                try await store.save(episode: try PodcastEpisode(
                    itemID: itemID, feedID: feedID, feedURL: feedURL, rssGUID: Self.guid, title: title,
                    publishedTime: Timestamp(Date(timeIntervalSince1970: 1_704_086_400)),
                    enclosureURL: Self.enclosure(Self.guid), enclosureMediaType: "audio/mpeg", createdAt: at
                ))
                switch seed {
                case .live: break
                case .kept, .policyKept, .policyKeptWithAnchor:
                    var queue = [itemID]
                    if seed == .policyKeptWithAnchor {
                        try await store.save(episode: PodcastEpisode(
                            itemID: anchorID, feedID: feedID, feedURL: feedURL, rssGUID: "anchor", title: "Anchor",
                            enclosureURL: anchorURL, enclosureMediaType: "audio/mpeg", createdAt: at
                        ))
                        queue.insert(anchorID, at: 0)
                    }
                    try await store.replacePodcastQueue(try PodcastQueueState(episodeIDs: queue, currentEpisodeID: nil))
                    if seed == .policyKept || seed == .policyKeptWithAnchor {
                        try await store.save(episodeDecision: .init(
                            episodeID: itemID, decision: .keep, source: .policy, decidedAt: at
                        ))
                    }
                case .retired: _ = try await store.retireEpisodes([itemID], at: at)
                case .completedRetired:
                    _ = try await store.completeAndRetireEpisode(listening: PodcastListeningState(
                        episodeID: itemID, completedAt: at, lastRevisionID: nil, updatedAt: at
                    ))
                case .dismissed: try await store.dismissPodcastEpisode(itemID)
                }
                try await store.save(feedAutomationPolicy: FeedAutomationPolicy(
                    autoKeep: .on, autoDownload: .off, autoPrepare: .off, keptLimit: .explicit(5)
                ), for: feedID)
                try await store.replaceEpisodeMatchRules(Self.rules, for: feedID)
                return store
            },
            podcastFeedClient: PodcastFeedClient(loader: FixedBodyLoader(body: Data(xml.utf8))),
            preferences: WiltedMacTestPreferences.ephemeral()
        )
        model.startStoreBootstrap()
        await model.waitForStoreBootstrap()
        await model.manualCompletionRecoveryTask?.value
        addTeardownBlock { await MainActor.run { model.stopLibrarySync() }; await model.close() }
        let book = WiltedMacIntentOutcomeBook(fileURL: nil)
        let applier = WiltedMacIntentApplier(
            host: model, ledger: WiltedMacIntentLedger(fileURL: nil), book: book,
            transport: InMemoryLibraryTransport(
                deviceID: "mac-test", server: InMemoryLibraryServer(writerDeviceID: "mac-test")
            )
        )
        return Rig(
            model: model, store: try XCTUnwrap(model.store), feedURL: feedURL, feedID: feedID, itemID: itemID,
            freshID: freshID, title: title, applier: applier, book: book
        )
    }

    static func enclosure(_ guid: String) -> URL { URL(string: "https://media.example.test/\(guid).mp3")! }

    static func rfc822(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss 'GMT'"
        return formatter.string(from: date)
    }
}
