import CryptoKit
import Foundation
import SwiftData
import XCTest
import WiltedDomain
@testable import WiltedProducer

extension LocalLibraryStoreTests {
    func testLatestTranscriptThrowsForCorruptNewestRevisionWithoutOlderFallback() async throws {
        let url = makeURL(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let item = try article()
        let store = try LocalLibraryStore(url: url)
        for (id, seconds, digit) in [("rev-old", 10.0, "a"), ("rev-new", 20.0, "b")] {
            let revision = try AudioRevision(
                itemID: item.itemID, revisionID: RevisionID(rawValue: id), durationSeconds: 10,
                byteCount: 10, contentHash: "sha256:" + String(repeating: digit, count: 64),
                mediaType: "audio/mp4", createdAt: Timestamp(Date(timeIntervalSince1970: seconds)),
                schemaVersion: 1)
            try await store.saveReadyRevision(revision, mediaURL: url.appendingPathComponent(id + ".m4a"))
        }
        let older = try Transcript(
            itemID: item.itemID, revisionID: RevisionID(rawValue: "rev-old"),
            availability: .available, text: "Valid older text.",
            updatedAt: Timestamp(Date(timeIntervalSince1970: 30)))
        try await store.save(transcript: older)
        let newest = try Transcript(
            itemID: item.itemID, revisionID: RevisionID(rawValue: "rev-new"),
            availability: .available, text: "Malformed newest record.",
            updatedAt: Timestamp(Date(timeIntervalSince1970: 1)))
        try await MainActor.run {
            let context = ModelContext(store.container)
            let corrupt = try LocalLibrarySchemaV7Models.TranscriptRecord(newest)
            corrupt.availability = "corrupt-availability"
            context.insert(corrupt)
            try context.save()
        }

        do {
            _ = try await store.latestTranscript(for: item.itemID)
            XCTFail("a corrupt newest revision must throw instead of returning nil or older text")
        } catch let error as LocalLibraryStoreError {
            guard case .invalidPreparationStatus("transcript") = error else {
                return XCTFail("unexpected decode failure: \(error)")
            }
        }
        let retainedOlder = try await store.transcript(for: item.itemID, revisionID: older.revisionID)
        XCTAssertEqual(retainedOlder, older, "a valid older fallback exists but must not hide corruption")
    }

    func testLatestTranscriptSurvivesRetirement() async throws {
        let url = makeURL(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let (feed, episode) = try podcastValues()
        let store = try LocalLibraryStore(url: url)
        try await store.save(feed: feed)
        try await store.save(episode: episode)
        let revision = try podcastRevision(itemID: episode.itemID, id: "rev-retained", hashDigit: "a")
        let transcript = try Transcript(itemID: episode.itemID, revisionID: revision.revisionID,
                                        availability: .available, text: "Retained after retirement.",
                                        updatedAt: revision.createdAt)
        try await store.saveReadyRevision(revision, mediaURL: url.appendingPathComponent("retained.m4a"),
                                          transcript: transcript)

        let retired = try await store.retireEpisode(episode.itemID)
        let loaded = try await store.latestTranscript(for: episode.itemID)
        XCTAssertTrue(retired)
        XCTAssertEqual(loaded, transcript)
    }

    func testLatestTranscriptPrefersNewestRevisionWhileOneExists() async throws {
        let url = makeURL(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let item = try article()
        let store = try LocalLibraryStore(url: url)
        let older = try AudioRevision(itemID: item.itemID, revisionID: RevisionID(rawValue: "rev-old"),
                                      durationSeconds: 10, byteCount: 10,
                                      contentHash: "sha256:" + String(repeating: "a", count: 64),
                                      mediaType: "audio/mp4", createdAt: Timestamp(Date(timeIntervalSince1970: 10)),
                                      schemaVersion: 1)
        let newer = try AudioRevision(itemID: item.itemID, revisionID: RevisionID(rawValue: "rev-new"),
                                      durationSeconds: 10, byteCount: 10,
                                      contentHash: "sha256:" + String(repeating: "b", count: 64),
                                      mediaType: "audio/mp4", createdAt: Timestamp(Date(timeIntervalSince1970: 20)),
                                      schemaVersion: 1)
        let oldTranscript = try Transcript(itemID: item.itemID, revisionID: older.revisionID,
                                           availability: .available, text: "Old", updatedAt: Timestamp(Date(timeIntervalSince1970: 30)))
        let newTranscript = try Transcript(itemID: item.itemID, revisionID: newer.revisionID,
                                           availability: .available, text: "New", updatedAt: Timestamp(Date(timeIntervalSince1970: 1)))
        try await store.saveReadyRevision(older, mediaURL: url.appendingPathComponent("old.m4a"), transcript: oldTranscript)
        try await store.saveReadyRevision(newer, mediaURL: url.appendingPathComponent("new.m4a"), transcript: newTranscript)

        let loaded = try await store.latestTranscript(for: item.itemID)
        XCTAssertEqual(loaded, newTranscript)
    }

    func testLatestTranscriptFallsBackToNewestUpdatedAtAndRevisionTieBreak() async throws {
        let url = makeURL(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let item = try article()
        let store = try LocalLibraryStore(url: url)
        let timestamp = Timestamp(Date(timeIntervalSince1970: 50))
        let first = try Transcript(itemID: item.itemID, revisionID: RevisionID(rawValue: "rev-a"),
                                   availability: .available, text: "First", updatedAt: timestamp)
        let second = try Transcript(itemID: item.itemID, revisionID: RevisionID(rawValue: "rev-b"),
                                    availability: .available, text: "Second", updatedAt: timestamp)
        try await store.save(transcript: first)
        try await store.save(transcript: second)

        let loaded = try await store.latestTranscript(for: item.itemID)
        XCTAssertEqual(loaded, second)
    }

    func testLatestTranscriptReturnsAbsentRecordWithoutOlderFallback() async throws {
        let url = makeURL(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let item = try article()
        let store = try LocalLibraryStore(url: url)
        let old = try Transcript(itemID: item.itemID, revisionID: RevisionID(rawValue: "rev-old"),
                                 availability: .available, text: "Older text.",
                                 updatedAt: Timestamp(Date(timeIntervalSince1970: 10)))
        let absent = try Transcript(itemID: item.itemID, revisionID: RevisionID(rawValue: "rev-new"),
                                    availability: .absent,
                                    updatedAt: Timestamp(Date(timeIntervalSince1970: 20)))
        try await store.save(transcript: old)
        try await store.save(transcript: absent)

        let loaded = try await store.latestTranscript(for: item.itemID)
        XCTAssertEqual(loaded, absent)
    }

    func testLatestTranscriptIsNilAfterDismissalAndUnsubscribe() async throws {
        let url = makeURL(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = try LocalLibraryStore(url: url)
        let (feed, episode) = try podcastValues()
        try await store.save(feed: feed)
        try await store.save(subscription: PodcastSubscription(feedID: feed.itemID, subscribedAt: feed.createdAt))
        try await store.save(episode: episode)
        let revision = try podcastRevision(itemID: episode.itemID, id: "rev-remove", hashDigit: "b")
        try await store.saveReadyRevision(
            revision, mediaURL: url.appendingPathComponent("remove.m4a"),
            transcript: try Transcript(itemID: episode.itemID, revisionID: revision.revisionID,
                                       availability: .available, text: "Removed.", updatedAt: revision.createdAt)
        )
        try await store.dismissPodcastEpisode(episode.itemID)
        let afterDismissal = try await store.latestTranscript(for: episode.itemID)
        XCTAssertNil(afterDismissal)

        let secondFeedURL = URL(string: "https://podcasts.example.test/latest-transcript-unsubscribe/feed.xml")!
        let (secondFeed, secondEpisodes) = try episodes(feedURL: secondFeedURL,
                                                        origin: Date(timeIntervalSince1970: 1_700_000_000),
                                                        daysAgo: [1])
        let second = secondEpisodes[0]
        try await store.save(feed: secondFeed)
        try await store.save(subscription: PodcastSubscription(feedID: secondFeed.itemID, subscribedAt: secondFeed.createdAt))
        try await store.save(episode: second)
        let secondRevision = try podcastRevision(itemID: second.itemID, id: "rev-unsubscribe", hashDigit: "c")
        try await store.saveReadyRevision(
            secondRevision, mediaURL: url.appendingPathComponent("unsubscribe.m4a"),
            transcript: try Transcript(itemID: second.itemID, revisionID: secondRevision.revisionID,
                                       availability: .available, text: "Unsubscribed.", updatedAt: secondRevision.createdAt)
        )
        _ = try await store.unsubscribeFromPodcast(feedID: secondFeed.itemID)
        let afterUnsubscribe = try await store.latestTranscript(for: second.itemID)
        XCTAssertNil(afterUnsubscribe)
    }

    func testLatestTranscriptIsNilForUnknownItem() async throws {
        let url = makeURL(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = try LocalLibraryStore(url: url)
        let unknown = try ItemID(rawValue: "unknown-latest-transcript")

        let loaded = try await store.latestTranscript(for: unknown)
        XCTAssertNil(loaded)
    }

    func testLatestTranscriptIgnoresOtherItems() async throws {
        let url = makeURL(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let first = try article()
        let second = try ItemID(rawValue: "other-latest-transcript")
        let store = try LocalLibraryStore(url: url)
        let transcript = try Transcript(itemID: second, revisionID: RevisionID(rawValue: "rev-other"),
                                        availability: .available, text: "Other item.",
                                        updatedAt: Timestamp(Date(timeIntervalSince1970: 10)))
        try await store.save(transcript: transcript)

        let loaded = try await store.latestTranscript(for: first.itemID)
        XCTAssertNil(loaded)
    }
}
