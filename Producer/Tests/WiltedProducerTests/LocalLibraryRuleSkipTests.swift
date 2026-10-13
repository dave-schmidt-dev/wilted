import Foundation
import XCTest
import WiltedDomain
@testable import WiltedProducer

/// A match rule's Skip on a refreshed episode: one save retires the episode
/// and records why, and a listener's manual decision always outranks it.
final class LocalLibraryRuleSkipTests: XCTestCase {
    private var directories: [URL] = []

    override func tearDown() {
        for directory in directories { try? FileManager.default.removeItem(at: directory) }
        super.tearDown()
    }

    func testRuleSkipRetiresTheEpisodeAndRecordsTheRuleInOneSave() async throws {
        let fixture = try await makeFixture()
        let ruleID = UUID()
        let decidedAt = Timestamp(Date(timeIntervalSince1970: 1_760_000_000))

        let skipped = try await fixture.store.retireEpisodeBySkipRule(fixture.episodeID, ruleID: ruleID, at: decidedAt)

        XCTAssertTrue(skipped)
        let removal = try await fixture.store.removalKind(for: fixture.episodeID)
        let retiredAt = try await fixture.store.retiredAt(for: fixture.episodeID)
        let decision = try await fixture.store.episodeDecision(for: fixture.episodeID)
        XCTAssertEqual(removal, .retired)
        XCTAssertEqual(retiredAt, decidedAt)
        XCTAssertEqual(decision, EpisodeDecisionRecord(
            episodeID: fixture.episodeID, decision: .skip, source: .rule, ruleID: ruleID, decidedAt: decidedAt
        ))
        let download = try await fixture.store.download(for: fixture.episodeID)
        XCTAssertNil(download, "a rule Skip reclaims the download record, as a manual Skip does")
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.mediaURL.path), "and, after the save, its file")
    }

    func testInjectedSaveFailureLeavesNeitherTheRetirementNorTheDecision() async throws {
        let fixture = try await makeFixture()

        var threw = false
        do {
            try await LocalLibraryStore.$feedAutomationBeforeSave.withValue({ throw InjectedRuleSkipFailure() }) {
                try await fixture.store.retireEpisodeBySkipRule(fixture.episodeID, ruleID: UUID())
            }
        } catch is InjectedRuleSkipFailure { threw = true }

        XCTAssertTrue(threw)
        let removal = try await fixture.store.removalKind(for: fixture.episodeID)
        let retiredAt = try await fixture.store.retiredAt(for: fixture.episodeID)
        let decision = try await fixture.store.episodeDecision(for: fixture.episodeID)
        let download = try await fixture.store.download(for: fixture.episodeID)
        XCTAssertNil(removal)
        XCTAssertNil(retiredAt)
        XCTAssertNil(decision)
        XCTAssertNotNil(download, "the staged media deletion rolled back with the rest")
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.mediaURL.path))
    }

    func testAManualDecisionBlocksALaterRuleSkip() async throws {
        let fixture = try await makeFixture()
        let manual = EpisodeDecisionRecord(
            episodeID: fixture.episodeID, decision: .keep, source: .manual,
            decidedAt: Timestamp(Date(timeIntervalSince1970: 1_750_000_000))
        )
        try await fixture.store.save(episodeDecision: manual)

        let skipped = try await fixture.store.retireEpisodeBySkipRule(fixture.episodeID, ruleID: UUID())

        XCTAssertFalse(skipped)
        let removal = try await fixture.store.removalKind(for: fixture.episodeID)
        let decision = try await fixture.store.episodeDecision(for: fixture.episodeID)
        let download = try await fixture.store.download(for: fixture.episodeID)
        XCTAssertNil(removal, "the restored episode stays in the feed")
        XCTAssertEqual(decision, manual, "the listener's decision is untouched")
        XCTAssertNotNil(download)
    }

    func testAnAlreadyRetiredEpisodeIsLeftAsItIs() async throws {
        let fixture = try await makeFixture()
        let firstRetiredAt = Timestamp(Date(timeIntervalSince1970: 1_740_000_000))
        try await fixture.store.retireEpisode(fixture.episodeID, at: firstRetiredAt)

        let skipped = try await fixture.store.retireEpisodeBySkipRule(fixture.episodeID, ruleID: UUID())

        XCTAssertFalse(skipped)
        let retiredAt = try await fixture.store.retiredAt(for: fixture.episodeID)
        let decision = try await fixture.store.episodeDecision(for: fixture.episodeID)
        XCTAssertEqual(retiredAt, firstRetiredAt)
        XCTAssertNil(decision, "no rule decision is written for an episode the rule did not retire")
    }

    // MARK: - Undo and rollback

    func testRestoringUnretiresTheEpisodeAndPutsBackItsPriorDecisionAndQueueInOneSave() async throws {
        let fixture = try await makeFixture()
        let prior = try await keptByPolicy(fixture)
        try await fixture.store.retireEpisodeBySkipRule(fixture.episodeID, ruleID: UUID())
        try await fixture.store.replacePodcastQueue(try PodcastQueueState(episodeIDs: [], currentEpisodeID: nil))

        try await fixture.store.restoreEpisodeDecisions(
            [fixture.episodeID: prior], queue: try PodcastQueueState(episodeIDs: [fixture.episodeID], currentEpisodeID: nil),
            unretiring: [fixture.episodeID]
        )

        let removal = try await fixture.store.removalKind(for: fixture.episodeID)
        let retiredAt = try await fixture.store.retiredAt(for: fixture.episodeID)
        let decision = try await fixture.store.episodeDecision(for: fixture.episodeID)
        let queue = try await fixture.store.podcastQueueState()
        let download = try await fixture.store.download(for: fixture.episodeID)
        XCTAssertNil(removal)
        XCTAssertNil(retiredAt)
        XCTAssertEqual(decision, prior)
        XCTAssertEqual(queue.episodeIDs, [fixture.episodeID])
        XCTAssertNil(download, "the audio the Skip deleted is not restored")
    }

    func testInjectedFailureWhileRestoringLeavesTheRuleSkipWhole() async throws {
        let fixture = try await makeFixture()
        let prior = try await keptByPolicy(fixture)
        let ruleID = UUID()
        try await fixture.store.retireEpisodeBySkipRule(fixture.episodeID, ruleID: ruleID)
        let skipped = try await fixture.store.episodeDecision(for: fixture.episodeID)

        var threw = false
        do {
            try await LocalLibraryStore.$feedAutomationBeforeSave.withValue({ throw InjectedRuleSkipFailure() }) {
                try await fixture.store.restoreEpisodeDecisions(
                    [fixture.episodeID: prior], queue: try PodcastQueueState(episodeIDs: [], currentEpisodeID: nil),
                    unretiring: [fixture.episodeID]
                )
            }
        } catch is InjectedRuleSkipFailure { threw = true }

        XCTAssertTrue(threw)
        let removal = try await fixture.store.removalKind(for: fixture.episodeID)
        let decision = try await fixture.store.episodeDecision(for: fixture.episodeID)
        XCTAssertEqual(removal, .retired, "still retired")
        XCTAssertEqual(decision, skipped, "and still carrying the rule's skip")
        XCTAssertEqual(decision?.ruleID, ruleID)
    }

    func testRestoringLeavesADismissedEpisodeDismissed() async throws {
        let fixture = try await makeFixture()
        try await fixture.store.retireEpisodeBySkipRule(fixture.episodeID, ruleID: UUID())
        try await fixture.store.dismissPodcastEpisode(fixture.episodeID)

        try await fixture.store.restoreEpisodeDecisions(
            [fixture.episodeID: nil], queue: try PodcastQueueState(episodeIDs: [], currentEpisodeID: nil),
            unretiring: [fixture.episodeID]
        )

        let removal = try await fixture.store.removalKind(for: fixture.episodeID)
        XCTAssertEqual(removal, .dismissed, "a dismissal is the stronger removal")
    }

    /// Records a policy Keep for the fixture episode and puts it in the queue.
    private func keptByPolicy(_ fixture: Fixture) async throws -> EpisodeDecisionRecord {
        let prior = EpisodeDecisionRecord(
            episodeID: fixture.episodeID, decision: .keep, source: .policy,
            decidedAt: Timestamp(Date(timeIntervalSince1970: 1_750_000_000))
        )
        try await fixture.store.save(episodeDecision: prior)
        try await fixture.store.replacePodcastQueue(try PodcastQueueState(episodeIDs: [fixture.episodeID], currentEpisodeID: nil))
        return prior
    }

    // MARK: - Fixture

    private struct Fixture {
        let store: LocalLibraryStore
        let episodeID: ItemID
        let mediaURL: URL
    }

    /// One subscribed feed with one live episode that has a completed
    /// download whose file sits inside the library directory.
    private func makeFixture() async throws -> Fixture {
        let directory = OwnedTestTemp.root.appendingPathComponent("wilted-rule-skip-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        directories.append(directory)
        let feedURL = URL(string: "https://podcasts.example.test/rule-skip.xml")!
        let feedID = try ItemID.derivePodcastFeed(from: feedURL)
        let enclosureURL = URL(string: "https://cdn.example.test/fight-companion.mp3")!
        let episodeID = try ItemID.derivePodcastEpisode(feedURL: feedURL, rssGUID: "fight", enclosureURL: enclosureURL)
        let store = try LocalLibraryStore(url: directory.appendingPathComponent("library.sqlite"))
        let now = Timestamp(Date())
        try await store.save(feed: PodcastFeed(itemID: feedID, canonicalURL: feedURL, title: "Rule Skip", createdAt: now))
        try await store.savePodcastEpisodes([try PodcastEpisode(
            itemID: episodeID, feedID: feedID, feedURL: feedURL, rssGUID: "fight",
            title: "Fight Companion - October 11, 2026", publishedTime: now,
            enclosureURL: enclosureURL, enclosureMediaType: "audio/mpeg", createdAt: now
        )], admission: .backfill)
        let mediaURL = directory.appendingPathComponent("fight-companion.mp3")
        try Data("audio".utf8).write(to: mediaURL)
        try await store.save(download: PodcastDownload(
            episodeID: episodeID, status: .completed, bytesReceived: 5, localURL: mediaURL,
            contentHash: "sha256:" + String(repeating: "a", count: 64), updatedAt: now
        ))
        return Fixture(store: store, episodeID: episodeID, mediaURL: mediaURL)
    }
}

private struct InjectedRuleSkipFailure: Error {}
