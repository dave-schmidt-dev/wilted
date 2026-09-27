import CryptoKit
import Foundation
import SwiftData
import XCTest
import WiltedDomain
import WiltedSync
@testable import WiltedProducer

extension LocalLibraryStoreTests {
    // MARK: Immutable-revision site attribution (Task 4.2)

    /// One podcast revision with a matching download, transcript, and outcome,
    /// for driving a single immutable-revision path.
    func immutableRevisionFixture(
        itemID: ItemID, id: String, hashCharacter: Character, path: String, bytes: Int64 = 64
    ) throws -> (
        revision: AudioRevision, mediaURL: URL, download: PodcastDownload,
        transcript: Transcript, outcome: PodcastPreparationOutcome
    ) {
        let when = Timestamp(Date(timeIntervalSince1970: 1_700_000_000))
        let hash = "sha256:" + String(repeating: String(hashCharacter), count: 64)
        let revisionID = try RevisionID(rawValue: id)
        let mediaURL = URL(fileURLWithPath: path)
        let revision = try AudioRevision(
            itemID: itemID, revisionID: revisionID, durationSeconds: 60, byteCount: bytes,
            contentHash: hash, mediaType: "audio/mpeg", createdAt: when, schemaVersion: 3
        )
        let download = try PodcastDownload(
            episodeID: itemID, status: .completed, bytesReceived: bytes, expectedByteCount: bytes,
            localURL: mediaURL, contentHash: hash, updatedAt: when
        )
        let transcript = try Transcript(
            itemID: itemID, revisionID: revisionID, availability: .available,
            text: "Transcript for \(id).", updatedAt: when
        )
        let outcome = PodcastPreparationOutcome(
            episodeID: itemID, revisionID: revisionID, policyDigest: "d",
            pipelineFingerprint: "f", semanticVersion: "v", producedAt: when
        )
        return (revision, mediaURL, download, transcript, outcome)
    }

    func immutableRevisionItemID(_ guid: String) throws -> ItemID {
        let feedURL = try XCTUnwrap(URL(string: "https://feeds.example.test/immutable-\(guid).xml"))
        let enclosureURL = try XCTUnwrap(URL(string: "https://cdn.example.test/immutable-\(guid).mp3"))
        return try ItemID.derivePodcastEpisode(feedURL: feedURL, rssGUID: guid, enclosureURL: enclosureURL)
    }

    private func immutableRevisionError(_ body: () async throws -> Void) async -> LocalLibraryStoreError? {
        do {
            try await body()
            return nil
        } catch let error as LocalLibraryStoreError {
            return error
        } catch {
            return nil
        }
    }

