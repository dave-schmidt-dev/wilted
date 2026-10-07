import CryptoKit
import Foundation
import SwiftData
import XCTest
import WiltedDomain
import WiltedSync
@testable import WiltedProducer

extension LocalLibraryStoreTests {
    // MARK: Orphan media audit and sweep (Task 2.1a)

    /// A store and a dedicated media root, so the audit never scans the store's
    /// own files.
    private func mediaSweepRoot(_ name: String) throws -> (root: URL, media: URL, store: LocalLibraryStore) {
        let root = OwnedTestTemp.root
            .appendingPathComponent("wilted-media-sweep-\(name)-\(UUID().uuidString)")
        let media = root.appendingPathComponent("media", isDirectory: true)
        try FileManager.default.createDirectory(at: media, withIntermediateDirectories: true)
        let store = try LocalLibraryStore(url: root.appendingPathComponent("library.sqlite"))
        return (root, media, store)
    }

    /// One feed with the given episodes admitted into `fixture`'s store.
    private func admittedPodcastEpisodes(
        in fixture: (root: URL, media: URL, store: LocalLibraryStore),
        name: String,
        daysAgo: [Int]
    ) async throws -> (feed: PodcastFeed, episodes: [PodcastEpisode]) {
        let origin = Date(timeIntervalSince1970: 1_700_000_000)
        let feedURL = try XCTUnwrap(URL(string: "https://podcasts.example.test/\(name)/feed.xml"))
        let (feed, all) = try episodes(feedURL: feedURL, origin: origin, daysAgo: daysAgo)
        try await fixture.store.save(feed: feed)
        try await fixture.store.save(subscription: PodcastSubscription(
            feedID: feed.itemID, subscribedAt: Timestamp(origin)
        ))
        try await fixture.store.savePodcastEpisodes(all, admission: .backfill)
        return (feed, all)
    }

    /// One prepared episode media file plus the revision record that names it,
    /// under the episode's own `PodcastAudio` directory.
    @discardableResult
    private func installEpisodeMedia(
        in fixture: (root: URL, media: URL, store: LocalLibraryStore),
        episode: PodcastEpisode,
        revisionID: String,
        fileName: String,
        hashCharacter: Character
    ) async throws -> URL {
        let media = fixture.media
            .appendingPathComponent("PodcastAudio", isDirectory: true)
            .appendingPathComponent(episode.itemID.rawValue, isDirectory: true)
            .appendingPathComponent(fileName)
        try FileManager.default.createDirectory(at: media.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(fileName.utf8).write(to: media)
        let listed = try immutableRevisionFixture(
            itemID: episode.itemID, id: revisionID, hashCharacter: hashCharacter, path: media.path
        )
        try await fixture.store.saveReadyRevision(listed.revision, mediaURL: listed.mediaURL)
        return media
    }

    func testMediaAuditCountsOnlyFilesNothingReachableNames() async throws {
        let fixture = try mediaSweepRoot("audit")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let itemID = try immutableRevisionItemID("audit")
        let named = try immutableRevisionFixture(
            itemID: itemID, id: "rev-audit", hashCharacter: "6",
            path: fixture.media.appendingPathComponent("named.m4a").path
        )
        try Data("named".utf8).write(to: named.mediaURL)
        try await fixture.store.saveReadyRevision(named.revision, mediaURL: named.mediaURL)

        let downloadURL = fixture.media.appendingPathComponent("download.mp3")
        try Data("download".utf8).write(to: downloadURL)
        try await fixture.store.save(download: try PodcastDownload(
            episodeID: itemID, status: .completed, bytesReceived: 8, expectedByteCount: 8,
            localURL: downloadURL, contentHash: "sha256:" + String(repeating: "7", count: 64),
            updatedAt: Timestamp(Date(timeIntervalSince1970: 1_700_000_000))
        ))

        let inFlight = fixture.media.appendingPathComponent("candidate-inflight.m4a")
        try Data("candidate".utf8).write(to: inFlight)
        fixture.store.inFlightMedia.begin(inFlight)

        let orphan = fixture.media.appendingPathComponent("orphan.m4a")
        try Data("orphan".utf8).write(to: orphan)

        let unreferenced = try await fixture.store.unreferencedMediaFiles(in: [fixture.media])
        XCTAssertEqual(
            unreferenced.map(\.lastPathComponent), ["orphan.m4a"],
            "the audit counts a file no record names and no writer holds"
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: orphan.path),
                      "the audit is a read; it deletes nothing")
    }

