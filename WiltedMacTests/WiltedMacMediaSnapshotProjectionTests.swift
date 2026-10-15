import Foundation
import SwiftData
import WiltedDomain
import WiltedLibrary
@testable import WiltedProducer
@testable import WiltedMac
import XCTest

@MainActor
final class WiltedMacMediaSnapshotProjectionTests: XCTestCase {
    private let feedURL = URL(string: "https://podcasts.example.test/projection-test.xml")!
    private let timestamp = Timestamp(Date(timeIntervalSince1970: 1_700_000_000))

    private func makeStore(_ suffix: String) throws -> (LocalLibraryStore, URL) {
        let dir = wiltedTemporaryDirectory(suffix)
        let storeURL = dir.appendingPathComponent("library.sqlite")
        let store = try LocalLibraryStore(url: storeURL)
        return (store, dir)
    }

    private func dummyAudioFile(in directory: URL, name: String, byteCount: Int64 = 256) throws -> (URL, String) {
        let fileURL = directory.appendingPathComponent(name)
        let data = Data(repeating: 0x41, count: Int(byteCount))
        try data.write(to: fileURL)
        let hash = "sha256:" + String(repeating: "a", count: 64)
        return (fileURL, hash)
    }

    private func seedPodcastEpisode(
        in store: LocalLibraryStore, directory: URL, guid: String, byteCount: Int64 = 256
    ) async throws -> (ItemID, RevisionID, URL) {
        let feedID = try ItemID.derivePodcastFeed(from: feedURL)
        try await store.save(feed: PodcastFeed(itemID: feedID, canonicalURL: feedURL, title: "Test Show", createdAt: timestamp))
        let enclosure = URL(string: "https://media.example.test/\(guid).mp3")!
        let itemID = try ItemID.derivePodcastEpisode(feedURL: feedURL, rssGUID: guid, enclosureURL: enclosure)
        let episode = try PodcastEpisode(
            itemID: itemID, feedID: feedID, feedURL: feedURL, rssGUID: guid, title: "Episode \(guid)",
            publishedTime: timestamp, enclosureURL: enclosure, enclosureMediaType: "audio/mpeg", createdAt: timestamp
        )
        try await store.save(episode: episode)

        let revisionID = try RevisionID(rawValue: "rev-\(guid)")
        let (fileURL, contentHash) = try dummyAudioFile(in: directory, name: "\(guid).m4a", byteCount: byteCount)
        let revision = try AudioRevision(
            itemID: itemID, revisionID: revisionID, durationSeconds: 120, byteCount: byteCount,
            contentHash: contentHash, mediaType: "audio/mp4", createdAt: timestamp, schemaVersion: 1
        )
        try await store.saveReadyRevision(revision, mediaURL: fileURL)
        let download = try PodcastDownload(
            episodeID: itemID, status: .completed, bytesReceived: byteCount,
            expectedByteCount: byteCount, localURL: fileURL, contentHash: contentHash, updatedAt: timestamp
        )
        try await store.save(download: download)
        let outcome = PodcastPreparationOutcome(
            episodeID: itemID, revisionID: revisionID, policyDigest: "policy-digest",
            pipelineFingerprint: "fingerprint", semanticVersion: "1.0.0", producedAt: timestamp,
            eligibility: .current
        )
        try await store.savePreparationOutcome(outcome)
        return (itemID, revisionID, fileURL)
    }

