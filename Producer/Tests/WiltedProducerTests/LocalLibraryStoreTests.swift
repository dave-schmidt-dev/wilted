import CryptoKit
import Foundation
import SwiftData
import XCTest
import WiltedDomain
import WiltedSync
@testable import WiltedProducer

final class LocalLibraryStoreTests: XCTestCase {
    func testLifetimeLedgerDeduplicatesAcrossRelaunchAndRejectsInvalidSeconds() async throws {
        let url = makeURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        var store = try LocalLibraryStore(url: url)

        let first = try await store.recordLifetimeStatistic(
            id: "speech|revision", kind: .speechGenerated, seconds: 12.5
        )
        let duplicate = try await store.recordLifetimeStatistic(
            id: "speech|revision", kind: .speechGenerated, seconds: 99
        )
        let negative = try await store.recordLifetimeStatistic(
            id: "negative", kind: .audioProcessed, seconds: -1
        )
        let infinite = try await store.recordLifetimeStatistic(
            id: "infinite", kind: .audioProcessed, seconds: .infinity
        )
        XCTAssertTrue(first)
        XCTAssertFalse(duplicate)
        XCTAssertFalse(negative)
        XCTAssertFalse(infinite)

        store = try LocalLibraryStore(url: url)
        let relaunchedDuplicate = try await store.recordLifetimeStatistic(
            id: "speech|revision", kind: .speechGenerated, seconds: 12.5
        )
        let totals = try await store.lifetimeStatistics()
        XCTAssertFalse(relaunchedDuplicate)
        XCTAssertEqual(totals, LifetimeStatistics(
            speechGeneratedSeconds: 12.5
        ))
    }

    /// Reproduces the pre-Phase-7 blanket behavior for tests written before
    /// rules existed: any fingerprint drift is treated as incompatible. Real
    /// callers use `PodcastPreparationPipeline.invalidationRules`, which
    /// starts empty -- see `LocalLibraryStoreInvalidationRuleTests`.
    static let blanketDriftRule = PodcastPreparationInvalidationRule(
        id: "test.blanket-drift", consequence: .resetPreparation, applies: { _ in true }
    )

