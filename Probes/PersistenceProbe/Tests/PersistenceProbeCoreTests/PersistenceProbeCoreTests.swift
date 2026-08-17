import XCTest
@testable import PersistenceProbeCore

final class PersistenceProbeCoreTests: XCTestCase {
    private func isolated(_ name: String) throws -> URL {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("persistence-probe-tests")
        let url = PersistenceStoreURL.deterministic(named: name, root: root)
        try PersistenceStoreURL.reset(url)
        return url
    }

    func testPureValuesRoundTripAndAllCategoriesInspect() async throws {
        let store = try PersistenceStore(url: try isolated("round-trip"))
        try await PersistenceProbeScenarios.populateAll(store)
        let inspection = try await store.inspect()
        XCTAssertEqual(inspection, PersistenceInspection(schemaVersion: 2, articles: 1, revisions: 1, playback: 1, journal: 1, syncState: 1, tombstones: 1))
        let playback = ProbePlayback(id: "fixture-playback", itemID: "fixture-article", revisionID: "fixture-revision", position: 12, encodedRecordSystemFields: Data([9, 8]), lastSeenChangeTag: Data([7, 6]))
        let fetchedPlayback = try await store.fetchPlayback(id: playback.id)
        XCTAssertEqual(fetchedPlayback, playback)
        let fetchedSyncState = try await store.fetchSyncState(key: "fixture-zone")
        XCTAssertEqual(fetchedSyncState, ProbeSyncState(key: "fixture-zone", engineState: Data([1, 2, 3, 4])))
    }

    func testConcurrentCallbacksAreSerializedByActor() async throws {
        let store = try PersistenceStore(url: try isolated("concurrent"))
        try await PersistenceProbeScenarios.concurrentJournalWrites(store, count: 48)
        let inspection = try await store.inspect()
        XCTAssertEqual(inspection.journal, 48)
    }

    func testReopenRetainsDurableValues() async throws {
        let url = try isolated("reopen")
        do {
            let store = try PersistenceStore(url: url)
            try await PersistenceProbeScenarios.populateAll(store, prefix: "reopen")
        }
        let reopened = try PersistenceStore(url: url)
        let inspection = try await reopened.inspect()
        XCTAssertEqual(inspection.total, 6)
        XCTAssertEqual(inspection.schemaVersion, 2)
    }

    func testForwardMigrationFromV1ToV2() async throws {
        let url = try isolated("migration")
        try PersistenceProbeScenarios.createV1Store(at: url)
        let migrated = try PersistenceStore(url: url)
        let inspection = try await migrated.inspect()
        XCTAssertEqual(inspection.schemaVersion, 2)
        XCTAssertEqual(inspection.articles, 1)
        let expected = ProbeArticle(id: "migration-article", canonicalURL: "https://example.test/v1", title: "Version one", source: nil, createdAt: Date(timeIntervalSince1970: 1_700_000_010), deleted: false)
        let migratedArticle = try await migrated.fetchArticle(id: "migration-article")
        XCTAssertEqual(migratedArticle, expected)
        let migratedSyncState = try await migrated.fetchSyncState(key: "migration-zone")
        XCTAssertEqual(migratedSyncState, ProbeSyncState(key: "migration-zone", engineState: Data()))
        try await migrated.save(article: ProbeArticle(id: "migration-v2", canonicalURL: "https://example.test/v2", title: "Version two", source: "example.test"))
        let afterSave = try await migrated.inspect()
        XCTAssertEqual(afterSave.articles, 2)
        let reopened = try PersistenceStore(url: url)
        let reopenedArticle = try await reopened.fetchArticle(id: "migration-article")
        XCTAssertEqual(reopenedArticle, expected)
    }
}