    func testImmutableRevisionSiteNamesThePlainReadyRevisionSave() async throws {
        let url = makeURL(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = try LocalLibraryStore(url: url)
        let itemID = try immutableRevisionItemID("plain")
        let fixture = try immutableRevisionFixture(
            itemID: itemID, id: "rev-site-plain", hashCharacter: "a", path: "/tmp/site/plain.mp3"
        )
        try await store.saveReadyRevision(fixture.revision, mediaURL: fixture.mediaURL)

        let error = await immutableRevisionError {
            try await store.saveReadyRevision(
                fixture.revision, mediaURL: URL(fileURLWithPath: "/tmp/site/changed.mp3")
            )
        }
        XCTAssertEqual(
            error,
            .immutableRevision(fixture.revision.revisionID, site: .readyRevision),
            "the plain revision save names its own site and the finalized revision"
        )
    }

    func testImmutableRevisionSiteNamesTheTranscriptReadyRevisionSave() async throws {
        let url = makeURL(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = try LocalLibraryStore(url: url)
        let itemID = try immutableRevisionItemID("transcript")
        let fixture = try immutableRevisionFixture(
            itemID: itemID, id: "rev-site-transcript", hashCharacter: "b", path: "/tmp/site/transcript.m4a"
        )
        try await store.saveReadyRevision(
            fixture.revision, mediaURL: fixture.mediaURL, transcript: fixture.transcript
        )

        let error = await immutableRevisionError {
            try await store.saveReadyRevision(
                fixture.revision, mediaURL: URL(fileURLWithPath: "/tmp/site/changed.m4a"),
                transcript: fixture.transcript
            )
        }
        XCTAssertEqual(
            error,
            .immutableRevision(fixture.revision.revisionID, site: .readyRevisionWithTranscript)
        )
    }

    func testImmutableRevisionSiteNamesTheOutcomeReadyRevisionSave() async throws {
        let url = makeURL(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = try LocalLibraryStore(url: url)
        let itemID = try immutableRevisionItemID("outcome")
        let fixture = try immutableRevisionFixture(
            itemID: itemID, id: "rev-site-outcome", hashCharacter: "c", path: "/tmp/site/outcome.m4a"
        )
        try await store.saveReadyRevision(
            fixture.revision, mediaURL: fixture.mediaURL, transcript: fixture.transcript,
            outcome: fixture.outcome
        )

        let error = await immutableRevisionError {
            try await store.saveReadyRevision(
                fixture.revision, mediaURL: URL(fileURLWithPath: "/tmp/site/changed.m4a"),
                transcript: fixture.transcript, outcome: fixture.outcome
            )
        }
        XCTAssertEqual(
            error,
            .immutableRevision(fixture.revision.revisionID, site: .readyRevisionWithOutcome)
        )
    }

    func testImmutableRevisionSiteNamesTheSyncCommit() async throws {
        let url = makeURL(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = try LocalLibraryStore(url: url)
        let itemID = try immutableRevisionItemID("sync")
        let base = try immutableRevisionFixture(
            itemID: itemID, id: "rev-site-sync", hashCharacter: "d", path: "/tmp/site/sync.mp3"
        )
        try await store.saveReadyRevision(base.revision, mediaURL: base.mediaURL)
        let conflicting = try immutableRevisionFixture(
            itemID: itemID, id: base.revision.revisionID.rawValue, hashCharacter: "e", path: "/tmp/site/sync-conflict.mp3"
        )

        let error = await immutableRevisionError {
            try await store.applySyncCommit(LocalLibrarySyncCommit(
                state: SyncRepositoryState(),
                revisions: [.init(revision: conflicting.revision, mediaURL: conflicting.mediaURL)]
            ))
        }
        XCTAssertEqual(
            error,
            .immutableRevision(base.revision.revisionID, site: .syncCommit)
        )
    }

    func testImmutableRevisionSiteNamesTheFinalizedDownload() async throws {
        let url = makeURL(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = try LocalLibraryStore(url: url)
        let itemID = try immutableRevisionItemID("finalized")
        let base = try immutableRevisionFixture(
            itemID: itemID, id: "rev-site-finalized", hashCharacter: "f", path: "/tmp/site/finalized.mp3"
        )
        try await store.finalizePodcastDownload(
            revision: base.revision, mediaURL: base.mediaURL, download: base.download
        )
        let conflicting = try immutableRevisionFixture(
            itemID: itemID, id: base.revision.revisionID.rawValue,
            hashCharacter: "0", path: "/tmp/site/finalized-conflict.mp3"
        )

        let error = await immutableRevisionError {
            try await store.finalizePodcastDownload(
                revision: conflicting.revision, mediaURL: conflicting.mediaURL, download: conflicting.download
            )
        }
        XCTAssertEqual(
            error,
            .immutableRevision(base.revision.revisionID, site: .finalizedDownload)
        )
    }

    func testImmutableRevisionSiteNamesAReplacementThatSupersedesItself() async throws {
        let url = makeURL(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = try LocalLibraryStore(url: url)
        let itemID = try immutableRevisionItemID("self-supersede")
        let fixture = try immutableRevisionFixture(
            itemID: itemID, id: "rev-site-self", hashCharacter: "1", path: "/tmp/site/self.m4a"
        )

        let error = await immutableRevisionError {
            try await store.replaceReadyRevision(
                fixture.revision, mediaURL: fixture.mediaURL, transcript: fixture.transcript,
                download: fixture.download, superseding: fixture.revision.revisionID,
                outcome: fixture.outcome
            )
        }
        XCTAssertEqual(
            error,
            .immutableRevision(fixture.revision.revisionID, site: .replacementSupersedesItself)
        )
    }

    func testImmutableRevisionSiteNamesAReplacementIdentityMismatch() async throws {
        let url = makeURL(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = try LocalLibraryStore(url: url)
        let itemID = try immutableRevisionItemID("replacement")
        let base = try immutableRevisionFixture(
            itemID: itemID, id: "rev-site-replacement", hashCharacter: "2", path: "/tmp/site/replacement.m4a"
        )
        try await store.saveReadyRevision(base.revision, mediaURL: base.mediaURL)
        let conflicting = try immutableRevisionFixture(
            itemID: itemID, id: base.revision.revisionID.rawValue,
            hashCharacter: "3", path: "/tmp/site/replacement-conflict.m4a"
        )
        let superseded = try RevisionID(rawValue: "rev-not-written-" + String(repeating: "4", count: 48))

        let error = await immutableRevisionError {
            try await store.replaceReadyRevision(
                conflicting.revision, mediaURL: conflicting.mediaURL,
                transcript: conflicting.transcript, download: conflicting.download,
                superseding: superseded, outcome: conflicting.outcome
            )
        }
        XCTAssertEqual(
            error,
            .immutableRevision(base.revision.revisionID, site: .replacement)
        )
    }

    func testTheSevenImmutableRevisionSitesProducePairwiseDistinctErrors() throws {
        let revision = try RevisionID(rawValue: "rev-distinct-" + String(repeating: "5", count: 50))
        let errors = ImmutableRevisionSite.allCases.map {
            LocalLibraryStoreError.immutableRevision(revision, site: $0)
        }
        XCTAssertEqual(errors.count, 7, "each immutable-revision site has a value")
        for (index, lhs) in errors.enumerated() {
            for rhs in errors[(index + 1)...] {
                XCTAssertNotEqual(lhs, rhs, "\(lhs) must not equal \(rhs)")
            }
        }
    }

}
