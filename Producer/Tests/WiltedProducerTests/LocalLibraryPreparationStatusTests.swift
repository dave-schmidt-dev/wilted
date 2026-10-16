import Foundation
import CryptoKit
import XCTest
import WiltedDomain
@testable import WiltedProducer

private final class PreparationPublicationReads: @unchecked Sendable {
    private let lock = NSLock()
    private var calls: [String: Int] = [:]
    private var rows: [String: Int] = [:]

    func record(_ kind: String, rows count: Int) {
        lock.lock(); defer { lock.unlock() }
        calls[kind, default: 0] += 1
        rows[kind, default: 0] += count
    }

    func count(_ kind: String) -> Int {
        lock.lock(); defer { lock.unlock() }
        return calls[kind, default: 0]
    }

    func rowsRead(_ kind: String) -> Int {
        lock.lock(); defer { lock.unlock() }
        return rows[kind, default: 0]
    }
}

extension LocalLibraryStoreTests {
    func testCurrentPreparationStatusUsesOnlyExactCurrentGenerationAndLeavesPublicationHistoryEmpty() async throws {
        let url = makeURL(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = try LocalLibraryStore(url: url)
        let (_, episode) = try podcastValues()
        let now = Timestamp(Date())
        let ticket = try await store.readmitWorkTicket(kind: .podcastPreparation, subjectID: episode.itemID.rawValue,
            requestSequence: 17, to: .running, at: now)
        let attempt = try PreparationAttemptIdentity(requestSequence: ticket.requestSequence, attemptCount: ticket.attemptCount)
        let request = PodcastPreparationPipeline.requestID(for: episode.itemID)
        for ordinal in 1...300 {
            let status = try PreparationStatus(stage: .extracting, detail: "Private /path", fraction: 0.4,
                cancellable: true, emittedAt: Timestamp(Date(timeIntervalSince1970: Double(ordinal))), attempt: attempt)
            try await store.record(preparation: .init(id: request + "|" + attempt.key + "|extracting#\(ordinal)",
                itemID: episode.itemID, requestID: request, status: status))
        }
        let entries = try await store.preparationJournal(for: request, attempt: attempt)
        XCTAssertEqual(entries.count, 256)
        let current = try await store.currentPreparationStatuses(for: [episode.itemID])
        XCTAssertEqual(current[episode.itemID]?.status?.attempt, attempt)
        XCTAssertEqual(current[episode.itemID]?.status?.fraction, 0.4)
        let other = try ItemID(rawValue: "item-unrelated-exact")
        let absent = try await store.currentPreparationStatuses(for: [other])
        XCTAssertTrue(absent.isEmpty)
        let publication = try await store.podcastLibrarySnapshot(profile: .publication)
        XCTAssertTrue(publication.preparationRuns.isEmpty)
        _ = try await store.finishPreparationAttempt(subjectID: episode.itemID.rawValue, attempt: attempt,
            state: .succeeded, at: now)
        let unproven = try await store.currentPreparationStatuses(for: [episode.itemID])
        XCTAssertEqual(unproven[episode.itemID]?.state, .succeeded,
                       "A ticket alone cannot clear status without current Ready/outcome proof")
    }

    func testQueuedDeferredFailedAndCancelledTicketsAreReconciledWithoutLegacyJournalIdentity() async throws {
        let url = makeURL(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = try LocalLibraryStore(url: url)
        let (_, episode) = try podcastValues()
        let now = Timestamp(Date())
        for (index, state) in [WorkTicketState.pending, .deferred, .failed, .cancelled].enumerated() {
            _ = try await store.readmitWorkTicket(kind: .podcastPreparation, subjectID: episode.itemID.rawValue,
                requestSequence: index + 1, to: state, at: now)
            let values = try await store.currentPreparationStatuses(for: [episode.itemID])
            XCTAssertEqual(values[episode.itemID]?.state, state)
            XCTAssertNil(values[episode.itemID]?.status)
        }
    }
}

extension LocalLibraryStoreTests {
    func testSuccessClearingRequiresBoundTerminalReadyAndCurrentOutcomeWhileNewFailureWins() async throws {
        let url = makeURL(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = try LocalLibraryStore(url: url)
        let (_, episode) = try podcastValues()
        let now = Timestamp(Date())
        let ticket = try await store.readmitWorkTicket(kind: .podcastPreparation, subjectID: episode.itemID.rawValue,
            requestSequence: 1, to: .running, at: now)
        let attempt = try PreparationAttemptIdentity(requestSequence: ticket.requestSequence, attemptCount: ticket.attemptCount)
        let requestID = PodcastPreparationPipeline.requestID(for: episode.itemID)
        let terminalID = requestID + "|" + attempt.key + "|terminal"
        let revisionID = try RevisionID(rawValue: "success-proof-revision")
        let terminal = try PreparationTerminalResult(outcome: .succeeded, revisionID: revisionID)
        // A legacy status cannot acquire identity merely by occupying a generation-looking ID.
        try await store.record(preparation: .init(id: terminalID, itemID: episode.itemID, requestID: requestID,
            status: PreparationStatus(stage: .completed, detail: "legacy", cancellable: false,
                terminalResult: terminal, emittedAt: now)))
        let legacy = try await store.currentPreparationStatuses(for: [episode.itemID])
        XCTAssertNil(legacy[episode.itemID]?.status)
        try await store.record(preparation: .init(id: terminalID, itemID: episode.itemID, requestID: requestID,
            status: PreparationStatus(stage: .completed, detail: "bound", cancellable: false,
                terminalResult: terminal, emittedAt: now, attempt: attempt)))
        let missingReady = try await store.currentPreparationStatuses(for: [episode.itemID])
        XCTAssertNotNil(missingReady[episode.itemID])
        let media = url.deletingLastPathComponent().appendingPathComponent("proof.mp3")
        let bytes = Data("proof bytes".utf8); try bytes.write(to: media)
        let revision = try AudioRevision(itemID: episode.itemID, revisionID: revisionID, durationSeconds: 2,
            byteCount: Int64(bytes.count), contentHash: "sha256:" + String(repeating: "a", count: 64),
            mediaType: "audio/mpeg", createdAt: now, schemaVersion: 3)
        try await store.saveReadyRevision(revision, mediaURL: media)
        let missingOutcome = try await store.currentPreparationStatuses(for: [episode.itemID])
        XCTAssertNotNil(missingOutcome[episode.itemID])
        let invalidOutcome = PodcastPreparationOutcome(episodeID: episode.itemID, revisionID: revisionID,
            policyDigest: "fixture", pipelineFingerprint: "fixture", semanticVersion: "v1", producedAt: now,
            eligibility: .invalid, invalidationRuleID: "fixture-rule")
        try await store.savePreparationOutcome(invalidOutcome)
        let invalid = try await store.currentPreparationStatuses(for: [episode.itemID])
        XCTAssertNotNil(invalid[episode.itemID])
        try await store.savePreparationOutcome(PodcastPreparationOutcome(episodeID: episode.itemID, revisionID: revisionID,
            policyDigest: "fixture", pipelineFingerprint: "fixture", semanticVersion: "v1", producedAt: now))
        let proven = try await store.currentPreparationStatuses(for: [episode.itemID])
        XCTAssertTrue(proven.isEmpty)
        let newer = try await store.readmitWorkTicket(kind: .podcastPreparation, subjectID: episode.itemID.rawValue,
            requestSequence: 2, to: .running, at: now)
        let newerAttempt = try PreparationAttemptIdentity(requestSequence: newer.requestSequence, attemptCount: newer.attemptCount)
        let failure = try PreparationStatus(stage: .failed, detail: "new failure", cancellable: false,
            terminalResult: PreparationTerminalResult(outcome: .failed,
                error: ProducerError(code: .failed, message: "failed", retryable: true)),
            emittedAt: now, attempt: newerAttempt)
        try await store.record(preparation: .init(id: requestID + "|" + newerAttempt.key + "|terminal",
            itemID: episode.itemID, requestID: requestID, status: failure))
        _ = try await store.finishPreparationAttempt(subjectID: episode.itemID.rawValue, attempt: newerAttempt,
            state: .failed, at: now)
        let current = try await store.currentPreparationStatuses(for: [episode.itemID])
        XCTAssertEqual(current[episode.itemID]?.state, .failed)
        XCTAssertEqual(current[episode.itemID]?.status?.attempt, newerAttempt)
        XCTAssertEqual(try Data(contentsOf: media), bytes)
    }
}

extension LocalLibraryStoreTests {
    func testScaledPublicationBatchesRelevantTicketsAndNeverReadsJournalsForEmptyKeptItems() async throws {
        let url = makeURL(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = try LocalLibraryStore(url: url)
        let ids = try (0..<1_501).map { try ItemID(rawValue: "kept-publication-\($0)") }
        let excluded = try ItemID(rawValue: "excluded-preparation")
        let now = Timestamp(Date())
        _ = try await store.readmitWorkTicket(kind: .podcastPreparation, subjectID: excluded.rawValue,
            requestSequence: 1, to: .running, at: now)
        _ = try await store.readmitWorkTicket(kind: .podcastDownload, subjectID: ids[0].rawValue,
            requestSequence: 2, to: .running, at: now)
        let emptyReads = PreparationPublicationReads()
        let empty = try await LocalLibraryStore.$preparationPublicationReadObserver.withValue({ kind, rows in
            emptyReads.record(kind, rows: rows)
        }) { try await store.currentPreparationStatuses(for: ids) }
        XCTAssertTrue(empty.isEmpty)
        XCTAssertEqual(emptyReads.count("tickets"), 1)
        XCTAssertEqual(emptyReads.rowsRead("tickets"), 1, "One kind-only batch; excluded subjects are filtered before journal reads")
        XCTAssertEqual(emptyReads.count("journal"), 0)
        XCTAssertEqual(emptyReads.count("ready"), 0)

        let current = try await store.readmitWorkTicket(kind: .podcastPreparation, subjectID: ids[0].rawValue,
            requestSequence: 3, to: .running, at: now)
        let attempt = try PreparationAttemptIdentity(requestSequence: current.requestSequence, attemptCount: current.attemptCount)
        let requestID = PodcastPreparationPipeline.requestID(for: ids[0])
        let status = try PreparationStatus(stage: .extracting, detail: "Working", cancellable: true,
            emittedAt: now, attempt: attempt)
        try await store.record(preparation: .init(id: requestID + "|" + attempt.key + "|extracting#1",
            itemID: ids[0], requestID: requestID, status: status))
        let activeReads = PreparationPublicationReads()
        let active = try await LocalLibraryStore.$preparationPublicationReadObserver.withValue({ kind, rows in
            activeReads.record(kind, rows: rows)
        }) { try await store.currentPreparationStatuses(for: ids) }
        XCTAssertEqual(Set(active.keys), [ids[0]])
        XCTAssertEqual(activeReads.count("tickets"), 1)
        XCTAssertEqual(activeReads.rowsRead("tickets"), 2)
        XCTAssertEqual(activeReads.count("journal"), 1)
        XCTAssertEqual(activeReads.rowsRead("journal"), 1)
        XCTAssertEqual(activeReads.count("ready"), 0)
    }
}

extension LocalLibraryStoreTests {
    func testUpgradeSucceededTicketWithLegacyOrEmptyJournalUsesExistingReadyOutcomeWithoutCertifyingNewMedia() async throws {
        let url = makeURL(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = try LocalLibraryStore(url: url)
        let (_, episode) = try podcastValues()
        let now = Timestamp(Date())
        let media = url.deletingLastPathComponent().appendingPathComponent("upgrade-ready.mp3")
        let bytes = Data("retained upgrade audio".utf8); try bytes.write(to: media)
        let revision = try AudioRevision(itemID: episode.itemID, revisionID: RevisionID(rawValue: "upgrade-ready"),
            durationSeconds: 3, byteCount: Int64(bytes.count), contentHash: "sha256:" + SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined(),
            mediaType: "audio/mpeg", createdAt: now, schemaVersion: 3)
        try await store.saveReadyRevision(revision, mediaURL: media,
            transcript: Transcript(itemID: episode.itemID, revisionID: revision.revisionID, availability: .available,
                text: "Retained", updatedAt: now),
            outcome: PodcastPreparationOutcome(episodeID: episode.itemID, revisionID: revision.revisionID,
                policyDigest: "legacy", pipelineFingerprint: "legacy", semanticVersion: "v1", producedAt: now))
        _ = try await store.readmitWorkTicket(kind: .podcastPreparation, subjectID: episode.itemID.rawValue,
            requestSequence: 1, to: .succeeded, at: now)
        let emptyJournal = try await store.currentPreparationStatuses(for: [episode.itemID])
        XCTAssertTrue(emptyJournal.isEmpty)
        let requestID = PodcastPreparationPipeline.requestID(for: episode.itemID)
        let legacy = try PreparationStatus(stage: .completed, detail: "legacy", cancellable: false,
            terminalResult: PreparationTerminalResult(outcome: .succeeded, revisionID: revision.revisionID), emittedAt: now)
        try await store.record(preparation: .init(id: requestID + "|terminal", itemID: episode.itemID,
            requestID: requestID, status: legacy))
        let legacyJournal = try await store.currentPreparationStatuses(for: [episode.itemID])
        XCTAssertTrue(legacyJournal.isEmpty)
        let recoveredTicket = try await store.readmitWorkTicket(kind: .podcastPreparation, subjectID: episode.itemID.rawValue,
            requestSequence: 2, to: .running, at: now)
        let recoveredAttempt = try PreparationAttemptIdentity(requestSequence: recoveredTicket.requestSequence,
            attemptCount: recoveredTicket.attemptCount)
        let nonterminal = try PreparationStatus(stage: .saving, detail: "output saved; terminal write lost",
            cancellable: true, emittedAt: now, attempt: recoveredAttempt)
        try await store.record(preparation: .init(id: requestID + "|" + recoveredAttempt.key + "|saving#1",
            itemID: episode.itemID, requestID: requestID, status: nonterminal))
        let stillRunning = try await store.currentPreparationStatuses(for: [episode.itemID])
        XCTAssertNotNil(stillRunning[episode.itemID], "Running work still requires its own successful terminal proof")
        _ = try await store.finishPreparationAttempt(subjectID: episode.itemID.rawValue, attempt: recoveredAttempt,
            state: .succeeded, at: now)
        let reconciled = try await store.currentPreparationStatuses(for: [episode.itemID])
        XCTAssertTrue(reconciled.isEmpty, "Succeeded ticket plus existing Ready/current outcome clears a lost terminal annotation")
        let ticket = try await store.readmitWorkTicket(kind: .podcastPreparation, subjectID: episode.itemID.rawValue,
            requestSequence: 3, to: .running, at: now)
        let attempt = try PreparationAttemptIdentity(requestSequence: ticket.requestSequence, attemptCount: ticket.attemptCount)
        let mismatch = try PreparationStatus(stage: .completed, detail: "mismatch", cancellable: false,
            terminalResult: PreparationTerminalResult(outcome: .succeeded, revisionID: RevisionID(rawValue: "different-ready")),
            emittedAt: now, attempt: attempt)
        try await store.record(preparation: .init(id: requestID + "|" + attempt.key + "|terminal", itemID: episode.itemID,
            requestID: requestID, status: mismatch))
        _ = try await store.finishPreparationAttempt(subjectID: episode.itemID.rawValue, attempt: attempt, state: .succeeded, at: now)
        let refused = try await store.currentPreparationStatuses(for: [episode.itemID])
        XCTAssertNotNil(refused[episode.itemID], "An explicit bound revision mismatch is not an upgrade absence")
        let readyAfter = try await store.readyRevision(for: episode.itemID)
        XCTAssertEqual(readyAfter?.revisionID, revision.revisionID)
        XCTAssertEqual(try Data(contentsOf: media), bytes)
    }
}

extension LocalLibraryStoreTests {
    func testHistoricalRestartClosureIsAppendOnlyAndCannotOverwriteCompletedGenerationOrCurrentTicket() async throws {
        let url = makeURL(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = try LocalLibraryStore(url: url)
        let (_, episode) = try podcastValues()
        let now = Timestamp(Date(timeIntervalSince1970: 1_700_000_000))
        let requestID = PodcastPreparationPipeline.requestID(for: episode.itemID)
        var staleSnapshots: [PreparationRunSummary] = []
        for sequence in 1...2 {
            let ticket = try await store.readmitWorkTicket(kind: .podcastPreparation, subjectID: episode.itemID.rawValue,
                requestSequence: sequence, to: .running, at: now)
            let attempt = try PreparationAttemptIdentity(requestSequence: ticket.requestSequence, attemptCount: ticket.attemptCount)
            let active = try PreparationStatus(stage: .extracting, detail: "active", cancellable: true,
                emittedAt: now, attempt: attempt)
            try await store.record(preparation: .init(id: requestID + "|" + attempt.key + "|extracting#1",
                itemID: episode.itemID, requestID: requestID, status: active))
            let snapshot = try await store.preparationRuns().first { $0.entries.first?.status.attempt == attempt }
            staleSnapshots.append(try XCTUnwrap(snapshot))
            if sequence == 1 {
                let success = try PreparationStatus(stage: .completed, detail: "completed", cancellable: false,
                    terminalResult: PreparationTerminalResult(outcome: .succeeded, revisionID: RevisionID(rawValue: "retained-ready")),
                    emittedAt: Timestamp(now.date.addingTimeInterval(1)), attempt: attempt)
                try await store.record(preparation: .init(id: requestID + "|" + attempt.key + "|terminal",
                    itemID: episode.itemID, requestID: requestID, status: success))
            }
        }
        let current = try await store.readmitWorkTicket(kind: .podcastPreparation, subjectID: episode.itemID.rawValue,
            requestSequence: 3, to: .running, at: now)
        let refused = try await store.closeInactivePreparationRun(staleSnapshots[0], at: now, detail: "Interrupted")
        XCTAssertFalse(refused, "A stale nonterminal snapshot cannot append over completed journal evidence")
        let closed = try await store.closeInactivePreparationRun(staleSnapshots[1],
            at: Timestamp(now.date.addingTimeInterval(-100)), detail: "Interrupted")
        XCTAssertTrue(closed)
        let duplicate = try await store.closeInactivePreparationRun(staleSnapshots[1], at: now, detail: "Interrupted")
        XCTAssertFalse(duplicate)
        let ticketAfter = try await store.workTicket(kind: .podcastPreparation, subjectID: episode.itemID.rawValue)
        XCTAssertEqual(ticketAfter, current)
        let runs = try await store.preparationRuns()
        XCTAssertEqual(runs.first { $0.entries.first?.status.attempt?.requestSequence == 1 }?.outcome, .succeeded)
        let historical = try XCTUnwrap(runs.first { $0.entries.first?.status.attempt?.requestSequence == 2 })
        XCTAssertEqual(historical.outcome, .failed)
        XCTAssertEqual(historical.entries.count, 2)
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(historical.entries.last?.status.emittedAt), now)
    }
}

extension LocalLibraryStoreTests {
    func testInactiveCurrentTicketCanCloseInterruptedJournalWithoutChangingItsTerminalState() async throws {
        let url = makeURL(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = try LocalLibraryStore(url: url)
        let (_, episode) = try podcastValues()
        let now = Timestamp(Date(timeIntervalSince1970: 1_700_000_000))
        let ticket = try await store.readmitWorkTicket(kind: .podcastPreparation, subjectID: episode.itemID.rawValue,
            requestSequence: 1, to: .running, at: now)
        let attempt = try PreparationAttemptIdentity(requestSequence: ticket.requestSequence, attemptCount: ticket.attemptCount)
        let requestID = PodcastPreparationPipeline.requestID(for: episode.itemID)
        let active = try PreparationStatus(stage: .extracting, detail: "journal save interrupted", cancellable: true,
            emittedAt: now, attempt: attempt)
        try await store.record(preparation: .init(id: requestID + "|" + attempt.key + "|extracting#1",
            itemID: episode.itemID, requestID: requestID, status: active))
        let beforeRuns = try await store.preparationRuns()
        let run = try XCTUnwrap(beforeRuns.first)
        let terminalTicket = try await store.finishPreparationAttempt(subjectID: episode.itemID.rawValue,
            attempt: attempt, state: .cancelled, at: now)
        let closed = try await store.closeInactivePreparationRun(run,
            at: Timestamp(now.date.addingTimeInterval(-100)), detail: "Interrupted")
        XCTAssertTrue(closed)
        let after = try await store.workTicket(kind: .podcastPreparation, subjectID: episode.itemID.rawValue)
        XCTAssertEqual(after, terminalTicket)
        let runs = try await store.preparationRuns()
        XCTAssertEqual(runs.count, 1)
        XCTAssertTrue(try XCTUnwrap(runs.first).isTerminal)
        let duplicate = try await store.closeInactivePreparationRun(run, at: now, detail: "Interrupted")
        XCTAssertFalse(duplicate)
    }
}
