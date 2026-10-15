import Foundation
import SwiftData
import Testing
import WiltedDomain
@testable import WiltedProducer

@Suite("Local library preparation journal lookup")
struct LocalLibraryPreparationJournalLookupTests {
    private static let historyCount = 7_000

    @Test func exactEventUpsertReadsOnlyTheNamedRowAndPreservesHistory() async throws {
        let directory = OwnedTestTemp.root.appendingPathComponent("wilted-preparation-lookup-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("library.sqlite")
        let store = try LocalLibraryStore(url: url)
        let sameRequest = "synthetic-shared-request"
        let siblingID = "synthetic-shared-terminal"
        let preservedHistory = try Self.entry(
            id: "history-0000", itemID: "history-item-0000", requestID: "history-request-0000", at: 1_700_000_000
        )

        try Self.seedHistory(in: store.container, preserving: preservedHistory, sameRequest: sameRequest, siblingID: siblingID)

        let inserted = try Self.entry(
            id: "synthetic-target-terminal", itemID: "inserted-item", requestID: sameRequest, at: 1_700_010_000
        )
        let readsBeforeInsert = await store.preparationJournalLookupRowsRead
        try await store.record(preparation: inserted)
        #expect(await store.preparationJournalLookupRowsRead - readsBeforeInsert == 0)
        let sharedAfterInsert = try await store.preparationJournal(for: sameRequest)
        #expect(sharedAfterInsert.map(\.id).sorted() == [inserted.id, siblingID].sorted())

        let updated = try Self.entry(
            id: inserted.id, itemID: "updated-item", requestID: "synthetic-updated-request", at: 1_700_020_000
        )
        let readsBeforeUpdate = await store.preparationJournalLookupRowsRead
        try await store.record(preparation: updated)
        #expect(await store.preparationJournalLookupRowsRead - readsBeforeUpdate == 1)
        let updatedRows = try await store.preparationJournal(for: updated.requestID)
        #expect(updatedRows == [updated])
        #expect(try await store.preparationJournal(for: sameRequest).map(\.id) == [siblingID])

        let reopened = try LocalLibraryStore(url: url)
        #expect(try await reopened.preparationJournal(for: preservedHistory.requestID) == [preservedHistory])
        #expect(try await reopened.preparationJournal(for: updated.requestID) == [updated])
        #expect(try await reopened.preparationJournal(for: sameRequest).map(\.id) == [siblingID])
    }

    private static func seedHistory(
        in container: ModelContainer, preserving preservedHistory: PreparationJournalEntry,
        sameRequest: String, siblingID: String
    ) throws {
        let context = ModelContext(container)
        context.insert(try LocalLibrarySchemaV3Models.PreparationRecord(preservedHistory))
        context.insert(try LocalLibrarySchemaV3Models.PreparationRecord(Self.entry(
            id: siblingID, itemID: "synthetic-sibling-item", requestID: sameRequest, at: 1_700_000_001
        )))
        for index in 2..<historyCount {
            context.insert(try LocalLibrarySchemaV3Models.PreparationRecord(Self.entry(
                id: "history-\(index)", itemID: "history-item-\(index)", requestID: "history-request-\(index)",
                at: 1_700_000_000 + TimeInterval(index)
            )))
        }
        try context.save()
    }

    private static func entry(id: String, itemID: String, requestID: String, at: TimeInterval) throws -> PreparationJournalEntry {
        PreparationJournalEntry(
            id: id, itemID: try ItemID(rawValue: itemID), requestID: requestID,
            status: try PreparationStatus(
                stage: .completed, detail: "Synthetic terminal success", fraction: 1, cancellable: false,
                terminalResult: try PreparationTerminalResult(
                    outcome: .succeeded, revisionID: RevisionID(rawValue: "revision-\(id)")
                ), emittedAt: Timestamp(Date(timeIntervalSince1970: at))
            )
        )
    }
}
