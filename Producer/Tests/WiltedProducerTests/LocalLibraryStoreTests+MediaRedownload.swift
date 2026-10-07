import CryptoKit
import Foundation
import SwiftData
import XCTest
import WiltedDomain
import WiltedSync
@testable import WiltedProducer

extension LocalLibraryStoreTests {
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
}
