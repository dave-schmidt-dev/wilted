import Foundation
import SwiftData
import XCTest
import WiltedDomain
@testable import WiltedProducer

final class LocalLibraryV17MigrationTests: XCTestCase {
    static let v16FixtureSHA256 = "cbd49249bd2e88d4de2731ad27fccfb66767e9f159ab58ded886238ad83ea494"
    private var directories: [URL] = []

    override func tearDown() {
        for directory in directories { try? FileManager.default.removeItem(at: directory) }
        super.tearDown()
    }

    func testV16FixtureBytesAreFrozenAndHaveRowsInEveryV16Table() throws {
        let url = fixtureURL("library-v16.store")
        XCTAssertEqual(try LocalLibraryStoreCompatibilityTests.sha256(of: url), Self.v16FixtureSHA256)
        XCTAssertEqual(try LocalLibraryStore.diskSchemaVersion(at: url), .known(16))
        let counts = try LocalLibraryStore.tableRowCounts(at: url)
        XCTAssertFalse(counts.isEmpty)
        for (table, count) in counts { XCTAssertGreaterThan(count, 0, "\(table) must hold a row") }
        XCTAssertEqual(counts.count, LocalLibrarySchemaV16.models.count)
    }

    func testV16FixtureMigratesToV17WithEqualRowCountsAndBackup() async throws {
        let source = fixtureURL("library-v16.store")
        let before = try LocalLibraryStore.tableRowCounts(at: source)
        let copied = try copiedFixture("library-v16.store")
        let backup: URL
        do {
            let store = try LocalLibraryStore(url: copied)
            let retained = await store.migrationBackupURL
            backup = try XCTUnwrap(retained)
        }
        XCTAssertEqual(try LocalLibraryStoreCompatibilityTests.sha256(of: backup), Self.v16FixtureSHA256)
        XCTAssertEqual(try LocalLibraryStore.diskSchemaVersion(at: copied), .known(17))
        var after = try LocalLibraryStore.tableRowCounts(at: copied)
        for table in ["ZAUDIOBOOKRECORD", "ZPLAYLISTRECORD", "ZPLAYLISTENTRYRECORD", "ZPLAYLISTRULERECORD"] {
            XCTAssertEqual(after.removeValue(forKey: table), 0, "\(table) starts empty")
        }
        XCTAssertEqual(after, before, "every pre-existing table keeps its exact row count")
    }

    func testMigratedFeedWithoutSourceKindReadsAsPodcast() throws {
        let copied = try copiedFixture("library-v16.store")
        _ = try LocalLibraryStore(url: copied)
        let schema = Schema(versionedSchema: LocalLibrarySchemaV17.self)
        let container = try ModelContainer(for: schema, configurations: [
            ModelConfiguration(schema: schema, url: copied, cloudKitDatabase: .none),
        ])
        let context = ModelContext(container)
        let feeds = try context.fetch(FetchDescriptor<LocalLibrarySchemaV17Models.PodcastFeedRecord>())
        XCTAssertFalse(feeds.isEmpty)
        for feed in feeds {
            XCTAssertNil(feed.sourceKind)
            XCTAssertEqual(feed.resolvedSourceKind, "podcast")
        }
        let articles = try context.fetch(FetchDescriptor<LocalLibrarySchemaV17Models.ArticleRecord>())
        XCTAssertTrue(articles.allSatisfy { $0.feedID == nil })
        let policies = try context.fetch(FetchDescriptor<LocalLibrarySchemaV17Models.PodcastFeedPolicyRecord>())
        XCTAssertFalse(policies.isEmpty)
        XCTAssertTrue(policies.allSatisfy { $0.isNews == nil })
    }

    func testFreshStoreReportsVersionSeventeen() async throws {
        let url = try freshStoreURL()
        let store = try LocalLibraryStore(url: url)
        let inspection = try await store.inspect()
        XCTAssertEqual(inspection.schemaVersion, .v17)
        XCTAssertEqual(LocalLibrarySchemaVersion.current.rawValue, 17)
        XCTAssertEqual(try LocalLibraryStore.diskSchemaVersion(at: url), .known(17))
    }