    func testSweepDeletesAnUnreferencedFileAndReportsFilesAndBytes() async throws {
        let fixture = try mediaSweepRoot("sweep-bytes")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let audio = fixture.media.appendingPathComponent("PodcastAudio", isDirectory: true)
        try FileManager.default.createDirectory(at: audio, withIntermediateDirectories: true)
        let orphan = audio.appendingPathComponent("orphan.m4a")
        let payload = Data("orphan".utf8)
        try payload.write(to: orphan)

        let report = try await fixture.store.sweepUnreferencedMedia(in: [audio], excluding: [])

        XCTAssertEqual(report.files, 1)
        XCTAssertEqual(report.bytes, Int64(payload.count))
        XCTAssertEqual(report.clearedRecords, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: orphan.path),
                       "unreferenced episode audio is deleted directly")
    }

    func testSweepKeepsReferencedInFlightAndExcludedFiles() async throws {
        let fixture = try mediaSweepRoot("sweep-keeps")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let itemID = try immutableRevisionItemID("sweep-keeps")
        let named = try immutableRevisionFixture(
            itemID: itemID, id: "rev-sweep-keeps", hashCharacter: "1",
            path: fixture.media.appendingPathComponent("named.m4a").path
        )
        try Data("named".utf8).write(to: named.mediaURL)
        try await fixture.store.saveReadyRevision(named.revision, mediaURL: named.mediaURL)

        let inFlight = fixture.media.appendingPathComponent("in-flight.m4a")
        try Data("in-flight".utf8).write(to: inFlight)
        fixture.store.inFlightMedia.begin(inFlight)

        let excluded = fixture.media.appendingPathComponent("excluded.m4a")
        try Data("excluded".utf8).write(to: excluded)

        let orphan = fixture.media.appendingPathComponent("orphan.m4a")
        try Data("orphan".utf8).write(to: orphan)

        let report = try await fixture.store.sweepUnreferencedMedia(
            in: [fixture.media], excluding: [excluded]
        )

        XCTAssertEqual(report.files, 1, "only the unguarded orphan is swept")
        for survivor in [named.mediaURL, inFlight, excluded] {
            XCTAssertTrue(
                FileManager.default.fileExists(atPath: survivor.path),
                "\(survivor.lastPathComponent) must survive"
            )
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: orphan.path))
    }

    func testSweepLeavesAlignedSttCacheAndInProgressPreparationOutputInPlace() async throws {
        let fixture = try mediaSweepRoot("sweep-stt")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let audio = fixture.media.appendingPathComponent("PodcastAudio", isDirectory: true)
        try FileManager.default.createDirectory(at: audio, withIntermediateDirectories: true)

        let cache = fixture.root.appendingPathComponent("aligned-stt", isDirectory: true)
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        let cached = cache.appendingPathComponent("aligned.json")
        try Data("cache".utf8).write(to: cached)

        let prepared = audio.appendingPathComponent("prepared-episode.m4a")
        try Data("prepared".utf8).write(to: prepared)
        fixture.store.inFlightMedia.begin(prepared)

        let report = try await fixture.store.sweepUnreferencedMedia(in: [audio], excluding: [])

        XCTAssertEqual(report.files, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: cached.path),
                      "a cache directory the caller did not pass is never scanned")
        XCTAssertTrue(FileManager.default.fileExists(atPath: prepared.path),
                      "a preparation output still registered in flight stays")
    }

    func testSweepKeepsAPublishedPreparationOutputMovedButNotYetCommitted() async throws {
        let fixture = try mediaSweepRoot("sweep-published")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let audio = fixture.media.appendingPathComponent("PodcastAudio", isDirectory: true)
        try FileManager.default.createDirectory(at: audio, withIntermediateDirectories: true)
        let finalURL = audio.appendingPathComponent("rev-published.m4a")
        try Data("prepared".utf8).write(to: finalURL)

        fixture.store.inFlightMedia.begin(finalURL)
        let whileMoving = try await fixture.store.sweepUnreferencedMedia(in: [audio], excluding: [])
        XCTAssertEqual(whileMoving.files, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: finalURL.path),
                      "the publish move registers the destination before the record lands")

        fixture.store.inFlightMedia.end(finalURL)
        let afterCommit = try await fixture.store.sweepUnreferencedMedia(in: [audio], excluding: [])
        XCTAssertEqual(afterCommit.files, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: finalURL.path))
    }

    func testDismissDeletesTheEpisodesMediaFile() async throws {
        let fixture = try mediaSweepRoot("dismiss-media")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let (_, episodes) = try await admittedPodcastEpisodes(in: fixture, name: "dismiss-media", daysAgo: [1])
        let episode = try XCTUnwrap(episodes.first)
        let media = try await installEpisodeMedia(
            in: fixture, episode: episode, revisionID: "rev-dismiss-media",
            fileName: "episode.m4a", hashCharacter: "e"
        )

        let dismissed = try await fixture.store.dismissPodcastEpisode(episode.itemID)

        XCTAssertTrue(dismissed)
        XCTAssertFalse(FileManager.default.fileExists(atPath: media.path),
                       "the deleted records named this media, so it goes with them")
        let readyAfterDismissal = try await fixture.store.readyRevision(for: episode.itemID)
        XCTAssertNil(readyAfterDismissal)
    }

    func testDismissKeepsAFileAnotherSurvivingEpisodeStillNames() async throws {
        let fixture = try mediaSweepRoot("dismiss-shared")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let (_, episodes) = try await admittedPodcastEpisodes(
            in: fixture, name: "dismiss-shared", daysAgo: [1, 2]
        )
        let shared = fixture.media.appendingPathComponent("shared.m4a")
        try Data("shared".utf8).write(to: shared)
        for (index, episode) in episodes.enumerated() {
            let listed = try immutableRevisionFixture(
                itemID: episode.itemID, id: "rev-dismiss-shared-\(index)",
                hashCharacter: Character(index == 0 ? "a" : "b"), path: shared.path
            )
            try await fixture.store.saveReadyRevision(listed.revision, mediaURL: listed.mediaURL)
        }

        try await fixture.store.dismissPodcastEpisode(episodes[0].itemID)
        XCTAssertTrue(FileManager.default.fileExists(atPath: shared.path),
                      "a surviving episode's revision still names the file")

        try await fixture.store.dismissPodcastEpisode(episodes[1].itemID)
        XCTAssertFalse(FileManager.default.fileExists(atPath: shared.path),
                       "the last record naming the file is gone, so the file goes")
    }

    func testUnsubscribeDeletesTheFeedsEpisodeMedia() async throws {
        let fixture = try mediaSweepRoot("unsubscribe-media")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let (feed, episodes) = try await admittedPodcastEpisodes(
            in: fixture, name: "unsubscribe-media", daysAgo: [1, 2]
        )
        var mediaFiles: [URL] = []
        for (index, episode) in episodes.enumerated() {
            mediaFiles.append(try await installEpisodeMedia(
                in: fixture, episode: episode, revisionID: "rev-unsubscribe-media-\(index)",
                fileName: "episode-\(index).m4a", hashCharacter: Character(index == 0 ? "c" : "d")
            ))
        }

        let removed = try await fixture.store.unsubscribeFromPodcast(feedID: feed.itemID)

        XCTAssertEqual(removed, episodes.count)
        for media in mediaFiles {
            XCTAssertFalse(FileManager.default.fileExists(atPath: media.path),
                           "unsubscribe reclaims the feed's episode media")
        }
    }

    func testSecondDismissalDeletesNothing() async throws {
        let fixture = try mediaSweepRoot("dismiss-second")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let (_, episodes) = try await admittedPodcastEpisodes(in: fixture, name: "dismiss-second", daysAgo: [1])
        let episode = try XCTUnwrap(episodes.first)
        let media = try await installEpisodeMedia(
            in: fixture, episode: episode, revisionID: "rev-dismiss-second",
            fileName: "episode.m4a", hashCharacter: "f"
        )

        let firstDismissal = try await fixture.store.dismissPodcastEpisode(episode.itemID)
        XCTAssertTrue(firstDismissal)
        XCTAssertFalse(FileManager.default.fileExists(atPath: media.path))

        // A fresh unreferenced file at the same path stands in for anything
        // that appeared after the first dismissal; the second must not touch it.
        try Data("again".utf8).write(to: media)
        let secondDismissal = try await fixture.store.dismissPodcastEpisode(episode.itemID)
        XCTAssertFalse(secondDismissal)
        XCTAssertTrue(FileManager.default.fileExists(atPath: media.path),
                      "a second dismissal returns false and deletes nothing")
    }

    func testSweepClearsADownloadRecordWhoseFileIsMissingLeavingTheEpisodeNotDownloaded() async throws {
        let fixture = try mediaSweepRoot("sweep-clear-download")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let (_, episodes) = try await admittedPodcastEpisodes(
            in: fixture, name: "sweep-clear-download", daysAgo: [1]
        )
        let episode = try XCTUnwrap(episodes.first)
        let missing = fixture.media
            .appendingPathComponent("PodcastAudio", isDirectory: true)
            .appendingPathComponent(episode.itemID.rawValue, isDirectory: true)
            .appendingPathComponent("missing.mp3")
        try await fixture.store.save(download: try PodcastDownload(
            episodeID: episode.itemID, status: .completed, bytesReceived: 9, expectedByteCount: 9,
            localURL: missing, contentHash: "sha256:" + String(repeating: "3", count: 64),
            updatedAt: Timestamp(Date(timeIntervalSince1970: 1_700_000_000))
        ))

        let report = try await fixture.store.sweepUnreferencedMedia(in: [fixture.media], excluding: [])

        XCTAssertEqual(report.clearedRecords, 1)
        let afterSweep = try await fixture.store.download(for: episode.itemID)
        XCTAssertNil(afterSweep, "a completed record whose file is gone reads as never downloaded")
    }

    func testSweepClearsNothingWhenTheMediaDirectoryItselfIsMissing() async throws {
        let fixture = try mediaSweepRoot("sweep-unmounted")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let itemID = try immutableRevisionItemID("sweep-unmounted")
        let missing = fixture.media
            .appendingPathComponent("PodcastAudio", isDirectory: true)
            .appendingPathComponent(itemID.rawValue, isDirectory: true)
            .appendingPathComponent("missing.mp3")
        try await fixture.store.save(download: try PodcastDownload(
            episodeID: itemID, status: .completed, bytesReceived: 9, expectedByteCount: 9,
            localURL: missing, contentHash: "sha256:" + String(repeating: "4", count: 64),
            updatedAt: Timestamp(Date(timeIntervalSince1970: 1_700_000_000))
        ))
        let listed = try immutableRevisionFixture(
            itemID: itemID, id: "rev-unmounted", hashCharacter: "5", path: missing.path
        )
        try await fixture.store.saveReadyRevision(listed.revision, mediaURL: listed.mediaURL)

        try FileManager.default.removeItem(at: fixture.media)

        let report = try await fixture.store.sweepUnreferencedMedia(in: [fixture.media], excluding: [])

        XCTAssertEqual(report.clearedRecords, 0,
                       "an absent media root is a missing volume, not an emptied library")
        let stillDownloaded = try await fixture.store.download(for: itemID)
        XCTAssertNotNil(stillDownloaded)
        let stillListed = try await fixture.store.revisions(for: itemID)
        XCTAssertEqual(stillListed.count, 1)
    }

    func testTheSweepStillReclaimsTheSupersededSourceAfterAReplacement() async throws {
        let fixture = try mediaSweepRoot("superseded")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let itemID = try immutableRevisionItemID("superseded")
        let source = try immutableRevisionFixture(
            itemID: itemID, id: "rev-source", hashCharacter: "8",
            path: fixture.media.appendingPathComponent("source.mp3").path
        )
        let prepared = try immutableRevisionFixture(
            itemID: itemID, id: "rev-prepared", hashCharacter: "9",
            path: fixture.media.appendingPathComponent("prepared.m4a").path
        )
        try Data("source".utf8).write(to: source.mediaURL)
        try Data("prepared".utf8).write(to: prepared.mediaURL)
        try await fixture.store.saveReadyRevision(source.revision, mediaURL: source.mediaURL)

        try await fixture.store.replaceReadyRevision(
            prepared.revision, mediaURL: prepared.mediaURL, transcript: prepared.transcript,
            download: prepared.download, superseding: source.revision.revisionID,
            outcome: prepared.outcome
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.mediaURL.path))

        let report = try await fixture.store.sweepUnreferencedMedia(in: [fixture.media], excluding: [])
        XCTAssertEqual(report.files, 1, "the superseded source is the one file nothing names")
        XCTAssertFalse(FileManager.default.fileExists(atPath: source.mediaURL.path),
                       "a re-download/replacement still reclaims the superseded source")
        XCTAssertTrue(FileManager.default.fileExists(atPath: prepared.mediaURL.path))
    }

    func testASynthesisCandidateSurvivesASweepWhileItIsInFlight() async throws {
        let fixture = try mediaSweepRoot("synthesis")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        // `makeStream()` returns (stream, continuation) in that order.
        let (enteredStream, entered) = AsyncStream<Void>.makeStream()
        let (releaseStream, release) = AsyncStream<Void>.makeStream()
        let articleURL = try XCTUnwrap(URL(string: "https://example.test/sweep-candidate"))
        let coordinator = PreparationCoordinator(
            store: fixture.store,
            mediaDirectory: fixture.media,
            extraction: { url in
                ExtractedArticle(
                    sourceURL: url, canonicalURL: url, title: "Sweep", source: "example.test",
                    author: nil, body: "Fixture body."
                )
            },
            synthesis: { _ in
                SpeechSynthesisResult(requestID: "sweep", samples: [0, 0.1, -0.1], sampleRate: 24_000)
            },
            assembly: { _, itemID, destination, _ in
                try Data("candidate".utf8).write(to: destination)
                entered.yield()
                for await _ in releaseStream { break }
                let revision = try AudioRevision(
                    itemID: itemID, revisionID: RevisionID(rawValue: "rev-sweep"),
                    durationSeconds: 1, byteCount: 9,
                    contentHash: "sha256:" + String(repeating: "b", count: 64),
                    mediaType: "audio/mp4", createdAt: Timestamp(Date(timeIntervalSince1970: 1)),
                    schemaVersion: 1
                )
                return AudioAssemblyResult(revision: revision, mediaURL: destination)
            }
        )
        let run = await coordinator.start(url: articleURL)
        let statusesTask = Task { await collectPreparationStatuses(run.statuses) }
        var iterator = enteredStream.makeAsyncIterator()
        await iterator.next()

        let duringSynthesis = try await fixture.store.sweepUnreferencedMedia(in: [fixture.media], excluding: [])
        XCTAssertEqual(duringSynthesis.files, 0,
                       "the candidate is registered in flight before it exists")
        XCTAssertTrue(
            try FileManager.default.contentsOfDirectory(atPath: fixture.media.path)
                .contains { $0.hasPrefix("candidate-") }
        )

        release.yield()
        let statuses = await statusesTask.value
        XCTAssertEqual(try XCTUnwrap(statuses.last, "the run emitted no status").stage, .completed)
        let afterCommit = try await fixture.store.sweepUnreferencedMedia(in: [fixture.media], excluding: [])
        XCTAssertEqual(afterCommit.files, 0,
                       "the committed revision names the candidate, so it is no longer an orphan")
    }

    func testTheAssemblerHoldsItsTemporaryMediaInFlightWhileItWrites() throws {
        let fixture = try mediaSweepRoot("assembler")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let registry = MediaInFlightRegistry()
        let seen = InFlightObservation()
        let destination = fixture.media.appendingPathComponent("assembled.m4a")
        _ = try AudioAssembler(inFlightMedia: registry).assemble(
            samples: (0..<4_410).map { Float(0.1 * sin(Double($0))) },
            itemID: try immutableRevisionItemID("assembler"),
            destinationURL: destination,
            isCancelled: {
                seen.observe(registry.inFlightPaths)
                return false
            }
        )

        XCTAssertTrue(seen.paths.contains { $0.contains(".tmp-") },
                      "the temporary transfer file is in flight while it is written")
        XCTAssertTrue(registry.inFlightPaths.isEmpty,
                      "the temporary registration ends when the file is published")
        XCTAssertTrue(FileManager.default.fileExists(atPath: destination.path))
    }

    func testAReDownloadSupersedingARevisionLeavesTheSupersededFileGone() async throws {
        let fixture = try mediaSweepRoot("redownload")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let itemID = try immutableRevisionItemID("redownload")
        let first = try immutableRevisionFixture(
            itemID: itemID, id: "rev-redownload-first", hashCharacter: "c",
            path: fixture.media.appendingPathComponent("first.mp3").path
        )
        let second = try immutableRevisionFixture(
            itemID: itemID, id: "rev-redownload-second", hashCharacter: "d",
            path: fixture.media.appendingPathComponent("second.m4a").path
        )
        try Data("first".utf8).write(to: first.mediaURL)
        try Data("second".utf8).write(to: second.mediaURL)
        try await fixture.store.finalizePodcastDownload(
            revision: first.revision, mediaURL: first.mediaURL, download: first.download
        )

        // The superseding write removes the old revision record, so the old
        // file is the one thing nothing names.
        try await fixture.store.replaceReadyRevision(
            second.revision, mediaURL: second.mediaURL, transcript: second.transcript,
            download: second.download, superseding: first.revision.revisionID,
            outcome: second.outcome
        )
        let survivors = try await fixture.store.revisions(for: itemID)
        XCTAssertEqual(survivors.map(\.revision.revisionID), [second.revision.revisionID])
        let report = try await fixture.store.sweepUnreferencedMedia(in: [fixture.media], excluding: [])
        XCTAssertEqual(report.files, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: first.mediaURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: second.mediaURL.path))
    }

    // MARK: A re-download deletes the file it replaces (Task 2.1b)

    /// A forced re-download that lands different bytes repoints the episode at
    /// a new file; the old file and the revision record that named it go with
    /// the save, so the episode is left with exactly one file.
    func testRedownloadOfChangedContentLeavesExactlyOneFileForTheEpisode() async throws {
        let fixture = try mediaSweepRoot("redownload-changed")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let (_, episodes) = try await admittedPodcastEpisodes(
            in: fixture, name: "redownload-changed", daysAgo: [1]
        )
        let episode = try XCTUnwrap(episodes.first)
        let original = try await installEpisodeMedia(
            in: fixture, episode: episode, revisionID: "rev-redownload-changed-original",
            fileName: "original.m4a", hashCharacter: "a"
        )
        try await fixture.store.save(download: try PodcastDownload(
            episodeID: episode.itemID, status: .completed, bytesReceived: 8, expectedByteCount: 8,
            localURL: original, contentHash: "sha256:" + String(repeating: "a", count: 64),
            updatedAt: Timestamp(Date(timeIntervalSince1970: 1_700_000_000))
        ))

        let replacement = try immutableRevisionFixture(
            itemID: episode.itemID, id: "rev-redownload-changed-replacement", hashCharacter: "b",
            path: original.deletingLastPathComponent()
                .appendingPathComponent("replacement.m4a").path
        )
        try Data("replacement".utf8).write(to: replacement.mediaURL)
        try await fixture.store.finalizePodcastDownload(
            revision: replacement.revision, mediaURL: replacement.mediaURL,
            download: replacement.download
        )

        XCTAssertFalse(FileManager.default.fileExists(atPath: original.path),
                       "the re-download deletes the file it replaces")
        XCTAssertTrue(FileManager.default.fileExists(atPath: replacement.mediaURL.path))
        let downloadAfter = try await fixture.store.download(for: episode.itemID)
        XCTAssertEqual(downloadAfter?.localURL, replacement.mediaURL,
                       "the download record names the new file")
        let revisionsAfter = try await fixture.store.revisions(for: episode.itemID)
        XCTAssertEqual(revisionsAfter.map(\.revision.revisionID), [replacement.revision.revisionID],
                       "the revision record that named the old file went with it")
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: original.deletingLastPathComponent().path),
            ["replacement.m4a"],
            "exactly one file remains for the episode"
        )
    }

    /// Identical content re-downloaded lands at the same path for the same
    /// revision, so nothing is deleted.
    func testRedownloadOfIdenticalContentKeepsItsFile() async throws {
        let fixture = try mediaSweepRoot("redownload-identical")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let (_, episodes) = try await admittedPodcastEpisodes(
            in: fixture, name: "redownload-identical", daysAgo: [1]
        )
        let episode = try XCTUnwrap(episodes.first)
        let original = try immutableRevisionFixture(
            itemID: episode.itemID, id: "rev-redownload-identical", hashCharacter: "c",
            path: fixture.media
                .appendingPathComponent("PodcastAudio", isDirectory: true)
                .appendingPathComponent(episode.itemID.rawValue, isDirectory: true)
                .appendingPathComponent("episode.m4a").path
        )
        try FileManager.default.createDirectory(
            at: original.mediaURL.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try Data("episode".utf8).write(to: original.mediaURL)
        try await fixture.store.finalizePodcastDownload(
            revision: original.revision, mediaURL: original.mediaURL, download: original.download
        )

        try await fixture.store.finalizePodcastDownload(
            revision: original.revision, mediaURL: original.mediaURL, download: original.download
        )

        XCTAssertTrue(FileManager.default.fileExists(atPath: original.mediaURL.path),
                      "identical content re-downloaded keeps its file")
        let downloadAfter = try await fixture.store.download(for: episode.itemID)
        XCTAssertEqual(downloadAfter?.localURL, original.mediaURL)
        let revisionsAfter = try await fixture.store.revisions(for: episode.itemID)
        XCTAssertEqual(revisionsAfter.map(\.revision.revisionID), [original.revision.revisionID])
    }

    /// The deletion primitive consults every surviving record, so a file
    /// another episode's revision still names survives the re-download.
    func testRedownloadKeepsAnOldFileAnotherEpisodeStillNames() async throws {
        let fixture = try mediaSweepRoot("redownload-shared")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let (_, episodes) = try await admittedPodcastEpisodes(
            in: fixture, name: "redownload-shared", daysAgo: [1, 2]
        )
        let shared = fixture.media.appendingPathComponent("shared.m4a")
        try Data("shared".utf8).write(to: shared)
        for (index, episode) in episodes.enumerated() {
            let listed = try immutableRevisionFixture(
                itemID: episode.itemID, id: "rev-redownload-shared-\(index)",
                hashCharacter: Character(index == 0 ? "a" : "b"), path: shared.path
            )
            try await fixture.store.saveReadyRevision(listed.revision, mediaURL: listed.mediaURL)
        }
        try await fixture.store.save(download: try PodcastDownload(
            episodeID: episodes[0].itemID, status: .completed, bytesReceived: 6, expectedByteCount: 6,
            localURL: shared, contentHash: "sha256:" + String(repeating: "a", count: 64),
            updatedAt: Timestamp(Date(timeIntervalSince1970: 1_700_000_000))
        ))

        let replacement = try immutableRevisionFixture(
            itemID: episodes[0].itemID, id: "rev-redownload-shared-replacement", hashCharacter: "d",
            path: fixture.media.appendingPathComponent("replacement.m4a").path
        )
        try Data("replacement".utf8).write(to: replacement.mediaURL)
        try await fixture.store.finalizePodcastDownload(
            revision: replacement.revision, mediaURL: replacement.mediaURL,
            download: replacement.download
        )

        XCTAssertTrue(FileManager.default.fileExists(atPath: shared.path),
                      "the other episode's revision still names the old file")
        XCTAssertTrue(FileManager.default.fileExists(atPath: replacement.mediaURL.path))
        let survivorRevision = try await fixture.store.readyRevision(for: episodes[1].itemID)
        XCTAssertEqual(survivorRevision?.mediaURL, shared)
        let reloadedRevisions = try await fixture.store.revisions(for: episodes[0].itemID)
        XCTAssertEqual(reloadedRevisions.map(\.revision.revisionID), [replacement.revision.revisionID],
                       "only the re-downloading episode loses its old revision record")
    }

    /// The guard runs before any save, so a finalize that fails it leaves the
    /// old file and every record naming it untouched.
    func testRedownloadDeletesNothingWhenTheSaveFails() async throws {
        let fixture = try mediaSweepRoot("redownload-failed-save")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let (_, episodes) = try await admittedPodcastEpisodes(
            in: fixture, name: "redownload-failed-save", daysAgo: [1]
        )
        let episode = try XCTUnwrap(episodes.first)
        let original = try await installEpisodeMedia(
            in: fixture, episode: episode, revisionID: "rev-redownload-failed-save",
            fileName: "episode.m4a", hashCharacter: "e"
        )
        try await fixture.store.save(download: try PodcastDownload(
            episodeID: episode.itemID, status: .completed, bytesReceived: 8, expectedByteCount: 8,
            localURL: original, contentHash: "sha256:" + String(repeating: "e", count: 64),
            updatedAt: Timestamp(Date(timeIntervalSince1970: 1_700_000_000))
        ))

        // The download's byte count does not match its revision, so the guard
        // fails before any record is written or any file is deleted.
        let mismatched = try immutableRevisionFixture(
            itemID: episode.itemID, id: "rev-redownload-failed-save-new", hashCharacter: "f",
            path: original.deletingLastPathComponent()
                .appendingPathComponent("never-finalized.m4a").path
        )
        let invalidDownload = try PodcastDownload(
            episodeID: episode.itemID, status: .completed, bytesReceived: 32, expectedByteCount: 64,
            localURL: mismatched.mediaURL, contentHash: mismatched.revision.contentHash,
            updatedAt: Timestamp(Date(timeIntervalSince1970: 1_700_000_000))
        )
        do {
            try await fixture.store.finalizePodcastDownload(
                revision: mismatched.revision, mediaURL: mismatched.mediaURL,
                download: invalidDownload
            )
            XCTFail("an invalid download must fail the guard")
        } catch {}

        XCTAssertTrue(FileManager.default.fileExists(atPath: original.path),
                       "a finalize that never saved deletes nothing")
        let downloadAfter = try await fixture.store.download(for: episode.itemID)
        XCTAssertEqual(downloadAfter?.localURL, original,
                       "the record still names the old file")
        let revisionsAfter = try await fixture.store.revisions(for: episode.itemID)
        let originalRevisionID = try RevisionID(rawValue: "rev-redownload-failed-save")
        XCTAssertEqual(revisionsAfter.map(\.revision.revisionID), [originalRevisionID],
                       "the revision record that names the old file survives the failed finalize")
    }

    // MARK: Records equal audio (Task 2.1c)

    /// Retiring deletes the revision, download, and artwork records that named
    /// the episode's media, and the files go with them.
    func testRetireDeletesTheEpisodesAudioAndItsAudioRecords() async throws {
        let fixture = try mediaSweepRoot("retire-media")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let (_, episodes) = try await admittedPodcastEpisodes(in: fixture, name: "retire-media", daysAgo: [1])
        let episode = try XCTUnwrap(episodes.first)
        let media = try await installEpisodeMedia(
            in: fixture, episode: episode, revisionID: "rev-retire-media",
            fileName: "episode.m4a", hashCharacter: "a"
        )
        try await fixture.store.save(download: try PodcastDownload(
            episodeID: episode.itemID, status: .completed, bytesReceived: 8, expectedByteCount: 8,
            localURL: media, contentHash: "sha256:" + String(repeating: "a", count: 64),
            updatedAt: Timestamp(Date(timeIntervalSince1970: 1_700_000_000))
        ))
        let artwork = media.deletingLastPathComponent().appendingPathComponent("cover.jpg")
        try Data("cover".utf8).write(to: artwork)
        let artworkRecord = try PodcastArtwork(
            id: "artwork-retire-media", ownerID: episode.itemID, localURL: artwork,
            updatedAt: Timestamp(Date(timeIntervalSince1970: 1_700_000_000))
        )
        try await fixture.store.save(artwork: artworkRecord)

        let retired = try await fixture.store.retireEpisode(episode.itemID)
        let downloadAfterRetire = try await fixture.store.download(for: episode.itemID)
        let revisionsAfterRetire = try await fixture.store.revisions(for: episode.itemID)
        let artworkAfterRetire = try await fixture.store.artwork(for: "artwork-retire-media")
        let removalKindAfterRetire = try await fixture.store.removalKind(for: episode.itemID)

        XCTAssertTrue(retired)
        for file in [media, artwork] {
            XCTAssertFalse(FileManager.default.fileExists(atPath: file.path),
                           "\(file.lastPathComponent) was named by a deleted record and goes with it")
        }
        XCTAssertNil(downloadAfterRetire)
        XCTAssertTrue(revisionsAfterRetire.isEmpty)
        XCTAssertNil(artworkAfterRetire)
        XCTAssertEqual(removalKindAfterRetire, .retired)
    }

    func testRetireKeepsAFileAnotherSurvivingEpisodeStillNames() async throws {
        let fixture = try mediaSweepRoot("retire-shared")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let (_, episodes) = try await admittedPodcastEpisodes(
            in: fixture, name: "retire-shared", daysAgo: [1, 2]
        )
        let shared = fixture.media.appendingPathComponent("shared.m4a")
        try Data("shared".utf8).write(to: shared)
        for (index, episode) in episodes.enumerated() {
            let listed = try immutableRevisionFixture(
                itemID: episode.itemID, id: "rev-retire-shared-\(index)",
                hashCharacter: Character(index == 0 ? "a" : "b"), path: shared.path
            )
            try await fixture.store.saveReadyRevision(listed.revision, mediaURL: listed.mediaURL)
        }

        let firstRetired = try await fixture.store.retireEpisode(episodes[0].itemID)
        XCTAssertTrue(firstRetired)
        XCTAssertTrue(FileManager.default.fileExists(atPath: shared.path),
                      "a surviving episode's revision still names the file")

        let secondRetired = try await fixture.store.retireEpisode(episodes[1].itemID)
        XCTAssertTrue(secondRetired)
        XCTAssertFalse(FileManager.default.fileExists(atPath: shared.path),
                       "the last record naming the file is gone, so the file goes")
    }

    /// A restored episode has no download or ready revision and reads as not
    /// downloaded; a fresh download commits cleanly afterwards.
    func testRestoreAfterRetireShowsTheEpisodeNotDownloadedAndAReDownloadSucceeds() async throws {
        let fixture = try mediaSweepRoot("retire-restore")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let (_, episodes) = try await admittedPodcastEpisodes(
            in: fixture, name: "retire-restore", daysAgo: [1]
        )
        let episode = try XCTUnwrap(episodes.first)
        let media = try await installEpisodeMedia(
            in: fixture, episode: episode, revisionID: "rev-retire-restore",
            fileName: "episode.m4a", hashCharacter: "c"
        )
        try await fixture.store.save(download: try PodcastDownload(
            episodeID: episode.itemID, status: .completed, bytesReceived: 8, expectedByteCount: 8,
            localURL: media, contentHash: "sha256:" + String(repeating: "c", count: 64),
            updatedAt: Timestamp(Date(timeIntervalSince1970: 1_700_000_000))
        ))
        let completedAt = Timestamp(Date(timeIntervalSince1970: 1_700_000_500))
        try await fixture.store.saveListening(PodcastListeningState(
            episodeID: episode.itemID, completedAt: completedAt,
            lastRevisionID: try RevisionID(rawValue: "rev-retire-restore"), updatedAt: completedAt
        ))
        let downloadBeforeRetire = try await fixture.store.download(for: episode.itemID)
        XCTAssertNotNil(downloadBeforeRetire)

        let retired = try await fixture.store.retireEpisode(episode.itemID)
        XCTAssertTrue(retired)
        XCTAssertFalse(FileManager.default.fileExists(atPath: media.path))
        let restored = try await fixture.store.restoreEpisode(episode.itemID)
        XCTAssertTrue(restored)

        let removalAfterRestore = try await fixture.store.removalKind(for: episode.itemID)
        let downloadAfterRestore = try await fixture.store.download(for: episode.itemID)
        let revisionAfterRestore = try await fixture.store.readyRevision(for: episode.itemID)
        let restoredListening = try await fixture.store.listeningState(for: episode.itemID)
        XCTAssertNil(removalAfterRestore)
        XCTAssertNil(downloadAfterRestore,
                     "a restored episode has no download record and reads as not downloaded")
        XCTAssertNil(revisionAfterRestore,
                     "the retired ready revision went with the records that named it")
        XCTAssertEqual(restoredListening?.completedAt, completedAt,
                       "restore keeps the listening history intact")
        XCTAssertNil(restoredListening?.lastRevisionID,
                     "restore clears the revision binding so the bootstrap sweep cannot re-retire")

        let redownloaded = try immutableRevisionFixture(
            itemID: episode.itemID, id: "rev-retire-restore-again", hashCharacter: "d",
            path: fixture.media
                .appendingPathComponent("PodcastAudio", isDirectory: true)
                .appendingPathComponent(episode.itemID.rawValue, isDirectory: true)
                .appendingPathComponent("episode-again.m4a").path
        )
        try Data("audio".utf8).write(to: redownloaded.mediaURL)
        try await fixture.store.finalizePodcastDownload(
            revision: redownloaded.revision, mediaURL: redownloaded.mediaURL,
            download: redownloaded.download
        )
        let downloadAfterRedownload = try await fixture.store.download(for: episode.itemID)
        let revisionAfterRedownload = try await fixture.store.readyRevision(for: episode.itemID)
        XCTAssertNotNil(downloadAfterRedownload, "a re-download commits a fresh record after a restore")
        XCTAssertEqual(revisionAfterRedownload?.mediaURL, redownloaded.mediaURL)
    }

    func testBatchRetireDeletesAudioForEveryNewlyRetiredEpisodeAndNoOthers() async throws {
        let fixture = try mediaSweepRoot("batch-retire")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let (_, episodes) = try await admittedPodcastEpisodes(
            in: fixture, name: "batch-retire", daysAgo: [1, 2, 3]
        )
        let hashCharacters: [Character] = ["a", "b", "c"]
        var mediaFiles: [URL] = []
        for (index, episode) in episodes.enumerated() {
            mediaFiles.append(try await installEpisodeMedia(
                in: fixture, episode: episode, revisionID: "rev-batch-retire-\(index)",
                fileName: "episode-\(index).m4a", hashCharacter: hashCharacters[index]
            ))
        }

        let result = try await fixture.store.retireEpisodes([episodes[0].itemID, episodes[1].itemID])
        let unretiredRevision = try await fixture.store.readyRevision(for: episodes[2].itemID)

        XCTAssertEqual(result.committed, [episodes[0].itemID, episodes[1].itemID])
        XCTAssertEqual(result.saveCount, 1)
        XCTAssertEqual(result.episodeRecordFetchCount, 1, "the batch still reads episode rows once")
        XCTAssertEqual(result.mediaRecordFetchCount, 3, "one read per media-record type, counted apart")
        XCTAssertFalse(FileManager.default.fileExists(atPath: mediaFiles[0].path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: mediaFiles[1].path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: mediaFiles[2].path),
                      "the episode the batch did not retire keeps its audio")
        XCTAssertNotNil(unretiredRevision)
    }

    /// Deleting a record deletes the file it named. A download record is the
    /// only record naming this file, and retirement deletes it.
    func testRecordsEqualAudioDeletingARecordDeletesItsFile() async throws {
        let fixture = try mediaSweepRoot("records-equal-audio-record")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let (_, episodes) = try await admittedPodcastEpisodes(
            in: fixture, name: "records-equal-audio-record", daysAgo: [1]
        )
        let episode = try XCTUnwrap(episodes.first)
        let media = fixture.media
            .appendingPathComponent("PodcastAudio", isDirectory: true)
            .appendingPathComponent(episode.itemID.rawValue, isDirectory: true)
            .appendingPathComponent("downloaded.mp3")
        try FileManager.default.createDirectory(at: media.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("downloaded".utf8).write(to: media)
        try await fixture.store.save(download: try PodcastDownload(
            episodeID: episode.itemID, status: .completed, bytesReceived: 10, expectedByteCount: 10,
            localURL: media, contentHash: "sha256:" + String(repeating: "b", count: 64),
            updatedAt: Timestamp(Date(timeIntervalSince1970: 1_700_000_000))
        ))
        let downloadBeforeRetire = try await fixture.store.download(for: episode.itemID)
        XCTAssertNotNil(downloadBeforeRetire)

        let retired = try await fixture.store.retireEpisode(episode.itemID)
        let downloadAfterRetire = try await fixture.store.download(for: episode.itemID)

        XCTAssertTrue(retired)
        XCTAssertNil(downloadAfterRetire, "the deleted record left no record naming the audio")
        XCTAssertFalse(FileManager.default.fileExists(atPath: media.path),
                       "the file went with the record that named it")
    }

    /// Deleting the file clears the records that named it: the sweep's
    /// reconcile direction of records equal audio.
    func testRecordsEqualAudioDeletingAFileClearsItsRecord() async throws {
        let fixture = try mediaSweepRoot("records-equal-audio-file")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let (_, episodes) = try await admittedPodcastEpisodes(
            in: fixture, name: "records-equal-audio-file", daysAgo: [1]
        )
        let episode = try XCTUnwrap(episodes.first)
        let media = try await installEpisodeMedia(
            in: fixture, episode: episode, revisionID: "rev-records-equal-audio-file",
            fileName: "episode.m4a", hashCharacter: "e"
        )
        try await fixture.store.save(download: try PodcastDownload(
            episodeID: episode.itemID, status: .completed, bytesReceived: 8, expectedByteCount: 8,
            localURL: media, contentHash: "sha256:" + String(repeating: "e", count: 64),
            updatedAt: Timestamp(Date(timeIntervalSince1970: 1_700_000_000))
        ))
        try FileManager.default.removeItem(at: media)

        let report = try await fixture.store.sweepUnreferencedMedia(in: [fixture.media], excluding: [])
        let downloadAfterSweep = try await fixture.store.download(for: episode.itemID)
        let revisionsAfterSweep = try await fixture.store.revisions(for: episode.itemID)

        XCTAssertEqual(report.clearedRecords, 2,
                       "the completed download and the revision record both named the missing file")
        XCTAssertNil(downloadAfterSweep)
        XCTAssertTrue(revisionsAfterSweep.isEmpty)
    }

}
