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

    @Test func displayedPreparationRunsBoundRowsBeforeLoadingSelectedRunDetails() async throws {
        let directory = OwnedTestTemp.root.appendingPathComponent("wilted-preparation-display-bound-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let store = try LocalLibraryStore(url: directory.appendingPathComponent("library.sqlite"))
        try Self.seedHistory(in: store.container, preserving: Self.entry(
            id: "history-0000", itemID: "history-item-0000", requestID: "history-request-0000", at: 1_700_000_000
        ), sameRequest: "synthetic-shared-request", siblingID: "synthetic-shared-terminal")

        let malformedEntry = try Self.entry(
            id: "synthetic-malformed-newest", itemID: "synthetic-malformed-item",
            requestID: "synthetic-malformed-request", at: 1_700_020_000
        )
        let malformed = try LocalLibrarySchemaV3Models.PreparationRecord(malformedEntry)
        malformed.statusData = Data("{".utf8)
        let context = ModelContext(store.container)
        context.insert(malformed)
        try context.save()

        let rowsBefore = await store.preparationRunRowsRead
        let decodesBefore = await store.preparationJournalDecodeAttemptCount
        let runs = try await store.preparationRuns()
        let rowsRead = await store.preparationRunRowsRead - rowsBefore
        let decodedStatuses = await store.preparationJournalDecodeAttemptCount - decodesBefore
        let largestPage = await store.preparationRunMaximumBatchRows

        #expect(runs.count == 200)
        #expect(runs.first?.requestID == "history-request-6999")
        #expect(runs.last?.requestID == "history-request-6800")
        #expect(rowsRead <= 512, "Only a candidate page and selected detail rows should be materialized")
        #expect(decodedStatuses <= 512, "Malformed and unselected history should not trigger full-history decoding")
        #expect(largestPage <= 256)

        let uncapped = try await store.preparationRuns(limit: Int.max)
        #expect(uncapped.count == Self.historyCount, "Correctness callers retain every valid run")
    }

    @Test func sameDecodedTimestampAcrossPageBoundaryUsesDeterministicEventOrder() async throws {
        let directory = OwnedTestTemp.root.appendingPathComponent("wilted-preparation-time-tie-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let store = try LocalLibraryStore(url: directory.appendingPathComponent("library.sqlite"))
        let context = ModelContext(store.container)
        let base = Date(timeIntervalSince1970: 1_700_000_000)

        for index in 0..<256 {
            let rawDate = base.addingTimeInterval(0.1234 - Double(index) * 0.000001)
            try Self.insert(id: "a-run-event-\(index)", itemID: "tie-item-a", requestID: "a-run",
                at: rawDate, in: context)
        }
        let olderRawDate = base.addingTimeInterval(0.12305)
        try Self.insert(id: "z-run-event", itemID: "tie-item-z", requestID: "z-run",
            at: olderRawDate, in: context)
        try Self.insert(id: "zz-older-run-event", itemID: "tie-item-older", requestID: "zz-older-run",
            at: base.addingTimeInterval(0.121), in: context)
        try context.save()

        let newestA = try JSONEncoder().encode(Timestamp(base.addingTimeInterval(0.1234)))
        let newestZ = try JSONEncoder().encode(Timestamp(olderRawDate))
        #expect(newestA == newestZ, "Raw dates differ but serialized status timestamps tie")
        let selected = try await store.preparationRuns(limit: 1)
        #expect(selected.map(\.requestID) == ["z-run"])
        #expect(await store.preparationRunMaximumBatchRows <= 256)
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

    private static func insert(
        id: String, itemID: String, requestID: String, at date: Date, in context: ModelContext
    ) throws {
        let entry = PreparationJournalEntry(
            id: id, itemID: try ItemID(rawValue: itemID), requestID: requestID,
            status: try PreparationStatus(stage: .extracting, detail: id, cancellable: true,
                emittedAt: Timestamp(date))
        )
        context.insert(try LocalLibrarySchemaV3Models.PreparationRecord(entry))
    }
}
