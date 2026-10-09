import Foundation
import XCTest
import WiltedDomain
@testable import WiltedProducer

final class LocalLibraryFeedAutomationTests: XCTestCase {
    static let v15FixtureSHA256 = "4322e61affd7b86bf90df38e76a0dc102d24b40155dc2be72a10fb5f3b20c3f3"
    private var directories: [URL] = []

    override func tearDown() {
        for directory in directories { try? FileManager.default.removeItem(at: directory) }
        super.tearDown()
    }

    func testV15FixtureBytesAreFrozen() throws {
        XCTAssertEqual(try LocalLibraryStoreCompatibilityTests.sha256(of: fixtureURL("library-v15.store")), Self.v15FixtureSHA256)
        XCTAssertEqual(try LocalLibraryStore.diskSchemaVersion(at: fixtureURL("library-v15.store")), .known(15))
    }

    func testV13V14AndV15FixturesMigrateToV17WithBackupAndRowsIntact() async throws {
        for name in ["library-v13.store", "library-v14.store", "library-v15.store"] {
            let source = fixtureURL(name)
            let before = try LocalLibraryStore.tableRowCounts(at: source)
            let copied = try copiedFixture(name)
            let backup: URL
            do {
                let store = try LocalLibraryStore(url: copied)
                let backupValue = await store.migrationBackupURL
                backup = try XCTUnwrap(backupValue)
            }
            XCTAssertEqual(try LocalLibraryStoreCompatibilityTests.sha256(of: backup),
                           try LocalLibraryStoreCompatibilityTests.sha256(of: source))
            XCTAssertEqual(try LocalLibraryStore.diskSchemaVersion(at: copied), .known(17))
            let after = try LocalLibraryStore.tableRowCounts(at: copied)
            for (table, count) in before { XCTAssertEqual(after[table], count, "\(name): \(table)") }
        }
    }

    func testPolicyRulesDecisionsAndUnsubscribeRoundTrip() async throws {
        let (store, feedID, episode) = try await subscribedStore()
        let episodeID = episode.itemID
        let policy = FeedAutomationPolicy(autoKeep: .on, autoDownload: .off, autoPrepare: .on, keptLimit: .explicit(3))
        try await store.save(feedAutomationPolicy: policy, for: feedID)
        let storedPolicy = try await store.feedAutomationPolicy(for: feedID)
        XCTAssertEqual(storedPolicy, policy)
        let rules = EpisodeMatchRules(rules: [
            EpisodeMatchRule(field: .title, includePattern: "news", action: .keep),
            EpisodeMatchRule(field: .notes, includePattern: "skip", action: .skip),
        ])
        try await store.replaceEpisodeMatchRules(rules, for: feedID)
        let storedRules = try await store.episodeMatchRules(for: feedID)
        XCTAssertEqual(storedRules, rules)
        let decision = EpisodeDecisionRecord(episodeID: episodeID, decision: .keep, source: .rule,
                                             ruleID: rules.rules[0].id, decidedAt: Timestamp(Date()))
        try await store.save(episodeDecision: decision)
        let storedDecision = try await store.episodeDecision(for: episodeID)
        let decisions = try await store.decisions(forFeed: feedID)
        let removed = try await store.unsubscribeFromPodcast(feedID: feedID)
        let clearedPolicy = try await store.feedAutomationPolicy(for: feedID)
        let clearedRules = try await store.episodeMatchRules(for: feedID)
        let clearedDecision = try await store.episodeDecision(for: episodeID)
        XCTAssertEqual(storedDecision, decision)
        XCTAssertEqual(decisions, [decision])
        XCTAssertEqual(removed, 1)
        XCTAssertEqual(clearedPolicy, FeedAutomationPolicy())
        XCTAssertEqual(clearedRules, EpisodeMatchRules())
        XCTAssertNil(clearedDecision)
        try await store.save(feed: PodcastFeed(itemID: feedID, canonicalURL: episode.feedURL, title: "Automation", createdAt: Timestamp(Date())))
        _ = try await store.savePodcastEpisodes([episode], admission: .backfill)
        let resubscribedDecision = try await store.episodeDecision(for: episodeID)
        XCTAssertNil(resubscribedDecision)
    }

    func testInjectedAdmissionFailureLeavesQueueDecisionAndTicketsEmpty() async throws {
        let (store, _, episode) = try await subscribedStore()
        let episodeID = episode.itemID
        let decision = EpisodeDecisionRecord(episodeID: episodeID, decision: .keep, source: .manual, decidedAt: Timestamp(Date()))
        var threw = false
        do {
            try await LocalLibraryStore.$feedAutomationBeforeSave.withValue({ throw InjectedFailure() }) {
                try await store.admitEpisode(decision, workTicketKinds: [.podcastDownload, .podcastPreparation])
            }
        } catch { threw = true }
        XCTAssertTrue(threw)
        let queue = try await store.queue()
        let savedDecision = try await store.episodeDecision(for: episodeID)
        let downloadTicket = try await store.workTicket(kind: .podcastDownload, subjectID: episodeID.rawValue)
        let preparationTicket = try await store.workTicket(kind: .podcastPreparation, subjectID: episodeID.rawValue)
        XCTAssertTrue(queue.isEmpty)
        XCTAssertNil(savedDecision)
        XCTAssertNil(downloadTicket)
        XCTAssertNil(preparationTicket)
    }

    private func fixtureURL(_ name: String) -> URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Fixtures/\(name)")
    }

    private func copiedFixture(_ name: String) throws -> URL {
        let directory = OwnedTestTemp.root.appendingPathComponent("wilted-v17-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        directories.append(directory)
        let copied = directory.appendingPathComponent(name)
        try FileManager.default.copyItem(at: fixtureURL(name), to: copied)
        return copied
    }

    private func subscribedStore() async throws -> (LocalLibraryStore, ItemID, PodcastEpisode) {
        let directory = OwnedTestTemp.root.appendingPathComponent("wilted-automation-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        directories.append(directory)
        let feedURL = URL(string: "https://podcasts.example.test/automation.xml")!
        let feedID = try ItemID.derivePodcastFeed(from: feedURL)
        let episodeURL = URL(string: "https://cdn.example.test/automation.mp3")!
        let episodeID = try ItemID.derivePodcastEpisode(feedURL: feedURL, rssGUID: "automation", enclosureURL: episodeURL)
        let store = try LocalLibraryStore(url: directory.appendingPathComponent("library.sqlite"))
        try await store.save(feed: PodcastFeed(itemID: feedID, canonicalURL: feedURL, title: "Automation", createdAt: Timestamp(Date())))
        let episode = try PodcastEpisode(itemID: episodeID, feedID: feedID, feedURL: feedURL,
                                     rssGUID: "automation", title: "news", publishedTime: Timestamp(Date()),
                                     enclosureURL: episodeURL, enclosureMediaType: "audio/mpeg", createdAt: Timestamp(Date()))
        try await store.savePodcastEpisodes([episode], admission: .backfill)
        return (store, feedID, episode)
    }
}

private struct InjectedFailure: Error {}
