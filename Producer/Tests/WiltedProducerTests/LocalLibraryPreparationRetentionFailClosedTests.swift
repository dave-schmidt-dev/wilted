import Foundation
import SwiftData
import XCTest
import WiltedDomain
@testable import WiltedProducer

/// Retention reads its protection from the journal, the newest revision, the current outcome and the
/// work ticket. When any of those cannot be read or validated for an episode, nothing is pruned for
/// that episode: a proof that cannot be seen must never look like no proof. Each test damages one
/// input on a history the existing test proves is otherwise pruned (5 old failures, an open run,
/// 3 newer failures and a newest run).
extension LocalLibraryStoreTests {
    private func prunesNothing(
        _ name: String, line: UInt = #line, damage: (PreparationHistoryFixture, ModelContext) throws -> Void
    ) async throws {
        let fixture = try await makePreparationHistoryStore(name)
        defer { try? FileManager.default.removeItem(at: fixture.url.deletingLastPathComponent()) }
        _ = try await addRetentionHistory(to: fixture, olderFailedGenerationCount: 5, newerFailedGenerationCount: 3)
        let context = ModelContext(fixture.store.container)
        try damage(fixture, context)
        try context.save()
        let before = try preparationHistoryIDs(in: fixture)
        _ = try await fixture.store.prunePreparationHistoryAndFetchOpenRuns()
        XCTAssertEqual(try preparationHistoryIDs(in: fixture), before, "nothing is pruned", line: line)
    }