    func testReadyAudioAndPreparedQueuedAudioUsePublicationProfileWithoutDecodingTranscripts() async throws {
        let (store, dir) = try makeStore("projection-publication-profile")
        let (itemID, revisionID, fileURL) = try await seedPodcastEpisode(in: store, directory: dir, guid: "clean")
        try await store.replacePodcastQueue(try PodcastQueueState(episodeIDs: [itemID], currentEpisodeID: itemID))

        // Insert corrupt TranscriptRecord that fails decodeTranscript
        let context = ModelContext(store.container)
        let corruptTranscript = try LocalLibrarySchemaV7Models.TranscriptRecord(Transcript(
            itemID: itemID, revisionID: revisionID, availability: .available,
            text: "Corrupt text", updatedAt: timestamp))
        corruptTranscript.availability = "invalid-unrecognized-availability"
        corruptTranscript.format = "invalid-format"
        corruptTranscript.timing = "invalid-timing"
        corruptTranscript.cues = Data([0xFF, 0xFE, 0xFD])
        context.insert(corruptTranscript)

        // Insert corrupt PreparationRecord that fails JSON decoding
        let corruptPrep = try LocalLibrarySchemaV3Models.PreparationRecord(PreparationJournalEntry(
            id: "corrupt-run|stage#1", itemID: itemID, requestID: "corrupt-run",
            status: try PreparationStatus(stage: .preparing, detail: "Synthetic preparation",
                cancellable: true, emittedAt: timestamp)))
        corruptPrep.statusData = Data([0xDE, 0xAD, 0xBE, 0xEF])
        context.insert(corruptPrep)
        try context.save()

        let beforeFull = await store.podcastLibrarySnapshotFetchCount
        _ = try await store.podcastLibrarySnapshot()
        let fullCost = await store.podcastLibrarySnapshotFetchCount - beforeFull
        let beforePublication = await store.podcastLibrarySnapshotFetchCount
        _ = try await store.podcastLibrarySnapshot(profile: .publication)
        let publicationCost = await store.podcastLibrarySnapshotFetchCount - beforePublication
        XCTAssertEqual(fullCost - publicationCost, 2, "Publication omits transcript and preparation-journal fetches")

        let localSource = WiltedMacLocalReadyAudioSource(store: store)

        // The actual ready-audio caller pays the measured publication cost.
        let beforeSingle = await store.podcastLibrarySnapshotFetchCount
        let single = try await localSource.readyAudio(for: itemID)
        let singleCost = await store.podcastLibrarySnapshotFetchCount - beforeSingle
        XCTAssertEqual(singleCost, publicationCost)
        let ready = try XCTUnwrap(single)
        XCTAssertEqual(ready.revisionID, revisionID)
        XCTAssertEqual(ready.fileURL, fileURL)
        XCTAssertEqual(ready.byteCount, 256)

        let beforeQueued = await store.podcastLibrarySnapshotFetchCount
        let queued = try await localSource.preparedQueuedAudio()
        let queuedCost = await store.podcastLibrarySnapshotFetchCount - beforeQueued
        XCTAssertEqual(queuedCost, publicationCost, "Queued ready audio also omits the two display payload fetches")
        XCTAssertEqual(queued[itemID]?.revisionID, revisionID)

        // Exact requested reads report corruption; the full snapshot intentionally skips bad rows.
        do {
            _ = try await store.transcript(for: itemID, revisionID: revisionID)
            XCTFail("The exact corrupt transcript read must throw")
        } catch let error as LocalLibraryStoreError {
            XCTAssertEqual(error, .invalidPreparationStatus("transcript"))
        }
        let exportText = "Verified transcript export remains available after the audio-only read."
        try await store.save(transcript: Transcript(itemID: itemID, revisionID: revisionID,
            availability: .available, text: exportText, updatedAt: timestamp))
        let beforeExport = await store.podcastLibrarySnapshotFetchCount
        let requestedValue = try await localSource.transcript(for: itemID, revisionID: revisionID)
        let exportCost = await store.podcastLibrarySnapshotFetchCount - beforeExport
        XCTAssertEqual(exportCost, fullCost, "Explicit transcript export retains the full snapshot read")
        let requested = try XCTUnwrap(requestedValue)
        XCTAssertEqual(requested.entryID, itemID)
        XCTAssertEqual(requested.revisionID, revisionID)
        XCTAssertEqual(requested.plainText, exportText, "Requested export still decodes its saved payload")
    }