    func testPodcastQueueMutationsNormalizeAndRestoreOrderAndCurrentIdentity() async throws {
        let url = makeURL(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let first = try ItemID(rawValue: "item-" + String(repeating: "1", count: 64))
        let second = try ItemID(rawValue: "item-" + String(repeating: "2", count: 64))
        let third = try ItemID(rawValue: "item-" + String(repeating: "3", count: 64))
        var store = try LocalLibraryStore(url: url)
        try await store.addPodcastQueueEpisode(first)
        try await store.addPodcastQueueEpisode(second)
        try await store.addPodcastQueueEpisode(third)
        try await store.setCurrentPodcastQueueEpisode(second)
        try await store.movePodcastQueueEpisode(from: 2, to: 0)
        let firstEntries = try await store.queue()
        let firstState = try await store.podcastQueueState()
        XCTAssertEqual(firstEntries.map(\.position), [0, 1, 2])
        XCTAssertEqual(firstState, try PodcastQueueState(
            episodeIDs: [third, first, second], currentEpisodeID: second
        ))

        store = try LocalLibraryStore(url: url)
        let reopened = try await store.podcastQueueState()
        XCTAssertEqual(reopened.episodeIDs, [third, first, second])
        XCTAssertEqual(reopened.currentEpisodeID, second)
        try await store.removePodcastQueueEpisode(first)
        let removedEntries = try await store.queue()
        let removedState = try await store.podcastQueueState()
        XCTAssertEqual(removedEntries.map(\.position), [0, 1])
        XCTAssertEqual(removedState.episodeIDs, [third, second])
    }

    struct ForcedMigrationFailure: Error {}

    func makeURL(_ name: String = #function) -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("wilted-store-\(name)-\(UUID().uuidString)").appendingPathComponent("library.sqlite")
    }

    func article() throws -> Article {
        let url = URL(string: "https://example.test/library/article")!
        return try Article(itemID: ItemID.derive(from: url), canonicalURL: url, title: "A durable article", source: "example.test", createdAt: Timestamp(Date(timeIntervalSince1970: 1_700_000_000)))
    }

    func revision(for article: Article, id: String, at time: TimeInterval = 1_700_000_001) throws -> AudioRevision {
        try AudioRevision(itemID: article.itemID, revisionID: RevisionID(rawValue: id), durationSeconds: 42, byteCount: 128,
                          contentHash: "sha256\(String(repeating: ":", count: 0)):\(String(repeating: "a", count: 64))",
                          mediaType: "audio/mp4", createdAt: Timestamp(Date(timeIntervalSince1970: time)), schemaVersion: 1)
    }

    func playback(for article: Article, revision: AudioRevision, position: Double) throws -> PlaybackState {
        try PlaybackState(itemID: article.itemID, revisionID: revision.revisionID, sessionID: "session-1", sequence: 1,
                          positionSeconds: position, durationSeconds: revision.durationSeconds, completed: false, intent: .progress,
                          deviceID: "device-mac", updatedAt: Timestamp(Date(timeIntervalSince1970: 1_700_000_010)))
    }

    func podcastValues() throws -> (PodcastFeed, PodcastEpisode) {
        let feedURL = URL(string: "https://podcasts.example.test/feed.xml")!
        let enclosureURL = URL(string: "https://podcasts.example.test/audio/episode-1.mp3")!
        let feedID = try ItemID.derivePodcastFeed(from: feedURL)
        let feed = try PodcastFeed(itemID: feedID, canonicalURL: feedURL, title: "The Wilted Show",
                                   author: "Wilted", artworkURL: URL(string: "https://podcasts.example.test/art.jpg"),
                                   createdAt: Timestamp(Date(timeIntervalSince1970: 1_700_000_100)))
        let episodeID = try ItemID.derivePodcastEpisode(feedURL: feedURL, rssGUID: "episode-1", enclosureURL: enclosureURL)
        let episode = try PodcastEpisode(itemID: episodeID, feedID: feedID, feedURL: feedURL, rssGUID: "episode-1",
                                         title: "Episode One", author: "Wilted", publishedTime: feed.createdAt,
                                         enclosureURL: enclosureURL, enclosureMediaType: "audio/mpeg", enclosureByteCount: 1000,
                                         durationSeconds: 120, artworkURL: feed.artworkURL, createdAt: feed.createdAt)
        return (feed, episode)
    }

    /// Marking an article deleted has to survive a round trip. Nothing covered
    /// this, and the producer's Remove action depends on it entirely.
    func testDeletingAnArticleSurvivesAReadBack() async throws {
        let url = makeURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let article = try article()
        let store = try LocalLibraryStore(url: url)
        try await store.save(article: article)
        var flags = try await store.articles().map(\.isDeleted)
        XCTAssertEqual(flags, [false])

        let deleted = try Article(
            itemID: article.itemID, canonicalURL: article.canonicalURL, title: article.title,
            source: article.source, author: article.author, publishedTime: article.publishedTime,
            createdAt: article.createdAt, isDeleted: true
        )
        try await store.save(article: deleted)
        flags = try await store.articles().map(\.isDeleted)
        XCTAssertEqual(flags, [true], "in-process read back")
        let single = try await store.article(for: article.itemID)?.isDeleted
        XCTAssertEqual(single, true, "single-item read back")

        let reopened = try LocalLibraryStore(url: url)
        flags = try await reopened.articles().map(\.isDeleted)
        XCTAssertEqual(flags, [true], "read back after reopen")
    }

    /// The player asks what preparation cut out of an episode so the
    /// transcript can say so in place. It has to be the newest success: a
    /// later failed attempt removed nothing, and answering with its absent
    /// timeline would erase markers the listener can still hear the seams of.
    func testTheLatestSuccessfulPreparationTimelineIsWhatIsReported() async throws {
        let url = makeURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = try LocalLibraryStore(url: url)
        let article = try article()
        let revision = try revision(for: article, id: "rev-timeline")
        try await store.save(article: article)

        let beforeAnyPreparation = try await store.latestPreparationTimeline(
            for: article.itemID, revisionID: revision.revisionID
        )
        XCTAssertNil(beforeAnyPreparation, "an item nothing has prepared has no cuts")

        let firstTimeline = try PreparationStatus.PreparationTimeline(
            removed: [try .init(originalStartSeconds: 60, originalEndSeconds: 90, label: "advertisement", confidence: 0.9)],
            kept: [try .init(originalStartSeconds: 0, originalEndSeconds: 60, outputStartSeconds: 0),
                   try .init(originalStartSeconds: 90, originalEndSeconds: 200, outputStartSeconds: 60)]
        )
        try await store.record(preparation: PreparationJournalEntry(
            id: "prep-old", itemID: article.itemID, requestID: "request-old",
            status: try PreparationStatus(
                stage: .completed, detail: "ready", fraction: 1, cancellable: false,
                terminalResult: try PreparationTerminalResult(outcome: .succeeded, revisionID: revision.revisionID),
                emittedAt: Timestamp(Date(timeIntervalSince1970: 1_700_000_000)),
                timeline: firstTimeline
            )
        ))

        let secondTimeline = try PreparationStatus.PreparationTimeline(
            removed: [try .init(originalStartSeconds: 30, originalEndSeconds: 45, label: "sponsor", confidence: 0.8)],
            kept: [try .init(originalStartSeconds: 0, originalEndSeconds: 30, outputStartSeconds: 0),
                   try .init(originalStartSeconds: 45, originalEndSeconds: 200, outputStartSeconds: 30)]
        )
        try await store.record(preparation: PreparationJournalEntry(
            id: "prep-new", itemID: article.itemID, requestID: "request-new",
            status: try PreparationStatus(
                stage: .completed, detail: "ready", fraction: 1, cancellable: false,
                terminalResult: try PreparationTerminalResult(outcome: .succeeded, revisionID: revision.revisionID),
                emittedAt: Timestamp(Date(timeIntervalSince1970: 1_700_000_100)),
                timeline: secondTimeline
            )
        ))

        // A later attempt that failed cut nothing, so it must not answer.
        try await store.record(preparation: PreparationJournalEntry(
            id: "prep-failed", itemID: article.itemID, requestID: "request-failed",
            status: try PreparationStatus(
                stage: .failed, detail: "worker exited", fraction: nil, cancellable: false,
                terminalResult: try PreparationTerminalResult(
                    outcome: .failed,
                    error: try ProducerError(code: .failed, message: "worker exited", retryable: true)
                ),
                emittedAt: Timestamp(Date(timeIntervalSince1970: 1_700_000_200))
            )
        ))

        let reported = try await store.latestPreparationTimeline(
            for: article.itemID, revisionID: revision.revisionID
        )
        XCTAssertEqual(reported, secondTimeline, "the newest success, not the newest terminal status")

        // Cutting an episode changes its bytes, so a timeline describes one
        // revision and no other. Answering for a revision this run did not
        // produce would draw cut markers over uncut audio.
        let otherRevision = try self.revision(for: article, id: "rev-timeline-other")
        let forAnotherRevision = try await store.latestPreparationTimeline(
            for: article.itemID, revisionID: otherRevision.revisionID
        )
        XCTAssertNil(forAnotherRevision, "a success recorded for a different revision is not this revision's timeline")
    }

    func testInterruptedStoreReopensWithArticleRevisionPreparationAndPlayback() async throws {
        let url = makeURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let article = try article()
        let revision = try revision(for: article, id: "rev-v1")
        let status = try PreparationStatus(stage: .completed, detail: "ready", fraction: 1, cancellable: false,
                                            terminalResult: try PreparationTerminalResult(outcome: .succeeded, revisionID: revision.revisionID),
                                            emittedAt: Timestamp(Date(timeIntervalSince1970: 1_700_000_002)))
        do {
            let store = try LocalLibraryStore(url: url)
            try await store.save(article: article)
            try await store.saveReadyRevision(revision, mediaURL: URL(fileURLWithPath: "/tmp/rev-v1.m4a"))
            try await store.record(preparation: PreparationJournalEntry(id: "prep-1", itemID: article.itemID, requestID: "request-1", status: status))
            try await store.save(playback: playback(for: article, revision: revision, position: 12))
        }
        let reopened = try LocalLibraryStore(url: url)
        let reopenedArticle = try await reopened.article(for: article.itemID)
        let reopenedRevision = try await reopened.readyRevision(for: article.itemID)
        let reopenedJournal = try await reopened.preparationJournal(for: "request-1")
        let reopenedPlayback = try await reopened.playbackState(for: article.itemID, revisionID: revision.revisionID)
        XCTAssertEqual(reopenedArticle, article)
        XCTAssertEqual(reopenedRevision?.revisionID, revision.revisionID)
        XCTAssertEqual(reopenedJournal.count, 1)
        XCTAssertEqual(reopenedPlayback?.positionSeconds, 12)
    }

    func testV2StoreMigratesArticlePlaybackAndSafeNewDefaults() async throws {
        let url = makeURL(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let item = try article()
        let rev = try revision(for: item, id: "rev-migration")
        let state = try playback(for: item, revision: rev, position: 17)
        try LocalLibraryStore.createV2MigrationFixture(at: url, article: item, playback: state)

        let migrated = try LocalLibraryStore(url: url)
        let migratedArticle = try await migrated.article(for: item.itemID)
        let migratedPlayback = try await migrated.playbackState(for: item.itemID, revisionID: rev.revisionID)
        XCTAssertEqual(migratedArticle, item)
        XCTAssertEqual(migratedPlayback?.positionSeconds, 17)
        let migratedStatus = try await migrated.syncStatus(for: item.itemID)
        let migratedSidecar = try await migrated.playbackSidecar(for: item.itemID, revisionID: rev.revisionID)
        XCTAssertEqual(migratedStatus, .localOnly)
        XCTAssertNil(migratedSidecar?.changeTag)
        let migratedTranscript = try await migrated.transcript(for: item.itemID, revisionID: rev.revisionID)
        let migratedInspection = try await migrated.inspect()
        XCTAssertNil(migratedTranscript)
        XCTAssertEqual(migratedInspection.schemaVersion, .v14)
    }

    /// The V4 -> V5 stage renames the deletion column. A read-back inside one
    /// schema version cannot catch a rename that drops its values, so this
    /// walks a deleted article from a frozen V2 store all the way to V5.
    func testDeletionFlagSurvivesMigrationFromV2() async throws {
        let url = makeURL(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let live = try article()
        let removed = try Article(
            itemID: live.itemID, canonicalURL: live.canonicalURL, title: live.title,
            source: live.source, author: live.author, publishedTime: live.publishedTime,
            createdAt: live.createdAt, isDeleted: true
        )
        let rev = try revision(for: removed, id: "rev-deleted-migration")
        try LocalLibraryStore.createV2MigrationFixture(
            at: url, article: removed, playback: try playback(for: removed, revision: rev, position: 3)
        )

        let migrated = try LocalLibraryStore(url: url)
        let flags = try await migrated.articles().map(\.isDeleted)
        XCTAssertEqual(flags, [true], "the deletion flag must survive the column rename")
        let single = try await migrated.article(for: removed.itemID)?.isDeleted
        XCTAssertEqual(single, true)
    }

    func testPriorRevisionIsPreservedAndImmutableWhenNewRevisionIsSaved() async throws {
        let url = makeURL(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let article = try article(); let old = try revision(for: article, id: "rev-old", at: 1_700_000_001); let new = try revision(for: article, id: "rev-new", at: 1_700_000_002)
        let store = try LocalLibraryStore(url: url)
        try await store.saveReadyRevision(old, mediaURL: URL(fileURLWithPath: "/tmp/old.m4a"))
        try await store.saveReadyRevision(new, mediaURL: URL(fileURLWithPath: "/tmp/new.m4a"))
        let revisions = try await store.revisions(for: article.itemID)
        XCTAssertEqual(Set(revisions.map(\.revisionID)), [old.revisionID, new.revisionID])
        do {
            try await store.saveReadyRevision(old, mediaURL: URL(fileURLWithPath: "/tmp/changed.m4a"))
            XCTFail("Expected immutable revision error")
        } catch {
            XCTAssertEqual(
                error as? LocalLibraryStoreError,
                .immutableRevision(old.revisionID, site: .readyRevision)
            )
        }
    }

}

func collectPreparationStatuses(
    _ stream: AsyncStream<PreparationStatus>
) async -> [PreparationStatus] {
    var statuses: [PreparationStatus] = []
    for await status in stream { statuses.append(status) }
    return statuses
}

/// Records what the assembler's synchronous cancellation probe observed.
final class InFlightObservation: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Set<String> = []

    func observe(_ paths: Set<String>) { lock.withLock { value.formUnion(paths) } }
    var paths: Set<String> { lock.withLock { value } }
}
