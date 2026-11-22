import Foundation
import SwiftData
import XCTest
import WiltedDomain
@testable import WiltedProducer

extension LocalLibraryStoreTests {
    func makeRetentionRun(
        itemID: ItemID, requestID: String, sequence: Int,
        outcome: PreparationOutcome?, revisionID: RevisionID? = nil, evidence: PreparationEvidence? = nil
    ) throws -> PreparationRunSummary {
        let attempt = try PreparationAttemptIdentity(requestSequence: sequence, attemptCount: 1)
        let prefix = requestID + "|" + attempt.key + "|"
        let base = Date(timeIntervalSince1970: 1_700_000_000 + Double(sequence * 10))
        var entries = [PreparationJournalEntry(id: prefix + "pipeline.start#1", itemID: itemID,
            requestID: requestID, status: try PreparationStatus(stage: .preparing, detail: "start",
                cancellable: true, emittedAt: Timestamp(base), evidence: evidence, attempt: attempt))]
        entries.append(PreparationJournalEntry(id: prefix + "extracting#heartbeat", itemID: itemID,
            requestID: requestID, status: try PreparationStatus(stage: .extracting, detail: "heartbeat",
                cancellable: true, emittedAt: Timestamp(base.addingTimeInterval(1)), attempt: attempt)))
        var terminalResult: PreparationTerminalResult?
        if let outcome {
            let error = outcome == .failed
                ? try ProducerError(code: .failed, message: "failed", retryable: true) : nil
            terminalResult = try PreparationTerminalResult(
                outcome: outcome, revisionID: revisionID, error: error)
            let stage: PreparationStage = outcome == .succeeded ? .completed : .failed
            entries.append(PreparationJournalEntry(id: prefix + "terminal", itemID: itemID,
                requestID: requestID, status: try PreparationStatus(stage: stage, detail: "terminal",
                    cancellable: false, terminalResult: terminalResult,
                    emittedAt: Timestamp(base.addingTimeInterval(2)), attempt: attempt)))
        }
        let stage: PreparationStage = outcome == .succeeded ? .completed : (outcome == .failed ? .failed : .preparing)
        return PreparationRunSummary(requestID: requestID, itemID: itemID,
            startedAt: Timestamp(base), updatedAt: Timestamp(base.addingTimeInterval(outcome == nil ? 1 : 2)),
            stage: stage, detail: "retention fixture", fraction: nil,
            isTerminal: outcome != nil, outcome: outcome, failure: terminalResult?.error, entries: entries)
    }

    func testPreparationRetentionPolicySelectsOnlyEligibleOldRows() throws {
        let itemID = try podcastValues().1.itemID
        let requestID = PodcastPreparationPipeline.requestID(for: itemID)
        var runs = try (1...8).map { try makeRetentionRun(itemID: itemID, requestID: requestID,
            sequence: $0, outcome: .failed) }
        runs.append(try makeRetentionRun(itemID: itemID, requestID: requestID,
            sequence: 9, outcome: nil))

        let ticket = try PreparationAttemptIdentity(requestSequence: 2, attemptCount: 1)
        let removals = LocalLibraryStore.prunablePreparationIDs(in: runs.reversed(),
            hasReadyRevision: false, currentRevision: nil, ticket: ticket)

        for sequence in [1, 3, 4, 5] {
            let prefix = requestID + "|generation-\(sequence)-1|"
            XCTAssertTrue(removals.contains(prefix + "pipeline.start#1"))
            XCTAssertTrue(removals.contains(prefix + "extracting#heartbeat"))
            XCTAssertTrue(removals.contains(prefix + "terminal"))
        }
        let protectedPrefixes = [2, 9].map { requestID + "|generation-\($0)-1|" }
        XCTAssertFalse(removals.contains { id in protectedPrefixes.contains(where: id.hasPrefix) })
        for sequence in 6...8 {
            let prefix = requestID + "|generation-\(sequence)-1|"
            XCTAssertFalse(removals.contains(prefix + "pipeline.start#1"))
            XCTAssertFalse(removals.contains(prefix + "terminal"))
            XCTAssertTrue(removals.contains(requestID + "|generation-\(sequence)-1|extracting#heartbeat"))
        }
        XCTAssertEqual(removals.count, 4 * 3 + 3)
    }

    func testPreparationRetentionPolicyKeepsReadyAndNewerGenerations() throws {
        let itemID = try podcastValues().1.itemID
        let requestID = PodcastPreparationPipeline.requestID(for: itemID)
        let ready = try RevisionID(rawValue: "proven-ready")
        let runs = try (1...12).map { sequence in
            try makeRetentionRun(itemID: itemID, requestID: requestID, sequence: sequence,
                outcome: sequence == 4 ? .succeeded : .failed, revisionID: sequence == 4 ? ready : nil)
        }
        let removals = LocalLibraryStore.prunablePreparationIDs(
            in: runs, hasReadyRevision: true, currentRevision: ready, ticket: nil)
        let older = runs.prefix(3).flatMap { $0.entries.map(\.id) }
        let heartbeats = runs[4..<11].flatMap { $0.entries.map(\.id).filter { $0.hasSuffix("#heartbeat") } }
        XCTAssertEqual(removals, Set(older + heartbeats))
    }

