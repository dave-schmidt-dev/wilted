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
}
