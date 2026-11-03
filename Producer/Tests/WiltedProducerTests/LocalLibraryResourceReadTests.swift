import Foundation
import SwiftData
import XCTest
import WiltedDomain
@testable import WiltedProducer

extension LocalLibraryStoreTests {
    func testDismissedPreparationHistoryReadsOnlyRequestedValidAttemptStatuses() async throws {
        let url = makeURL(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = try LocalLibraryStore(url: url)
        let included = try ItemID(rawValue: "history-included")
        let malformed = try ItemID(rawValue: "history-malformed")
        let unrelated = try ItemID(rawValue: "history-unrelated")
        let at = Timestamp(Date(timeIntervalSince1970: 1_700_000_000))
        let status = try PreparationStatus(stage: .preparing, detail: "Synthetic", cancellable: true, emittedAt: at)
        try await store.record(preparation: PreparationJournalEntry(
            id: "included|stage#1", itemID: included, requestID: "included", status: status))
        try await store.record(preparation: PreparationJournalEntry(
            id: "unrelated|stage#1", itemID: unrelated, requestID: "unrelated", status: status))

        let context = ModelContext(store.container)
        let corrupt = try LocalLibrarySchemaV3Models.PreparationRecord(PreparationJournalEntry(
            id: "malformed|stage#1", itemID: malformed, requestID: "malformed", status: status))
        corrupt.statusData = Data([0xFF, 0x00])
        context.insert(corrupt)
        context.insert(try LocalLibrarySchemaV3Models.PreparationRecord(PreparationJournalEntry(
            id: "forced-marker", itemID: included,
            requestID: LocalLibraryStore.forcedRedownloadRequestPrefix + included.rawValue, status: status)))
        context.insert(try LocalLibrarySchemaV3Models.PreparationRecord(PreparationJournalEntry(
            id: "reset-marker", itemID: malformed,
            requestID: LocalLibraryStore.resetPreparationRequestPrefix + malformed.rawValue, status: status)))
        try context.save()

        let rowsBefore = await store.dismissedPreparationHistoryRowsRead
        let decodesBefore = await store.preparationJournalDecodeAttemptCount
        let prepared = try await store.preparationHistoryItemIDs(for: [included, malformed])
        let rowsRead = await store.dismissedPreparationHistoryRowsRead - rowsBefore
        let decodeAttempts = await store.preparationJournalDecodeAttemptCount - decodesBefore

        XCTAssertEqual(prepared, Set([included]), "Malformed rows and scheduling markers never claim preparation history")
        XCTAssertEqual(rowsRead, 4, "The lookup reads only rows belonging to the two requested IDs")
        XCTAssertEqual(decodeAttempts, 2, "Scheduling markers are skipped before status decoding")
    }
}