    func testPreparedAudioProofGuardsPreserveExclusions() async throws {
        let (store, dir) = try makeStore("projection-guards")
        let (goodID, goodRev, _) = try await seedPodcastEpisode(in: store, directory: dir, guid: "good")
        let (unprepID, _, _) = try await seedPodcastEpisode(in: store, directory: dir, guid: "unprepared")
        let (retiredID, _, _) = try await seedPodcastEpisode(in: store, directory: dir, guid: "retired")
        let (dismissedID, _, _) = try await seedPodcastEpisode(in: store, directory: dir, guid: "dismissed")
        let (badHashID, _, _) = try await seedPodcastEpisode(in: store, directory: dir, guid: "bad-hash")

        // Invalidate eligibility for unprepID
        let invalidOutcome = PodcastPreparationOutcome(
            episodeID: unprepID, revisionID: try RevisionID(rawValue: "rev-unprepared"),
            policyDigest: "p", pipelineFingerprint: "f", semanticVersion: "1.0", producedAt: timestamp,
            eligibility: .invalid
        )
        try await store.savePreparationOutcome(invalidOutcome)

        // Retire retiredID
        _ = try await store.retireEpisode(retiredID)

        // Dismiss dismissedID
        _ = try await store.dismissPodcastEpisode(dismissedID)

        // Corrupt content hash on download for badHashID
        let badDownload = try PodcastDownload(
            episodeID: badHashID, status: .completed, bytesReceived: 256,
            expectedByteCount: 256, localURL: dir.appendingPathComponent("bad-hash.m4a"),
            contentHash: "sha256:" + String(repeating: "d", count: 64), updatedAt: timestamp
        )
        try await store.save(download: badDownload)

        try await store.replacePodcastQueue(try PodcastQueueState(
            episodeIDs: [goodID, unprepID, retiredID, dismissedID, badHashID], currentEpisodeID: goodID
        ))

        let source = WiltedMacLocalReadyAudioSource(store: store)
        let prepared = try await source.preparedQueuedAudio()

        XCTAssertEqual(prepared.count, 1)
        XCTAssertEqual(prepared[goodID]?.revisionID, goodRev)
        XCTAssertNil(prepared[unprepID], "invalid eligibility must be excluded")
        XCTAssertNil(prepared[retiredID], "retired episode must be excluded")
        XCTAssertNil(prepared[dismissedID], "dismissed episode must be excluded")
        XCTAssertNil(prepared[badHashID], "content hash mismatch must be excluded")
    }