    /// The previous build knows schemas through V16 only. A V17 store matches
    /// none of them, which is the input to its downgrade refusal (the refusal
    /// itself, before any write, is pinned by testNewerStoreIsRefusedWithoutAnyWrite).
    func testPreviousBuildDoesNotRecognizeAV17Store() throws {
        let url = try freshStoreURL()
        do { _ = try LocalLibraryStore(url: url) }
        let metadata = try NSPersistentStoreCoordinator.metadataForPersistentStore(
            type: .sqlite, at: url, options: [NSReadOnlyPersistentStoreOption: true]
        )
        for schema in LocalLibraryV16MigrationPlan.schemas {
            let model = try XCTUnwrap(NSManagedObjectModel.makeManagedObjectModel(for: schema.models))
            XCTAssertFalse(model.isConfiguration(withName: nil, compatibleWithStoreMetadata: metadata),
                           "V\(schema.versionIdentifier.major) must not accept a V17 store")
        }
    }

    /// Reproduces `library-v16.store`: migrates a copy of the frozen V15
    /// fixture to V16 with the frozen V16 schema, adds one row to each table
    /// V16 introduced (and the V8 dismissal table, empty in V15), checkpoints
    /// the WAL into the main file, and copies it to the directory named by
    /// `WILTED_GENERATE_V16_FIXTURE`. Skipped unless that variable is set.
    func testGenerateV16Fixture() throws {
        guard let output = ProcessInfo.processInfo.environment["WILTED_GENERATE_V16_FIXTURE"] else {
            throw XCTSkip("set WILTED_GENERATE_V16_FIXTURE=<directory> to regenerate library-v16.store")
        }
        let work = try copiedFixture("library-v15.store")
        let at = Date(timeIntervalSince1970: 1_700_000_000)
        try autoreleasepool {
            let schema = Schema(versionedSchema: LocalLibrarySchemaV16.self)
            let container = try ModelContainer(
                for: schema, migrationPlan: LocalLibraryV16MigrationPlan.self,
                configurations: [ModelConfiguration(schema: schema, url: work, cloudKitDatabase: .none)]
            )
            let context = ModelContext(container)
            let feedID = try XCTUnwrap(context.fetch(FetchDescriptor<LocalLibrarySchemaV6Models.PodcastFeedRecord>()).first).id
            let episodeID = try XCTUnwrap(context.fetch(FetchDescriptor<LocalLibrarySchemaV10Models.PodcastEpisodeRecord>()).first).id
            let ruleID = UUID(uuidString: "00000000-0000-4000-8000-000000000016")!
            context.insert(LocalLibrarySchemaV8Models.PodcastEpisodeDismissalRecord(
                episodeID: "fixture-dismissed", feedID: feedID, title: "Dismissed fixture episode", dismissedAt: at))
            context.insert(LocalLibrarySchemaV16Models.PodcastFeedPolicyRecord(
                feedID: feedID, autoKeep: "on", autoDownload: "off", autoPrepare: "on", keptLimit: 3, updatedAt: at))
            context.insert(LocalLibrarySchemaV16Models.EpisodeMatchRuleRecord(
                id: ruleID, feedID: feedID, order: 0, field: "title", includePattern: "news",
                excludePattern: nil, action: "keep", enabled: true, updatedAt: at))
            context.insert(LocalLibrarySchemaV16Models.EpisodeDecisionRecord(
                episodeID: episodeID, decision: "keep", source: "rule", ruleID: ruleID, decidedAt: at))
            try context.save()
        }
        let checkpoint = Process()
        checkpoint.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        checkpoint.arguments = [work.path, "PRAGMA wal_checkpoint(TRUNCATE);"]
        checkpoint.standardOutput = FileHandle.nullDevice
        try checkpoint.run()
        checkpoint.waitUntilExit()
        XCTAssertEqual(checkpoint.terminationStatus, 0)
        let destination = URL(fileURLWithPath: output, isDirectory: true).appendingPathComponent("library-v16.store")
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.copyItem(at: work, to: destination)
    }

    private func fixtureURL(_ name: String) -> URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Fixtures/\(name)")
    }

    private func freshStoreURL() throws -> URL {
        let directory = OwnedTestTemp.root.appendingPathComponent("wilted-v17-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        directories.append(directory)
        return directory.appendingPathComponent("library.sqlite")
    }

    private func copiedFixture(_ name: String) throws -> URL {
        let url = try freshStoreURL().deletingLastPathComponent().appendingPathComponent(name)
        try FileManager.default.copyItem(at: fixtureURL(name), to: url)
        return url
    }
}
