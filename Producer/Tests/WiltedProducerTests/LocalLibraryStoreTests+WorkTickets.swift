import CryptoKit
import Foundation
import SwiftData
import XCTest
import WiltedDomain
import WiltedSync
@testable import WiltedProducer

extension LocalLibraryStoreTests {
    // MARK: - V12 work tickets

    /// Step 1 done-condition: a V11 fixture opens at V12 and every prior row
    /// reads back intact -- the new work-ticket table must be purely
    /// additive.
    func testV11FixtureOpensAtV12WithPriorRowsIntact() async throws {
        let url = makeURL(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let episodeID = try ItemID(rawValue: "item-" + String(repeating: "7", count: 64))
        let revisionID = try RevisionID(rawValue: "rev-v11-fixture")
        let download = try PodcastDownload(
            episodeID: episodeID, status: .completed, bytesReceived: 512, expectedByteCount: 512,
            localURL: URL(fileURLWithPath: "/tmp/v11-fixture.m4a"),
            contentHash: "sha256:" + String(repeating: "7", count: 64),
            updatedAt: Timestamp(Date(timeIntervalSince1970: 1_700_002_000))
        )
        let journalEntry = try succeededPreparationEntry(
            itemID: episodeID, revisionID: revisionID, requestID: "podcast-prepare|\(episodeID.rawValue)",
            fingerprint: "fp-v11-fixture", at: 1_700_002_100
        )

        try LocalLibraryStore.createV11MigrationFixture(at: url, downloads: [download], preparationEntries: [journalEntry])

        let migrated = try LocalLibraryStore(url: url)
        let inspection = try await migrated.inspect()
        XCTAssertEqual(inspection.schemaVersion, .current, "the migration plan must carry a V11 store to the current schema")

        let migratedDownload = try await migrated.download(for: episodeID)
        XCTAssertEqual(migratedDownload, download, "the pre-existing download row must survive the lightweight migration")

        let migratedJournal = try await migrated.preparationJournal(for: journalEntry.requestID)
        XCTAssertEqual(migratedJournal.count, 1, "the pre-existing preparation journal row must survive the lightweight migration")
        XCTAssertEqual(migratedJournal.first?.id, journalEntry.id)

        let tickets = try await migrated.workTickets()
        XCTAssertTrue(tickets.isEmpty, "a freshly migrated V11 store must not fabricate any work tickets")
    }

    /// Step 2 done-conditions: two issues against one store return 1 then 2,
    /// and a re-issue for the same subject returns the existing row rather
    /// than a second one. `upsertWorkTicket` is exercised separately for the
    /// state-transition path it is meant for.
    func testIssueWorkTicketAllocatesMonotonicSequenceAndReissueReturnsExistingRow() async throws {
        let url = makeURL(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = try LocalLibraryStore(url: url)
        let requestedAt = Timestamp(Date(timeIntervalSince1970: 1_700_003_000))

        let first = try await store.issueWorkTicket(kind: .podcastDownload, subjectID: "episode-1", requestedAt: requestedAt)
        let second = try await store.issueWorkTicket(kind: .podcastPreparation, subjectID: "episode-1", requestedAt: requestedAt)
        XCTAssertEqual(first.requestSequence, 1)
        XCTAssertEqual(second.requestSequence, 2)
        XCTAssertNotEqual(first.id, second.id, "different kinds for the same subject are different tickets")

        let reissued = try await store.issueWorkTicket(kind: .podcastDownload, subjectID: "episode-1", requestedAt: requestedAt)
        XCTAssertEqual(reissued.requestSequence, first.requestSequence, "a re-issue must return the existing row, not allocate a new sequence number")
        XCTAssertEqual(reissued, first)

        let tickets = try await store.workTickets()
        XCTAssertEqual(tickets.count, 2, "the re-issue must not have inserted a duplicate row")

        // upsertWorkTicket drives the state-transition path: caller-supplied
        // fields overwrite in place, keyed by id, without touching sequence
        // allocation.
        var running = first
        running.state = .running
        running.attemptCount = 1
        running.runID = "run-1"
        running.updatedAt = Timestamp(Date(timeIntervalSince1970: 1_700_003_100))
        try await store.upsertWorkTicket(running)
        let afterTransition = try await store.workTickets()
        XCTAssertEqual(afterTransition.count, 2, "upserting an existing ticket must update in place, not insert a third row")
        let updated = afterTransition.first { $0.id == first.id }
        XCTAssertEqual(updated?.state, .running)
        XCTAssertEqual(updated?.attemptCount, 1)
        XCTAssertEqual(updated?.runID, "run-1")
        XCTAssertFalse(updated?.state.isTerminal ?? true)

        var succeeded = running
        succeeded.state = .succeeded
        try await store.upsertWorkTicket(succeeded)
        let afterCompletion = try await store.workTickets()
        XCTAssertEqual(afterCompletion.first { $0.id == first.id }?.state, .succeeded)
        XCTAssertTrue(WorkTicketState.succeeded.isTerminal)
        XCTAssertTrue(WorkTicketState.failed.isTerminal)
        XCTAssertTrue(WorkTicketState.cancelled.isTerminal)
        XCTAssertFalse(WorkTicketState.pending.isTerminal)
        XCTAssertFalse(WorkTicketState.deferred.isTerminal)
    }

    /// A retry is a new request, but not a second durable row. Its newer
    /// sequence atomically replaces the old terminal attempt, so an old
    /// completion that lands late cannot reopen or overwrite the retry.
    func testReadmittingATerminalTicketReplacesPolicyAndRejectsLateOlderWrites() async throws {
        let url = makeURL(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = try LocalLibraryStore(url: url)
        let firstAt = Timestamp(Date(timeIntervalSince1970: 1_700_005_000))
        let retryAt = Timestamp(Date(timeIntervalSince1970: 1_700_005_100))
        let oldSnapshot = Data("removeAds=false".utf8)
        let newSnapshot = Data("removeAds=true".utf8)
        let oldProcessing = Data("offPeak".utf8)
        let newProcessing = Data("immediate".utf8)

        _ = try await store.readmitWorkTicket(
            kind: .podcastPreparation, subjectID: "episode-retry", requestSequence: 10,
            policySnapshot: oldSnapshot, processingPolicy: oldProcessing, to: .running, at: firstAt
        )
        _ = try await store.applyWorkTicketTransition(
            kind: .podcastPreparation, subjectID: "episode-retry", requestSequence: 10,
            to: .failed, failureKind: "retryable", lastFailureMessage: "old failure", at: firstAt
        )
        let failedTicket = try await store.workTicket(kind: .podcastPreparation, subjectID: "episode-retry")
        var failed = try XCTUnwrap(failedTicket)
        failed.runID = "old-run"
        failed.nextEligibleAt = Timestamp(firstAt.date.addingTimeInterval(60))
        failed.resolvedItemID = "old-resolution"
        try await store.upsertWorkTicket(failed)

        let retried = try await store.readmitWorkTicket(
            kind: .podcastPreparation, subjectID: "episode-retry", requestSequence: 11,
            policySnapshot: newSnapshot, processingPolicy: newProcessing, to: .running, at: retryAt
        )
        XCTAssertEqual(retried.requestSequence, 11)
        XCTAssertEqual(retried.state, .running)
        XCTAssertEqual(retried.attemptCount, 2, "the retry entered running once")
        XCTAssertEqual(retried.policySnapshot, newSnapshot)
        XCTAssertEqual(retried.processingPolicy, newProcessing)
        XCTAssertNil(retried.failureKind)
        XCTAssertNil(retried.lastFailureMessage)
        XCTAssertNil(retried.nextEligibleAt)
        XCTAssertNil(retried.runID)
        XCTAssertNil(retried.resolvedItemID)

        let duplicateRunning = try await store.applyWorkTicketTransition(
            kind: .podcastPreparation, subjectID: "episode-retry", requestSequence: 11,
            to: .running, at: retryAt
        )
        XCTAssertEqual(duplicateRunning.attemptCount, 2, "a duplicate running write is not another attempt")

        let lateOlderFailure = try await store.applyWorkTicketTransition(
            kind: .podcastPreparation, subjectID: "episode-retry", requestSequence: 10,
            to: .failed, failureKind: "terminal", lastFailureMessage: "late old failure", at: retryAt
        )
        XCTAssertEqual(lateOlderFailure, duplicateRunning, "a late older attempt is a no-op")
        let tickets = try await store.workTickets().filter { $0.id == retried.id }
        XCTAssertEqual(tickets, [duplicateRunning], "re-admission retains exactly one row per ticket key")
    }

    /// REQUIRED EMPIRICAL CHECK: establishes what this repo's SwiftData
    /// version actually does when a main-actor write and a store-actor write
    /// race a conflicting insert against `WorkTicketRecord.id`'s
    /// `@Attribute(.unique)`. `issueWorkTicket`'s find-or-insert pattern is
    /// only safe if one write wins deterministically (either by throwing or
    /// by the constraint rejecting/merging the loser) -- silent duplication
    /// would mean two live tickets for the same subject, which later steps
    /// must not build on.
    func testConcurrentUniqueInsertAcrossStoreActorAndMainActorContexts() async throws {
        let url = makeURL(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = try LocalLibraryStore(url: url)
        let requestedAt = Timestamp(Date(timeIntervalSince1970: 1_700_004_000))

        async let storeActorWrite: WorkTicket = store.issueWorkTicket(
            kind: .podcastDownload, subjectID: "race-subject", requestedAt: requestedAt
        )
        async let mainActorWrite: Void = MainActor.run {
            try store.seedRawWorkTicket(
                kind: .podcastDownload, subjectID: "race-subject", requestSequence: 999, requestedAt: requestedAt
            )
        }

        var storeActorError: Error?
        var mainActorError: Error?
        do { _ = try await storeActorWrite } catch { storeActorError = error }
        do { _ = try await mainActorWrite } catch { mainActorError = error }

        let tickets = try await store.workTickets()
        let matching = tickets.filter { $0.kind == .podcastDownload && $0.subjectID == "race-subject" }

        // This assertion IS the empirical finding: it records, via the
        // failure message if it fails, exactly what this SwiftData version
        // did with the race. See HISTORY.md / the task report for the
        // observed outcome; do not "fix" this test to force it green without
        // updating that report.
        XCTAssertEqual(matching.count, 1,
            "expected exactly one surviving row for a raced unique insert, found \(matching.count) " +
            "(storeActorError=\(String(describing: storeActorError)), mainActorError=\(String(describing: mainActorError)))")
    }

    /// Step 3 done-condition: a second `reconcileWorkTickets` pass must be a
    /// no-op. A run where the second call has nothing left to import, adopt,
    /// or close would pass trivially and prove nothing about the
    /// find-or-insert paths reconciliation depends on, so this seeds a
    /// still-pending ticket, a running ticket belonging to a dead process,
    /// and a retryable orphan download *before either call*, then compares
    /// a full sorted snapshot of every column across both passes.
    func testReconcilingWorkTicketsASecondTimeChangesNothing() async throws {
        let url = makeURL(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let origin = Date(timeIntervalSince1970: 1_700_000_000)
        let feedURL = URL(string: "https://podcasts.example.test/reconcile/feed.xml")!
        let (feed, all) = try episodes(feedURL: feedURL, origin: origin, daysAgo: [1, 2])
        let store = try LocalLibraryStore(url: url)
        try await store.save(feed: feed)
        try await store.save(subscription: PodcastSubscription(feedID: feed.itemID, subscribedAt: Timestamp(origin)))
        _ = try await store.admitPodcastEpisodes(all, admission: .incremental, claimingNewest: 2)

        // An orphan retryable download with no ticket yet -- step 2 should adopt it once.
        let retryableEpisode = all[0].itemID
        try await store.save(download: PodcastDownload(
            episodeID: retryableEpisode, status: .failed, updatedAt: Timestamp(origin), failureKind: .retryable
        ))

        let requestedAt = Timestamp(origin)
        // A ticket already in the queue that neither step should touch.
        let untouched = try await store.issueWorkTicket(
            kind: .articlePreparation, subjectID: "article-untouched", requestedAt: requestedAt
        )

        // A running ticket this process did not start -- step 3 should close it.
        var running = try await store.issueWorkTicket(
            kind: .podcastPreparation, subjectID: "episode-running", requestedAt: requestedAt
        )
        running.state = .running
        running.attemptCount = 1
        running.runID = "dead-run"
        running.updatedAt = requestedAt
        try await store.upsertWorkTicket(running)

        let deferral = WorkTicketImportedDeferral(
            subjectID: "episode-deferred",
            policySnapshot: Data("snapshot".utf8), processingPolicy: Data("policy".utf8)
        )

        let firstNow = Timestamp(origin.addingTimeInterval(3_600))
        let first = try await store.reconcileWorkTickets(
            now: firstNow, sequenceFloor: 0, importedDeferrals: [deferral]
        )
        XCTAssertEqual(first.importedDeferralCount, 1)
        XCTAssertEqual(first.adoptedDownloadCount, 1)
        XCTAssertEqual(first.closedRunCount, 1)
        XCTAssertEqual(first.prunedCount, 0)

        let firstSnapshot = try await store.workTickets().sorted { $0.id < $1.id }
        XCTAssertTrue(firstSnapshot.contains { $0.id == untouched.id && $0.state == .pending },
                      "the pre-existing pending ticket must be left alone")
        XCTAssertTrue(firstSnapshot.contains { $0.id == running.id && $0.state == .pending && $0.attemptCount == 2 },
                      "the interrupted running ticket retries: pending with attemptCount+1")

        let secondNow = Timestamp(origin.addingTimeInterval(3_660))
        let second = try await store.reconcileWorkTickets(
            now: secondNow, sequenceFloor: 0, importedDeferrals: [deferral]
        )
        XCTAssertEqual(second.importedDeferralCount, 0, "the deferral already has a ticket")
        XCTAssertEqual(second.adoptedDownloadCount, 0, "the download already has a ticket")
        XCTAssertEqual(second.closedRunCount, 0, "nothing is running any more")
        XCTAssertEqual(second.prunedCount, 0)

        let secondSnapshot = try await store.workTickets().sorted { $0.id < $1.id }
        XCTAssertEqual(firstSnapshot, secondSnapshot, "a second reconcile must change nothing")
    }

    func testReconcileWorkTicketsReportsCountedProgress() async throws {
        final class ProgressRecorder: @unchecked Sendable {
            private let lock = NSLock()
            private var stored: [LocalLibraryStore.WorkTicketReconciliationProgress] = []

            func append(_ update: LocalLibraryStore.WorkTicketReconciliationProgress) {
                lock.withLock { stored.append(update) }
            }

            var updates: [LocalLibraryStore.WorkTicketReconciliationProgress] {
                lock.withLock { stored }
            }
        }

        let url = makeURL(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = try LocalLibraryStore(url: url)
        let now = Timestamp(Date(timeIntervalSince1970: 1_700_010_000))
        let recorder = ProgressRecorder()

        let result = try await store.reconcileWorkTickets(
            now: now, sequenceFloor: 0,
            importedDeferrals: [
                WorkTicketImportedDeferral(subjectID: "first"),
                WorkTicketImportedDeferral(subjectID: "second"),
            ],
            progress: { recorder.append($0) }
        )
        let progress = recorder.updates

        XCTAssertEqual(
            progress.filter { $0.step == .importingDeferrals }.map { "\($0.done)/\($0.total)" },
            ["0/2", "1/2", "2/2"]
        )
        XCTAssertEqual(result.importedDeferralCount, 2)
        XCTAssertTrue(result.errors.isEmpty)
        let firstTicket = try await store.workTicket(kind: .podcastPreparation, subjectID: "first")
        let secondTicket = try await store.workTicket(kind: .podcastPreparation, subjectID: "second")
        XCTAssertNotNil(firstTicket)
        XCTAssertNotNil(secondTicket)
        XCTAssertEqual(
            Set(progress.filter { $0.step != .importingDeferrals }.map(\.step)),
            Set(LocalLibraryStore.WorkTicketReconciliationStep.allCases.filter { $0 != .importingDeferrals }),
            "every recovery step reports even when it has no candidate tickets"
        )
    }

    // MARK: - V13 episode removals

    /// Task 4.5 done-condition 2: a V12 store seeded with a bare `retiredAt`
    /// row and two standalone dismissal tombstones -- one whose episode row
    /// still exists, one whose row is already gone, the ordinary case since
    /// dismissal used to delete it -- reconciles so every removal becomes a
    /// `removalKind` on an episode row, nothing lost or duplicated, and a
    /// second run changes nothing further.
    func testReconcileEpisodeRemovalsFoldsPreV13RemovalsOntoTheEpisodeRow() async throws {
        let url = makeURL(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let origin = Date(timeIntervalSince1970: 1_700_004_000)
        let feedURL = URL(string: "https://podcasts.example.test/v13-removals/feed.xml")!
        let (_, all) = try episodes(feedURL: feedURL, origin: origin, daysAgo: [1, 2])
        let retiredEpisode = all[0]
        let dismissedWithSurvivingRow = all[1]
        let goneEnclosure = URL(string: "https://podcasts.example.test/v13-removals/gone.mp3")!
        let goneEpisodeID = try ItemID.derivePodcastEpisode(
            feedURL: feedURL, rssGUID: "gone", enclosureURL: goneEnclosure
        )

        try LocalLibraryStore.createV12MigrationFixture(
            at: url, episodes: [retiredEpisode, dismissedWithSurvivingRow],
            retiredEpisodeIDs: [retiredEpisode.itemID.rawValue],
            dismissals: [
                (episodeID: dismissedWithSurvivingRow.itemID.rawValue, feedID: dismissedWithSurvivingRow.feedID.rawValue,
                 title: dismissedWithSurvivingRow.title, dismissedAt: origin.addingTimeInterval(100)),
                (episodeID: goneEpisodeID.rawValue, feedID: nil, title: "Gone episode",
                 dismissedAt: origin.addingTimeInterval(200)),
            ]
        )

        let migrated = try LocalLibraryStore(url: url)
        let inspection = try await migrated.inspect()
        XCTAssertEqual(inspection.schemaVersion, .current, "the migration plan must carry a V12 store to the current schema")

        let first = try await migrated.reconcileEpisodeRemovals()
        XCTAssertEqual(first.backfilledRetirementCount, 1)
        XCTAssertEqual(first.convertedDismissalCount, 2)

        var retiredKind = try await migrated.removalKind(for: retiredEpisode.itemID)
        var dismissedKind = try await migrated.removalKind(for: dismissedWithSurvivingRow.itemID)
        var goneKind = try await migrated.removalKind(for: goneEpisodeID)
        XCTAssertEqual(retiredKind, .retired)
        XCTAssertEqual(dismissedKind, .dismissed)
        XCTAssertEqual(goneKind, .dismissed,
                       "a tombstone whose row was already gone gets a placeholder row, not silent loss")

        let dismissed = try await migrated.dismissedPodcastEpisodes().map(\.episodeID).sorted { $0.rawValue < $1.rawValue }
        XCTAssertEqual(dismissed, [dismissedWithSurvivingRow.itemID, goneEpisodeID].sorted { $0.rawValue < $1.rawValue })

        let second = try await migrated.reconcileEpisodeRemovals()
        XCTAssertEqual(second.backfilledRetirementCount, 0, "a second run finds nothing left to backfill")
        XCTAssertEqual(second.convertedDismissalCount, 0, "the tombstones are gone after the first run")
        retiredKind = try await migrated.removalKind(for: retiredEpisode.itemID)
        dismissedKind = try await migrated.removalKind(for: dismissedWithSurvivingRow.itemID)
        goneKind = try await migrated.removalKind(for: goneEpisodeID)
        XCTAssertEqual(retiredKind, .retired)
        XCTAssertEqual(dismissedKind, .dismissed)
        XCTAssertEqual(goneKind, .dismissed)
    }

    /// A retired episode and a dismissed one both come back through the same
    /// store operation.
    func testRestoreEpisodeReversesBothRetirementAndDismissalThroughOneOperation() async throws {
        let url = makeURL(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let origin = Date(timeIntervalSince1970: 1_700_005_000)
        let feedURL = URL(string: "https://podcasts.example.test/v13-restore/feed.xml")!
        let (feed, all) = try episodes(feedURL: feedURL, origin: origin, daysAgo: [1, 2])
        let retiredEpisode = all[0]
        let dismissedEpisode = all[1]
        let store = try LocalLibraryStore(url: url)
        try await store.save(feed: feed)
        try await store.save(subscription: PodcastSubscription(feedID: feed.itemID, subscribedAt: Timestamp(origin)))
        try await store.savePodcastEpisodes(all, admission: .backfill)
        _ = try await store.retireEpisode(retiredEpisode.itemID, at: Timestamp(origin))
        try await store.dismissPodcastEpisode(dismissedEpisode.itemID, at: Timestamp(origin))

        let restoredRetired = try await store.restoreEpisode(retiredEpisode.itemID)
        let restoredDismissed = try await store.restoreEpisode(dismissedEpisode.itemID)
        XCTAssertTrue(restoredRetired)
        XCTAssertTrue(restoredDismissed)

        let retiredKindAfter = try await store.removalKind(for: retiredEpisode.itemID)
        let dismissedKindAfter = try await store.removalKind(for: dismissedEpisode.itemID)
        let retiredAtAfterRetired = try await store.retiredAt(for: retiredEpisode.itemID)
        let retiredAtAfterDismissed = try await store.retiredAt(for: dismissedEpisode.itemID)
        XCTAssertNil(retiredKindAfter)
        XCTAssertNil(dismissedKindAfter)
        XCTAssertNil(retiredAtAfterRetired)
        XCTAssertNil(retiredAtAfterDismissed)
    }
}
