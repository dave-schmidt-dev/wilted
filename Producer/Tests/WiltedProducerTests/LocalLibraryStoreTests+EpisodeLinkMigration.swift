import Foundation
import SwiftData
import XCTest
import WiltedDomain
@testable import WiltedProducer

/// V15 episode page links: the frozen V14 store migrates through V16 without losing a row
/// or a statistic, and the link row follows its episode through admission,
/// refresh, snapshot reads and hard deletion.
final class LocalLibraryEpisodeLinkTests: XCTestCase {
    /// SHA-256 of the checked-in V14 fixture: a V13 fixture migrated by the V14
    /// build, plus measured events, a high-water mark and a ready summary.
    static let v14FixtureSHA256 = "70f9e5cf6db8e68ac45375f61641fa5a3a9d4cef7a16c2436ce55aecf3bdeecf"

    private var directories: [URL] = []

    override func tearDown() {
        for directory in directories { try? FileManager.default.removeItem(at: directory) }
        directories = []
        super.tearDown()
    }

    private func makeStoreURL(_ name: String = "library.sqlite") throws -> URL {
        let directory = OwnedTestTemp.root
            .appendingPathComponent("wilted-episode-links-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        directories.append(directory)
        return directory.appendingPathComponent(name)
    }

    private var v14FixtureURL: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Fixtures/library-v14.store")
    }

    private func copiedV14Fixture() throws -> URL {
        let url = try makeStoreURL("library-v14.store")
        try FileManager.default.copyItem(at: v14FixtureURL, to: url)
        return url
    }

    // MARK: - Migration

    func testV14FixtureBytesAreFrozen() throws {
        XCTAssertEqual(try LocalLibraryStoreCompatibilityTests.sha256(of: v14FixtureURL), Self.v14FixtureSHA256)
        XCTAssertEqual(try LocalLibraryStore.diskSchemaVersion(at: v14FixtureURL), .known(14))
    }

    func testV14FixtureMigratesToV16KeepingEveryRowAndStatistic() async throws {
        let copied = try copiedV14Fixture()
        let before = try LocalLibraryStore.tableRowCounts(at: v14FixtureURL)
        XCTAssertGreaterThan(before.values.reduce(0, +), 10, "the fixture must carry real rows")

        let backupURL: URL
        do {
            let store = try LocalLibraryStore(url: copied)
            let retained = await store.migrationBackupURL
            backupURL = try XCTUnwrap(retained, "a V14 store must be backed up before it opens as V16")
            let summary = try await store.lifetimeStatisticsSummary()
            XCTAssertEqual(summary.state, .ready)
            XCTAssertEqual(summary.legacy, LifetimeStatistics(audioProcessedSeconds: 12.5))
            XCTAssertEqual(summary.measured, LifetimeMeasuredTotals(
                playedMilliseconds: 90_000, receivedBytes: 4_096, manuallySkippedMilliseconds: 30_000
            ))
            let highWater = try await store.lifetimeMeasureHighWater(kind: .manuallySkippedTime, ownerKey: "fixture-session")
            XCTAssertEqual(highWater?.baseUnits, 30_000)
            let episodes = try await store.podcastEpisodes()
            XCTAssertEqual(Set(episodes.compactMap(\.rssGUID)), ["active", "dismissed"])
            XCTAssertTrue(episodes.allSatisfy { $0.episodeLink == nil }, "a migrated episode has no link yet")
        }
        XCTAssertEqual(try LocalLibraryStoreCompatibilityTests.sha256(of: backupURL), Self.v14FixtureSHA256,
                       "the backup is the untouched V14 store")
        XCTAssertEqual(try LocalLibraryStore.diskSchemaVersion(at: copied), .known(17))

        var after = try LocalLibraryStore.tableRowCounts(at: copied)
        XCTAssertEqual(after.removeValue(forKey: "ZPODCASTEPISODELINKRECORD"), 0, "the new table starts empty")
        XCTAssertEqual(after.removeValue(forKey: "ZPODCASTFEEDPOLICYRECORD"), 0)
        XCTAssertEqual(after.removeValue(forKey: "ZEPISODEMATCHRULERECORD"), 0)
        XCTAssertEqual(after.removeValue(forKey: "ZEPISODEDECISIONRECORD"), 0)
        for table in ["ZAUDIOBOOKRECORD", "ZPLAYLISTRECORD", "ZPLAYLISTENTRYRECORD", "ZPLAYLISTRULERECORD"] {
            XCTAssertEqual(after.removeValue(forKey: table), 0, "the V17 table \(table) starts empty")
        }
        XCTAssertEqual(after, before, "every pre-existing table keeps its exact row count")

        let reopened = try LocalLibraryStore(url: copied)
        let secondBackup = await reopened.migrationBackupURL
        XCTAssertNil(secondBackup)
        let rebuilt = try await reopened.rebuildLifetimeStatisticsSummary()
        XCTAssertEqual(rebuilt.measured.playedMilliseconds, 90_000)
        XCTAssertEqual(try LocalLibraryStoreCompatibilityTests.sha256(of: v14FixtureURL), Self.v14FixtureSHA256)
    }

