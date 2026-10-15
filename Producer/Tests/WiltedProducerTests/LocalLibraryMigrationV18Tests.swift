import Foundation
import SwiftData
import XCTest
import WiltedDomain
@testable import WiltedProducer

final class LocalLibraryMigrationV18Tests: XCTestCase {
    func testV17SubscriptionsMigrateToV18WithoutRowLoss() async throws {
        let directory = OwnedTestTemp.root.appendingPathComponent("wilted-v18-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("library.sqlite")
        let subscriptions = try (0..<3).map { index in
            PodcastSubscription(
                feedID: try ItemID.derivePodcastFeed(from: URL(string: "https://feeds.example.test/v18-\(index).xml")!),
                subscribedAt: Timestamp(Date(timeIntervalSince1970: 1_700_000_000 + Double(index))),
                enabled: index != 1)
        }
        try autoreleasepool {
            let schema = Schema(versionedSchema: LocalLibrarySchemaV17.self)
            let container = try ModelContainer(for: schema, configurations: [
                ModelConfiguration(schema: schema, url: url, cloudKitDatabase: .none)])
            let context = ModelContext(container)
            for subscription in subscriptions {
                context.insert(LocalLibrarySchemaV6Models.PodcastSubscriptionRecord(subscription))
            }
            try context.save()
        }
        XCTAssertEqual(try LocalLibraryStore.diskSchemaVersion(at: url), .known(17))
        let before = try LocalLibraryStore.tableRowCounts(at: url)
        let store = try LocalLibraryStore(url: url)
        let values = try await store.subscriptions()
        XCTAssertEqual(Set(values.map(\.feedID)), Set(subscriptions.map(\.feedID)))
        for expected in subscriptions {
            XCTAssertEqual(values.first { $0.feedID == expected.feedID }, expected)
        }
        let version = await store.schemaVersion
        XCTAssertEqual(version.rawValue, LocalLibrarySchemaVersion.current.rawValue,
                       "opening a frozen V17 store must migrate to current")
        XCTAssertEqual(try LocalLibraryStore.diskSchemaVersion(at: url),
                       .known(LocalLibrarySchemaVersion.current.rawValue))
        var expectedCounts = before
        // Opening the library initializes these two empty statistics singleton tables.
        expectedCounts["ZLIFETIMESTATISTICSSUMMARYRECORD"] = 1
        expectedCounts["ZLIFETIMESTATISTICSTRACKINGRECORD"] = 1
        let after = try LocalLibraryStore.tableRowCounts(at: url)
        for (table, count) in expectedCounts {
            XCTAssertEqual(after[table], count, "table \(table) keeps its expected row count")
        }
        for (table, count) in after where expectedCounts[table] == nil {
            XCTAssertEqual(count, 0, "newly added table \(table) starts empty")
        }
        XCTAssertTrue(values.allSatisfy { $0.displayName == nil })
        let retained = await store.migrationBackupURL
        let backup = try XCTUnwrap(retained)
        XCTAssertEqual(try LocalLibraryStore.diskSchemaVersion(at: backup), .known(17))
        XCTAssertEqual(try LocalLibraryStore.tableRowCounts(at: backup), before)
        let reopened = try LocalLibraryStore(url: url)
        let secondBackup = await reopened.migrationBackupURL
        XCTAssertNil(secondBackup, "reopening V18 must not migrate or back up again")
    }
}
