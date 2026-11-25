import CryptoKit
import Foundation
import XCTest
import WiltedDomain
import WiltedLibrary
@testable import WiltedProducer

extension LocalLibraryStoreTests {
    func testNotebookOwnerPartitionTombstoneAndUndoUseNewIdentity() async throws {
        let url = makeURL(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = try LocalLibraryStore(url: url)
        let device = "notebook-test-device"
        let ownerA = try NotebookLocalScope(ownerToken: "account-a", deviceID: device)
        let ownerB = try NotebookLocalScope(ownerToken: "account-b", deviceID: device)
        let source = try ItemID(rawValue: "episode-notebook")
        let revision = try RevisionID(rawValue: "revision-notebook")
        let id = try ItemID(rawValue: "notebook-old")
        let entry = try LibraryNotebookEntry(
            id: id, sourceItemID: source, sourceRevision: revision, sourceTitle: "Episode",
            sourceURL: URL(string: "https://podcasts.example.test/episode")!,
            startSeconds: 12, endSeconds: 42, textExcerpt: "A saved cue.", capturedOn: .mac
        )

        _ = try await store.saveNotebookEntry(entry, in: ownerA)
        let ownerAEntries = try await store.notebookEntries(in: ownerA)
        let ownerBEntries = try await store.notebookEntries(in: ownerB)
        XCTAssertEqual(ownerAEntries, [entry])
        XCTAssertTrue(ownerBEntries.isEmpty, "account switches never merge local rows")

        let tombstoneValue = try await store.tombstoneNotebookEntry(id: id, in: ownerA, at: Date(timeIntervalSince1970: 20))
        let tombstone = try XCTUnwrap(tombstoneValue)
        XCTAssertTrue(tombstone.isDeleted)
        do {
            _ = try await store.saveNotebookEntry(entry, in: ownerA)
            XCTFail("raw store writes must not revive a tombstoned identity")
        } catch let error as LibraryNotebookStoreError {
            XCTAssertEqual(error, .tombstoneCannotBeReused)
        }

        let restoredID = try ItemID(rawValue: "notebook-restored")
        let restoredValue = try await store.restoreNotebookEntry(id: id, as: restoredID, in: ownerA,
                                                                  at: Date(timeIntervalSince1970: 30))
        let restored = try XCTUnwrap(restoredValue)
        XCTAssertFalse(restored.isDeleted)
        XCTAssertNotEqual(restored.id, tombstone.id)
        let tombstonedValue = try await store.notebookEntry(id: id, in: ownerA)
        let restoredStoredValue = try await store.notebookEntry(id: restoredID, in: ownerA)
        XCTAssertTrue(try XCTUnwrap(tombstonedValue).isDeleted)
        XCTAssertEqual(restoredStoredValue, restored)
    }

    func testLateNotebookCaptureFillsOnlyItsExactTranscriptAfterReprepare() async throws {
        let url = makeURL(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = try LocalLibraryStore(url: url)
        let scope = try NotebookLocalScope(ownerToken: "account-a", deviceID: "notebook-device")
        let source = try ItemID(rawValue: "episode-notebook-history")
        let oldID = try RevisionID(rawValue: "notebook-history-old")
        let newID = try RevisionID(rawValue: "notebook-history-new")
        let now = Timestamp(Date(timeIntervalSince1970: 1_700_000_000))
        let oldBytes = Data("old prepared audio".utf8)
        let newBytes = Data("new prepared audio".utf8)
        func hash(_ bytes: Data) -> String {
            "sha256:" + SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        }
        let oldRevision = try AudioRevision(itemID: source, revisionID: oldID, durationSeconds: 90,
            byteCount: Int64(oldBytes.count), contentHash: hash(oldBytes), mediaType: "audio/mp4",
            createdAt: now, schemaVersion: 3)
        let newRevision = try AudioRevision(itemID: source, revisionID: newID, durationSeconds: 90,
            byteCount: Int64(newBytes.count), contentHash: hash(newBytes), mediaType: "audio/mp4",
            createdAt: Timestamp(now.date.addingTimeInterval(60)), schemaVersion: 3)
        let oldTranscript = try Transcript(
            itemID: source, revisionID: oldID, availability: .available, text: "Exact old words.",
            timing: .aligned,
            cues: [try TranscriptCue(startSeconds: 12, endSeconds: 14, text: "Exact old words.")], updatedAt: now
        )
        let newTranscript = try Transcript(
            itemID: source, revisionID: newID, availability: .available, text: "Different newer words.",
            timing: .aligned,
            cues: [try TranscriptCue(startSeconds: 12, endSeconds: 14, text: "Different newer words.")],
            updatedAt: Timestamp(now.date.addingTimeInterval(60))
        )
        let oldURL = url.deletingLastPathComponent().appendingPathComponent("old.m4a")
        let newURL = url.deletingLastPathComponent().appendingPathComponent("new.m4a")
        try oldBytes.write(to: oldURL)
        try newBytes.write(to: newURL)
        try await store.saveReadyRevision(oldRevision, mediaURL: oldURL, transcript: oldTranscript)
        try await store.replaceReadyRevision(
            newRevision, mediaURL: newURL, transcript: newTranscript,
            download: try PodcastDownload(episodeID: source, status: .completed,
                bytesReceived: Int64(newBytes.count), expectedByteCount: Int64(newBytes.count),
                localURL: newURL, contentHash: hash(newBytes), updatedAt: newRevision.createdAt),
            superseding: oldID,
            outcome: PodcastPreparationOutcome(episodeID: source, revisionID: newID, policyDigest: "policy",
                pipelineFingerprint: "fixture", semanticVersion: "test", producedAt: newRevision.createdAt)
        )

        let reclaimedAudio = try await store.readyRevision(for: source, revisionID: oldID)
        let retainedTranscript = try await store.transcript(for: source, revisionID: oldID)
        XCTAssertNil(reclaimedAudio, "superseded audio can be reclaimed")
        XCTAssertNil(retainedTranscript, "superseded transcripts leave the active playback library")

        let entry = try LibraryNotebookEntry(
            id: ItemID(rawValue: "late-phone-capture"), sourceItemID: source, sourceRevision: oldID,
            sourceTitle: "Episode", sourceURL: URL(string: "https://podcasts.example.test/episode")!,
            startSeconds: 12, endSeconds: 14, capturedOn: .iphone
        )
        _ = try await store.saveNotebookEntry(entry, in: scope)
        let filledValue = try await store.fillNotebookExcerptFromExactTranscript(id: entry.id, in: scope)
        let filled = try XCTUnwrap(filledValue)
        XCTAssertEqual(filled.textExcerpt, "Exact old words.")
        XCTAssertNotEqual(filled.textExcerpt, newTranscript.text)
    }
}
