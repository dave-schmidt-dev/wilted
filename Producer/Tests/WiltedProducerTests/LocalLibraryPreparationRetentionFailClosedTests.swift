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
