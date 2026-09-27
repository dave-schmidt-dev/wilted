import CryptoKit
import Foundation
import SwiftData
import XCTest
import WiltedDomain
import WiltedSync
@testable import WiltedProducer

extension LocalLibraryStoreTests {
    // MARK: Orphan media audit and reclaim (Task 4.4)

    /// A store and a dedicated media root, so the audit never scans the store's
    /// own files.
    private func mediaSweepRoot(_ name: String) throws -> (root: URL, media: URL, store: LocalLibraryStore) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("wilted-media-sweep-\(name)-\(UUID().uuidString)")
        let media = root.appendingPathComponent("media", isDirectory: true)
        try FileManager.default.createDirectory(at: media, withIntermediateDirectories: true)
        let store = try LocalLibraryStore(url: root.appendingPathComponent("library.sqlite"))
        return (root, media, store)
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

        let reclaimed = try await fixture.store.reclaimUnreferencedMedia(in: [fixture.media])
        XCTAssertEqual(reclaimed, 1, "the superseded source is the one file nothing names")
        XCTAssertFalse(FileManager.default.fileExists(atPath: source.mediaURL.path),
                       "a re-download/replacement still reclaims the superseded source")
        XCTAssertTrue(FileManager.default.fileExists(atPath: prepared.mediaURL.path))
    }

    func testAnInFlightMediaFileSurvivesTheSweepAndIsReclaimedWhenReleased() async throws {
        let fixture = try mediaSweepRoot("in-flight")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let candidate = fixture.media.appendingPathComponent("candidate-holding.m4a")
        try Data("candidate".utf8).write(to: candidate)
        fixture.store.inFlightMedia.begin(candidate)

        let whileInFlight = try await fixture.store.reclaimUnreferencedMedia(in: [fixture.media])
        XCTAssertEqual(whileInFlight, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: candidate.path),
                      "a download or synthesis whose revision has not committed survives")

        fixture.store.inFlightMedia.end(candidate)
        let afterRelease = try await fixture.store.reclaimUnreferencedMedia(in: [fixture.media])
        XCTAssertEqual(afterRelease, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: candidate.path))
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

        let duringSynthesis = try await fixture.store.reclaimUnreferencedMedia(in: [fixture.media])
        XCTAssertEqual(duringSynthesis, 0,
                       "the candidate is registered in flight before it exists")
        XCTAssertTrue(
            try FileManager.default.contentsOfDirectory(atPath: fixture.media.path)
                .contains { $0.hasPrefix("candidate-") }
        )

        release.yield()
        let statuses = await statusesTask.value
        XCTAssertEqual(try XCTUnwrap(statuses.last, "the run emitted no status").stage, .completed)
        let afterCommit = try await fixture.store.reclaimUnreferencedMedia(in: [fixture.media])
        XCTAssertEqual(afterCommit, 0,
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

    func testDismissalWithASurvivingRevisionSharingAContentHashKeepsTheFile() async throws {
        let fixture = try mediaSweepRoot("shared-hash")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let dismissedItem = try immutableRevisionItemID("dismissed")
        let survivingItem = try immutableRevisionItemID("surviving")
        let shared = fixture.media.appendingPathComponent("shared.m4a")
        try Data("shared".utf8).write(to: shared)
        let hash = "sha256:" + String(repeating: "a", count: 64)
        let when = Timestamp(Date(timeIntervalSince1970: 1_700_000_000))
        let dismissed = try AudioRevision(
            itemID: dismissedItem, revisionID: RevisionID(rawValue: "rev-dismissed"),
            durationSeconds: 60, byteCount: 6, contentHash: hash, mediaType: "audio/mpeg",
            createdAt: when, schemaVersion: 3
        )
        let surviving = try AudioRevision(
            itemID: survivingItem, revisionID: RevisionID(rawValue: "rev-surviving"),
            durationSeconds: 60, byteCount: 6, contentHash: hash, mediaType: "audio/mpeg",
            createdAt: when, schemaVersion: 3
        )
        try await fixture.store.saveReadyRevision(dismissed, mediaURL: shared)
        try await fixture.store.saveReadyRevision(surviving, mediaURL: shared)

        try await fixture.store.dismissPodcastEpisode(dismissedItem)

        let reclaimed = try await fixture.store.reclaimUnreferencedMedia(in: [fixture.media])
        XCTAssertEqual(reclaimed, 0,
                       "a surviving revision with the same content hash still names the file")
        XCTAssertTrue(FileManager.default.fileExists(atPath: shared.path))
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
        let reclaimed = try await fixture.store.reclaimUnreferencedMedia(in: [fixture.media])
        XCTAssertEqual(reclaimed, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: first.mediaURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: second.mediaURL.path))
    }

}