    func addRetentionHistory(
        to fixture: PreparationHistoryFixture, olderFailedGenerationCount: Int, newerFailedGenerationCount: Int
    ) async throws -> (
        readyAttempt: PreparationAttemptIdentity, openAttempt: PreparationAttemptIdentity, newestAttempt: PreparationAttemptIdentity
    ) {
        let context = ModelContext(fixture.store.container)
        let readySequence = olderFailedGenerationCount + 1
        let openSequence = readySequence + 1
        let newestSequence = openSequence + newerFailedGenerationCount + 1
        let evidence = try PreparationEvidence(kind: LocalLibraryStore.pipelineProvenanceEvidenceKind, fields: [
            "fingerprint": "ready-pipeline", "sourceRevisionID": fixture.revision.revisionID.rawValue,
            "sourceHash": fixture.hash
        ])
        for sequence in 1...newestSequence {
            let isReady = sequence == readySequence
            let outcome: PreparationOutcome? = isReady ? .succeeded : (sequence == openSequence ? nil : .failed)
            let run = try makeRetentionRun(itemID: fixture.itemID, requestID: fixture.requestID,
                sequence: sequence, outcome: outcome, revisionID: isReady ? fixture.revision.revisionID : nil,
                evidence: isReady ? evidence : nil)
            for entry in run.entries { context.insert(try LocalLibrarySchemaV3Models.PreparationRecord(entry)) }
        }
        try context.save()
        _ = try await fixture.store.readmitWorkTicket(kind: .podcastPreparation, subjectID: fixture.itemID.rawValue,
            requestSequence: newestSequence, to: .running, at: Timestamp(fixture.base.addingTimeInterval(10 * Double(newestSequence))))
        return try (PreparationAttemptIdentity(requestSequence: readySequence, attemptCount: 1),
                    PreparationAttemptIdentity(requestSequence: openSequence, attemptCount: 1),
                    PreparationAttemptIdentity(requestSequence: newestSequence, attemptCount: 1))
    }

    func preparationHistoryIDs(in fixture: PreparationHistoryFixture) throws -> Set<String> {
        Set(try ModelContext(fixture.store.container)
            .fetch(FetchDescriptor<LocalLibrarySchemaV3Models.PreparationRecord>())
            .map(\.id))
    }

    func testPreparationRetentionPrunesOldFailedGenerationsAndKeepsProtectedRows() async throws {
        let fixture = try await makePreparationHistoryStore("retention-protected")
        defer { try? FileManager.default.removeItem(at: fixture.url.deletingLastPathComponent()) }
        let attempts = try await addRetentionHistory(to: fixture,
            olderFailedGenerationCount: 5, newerFailedGenerationCount: 3)

        let forcedRequestID = LocalLibraryStore.forcedRedownloadRequestPrefix + fixture.itemID.rawValue
        let resetRequestID = LocalLibraryStore.resetPreparationRequestPrefix + fixture.itemID.rawValue
        let markerError = try ProducerError(code: .failed, message: "marker", retryable: true)
        let markerResult = try PreparationTerminalResult(outcome: .failed, error: markerError)
        let context = ModelContext(fixture.store.container)
        try insertPreparation(context, id: forcedRequestID + "|marker", itemID: fixture.itemID,
            requestID: forcedRequestID, stage: .failed, at: fixture.base, attempt: nil, terminal: markerResult)
        try insertPreparation(context, id: resetRequestID + "|marker", itemID: fixture.itemID,
            requestID: resetRequestID, stage: .preparing, at: fixture.base, attempt: nil)
        try context.save()

        let before = try preparationHistoryIDs(in: fixture)
        let runs = try await fixture.store.prunePreparationHistoryAndFetchOpenRuns()
        let after = try preparationHistoryIDs(in: fixture)
        let readyPrefix = fixture.requestID + "|" + attempts.readyAttempt.key + "|"
        XCTAssertTrue(after.contains(readyPrefix + "terminal"))
        XCTAssertTrue(after.contains(readyPrefix + "extracting#heartbeat"))

        let openPrefix = fixture.requestID + "|" + attempts.openAttempt.key + "|"
        XCTAssertTrue(after.contains(openPrefix + "pipeline.start#1"), "older non-terminal attempts remain open")
        XCTAssertTrue(after.contains(openPrefix + "extracting#heartbeat"))
        let newestPrefix = fixture.requestID + "|" + attempts.newestAttempt.key + "|"
        XCTAssertTrue(after.contains(newestPrefix + "pipeline.start#1"), "the ticket generation survives")
        XCTAssertTrue(after.contains(newestPrefix + "extracting#heartbeat"))
        XCTAssertTrue(after.contains(newestPrefix + "terminal"), "the newest terminal generation survives")
        XCTAssertTrue(runs.contains { $0.entries.first?.status.attempt == attempts.openAttempt })

        for sequence in 1...5 {
            let prefix = fixture.requestID + "|generation-\(sequence)-1|"
            XCTAssertFalse(after.contains { $0.hasPrefix(prefix) }, "old failed generation \(sequence) is pruned whole")
        }
        for sequence in 9...10 {
            let prefix = fixture.requestID + "|generation-\(sequence)-1|"
            XCTAssertTrue(after.contains(prefix + "pipeline.start#1"), "the newest failed attempts remain")
            XCTAssertTrue(after.contains(prefix + "terminal"))
            XCTAssertFalse(after.contains(prefix + "extracting#heartbeat"), "unprotected terminal heartbeats are pruned")
        }
        XCTAssertTrue(after.contains(fixture.requestID + "|generation-8-1|pipeline.start#1"),
            "a newer-than-proof candidate is retained even past the failure count")
        XCTAssertTrue(after.contains(fixture.requestID + "|generation-11-1|extracting#heartbeat"),
            "the newest terminal generation keeps its heartbeat")
        XCTAssertTrue(after.contains(forcedRequestID + "|marker"))
        XCTAssertTrue(after.contains(resetRequestID + "|marker"))
        XCTAssertNotEqual(before, after)

        _ = try await fixture.store.prunePreparationHistoryAndFetchOpenRuns()
        XCTAssertEqual(try preparationHistoryIDs(in: fixture), after, "a second pass deletes nothing")
    }

