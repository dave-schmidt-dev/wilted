import Foundation
import XCTest
import WiltedDomain
@testable import WiltedProducer

extension LocalLibraryStoreTests {
    func testRecoveredSameSequenceRejectsDelayedJournalAndTerminalTicketWritesAfterReopen() async throws {
        let url = makeURL(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        var store = try LocalLibraryStore(url: url)
        let (_, episode) = try podcastValues()
        let now = Timestamp(Date())
        var ticket = try await store.readmitWorkTicket(kind: .podcastPreparation, subjectID: episode.itemID.rawValue,
            requestSequence: 8, to: .running, at: now)
        let old = try PreparationAttemptIdentity(requestSequence: ticket.requestSequence, attemptCount: ticket.attemptCount)
        let request = PodcastPreparationPipeline.requestID(for: episode.itemID)
        let oldStatus = try PreparationStatus(stage: .extracting, detail: "Old", cancellable: true, emittedAt: now, attempt: old)
        try await store.record(preparation: .init(id: request + "|" + old.key + "|extracting#1",
            itemID: episode.itemID, requestID: request, status: oldStatus))
        ticket.attemptCount += 1
        _ = try await store.upsertWorkTicket(ticket)
        store = try LocalLibraryStore(url: url)
        let current = try PreparationAttemptIdentity(requestSequence: ticket.requestSequence, attemptCount: ticket.attemptCount)
        try await store.record(preparation: .init(id: request + "|" + old.key + "|terminal",
            itemID: episode.itemID, requestID: request, status: oldStatus))
        let rejected = try await store.finishPreparationAttempt(subjectID: episode.itemID.rawValue, attempt: old,
            state: .failed, at: now)
        XCTAssertNil(rejected)
        let oldEntries = try await store.preparationJournal(for: request, attempt: old)
        let currentEntries = try await store.preparationJournal(for: request, attempt: current)
        XCTAssertEqual(oldEntries.count, 1)
        XCTAssertTrue(currentEntries.isEmpty)
        let newStatus = try PreparationStatus(stage: .saving, detail: "New", cancellable: true, emittedAt: now, attempt: current)
        try await store.record(preparation: .init(id: request + "|" + current.key + "|saving#1",
            itemID: episode.itemID, requestID: request, status: newStatus))
        let summaries = try await store.preparationRuns()
        XCTAssertEqual(Set(summaries.map(\.id)).count, 2)
        XCTAssertEqual(Set(summaries.map(\.requestID)), [request])
        _ = try await store.readmitWorkTicket(kind: .podcastPreparation, subjectID: episode.itemID.rawValue,
            requestSequence: 9, to: .running, at: now)
        let stale = try await store.finishPreparationAttempt(subjectID: episode.itemID.rawValue, attempt: current,
            state: .succeeded, at: now)
        XCTAssertNil(stale)
    }
}