    func testFailureAfterV14MigrationRestoresTheV14Original() throws {
        let copied = try copiedV14Fixture()
        let hooks = LocalLibraryOpenHooks(afterMigration: {
            XCTAssertEqual(try LocalLibraryStore.diskSchemaVersion(at: copied), .known(17))
            throw InjectedMigrationFailure()
        })
        XCTAssertThrowsError(try LocalLibraryStore(url: copied, migrate: true, hooks: hooks)) { error in
            guard case .migrationFailedRestored? = error as? LocalLibraryStoreError else {
                return XCTFail("expected a restored migration failure, got \(error)")
            }
        }
        XCTAssertEqual(try LocalLibraryStoreCompatibilityTests.sha256(of: copied), Self.v14FixtureSHA256)
        XCTAssertEqual(try LocalLibraryStore.diskSchemaVersion(at: copied), .known(14))
    }

    func testV14FixtureIsRefusedUnmodifiedWithoutMigration() throws {
        let copied = try copiedV14Fixture()
        XCTAssertThrowsError(try LocalLibraryStore(url: copied, migrate: false)) { error in
            XCTAssertEqual(error as? LocalLibraryStoreError, .migrationRequired(fromVersion: 14))
        }
        XCTAssertEqual(try LocalLibraryStoreCompatibilityTests.sha256(of: copied), Self.v14FixtureSHA256)
    }

    /// An older build must not open a V16 store: the automation tables are unknown to
    /// it. A store from any schema newer than this build gets the same refusal.
    func testStoreNewerThanV16IsRefusedAndLeftByteIdentical() throws {
        let url = try makeStoreURL()
        let schema = Schema(LocalLibrarySchemaV16.models + [FutureSchemaRecord.self])
        let future = try ModelContainer(for: schema, configurations: [
            ModelConfiguration(schema: schema, url: url, cloudKitDatabase: .none),
        ])
        defer { withExtendedLifetime(future) {} }
        let context = ModelContext(future)
        context.insert(LocalLibrarySchemaV15Models.PodcastEpisodeLinkRecord(
            itemID: "e", url: "https://show.example.test/e", updatedAt: Date()
        ))
        context.insert(FutureSchemaRecord(id: "future"))
        try context.save()
        let before = try LocalLibraryStoreCompatibilityTests.directorySnapshot(url.deletingLastPathComponent())
        for migrate in [true, false] {
            XCTAssertThrowsError(try LocalLibraryStore(url: url, migrate: migrate)) { error in
                guard case .incompatibleStoreVersion? = error as? LocalLibraryStoreError else {
                    return XCTFail("expected a downgrade refusal, got \(error)")
                }
            }
        }
        XCTAssertEqual(try LocalLibraryStoreCompatibilityTests.directorySnapshot(url.deletingLastPathComponent()), before)
    }

    // MARK: - Persistence

    private let origin = Date(timeIntervalSince1970: 1_700_000_000)
    private let feedURL = URL(string: "https://podcasts.example.test/links/feed.xml")!

    private func episode(_ guid: String, link: String?) throws -> PodcastEpisode {
        let feedID = try ItemID.derivePodcastFeed(from: feedURL)
        let enclosureURL = URL(string: "https://cdn.example.test/links/\(guid).mp3")!
        return try PodcastEpisode(
            itemID: ItemID.derivePodcastEpisode(feedURL: feedURL, rssGUID: guid, enclosureURL: enclosureURL),
            feedID: feedID, feedURL: feedURL, rssGUID: guid, title: guid,
            publishedTime: Timestamp(origin), enclosureURL: enclosureURL, enclosureMediaType: "audio/mpeg",
            episodeLink: link.flatMap(URL.init(string:)), createdAt: Timestamp(origin)
        )
    }

