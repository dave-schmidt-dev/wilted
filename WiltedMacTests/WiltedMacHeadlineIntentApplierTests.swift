import Foundation
import XCTest
import WiltedLibrary
@testable import WiltedMac

@MainActor
final class WiltedMacHeadlineIntentApplierTests: XCTestCase {
    private let phone = "iphone"
    nonisolated private static let fixedNow = Date(timeIntervalSince1970: 1_800_000_000)

    private func story() throws -> LibraryHeadlineStory {
        try LibraryHeadlineStory(
            id: "story-a", title: "A story", publisherID: "feed-a", publisherName: "Example News",
            link: URL(string: "https://example.com/story-a"), publishedAt: Self.fixedNow,
            firstSeenAt: Self.fixedNow, lastSeenAt: Self.fixedNow)
    }

    private func applier(
        store: WiltedMacHeadlineCatalogStore,
        server: InMemoryLibraryServer,
        bookURL: URL?,
        ledger: WiltedMacIntentLedger,
        refresh: @escaping @MainActor () -> Void = {}
    ) -> WiltedMacIntentApplier {
        let at = Self.fixedNow
        return WiltedMacIntentApplier(
            host: FakeDecisionHost(), ledger: ledger,
            book: WiltedMacIntentOutcomeBook(fileURL: bookURL, now: { at }),
            transport: InMemoryLibraryTransport(deviceID: "mac", server: server),
            headlineCatalog: store, now: { at }, onApplied: refresh)
    }

    func testHeadlineSaveReceiptRepairsCrashBeforeOutcomeBookAndPublishesOnce() async throws {
        let directory = wiltedTemporaryDirectory("headline-intent-replay")
        let storeURL = directory.appendingPathComponent("catalog.json")
        let bookURL = directory.appendingPathComponent("outcomes.json")
        let server = InMemoryLibraryServer(writerDeviceID: "mac")
        let initialStore = WiltedMacHeadlineCatalogStore(fileURL: storeURL, now: { Self.fixedNow })
        let story = try story()
        _ = try initialStore.mergeRecent([story], at: Self.fixedNow)
        let intent = try LibraryIntent.setHeadlineSaved(
            story: story, isSaved: true, basedOnRevision: 0, deviceID: phone, createdAt: Self.fixedNow, id: "save-a")

        XCTAssertEqual(try initialStore.apply(intent, at: Self.fixedNow), .applied)
        let restartedStore = WiltedMacHeadlineCatalogStore(fileURL: storeURL, now: { Self.fixedNow })
        let ledger = WiltedMacIntentLedger(fileURL: directory.appendingPathComponent("ledger.json"), now: { Self.fixedNow })
        var refreshes = 0
        let restarted = applier(
            store: restartedStore, server: server, bookURL: bookURL, ledger: ledger) { refreshes += 1 }
        try await restarted.apply(intent)
        try await restarted.apply(intent)

        XCTAssertEqual(try restartedStore.projection(at: Self.fixedNow).saved.first?.savedRevision, 1)
        XCTAssertEqual(refreshes, 1, "the store receipt completes the outcome after the simulated crash")
        let recordedByGenericLedger = await ledger.contains(intent.id)
        XCTAssertFalse(recordedByGenericLedger, "headline commands bypass the generic side-effect ledger")
        let outcomes = try await InMemoryLibraryTransport(deviceID: phone, server: server).intentOutcomes()
        XCTAssertEqual(outcomes.map(\.intentID), [intent.id])
        XCTAssertEqual(outcomes.first?.disposition, .applied)
    }

    func testStaleHeadlineSavePublishesExplicitRevisionConflict() async throws {
        let directory = wiltedTemporaryDirectory("headline-intent-stale")
        let server = InMemoryLibraryServer(writerDeviceID: "mac")
        let store = WiltedMacHeadlineCatalogStore(fileURL: directory.appendingPathComponent("catalog.json"), now: { Self.fixedNow })
        let story = try story()
        _ = try store.mergeRecent([story], at: Self.fixedNow)
        XCTAssertEqual(try store.setSaved(
            story: story, isSaved: true, basedOnRevision: 0, commandID: "mac-save", at: Self.fixedNow), .applied)
        let intent = try LibraryIntent.setHeadlineSaved(
            story: story, isSaved: false, basedOnRevision: 0, deviceID: phone, createdAt: Self.fixedNow, id: "stale-unsave")
        let ledger = WiltedMacIntentLedger(fileURL: nil, now: { Self.fixedNow })
        let applier = applier(store: store, server: server, bookURL: nil, ledger: ledger)

        try await applier.apply(intent)

        let outcomes = try await InMemoryLibraryTransport(deviceID: phone, server: server).intentOutcomes()
        let outcome = try XCTUnwrap(outcomes.first)
        XCTAssertEqual(outcome.disposition, .rejected)
        XCTAssertEqual(outcome.reason, IntentOutcome.reasonStaleRevision)
        XCTAssertEqual(try store.projection(at: Self.fixedNow).saved.first?.savedRevision, 1)
    }
}