    private func journalRow(
        _ id: String, in context: ModelContext
    ) throws -> LocalLibrarySchemaV3Models.PreparationRecord {
        try XCTUnwrap(try context.fetch(FetchDescriptor<LocalLibrarySchemaV3Models.PreparationRecord>(
            predicate: #Predicate { $0.id == id })).first)
    }

    func testRetentionPrunesNothingWhenTheReadyProofRowCannotBeDecoded() async throws {
        try await prunesNothing("retention-undecodable") { fixture, context in
            let row = try journalRow(fixture.requestID + "|generation-6-1|terminal", in: context)
            row.statusData = Data("not json".utf8)
        }
    }

    func testRetentionPrunesNothingWhenAJournalRowHasAnInvalidItemID() async throws {
        try await prunesNothing("retention-bad-item") { fixture, context in
            let row = try journalRow(fixture.requestID + "|generation-6-1|terminal", in: context)
            row.itemID = ""
        }
    }

    func testRetentionPrunesNothingWhenATerminalNamesADifferentGeneration() async throws {
        try await prunesNothing("retention-mismatch") { fixture, context in
            // Generation 10's terminal claims to close generation 7, which is open.
            let open = try PreparationAttemptIdentity(requestSequence: 7, attemptCount: 1)
            let result = try PreparationTerminalResult(
                outcome: .failed, error: ProducerError(code: .failed, message: "x", retryable: true))
            let status = try PreparationStatus(
                stage: .failed, detail: "terminal", cancellable: false, terminalResult: result,
                emittedAt: Timestamp(fixture.base.addingTimeInterval(500)), attempt: open)
            let row = try journalRow(fixture.requestID + "|generation-10-1|terminal", in: context)
            row.statusData = try JSONEncoder().encode(status)
        }
    }

    func testRetentionPrunesNothingWhenTheNewestRevisionCannotBeValidated() async throws {
        try await prunesNothing("retention-bad-revision") { fixture, context in
            let item = fixture.itemID.rawValue
            for row in try context.fetch(FetchDescriptor<LocalLibrarySchemaV3Models.RevisionRecord>())
            where row.itemID == item { row.byteCount = 0 }
        }
    }

    func testRetentionPrunesNothingWhenTheReadyRevisionHasNoCurrentOutcome() async throws {
        try await prunesNothing("retention-no-outcome") { _, context in
            for row in try context.fetch(
                FetchDescriptor<LocalLibrarySchemaV10Models.PodcastPreparationOutcomeRecord>()) {
                context.delete(row)
            }
        }
    }

    func testRetentionPrunesNothingWhenTheTicketIdentityIsInvalid() async throws {
        try await prunesNothing("retention-bad-ticket") { fixture, context in
            let item = fixture.itemID.rawValue
            for row in try context.fetch(FetchDescriptor<LocalLibrarySchemaV22Models.WorkTicketRecord>())
            where row.subjectID == item && row.kind == WorkTicketKind.podcastPreparation.rawValue {
                row.requestSequence = -3
            }
        }
    }

    func testRetentionPrunesNothingWhenARunningTicketHasNoAttempt() async throws {
        try await prunesNothing("retention-ticket-no-attempt") { fixture, context in
            let item = fixture.itemID.rawValue
            for row in try context.fetch(FetchDescriptor<LocalLibrarySchemaV22Models.WorkTicketRecord>())
            where row.subjectID == item && row.kind == WorkTicketKind.podcastPreparation.rawValue {
                row.attemptCount = 0
            }
        }
    }

    func testRetentionPrunesNothingWhenTheTicketDisagreesWithItsDurableKey() async throws {
        try await prunesNothing("retention-ticket-subject") { fixture, context in
            let item = fixture.itemID.rawValue
            for row in try context.fetch(FetchDescriptor<LocalLibrarySchemaV22Models.WorkTicketRecord>())
            where row.subjectID == item && row.kind == WorkTicketKind.podcastPreparation.rawValue {
                row.subjectID = "someone-else"
            }
        }
    }

    func testRetentionPrunesNothingWhenTheRevisionRowHasNoOwner() async throws {
        try await prunesNothing("retention-revision-owner-empty") { fixture, context in
            for row in try context.fetch(FetchDescriptor<LocalLibrarySchemaV3Models.RevisionRecord>())
            where row.itemID == fixture.itemID.rawValue { row.itemID = "" }
        }
    }

    func testRetentionPrunesNothingWhenTheRevisionRowBelongsToAnotherEpisode() async throws {
        try await prunesNothing("retention-revision-owner-other") { fixture, context in
            let other = try ItemID.derivePodcastEpisode(
                feedURL: URL(string: "https://feeds.example.test/other.xml")!, rssGUID: "other",
                enclosureURL: URL(string: "https://media.example.test/other.mp3")!)
            for row in try context.fetch(FetchDescriptor<LocalLibrarySchemaV3Models.RevisionRecord>())
            where row.itemID == fixture.itemID.rawValue { row.itemID = other.rawValue }
        }
    }

    // Pruning needs positive proof. An episode with a Ready revision is pruned only when the succeeded
    // run that produced it is found in its own history, whole and uncontradicted; one that looks
    // never-prepared is pruned only when no row anywhere shows it was prepared.

    func testRetentionPrunesNothingWhenTheReadyProofRunIsMissingFromTheJournal() async throws {
        try await prunesNothing("retention-proof-missing") { fixture, context in
            let prefix = fixture.requestID + "|generation-6-1|"
            for row in try context.fetch(FetchDescriptor<LocalLibrarySchemaV3Models.PreparationRecord>(
                predicate: #Predicate { $0.id.starts(with: prefix) })) { context.delete(row) }
            // Unbound legacy rows too: they are not exempt from an episode that is skipped whole.
            let failure = try PreparationTerminalResult(
                outcome: .failed, error: ProducerError(code: .failed, message: "legacy", retryable: true))
            try insertPreparation(context, id: fixture.requestID + "|extracting#1", itemID: fixture.itemID,
                requestID: fixture.requestID, stage: .extracting, at: fixture.base, attempt: nil)
            try insertPreparation(context, id: fixture.requestID + "|terminal", itemID: fixture.itemID,
                requestID: fixture.requestID, stage: .failed, at: fixture.base.addingTimeInterval(1),
                attempt: nil, terminal: failure)
        }
    }

    func testRetentionPrunesNothingWhenTheReadyTerminalLosesItsRequestID() async throws {
        try await prunesNothing("retention-proof-request-damaged") { fixture, context in
            let row = try journalRow(fixture.requestID + "|generation-6-1|terminal", in: context)
            row.requestID = "damaged-" + row.requestID
        }
    }

    func testRetentionPrunesNothingWhenALaterFailureContradictsTheReadySuccess() async throws {
        try await prunesNothing("retention-proof-contradicted") { fixture, context in
            let attempt = try PreparationAttemptIdentity(requestSequence: 6, attemptCount: 1)
            let failure = try PreparationTerminalResult(
                outcome: .failed, error: ProducerError(code: .failed, message: "late", retryable: true))
            try insertPreparation(
                context, id: fixture.requestID + "|generation-6-1|terminal-late", itemID: fixture.itemID,
                requestID: fixture.requestID, stage: .failed, at: fixture.base.addingTimeInterval(5_000),
                attempt: attempt, terminal: failure)
        }
    }

    func testRetentionPrunesNothingWhenTheCurrentOutcomeSurvivesButItsRevisionLostItsMedia() async throws {
        try await prunesNothing("retention-media-lost") { fixture, context in
            for row in try context.fetch(FetchDescriptor<LocalLibrarySchemaV3Models.RevisionRecord>())
            where row.itemID == fixture.itemID.rawValue { row.mediaURL = nil }
        }
    }

    /// The outcome's key names this episode and its Ready revision, but its fields consistently name
    /// another episode and that episode's own revision. Trusting the key would take it for this
    /// episode's current outcome.
    func testRetentionPrunesNothingWhenAnOutcomeKeyNamesThisEpisodeButItsFieldsNameAnother() async throws {
        try await prunesNothing("retention-outcome-key") { fixture, context in
            let other = try ItemID.derivePodcastEpisode(
                feedURL: URL(string: "https://feeds.example.test/keyed.xml")!, rssGUID: "keyed",
                enclosureURL: URL(string: "https://media.example.test/keyed.mp3")!)
            let otherRevision = try AudioRevision(
                itemID: other, revisionID: RevisionID(rawValue: "keyed-revision"),
                durationSeconds: fixture.revision.durationSeconds, byteCount: fixture.revision.byteCount,
                contentHash: fixture.revision.contentHash, mediaType: fixture.revision.mediaType,
                createdAt: fixture.revision.createdAt, schemaVersion: fixture.revision.schemaVersion)
            context.insert(LocalLibrarySchemaV3Models.RevisionRecord(otherRevision, mediaURL: fixture.mediaURL))
            for row in try context.fetch(
                FetchDescriptor<LocalLibrarySchemaV10Models.PodcastPreparationOutcomeRecord>()) {
                row.episodeID = other.rawValue
                row.revisionID = otherRevision.revisionID.rawValue
            }
        }
    }

    func testRetentionPrunesNothingWhenOnlyANonCurrentOutcomeSurvives() async throws {
        try await prunesNothing("retention-noncurrent-outcome") { fixture, context in
            for row in try context.fetch(FetchDescriptor<LocalLibrarySchemaV3Models.RevisionRecord>())
            where row.itemID == fixture.itemID.rawValue { context.delete(row) }
            for row in try context.fetch(
                FetchDescriptor<LocalLibrarySchemaV10Models.PodcastPreparationOutcomeRecord>()) {
                row.eligibility = PodcastPreparationEligibility.invalid.rawValue
            }
            let prefix = fixture.requestID + "|generation-6-1|"
            for row in try context.fetch(FetchDescriptor<LocalLibrarySchemaV3Models.PreparationRecord>(
                predicate: #Predicate { $0.id.starts(with: prefix) })) { context.delete(row) }
        }
    }

    /// A non-current outcome row keyed to this episode and revision, whose fields name another
    /// episode, is still a sign this episode was prepared: its key must count, not only its fields.
    func testRetentionPrunesNothingWhenANonCurrentOutcomeIsKeyedToThisEpisodeButNamesAnother() async throws {
        try await prunesNothing("retention-noncurrent-keyed") { fixture, context in
            for row in try context.fetch(FetchDescriptor<LocalLibrarySchemaV3Models.RevisionRecord>())
            where row.itemID == fixture.itemID.rawValue { context.delete(row) }
            let other = try ItemID.derivePodcastEpisode(
                feedURL: URL(string: "https://feeds.example.test/keyed-stale.xml")!, rssGUID: "keyed-stale",
                enclosureURL: URL(string: "https://media.example.test/keyed-stale.mp3")!)
            for row in try context.fetch(
                FetchDescriptor<LocalLibrarySchemaV10Models.PodcastPreparationOutcomeRecord>()) {
                row.eligibility = PodcastPreparationEligibility.invalid.rawValue
                row.episodeID = other.rawValue
            }
            let prefix = fixture.requestID + "|generation-6-1|"
            for row in try context.fetch(FetchDescriptor<LocalLibrarySchemaV3Models.PreparationRecord>(
                predicate: #Predicate { $0.id.starts(with: prefix) })) { context.delete(row) }
        }
    }

    /// An older run that proves the revision stays when a newer run for the same revision holds a
    /// failure and then a success: the newer one is not valid proof, so it must not displace it.
    func testRetentionKeepsTheValidatedProofRunWhenANewerRunIsContradictory() async throws {
        let fixture = try await makePreparationHistoryStore("retention-two-proofs")
        defer { try? FileManager.default.removeItem(at: fixture.url.deletingLastPathComponent()) }
        _ = try await addRetentionHistory(to: fixture, olderFailedGenerationCount: 5, newerFailedGenerationCount: 3)
        let context = ModelContext(fixture.store.container)
        let attempt = try PreparationAttemptIdentity(requestSequence: 9, attemptCount: 1)
        let success = try PreparationTerminalResult(outcome: .succeeded, revisionID: fixture.revision.revisionID)
        try insertPreparation(
            context, id: fixture.requestID + "|generation-9-1|terminal-late", itemID: fixture.itemID,
            requestID: fixture.requestID, stage: .completed, at: fixture.base.addingTimeInterval(5_000),
            attempt: attempt, terminal: success)
        try context.save()

        let proofPrefix = fixture.requestID + "|generation-6-1|"
        let proofRows = try preparationHistoryIDs(in: fixture).filter { $0.hasPrefix(proofPrefix) }
        XCTAssertFalse(proofRows.isEmpty)
        _ = try await fixture.store.prunePreparationHistoryAndFetchOpenRuns()
        let after = try preparationHistoryIDs(in: fixture)
        XCTAssertEqual(after.filter { $0.hasPrefix(proofPrefix) }, proofRows, "the validated proof run is kept whole")
        XCTAssertFalse(after.contains { $0.hasPrefix(fixture.requestID + "|generation-1-1|") }, "older failures are still pruned")
    }

    func testRetentionPrunesNothingWhenASucceededRunExistsButNoRevisionDoes() async throws {
        try await prunesNothing("retention-never-prepared-not-proven") { fixture, context in
            for row in try context.fetch(FetchDescriptor<LocalLibrarySchemaV3Models.RevisionRecord>())
            where row.itemID == fixture.itemID.rawValue { context.delete(row) }
            for row in try context.fetch(
                FetchDescriptor<LocalLibrarySchemaV10Models.PodcastPreparationOutcomeRecord>()) {
                context.delete(row)
            }
        }
    }

    /// A damaged episode stops pruning for itself and for the episode its rows name, and no further:
    /// an unrelated healthy episode is still pruned.
    func testAReadyTerminalNamingAnotherEpisodeBlocksBothButLeavesAHealthyEpisodePruned() async throws {
        let fixture = try await makePreparationHistoryStore("retention-conflict")
        defer { try? FileManager.default.removeItem(at: fixture.url.deletingLastPathComponent()) }
        _ = try await addRetentionHistory(to: fixture, olderFailedGenerationCount: 5, newerFailedGenerationCount: 3)
        let healthy = try ItemID.derivePodcastEpisode(
            feedURL: URL(string: "https://feeds.example.test/healthy.xml")!, rssGUID: "healthy",
            enclosureURL: URL(string: "https://media.example.test/healthy.mp3")!)
        let healthyRequest = PodcastPreparationPipeline.requestID(for: healthy)
        let context = ModelContext(fixture.store.container)
        for sequence in 1...8 {
            let run = try makeRetentionRun(itemID: healthy, requestID: healthyRequest, sequence: sequence, outcome: .failed)
            for entry in run.entries { context.insert(try LocalLibrarySchemaV3Models.PreparationRecord(entry)) }
        }
        // The Ready proof's terminal row now claims a different, valid episode.
        let proof = fixture.requestID + "|generation-6-1|terminal"
        let proofRow = try XCTUnwrap(try context.fetch(FetchDescriptor<LocalLibrarySchemaV3Models.PreparationRecord>(
            predicate: #Predicate { $0.id == proof })).first)
        proofRow.itemID = healthy.rawValue
        try context.save()

        let damaged = try preparationHistoryIDs(in: fixture).filter { $0.hasPrefix(fixture.requestID) }
        let healthyBefore = try preparationHistoryIDs(in: fixture).filter { $0.hasPrefix(healthyRequest) }
        _ = try await fixture.store.prunePreparationHistoryAndFetchOpenRuns()
        let after = try preparationHistoryIDs(in: fixture)
        XCTAssertEqual(after.filter { $0.hasPrefix(fixture.requestID) }, damaged, "the damaged episode keeps everything")
        XCTAssertEqual(after.filter { $0.hasPrefix(healthyRequest) }, healthyBefore, "so does the episode its row names")

        // A third, unrelated episode with the same shape of history is pruned as usual.
        let other = try ItemID.derivePodcastEpisode(
            feedURL: URL(string: "https://feeds.example.test/third.xml")!, rssGUID: "third",
            enclosureURL: URL(string: "https://media.example.test/third.mp3")!)
        let otherRequest = PodcastPreparationPipeline.requestID(for: other)
        for sequence in 1...8 {
            let run = try makeRetentionRun(itemID: other, requestID: otherRequest, sequence: sequence, outcome: .failed)
            for entry in run.entries { context.insert(try LocalLibrarySchemaV3Models.PreparationRecord(entry)) }
        }
        try context.save()
        let otherBefore = try preparationHistoryIDs(in: fixture).filter { $0.hasPrefix(otherRequest) }
        _ = try await fixture.store.prunePreparationHistoryAndFetchOpenRuns()
        let otherAfter = try preparationHistoryIDs(in: fixture).filter { $0.hasPrefix(otherRequest) }
        XCTAssertLessThan(otherAfter.count, otherBefore.count, "an unrelated healthy episode is still pruned")
        XCTAssertEqual(try preparationHistoryIDs(in: fixture).filter { $0.hasPrefix(fixture.requestID) }, damaged)
    }
}