    private func subscribedStore() async throws -> (LocalLibraryStore, URL) {
        let url = try makeStoreURL()
        let store = try LocalLibraryStore(url: url)
        let feedID = try ItemID.derivePodcastFeed(from: feedURL)
        try await store.save(feed: PodcastFeed(itemID: feedID, canonicalURL: feedURL, title: "Show", createdAt: Timestamp(origin)))
        try await store.save(subscription: PodcastSubscription(feedID: feedID, subscribedAt: Timestamp(origin)))
        return (store, url)
    }

    private func linkRows(_ url: URL) throws -> Int {
        try LocalLibraryStore.tableRowCounts(at: url)["ZPODCASTEPISODELINKRECORD"] ?? -1
    }

    func testAdmissionStoresTheLinkAndTheSnapshotJoinsIt() async throws {
        let (store, url) = try await subscribedStore()
        let linked = try episode("linked", link: "https://show.example.test/episodes/linked")
        let bare = try episode("bare", link: nil)
        _ = try await store.savePodcastEpisodes([linked, bare], admission: .backfill)

        let snapshot = try await store.podcastLibrarySnapshot()
        let byGUID = Dictionary(uniqueKeysWithValues: snapshot.episodes.map { ($0.rssGUID ?? "", $0) })
        XCTAssertEqual(byGUID["linked"]?.episodeLink?.absoluteString, "https://show.example.test/episodes/linked")
        XCTAssertNil(byGUID["bare"]?.episodeLink)
        let single = try await store.podcastEpisode(for: linked.itemID)
        XCTAssertEqual(single, linked)
        XCTAssertEqual(try linkRows(url), 1)
    }

    func testRefreshWritesTheLinkForAnExistingEpisodeAndTracksChanges() async throws {
        let (store, url) = try await subscribedStore()
        let first = try episode("same", link: nil)
        _ = try await store.savePodcastEpisodes([first], admission: .backfill)
        var stored = try await store.podcastEpisode(for: first.itemID)
        XCTAssertNil(stored?.episodeLink)

        let withLink = try episode("same", link: "https://show.example.test/episodes/same")
        let refreshed = try await store.savePodcastEpisodes([withLink], admission: .incremental)
        XCTAssertTrue(refreshed.newlyAdmitted.isEmpty, "the episode already existed")
        stored = try await store.podcastEpisode(for: first.itemID)
        XCTAssertEqual(stored?.episodeLink?.absoluteString, "https://show.example.test/episodes/same")

        let moved = try episode("same", link: "https://show.example.test/moved")
        _ = try await store.savePodcastEpisodes([moved], admission: .incremental)
        stored = try await store.podcastEpisode(for: first.itemID)
        XCTAssertEqual(stored?.episodeLink?.absoluteString, "https://show.example.test/moved")
        XCTAssertEqual(try linkRows(url), 1, "one row per episode, updated in place")

        _ = try await store.savePodcastEpisodes([first], admission: .incremental)
        stored = try await store.podcastEpisode(for: first.itemID)
        XCTAssertNil(stored?.episodeLink, "a feed that drops the link drops it here")
        XCTAssertEqual(try linkRows(url), 0)
    }

    func testDismissalKeepsTheLinkAndUnsubscribeDeletesIt() async throws {
        let (store, url) = try await subscribedStore()
        let linked = try episode("linked", link: "https://show.example.test/episodes/linked")
        let other = try episode("other", link: "https://show.example.test/episodes/other")
        _ = try await store.savePodcastEpisodes([linked, other], admission: .backfill)
        try await store.dismissPodcastEpisode(linked.itemID)
        XCTAssertEqual(try linkRows(url), 2, "a dismissed episode keeps its row, so it keeps its link")

        let removed = try await store.unsubscribeFromPodcast(feedID: linked.feedID)
        XCTAssertEqual(removed, 2)
        XCTAssertEqual(try linkRows(url), 0, "hard deletion leaves no orphan link")
        let remaining = try await store.podcastEpisodes()
        XCTAssertTrue(remaining.isEmpty)
    }
}
