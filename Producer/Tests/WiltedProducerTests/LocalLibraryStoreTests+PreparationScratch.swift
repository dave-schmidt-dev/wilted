import Darwin
import Foundation
import XCTest
import WiltedDomain
@testable import WiltedProducer

extension LocalLibraryStoreTests {
    // MARK: Abandoned preparation scratch (Wilted PR-3)

    private func preparationScratchDirectory(
        in fixture: (root: URL, media: URL, store: LocalLibraryStore)
    ) throws -> URL {
        let preparation = fixture.media.appendingPathComponent("preparation", isDirectory: true)
        try FileManager.default.createDirectory(at: preparation, withIntermediateDirectories: true)
        return preparation
    }

    @discardableResult
    private func writePreparationScratch(
        _ name: String, in directory: URL, contents: String
    ) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(name)
        try Data(contents.utf8).write(to: url)
        return url
    }

    private func preparationScratchBytes(_ urls: [URL]) -> Int64 {
        urls.reduce(0) { total, url in
            guard let data = try? Data(contentsOf: url) else { return total }
            return total + Int64(data.count)
        }
    }

    func testPreparationScratchRemovesEachLeftoverKindAndCountsBytes() async throws {
        let fixture = try mediaSweepRoot("prep-scratch-kinds")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let preparation = try preparationScratchDirectory(in: fixture)
        let prepared = try writePreparationScratch(
            "prepared-episode.m4a", in: preparation, contents: "prepared"
        )
        let rendering = try writePreparationScratch(
            ".prepared-episode.rendering-99999999.mp3", in: preparation, contents: "rendering"
        )
        let candidate = try writePreparationScratch(
            ".candidate-run.m4a.tmp-\(UUID().uuidString).m4a",
            in: fixture.media, contents: "candidate"
        )
        let audiobook = try writePreparationScratch(
            ".audiobook-\(UUID().uuidString)-v0.tmp.m4a",
            in: fixture.media, contents: "audiobook"
        )
        let expectedBytes = preparationScratchBytes([prepared, rendering, candidate, audiobook])

        let report = try await fixture.store.removeAbandonedPreparationScratch(in: fixture.media)

        XCTAssertEqual(report, PreparationScratchSweep(
            removed: 4, bytes: expectedBytes, failed: 0, skippedLiveWorker: false
        ))
        for removed in [prepared, rendering, candidate, audiobook] {
            XCTAssertFalse(FileManager.default.fileExists(atPath: removed.path),
                           "\(removed.lastPathComponent) is abandoned scratch")
        }
    }

    func testPreparationScratchKeepsReferencedAndNonCandidateFiles() async throws {
        let fixture = try mediaSweepRoot("prep-scratch-survivors")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let preparation = try preparationScratchDirectory(in: fixture)
        let (_, episodes) = try await admittedPodcastEpisodes(
            in: fixture, name: "prep-scratch-survivors", daysAgo: [1]
        )
        let episode = try XCTUnwrap(episodes.first)
        let episodeMedia = try await installEpisodeMedia(
            in: fixture, episode: episode, revisionID: "rev-prep-scratch-survivors",
            fileName: "episode.m4a", hashCharacter: "a"
        )

        let namedPrepared = try writePreparationScratch(
            "prepared-named.m4a", in: preparation, contents: "named"
        )
        let itemID = try immutableRevisionItemID("prep-scratch-survivors")
        let named = try immutableRevisionFixture(
            itemID: itemID, id: "rev-prep-scratch-named", hashCharacter: "b",
            path: namedPrepared.path
        )
        try await fixture.store.saveReadyRevision(named.revision, mediaURL: named.mediaURL)

        let notes = try writePreparationScratch("notes.txt", in: preparation, contents: "notes")
        let nested = try writePreparationScratch(
            "prepared-nested.mp3",
            in: preparation.appendingPathComponent("nested", isDirectory: true),
            contents: "nested"
        )
        let directory = preparation.appendingPathComponent("prepared-dir", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let target = fixture.root.appendingPathComponent("outside-target.mp3")
        try Data("target".utf8).write(to: target)
        let link = preparation.appendingPathComponent("prepared-link.mp3")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)

        let committedCandidate = try writePreparationScratch(
            "candidate-committed.m4a", in: fixture.media, contents: "committed"
        )

        let report = try await fixture.store.removeAbandonedPreparationScratch(in: fixture.media)

        XCTAssertEqual(report, PreparationScratchSweep(
            removed: 0, bytes: 0, failed: 0, skippedLiveWorker: false
        ))
        for survivor in [episodeMedia, namedPrepared, notes, nested, directory, link, committedCandidate] {
            XCTAssertTrue(FileManager.default.fileExists(atPath: survivor.path),
                          "\(survivor.lastPathComponent) must survive")
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: target.path),
                      "the symlink target is outside media and must survive")
        let linkDestination = try FileManager.default.destinationOfSymbolicLink(atPath: link.path)
        XCTAssertEqual(
            URL(fileURLWithPath: linkDestination).resolvingSymlinksInPath().path,
            target.resolvingSymlinksInPath().path,
            "the symbolic link itself is kept, not followed or removed"
        )
    }

    func testPreparationScratchSkipsPreparationWhileARenderingWorkerIsAlive() async throws {
        let fixture = try mediaSweepRoot("prep-scratch-live")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let preparation = try preparationScratchDirectory(in: fixture)
        let rendering = try writePreparationScratch(
            ".prepared-a.rendering-\(getpid()).mp3", in: preparation, contents: "rendering"
        )
        let prepared = try writePreparationScratch(
            "prepared-other.m4a", in: preparation, contents: "prepared"
        )
        let candidate = try writePreparationScratch(
            ".candidate-live.m4a.tmp-\(UUID().uuidString).m4a",
            in: fixture.media, contents: "candidate"
        )
        let expectedBytes = preparationScratchBytes([candidate])

        let report = try await fixture.store.removeAbandonedPreparationScratch(in: fixture.media)

        XCTAssertEqual(report, PreparationScratchSweep(
            removed: 1, bytes: expectedBytes, failed: 0, skippedLiveWorker: true
        ))
        XCTAssertTrue(FileManager.default.fileExists(atPath: rendering.path),
                      "a live worker's rendering file keeps the preparation directory")
        XCTAssertTrue(FileManager.default.fileExists(atPath: prepared.path),
                      "every preparation file survives while the worker is alive")
        XCTAssertFalse(FileManager.default.fileExists(atPath: candidate.path),
                       "a media temporary is still swept")
    }

    func testPreparationScratchRemovesRenderingFromADeadWorker() async throws {
        let fixture = try mediaSweepRoot("prep-scratch-dead")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let preparation = try preparationScratchDirectory(in: fixture)
        let rendering = try writePreparationScratch(
            ".prepared-a.rendering-99999999.mp3", in: preparation, contents: "rendering"
        )
        let prepared = try writePreparationScratch(
            "prepared-other.m4a", in: preparation, contents: "prepared"
        )
        let expectedBytes = preparationScratchBytes([rendering, prepared])

        let report = try await fixture.store.removeAbandonedPreparationScratch(in: fixture.media)

        XCTAssertEqual(report, PreparationScratchSweep(
            removed: 2, bytes: expectedBytes, failed: 0, skippedLiveWorker: false
        ))
        XCTAssertFalse(FileManager.default.fileExists(atPath: rendering.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: prepared.path))
    }

    func testPreparationScratchToleratesAMissingMediaDirectory() async throws {
        let fixture = try mediaSweepRoot("prep-scratch-missing")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        try FileManager.default.removeItem(at: fixture.media)

        let report = try await fixture.store.removeAbandonedPreparationScratch(in: fixture.media)

        XCTAssertEqual(report, PreparationScratchSweep(
            removed: 0, bytes: 0, failed: 0, skippedLiveWorker: false
        ))
    }

    func testPreparationScratchSkipsAPreparationSymlinkToAnotherDirectory() async throws {
        let fixture = try mediaSweepRoot("prep-scratch-symlink")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let outside = fixture.root.appendingPathComponent("outside-preparation", isDirectory: true)
        let prepared = try writePreparationScratch(
            "prepared-outside.m4a", in: outside, contents: "outside"
        )
        let link = fixture.media.appendingPathComponent("preparation", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)

        let report = try await fixture.store.removeAbandonedPreparationScratch(in: fixture.media)

        XCTAssertEqual(report, PreparationScratchSweep(
            removed: 0, bytes: 0, failed: 0, skippedLiveWorker: false
        ))
        XCTAssertTrue(FileManager.default.fileExists(atPath: prepared.path),
                      "a preparation symlink is never followed")
        let linkDestination = try FileManager.default.destinationOfSymbolicLink(atPath: link.path)
        XCTAssertEqual(
            URL(fileURLWithPath: linkDestination).resolvingSymlinksInPath().path,
            outside.resolvingSymlinksInPath().path
        )
    }

    func testPreparationScratchRemovesNothingWhenAStoredPathIsOutsideTheLibrary() async throws {
        let fixture = try mediaSweepRoot("prep-scratch-outside")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let outside = OwnedTestTemp.root.appendingPathComponent(
            "prep-scratch-outside-\(UUID().uuidString)", isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: outside) }
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let outsideMedia = outside.appendingPathComponent("elsewhere.mp3")
        try Data("elsewhere".utf8).write(to: outsideMedia)
        let itemID = try immutableRevisionItemID("prep-scratch-outside")
        try await fixture.store.save(download: try PodcastDownload(
            episodeID: itemID, status: .completed, bytesReceived: 9, expectedByteCount: 9,
            localURL: outsideMedia, contentHash: "sha256:" + String(repeating: "c", count: 64),
            updatedAt: Timestamp(Date(timeIntervalSince1970: 1_700_000_000))
        ))

        let preparation = try preparationScratchDirectory(in: fixture)
        let prepared = try writePreparationScratch(
            "prepared-leftover.m4a", in: preparation, contents: "prepared"
        )
        let candidate = try writePreparationScratch(
            ".candidate-outside.m4a.tmp-\(UUID().uuidString).m4a",
            in: fixture.media, contents: "candidate"
        )

        let report = try await fixture.store.removeAbandonedPreparationScratch(in: fixture.media)

        XCTAssertEqual(report, PreparationScratchSweep(
            removed: 0, bytes: 0, failed: 0, skippedLiveWorker: false
        ))
        for survivor in [outsideMedia, prepared, candidate] {
            XCTAssertTrue(FileManager.default.fileExists(atPath: survivor.path),
                          "\(survivor.lastPathComponent) must survive a relocated store")
        }
    }
}