    func testPreparationRetentionKeepsLegacyRowsWhenTheReadyProofIsUnbound() async throws {
        let fixture = try await makePreparationHistoryStore("retention-legacy")
        defer { try? FileManager.default.removeItem(at: fixture.url.deletingLastPathComponent()) }
        _ = try await addRetentionHistory(to: fixture,
            olderFailedGenerationCount: 0, newerFailedGenerationCount: 8)
        // The Ready proof is a legacy success carrying no generation: found, but unbound.
        let result = try PreparationTerminalResult(outcome: .succeeded, revisionID: fixture.revision.revisionID)
        let context = ModelContext(fixture.store.container)
        try insertPreparation(context, id: fixture.requestID + "|extracting#1", itemID: fixture.itemID,
            requestID: fixture.requestID, stage: .extracting, at: fixture.base, attempt: nil)
        try insertPreparation(context, id: fixture.requestID + "|terminal", itemID: fixture.itemID,
            requestID: fixture.requestID, stage: .completed, at: fixture.base.addingTimeInterval(1),
            attempt: nil, terminal: result)
        let readyPrefix = fixture.requestID + "|generation-1-1|"
        for row in try context.fetch(FetchDescriptor<LocalLibrarySchemaV3Models.PreparationRecord>(
            predicate: #Predicate { $0.id.starts(with: readyPrefix) })) {
            context.delete(row)
        }
        try context.save()

        let before = try preparationHistoryIDs(in: fixture)
        _ = try await fixture.store.prunePreparationHistoryAndFetchOpenRuns()
        let after = try preparationHistoryIDs(in: fixture)
        XCTAssertTrue(after.contains(fixture.requestID + "|extracting#1"))
        XCTAssertTrue(after.contains(fixture.requestID + "|terminal"))
        // The legacy success is the oldest run and the proof, so every bound failure is newer than it:
        // each keeps its start and terminal rows and only its heartbeat is pruned. (With no proof found
        // at all, nothing is pruned: see the fail-closed tests.)
        XCTAssertTrue(after.contains(fixture.requestID + "|generation-3-1|terminal"))
        XCTAssertFalse(after.contains(fixture.requestID + "|generation-3-1|extracting#heartbeat"))
        XCTAssertNotEqual(after, before)
    }

    func testPreparationRetentionReadCountIsFlatWhenHistoryDoubles() async throws {
        var readCounts: [Int] = []
        for depth in [80, 160] {
            let fixture = try await makePreparationHistoryStore("retention-depth-\(depth)")
            defer { try? FileManager.default.removeItem(at: fixture.url.deletingLastPathComponent()) }
            _ = try await addRetentionHistory(to: fixture,
                olderFailedGenerationCount: depth, newerFailedGenerationCount: 3)
            let journalRows = try preparationHistoryRowCount(in: fixture.store.container,
                requestID: fixture.requestID)
            let before = await fixture.store.preparationMaintenanceRowsRead
            _ = try await fixture.store.invalidateStalePodcastPreparations(currentFingerprint: "ready-pipeline", rules: [])
            let afterInvalidation = await fixture.store.preparationMaintenanceRowsRead
            let decodeBefore = await fixture.store.preparationJournalDecodeAttemptCount
            _ = try await fixture.store.prunePreparationHistoryAndFetchOpenRuns()
            let after = await fixture.store.preparationMaintenanceRowsRead
            let decodeAfter = await fixture.store.preparationJournalDecodeAttemptCount
            XCTAssertGreaterThan(afterInvalidation, before)
            XCTAssertEqual(after, afterInvalidation, "retention adds no journal reads to the recovery snapshot")
            XCTAssertEqual(decodeAfter - decodeBefore, journalRows)
            readCounts.append(after - before)
        }
        XCTAssertEqual(readCounts[0], readCounts[1], "maintenance row reads do not scale with retained history depth")
    }
}