    func testArticleAndAudiobookPathInOwnAudioUsesPublicationProfile() async throws {
        let (store, dir) = try makeStore("projection-articles-books")
        let (podcastID, podcastRev, _) = try await seedPodcastEpisode(in: store, directory: dir, guid: "pod")

        // Seed live article
        let articleURL = URL(string: "https://articles.example.test/post-1")!
        let articleID = try ItemID.derive(from: articleURL)
        let article = try Article(itemID: articleID, canonicalURL: articleURL, title: "Post 1", source: "Blog", createdAt: timestamp)
        try await store.save(article: article)
        let (articleFile, articleHash) = try dummyAudioFile(in: dir, name: "article.m4a", byteCount: 512)
        let articleRevID = try RevisionID(rawValue: "rev-article")
        let articleRevision = try AudioRevision(
            itemID: articleID, revisionID: articleRevID, durationSeconds: 60, byteCount: 512,
            contentHash: articleHash, mediaType: "audio/mp4", createdAt: timestamp, schemaVersion: 1
        )
        try await store.saveReadyRevision(articleRevision, mediaURL: articleFile)

        // Seed deleted article
        let deletedURL = URL(string: "https://articles.example.test/post-deleted")!
        let deletedID = try ItemID.derive(from: deletedURL)
        let deletedArticle = try Article(
            itemID: deletedID, canonicalURL: deletedURL, title: "Deleted Post", source: "Blog",
            createdAt: timestamp, isDeleted: true
        )
        try await store.save(article: deletedArticle)
        let (delFile, delHash) = try dummyAudioFile(in: dir, name: "del.m4a", byteCount: 128)
        let delRevID = try RevisionID(rawValue: "rev-deleted")
        let delRevision = try AudioRevision(
            itemID: deletedID, revisionID: delRevID, durationSeconds: 30, byteCount: 128,
            contentHash: delHash, mediaType: "audio/mp4", createdAt: timestamp, schemaVersion: 1
        )
        try await store.saveReadyRevision(delRevision, mediaURL: delFile)

        // Seed live audiobook volume
        let bookID = try ItemID.audiobook(contentDigest: String(repeating: "b", count: 64), layout: "x", volume: 0)
        let (bookFile, bookHash) = try dummyAudioFile(in: dir, name: "book.m4a", byteCount: 1024)
        let bookRevID = try RevisionID(rawValue: "rev-book")
        let bookRevision = try AudioRevision(
            itemID: bookID, revisionID: bookRevID, durationSeconds: 900, byteCount: 1024,
            contentHash: bookHash, mediaType: "audio/mp4", createdAt: timestamp, schemaVersion: 1
        )
        try await store.saveAudiobookVolumes([
            AudiobookVolumeSave(
                itemID: bookID, revision: bookRevision, mediaURL: bookFile, title: "Book One", author: "Author",
                chapters: [AudiobookChapterMark(title: "Ch 1", startSeconds: 0)], sourceFormat: "audio",
                volumeIndex: 0, volumeCount: 1, createdAt: timestamp.date
            )
        ])

        // Seed removed audiobook volume
        let removedBookID = try ItemID.audiobook(contentDigest: String(repeating: "c", count: 64), layout: "x", volume: 0)
        let (remBookFile, remBookHash) = try dummyAudioFile(in: dir, name: "rem-book.m4a", byteCount: 256)
        let remBookRevID = try RevisionID(rawValue: "rev-rem-book")
        let remBookRevision = try AudioRevision(
            itemID: removedBookID, revisionID: remBookRevID, durationSeconds: 300, byteCount: 256,
            contentHash: remBookHash, mediaType: "audio/mp4", createdAt: timestamp, schemaVersion: 1
        )
        try await store.saveAudiobookVolumes([
            AudiobookVolumeSave(
                itemID: removedBookID, revision: remBookRevision, mediaURL: remBookFile, title: "Removed Book", author: "Author",
                chapters: [AudiobookChapterMark(title: "Ch 1", startSeconds: 0)], sourceFormat: "audio",
                volumeIndex: 0, volumeCount: 1, createdAt: timestamp.date
            )
        ])

        let removedContext = ModelContext(store.container)
        let removedRawID = removedBookID.rawValue
        let removedRecord = try XCTUnwrap(removedContext.fetch(
            FetchDescriptor<LocalLibrarySchemaV17Models.AudiobookRecord>(predicate: #Predicate { $0.id == removedRawID })
        ).first)
        removedRecord.isRemoved = true
        try removedContext.save()

        try await store.replacePodcastQueue(try PodcastQueueState(
            episodeIDs: [podcastID, articleID, deletedID, bookID, removedBookID], currentEpisodeID: podcastID
        ))

        let librarySource = WiltedMacLibraryReadyAudioSource(store: store)
        let allReady = try await librarySource.preparedQueuedAudio()

        XCTAssertEqual(allReady[podcastID]?.revisionID, podcastRev)
        XCTAssertEqual(allReady[articleID]?.revisionID, articleRevID)
        XCTAssertEqual(allReady[bookID]?.revisionID, bookRevID)
        XCTAssertNil(allReady[deletedID], "deleted articles must be excluded from ownAudio")
        XCTAssertNil(allReady[removedBookID], "removed audiobooks must be excluded from ownAudio")

        let singleArticle = try await librarySource.readyAudio(for: articleID)
        XCTAssertEqual(singleArticle?.revisionID, articleRevID)

        let singleBook = try await librarySource.readyAudio(for: bookID)
        XCTAssertEqual(singleBook?.revisionID, bookRevID)
    }
}
