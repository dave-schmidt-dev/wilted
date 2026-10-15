import CryptoKit
import Foundation
import SwiftData
import XCTest
import WiltedDomain
import WiltedSync
@testable import WiltedProducer

extension LocalLibraryStoreTests {
    func testPodcastSnapshotCapturesOrderedQueueAndRemovalInOneImmutableValue() async throws {
        let url = makeURL(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let origin = Date(timeIntervalSince1970: 1_700_000_000)
        let feedURL = URL(string: "https://podcasts.example.test/snapshot-queue.xml")!
        let (feed, values) = try episodes(feedURL: feedURL, origin: origin, daysAgo: [1, 2, 3])
        let store = try LocalLibraryStore(url: url)
        try await store.save(feed: feed)
        for episode in values { try await store.save(episode: episode) }
        let ids = values.map(\.itemID)
        let ordered = [ids[2], ids[0], ids[1]]
        try await store.replacePodcastQueue(try PodcastQueueState(episodeIDs: ordered, currentEpisodeID: ids[0]))
        let before = try await store.podcastLibrarySnapshot()
        XCTAssertEqual(before.podcastQueue.episodeIDs, ordered)
        XCTAssertEqual(before.podcastQueue.currentEpisodeID, ids[0])
        XCTAssertNil(before.removalKindByEpisode[ids[1]])

        try await store.removePodcastQueueEpisode(ids[2])
        let retired = try await store.completeAndRetireEpisode(listening: .init(
            episodeID: ids[1], completedAt: Timestamp(origin), lastRevisionID: nil, updatedAt: Timestamp(origin)))
        XCTAssertTrue(retired)
        let after = try await store.podcastLibrarySnapshot()
        XCTAssertEqual(after.podcastQueue.episodeIDs, [ids[0], ids[1]])
        XCTAssertEqual(after.podcastQueue.currentEpisodeID, ids[0])
        XCTAssertEqual(after.removalKindByEpisode[ids[1]], .retired)
        XCTAssertNotNil(after.retiredAtByEpisode[ids[1]])
        XCTAssertEqual(before.podcastQueue.episodeIDs, ordered, "later commits cannot rewrite a captured membership")
        XCTAssertEqual(before.podcastQueue.currentEpisodeID, ids[0])
        XCTAssertNil(before.removalKindByEpisode[ids[1]], "later retirement cannot rewrite captured eligibility")
        XCTAssertNil(before.retiredAtByEpisode[ids[1]])
    }

    func testPublicationProfileOmitsOnlyTranscriptAndPreparationHistory() async throws {
        let url = makeURL(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = try LocalLibraryStore(url: url)
        let (feed, values) = try episodes(feedURL: URL(string: "https://example.test/profile.xml")!,
            origin: Date(timeIntervalSince1970: 1_700_000_000), daysAgo: [1, 2, 3])
        try await store.save(feed: feed)
        for value in values { try await store.save(episode: value) }
        let id = values[0].itemID
        let rev = try revision(for: article(), id: "publication-profile", at: 1_700_000_001)
        let audio = try AudioRevision(itemID: id, revisionID: rev.revisionID, durationSeconds: 20,
            byteCount: 1, contentHash: rev.contentHash, mediaType: "audio/mp4", createdAt: rev.createdAt, schemaVersion: 1)
        let transcript = try Transcript(itemID: id, revisionID: audio.revisionID, availability: .available,
            text: "Timed words", timing: .aligned,
            cues: [TranscriptCue(startSeconds: 0, endSeconds: 2, text: "Timed words")], updatedAt: audio.createdAt)
        try await store.saveReadyRevision(audio, mediaURL: url.appendingPathExtension("m4a"), transcript: transcript)
        try await store.record(preparation: succeededPreparationEntry(itemID: id, revisionID: audio.revisionID,
            requestID: "profile-run", fingerprint: "profile-fingerprint", at: 1_700_000_002))
        try await store.savePreparationOutcome(PodcastPreparationOutcome(episodeID: id, revisionID: audio.revisionID,
            policyDigest: "profile-policy", pipelineFingerprint: "profile-fingerprint", semanticVersion: "1.0.0",
            producedAt: audio.createdAt, eligibility: .current))
        try await store.saveListening(PodcastListeningState(episodeID: id, completedAt: nil,
            lastRevisionID: audio.revisionID, updatedAt: audio.createdAt))
        _ = try await store.save(episodeDecision: EpisodeDecisionRecord(episodeID: id, decision: .keep,
            source: .manual, decidedAt: audio.createdAt))
        try await store.replacePodcastQueue(try PodcastQueueState(episodeIDs: values.map(\.itemID), currentEpisodeID: id))
        _ = try await store.retireEpisode(values[2].itemID)
        let before = await store.podcastLibrarySnapshotFetchCount
        let full = try await store.podcastLibrarySnapshot()
        let fullCost = await store.podcastLibrarySnapshotFetchCount - before
        let publication = try await store.podcastLibrarySnapshot(profile: .publication)
        let totalCost = await store.podcastLibrarySnapshotFetchCount - before
        XCTAssertEqual(totalCost - fullCost, fullCost - 2)
        XCTAssertEqual(full.transcripts.values.first?.cues, transcript.cues)
        XCTAssertEqual(full.preparationRuns.count, 1)
        XCTAssertTrue(publication.transcripts.isEmpty); XCTAssertTrue(publication.preparationRuns.isEmpty)
        XCTAssertEqual(publication.episodes, full.episodes); XCTAssertEqual(publication.articles, full.articles)
        XCTAssertEqual(publication.feeds, full.feeds); XCTAssertEqual(publication.subscriptions, full.subscriptions)
        XCTAssertEqual(publication.podcastQueue, full.podcastQueue); XCTAssertEqual(publication.downloads, full.downloads)
        XCTAssertEqual(publication.readyRevisions.mapValues(\.revision), full.readyRevisions.mapValues(\.revision))
        XCTAssertEqual(publication.readyRevisions.mapValues(\.mediaURL), full.readyRevisions.mapValues(\.mediaURL))
        XCTAssertEqual(publication.playbackStates, full.playbackStates)
        XCTAssertEqual(publication.preparationOutcomes, full.preparationOutcomes)
        XCTAssertEqual(publication.listeningStates, full.listeningStates)
        XCTAssertEqual(publication.episodeDecisions, full.episodeDecisions)
        XCTAssertEqual(publication.retiredAtByEpisode, full.retiredAtByEpisode)
        XCTAssertEqual(publication.removalKindByEpisode, full.removalKindByEpisode)
        XCTAssertEqual(publication.articleFeeds, full.articleFeeds); XCTAssertEqual(publication.feedIDByArticle, full.feedIDByArticle)
        XCTAssertEqual(publication.audiobooks, full.audiobooks)
    }

    func save(revision id: String, of itemID: ItemID, at second: TimeInterval,
                      saying text: String, into store: LocalLibraryStore, near url: URL) async throws {
        let revisionID = try RevisionID(rawValue: id)
        let mediaURL = url.deletingLastPathComponent().appendingPathComponent("\(id).m4a")
        try Data([0x00]).write(to: mediaURL)
        let revision = try AudioRevision(
            itemID: itemID, revisionID: revisionID, durationSeconds: second, byteCount: 1,
            contentHash: "sha256:" + String(repeating: "0", count: 64), mediaType: "audio/mp4",
            createdAt: Timestamp(Date(timeIntervalSince1970: 1_700_000_000 + second)), schemaVersion: 1
        )
        let transcript = try Transcript(
            itemID: itemID, revisionID: revisionID, availability: .available, text: text,
            updatedAt: Timestamp(Date(timeIntervalSince1970: 1_700_000_000 + second))
        )
        try await store.saveReadyRevision(revision, mediaURL: mediaURL, transcript: transcript)
    }

    /// `loadLibrary` used to call `readyRevision(for:)`,
    /// `playbackState(for:revisionID:)`, `transcript(for:revisionID:)`,
    /// `preparationOutcome(for:revisionID:)`, `listeningState(for:)`, and
    /// `retiredAt(for:)` once per episode, each doing its own unfiltered
    /// full-table fetch -- read cost scaled with episode count.
    /// `podcastLibrarySnapshot()` exists to fetch each table exactly once
    /// regardless of how many episodes are in the library; this proves it by
    /// seeding 3 episodes and then 27 more (30 total) and requiring the
    /// second snapshot cost exactly what the first did.
    func testPodcastLibrarySnapshotFetchCountDoesNotScaleWithEpisodeCount() async throws {
        let url = makeURL(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = try LocalLibraryStore(url: url)
        let feedURL = URL(string: "https://podcasts.example.test/scale-feed.xml")!
        let feedID = try ItemID.derivePodcastFeed(from: feedURL)
        let feed = try PodcastFeed(itemID: feedID, canonicalURL: feedURL, title: "Scale Show", author: "Wilted",
                                   artworkURL: nil, createdAt: Timestamp(Date(timeIntervalSince1970: 1_700_000_100)))
        try await store.save(feed: feed)
        try await store.save(feedSubscription: PodcastSubscription(feedID: feedID, subscribedAt: feed.createdAt, enabled: true))

        func addEpisodes(_ range: Range<Int>) async throws {
            for i in range {
                let enclosureURL = URL(string: "https://podcasts.example.test/scale-audio-\(i).mp3")!
                let episodeID = try ItemID.derivePodcastEpisode(feedURL: feedURL, rssGUID: "scale-episode-\(i)", enclosureURL: enclosureURL)
                let episode = try PodcastEpisode(
                    itemID: episodeID, feedID: feedID, feedURL: feedURL, rssGUID: "scale-episode-\(i)",
                    title: "Episode \(i)", author: "Wilted", publishedTime: feed.createdAt,
                    enclosureURL: enclosureURL, enclosureMediaType: "audio/mpeg", enclosureByteCount: 1000,
                    durationSeconds: 120, artworkURL: nil, createdAt: feed.createdAt
                )
                try await store.save(episode: episode)
            }
        }

        try await addEpisodes(0..<3)
        _ = try await store.podcastLibrarySnapshot()
        let costAt3 = await store.podcastLibrarySnapshotFetchCount

        try await addEpisodes(3..<30)
        _ = try await store.podcastLibrarySnapshot()
        let costAt30 = await store.podcastLibrarySnapshotFetchCount

        XCTAssertGreaterThan(costAt3, 0)
        XCTAssertEqual(costAt30 - costAt3, costAt3,
                       "a 10x increase in episode count must not change the snapshot's fetch count")
    }

    func testNewestReadyRevisionsByItemIDSkipsMalformedRowAndReturnsWellFormedRows() async throws {
        let url = makeURL(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = try LocalLibraryStore(url: url)

        // Seed well-formed rows
        let wellFormedArticle1 = try article()
        let wellFormedRev1 = try revision(for: wellFormedArticle1, id: "rev-well-formed-1", at: 1_700_000_001)
        let mediaURL1 = URL(fileURLWithPath: "/tmp/media-1.m4a")
        try await store.save(article: wellFormedArticle1)
        try await store.saveReadyRevision(wellFormedRev1, mediaURL: mediaURL1)

        let article2URL = URL(string: "https://example.test/library/article-2")!
        let wellFormedArticle2 = try Article(
            itemID: ItemID.derive(from: article2URL),
            canonicalURL: article2URL,
            title: "Article Two",
            source: "example.test",
            createdAt: Timestamp(Date(timeIntervalSince1970: 1_700_000_002))
        )
        let wellFormedRev2 = try revision(for: wellFormedArticle2, id: "rev-well-formed-2", at: 1_700_000_003)
        let mediaURL2 = URL(fileURLWithPath: "/tmp/media-2.m4a")
        try await store.save(article: wellFormedArticle2)
        try await store.saveReadyRevision(wellFormedRev2, mediaURL: mediaURL2)

        // Seed a malformed row that fails AudioRevision validation (e.g. non-positive duration)
        let malformedItemID = "malformed-item"
        try store.seedRevisionRecord(
            id: "rev-malformed",
            itemID: malformedItemID,
            durationSeconds: -5.0,
            byteCount: 128,
            contentHash: "sha256:" + String(repeating: "f", count: 64),
            mediaType: "audio/mp4",
            mediaURL: "file:///tmp/malformed.m4a",
            createdAt: Date(timeIntervalSince1970: 1_700_000_010),
            schemaVersion: 3
        )

        let context = ModelContext(store.container)
        let results = try store.newestReadyRevisionsByItemID(in: context)

        XCTAssertEqual(results.count, 2)
        XCTAssertEqual(results[wellFormedArticle1.itemID.rawValue]?.revision.revisionID, wellFormedRev1.revisionID)
        XCTAssertEqual(results[wellFormedArticle1.itemID.rawValue]?.mediaURL, mediaURL1)
        XCTAssertEqual(results[wellFormedArticle2.itemID.rawValue]?.revision.revisionID, wellFormedRev2.revisionID)
        XCTAssertEqual(results[wellFormedArticle2.itemID.rawValue]?.mediaURL, mediaURL2)
        XCTAssertNil(results[malformedItemID])
    }

}
