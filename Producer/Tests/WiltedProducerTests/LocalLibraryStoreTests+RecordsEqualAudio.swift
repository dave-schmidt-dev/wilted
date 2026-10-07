import CryptoKit
import Foundation
import SwiftData
import XCTest
import WiltedDomain
import WiltedSync
@testable import WiltedProducer

extension LocalLibraryStoreTests {
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
