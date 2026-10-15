import Foundation
import XCTest
import WiltedDomain
@testable import WiltedProducer

extension LocalLibraryStore {
    /// Synchronous synthetic actor work models an already executing fetch. Cancellation cannot stop it.
    fileprivate func holdPlaybackReadForTesting(entered: DispatchSemaphore) {
        entered.signal()
        Thread.sleep(forTimeInterval: 0.25)
    }
}

extension LocalLibraryStoreTests {
    func testPlaybackTranscriptSeparatesActorAdmissionFromFetchAndDecode() async throws {
        let url = makeURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = try LocalLibraryStore(url: url)
        let itemID = try ItemID(rawValue: "contention-target")
        let revisionID = try RevisionID(rawValue: "contention-revision")
        try await store.save(transcript: Transcript(
            itemID: itemID, revisionID: revisionID, availability: .available,
            text: "Exact revision survives actor contention", updatedAt: Timestamp(Date())))
        LocalLibraryStoreStageTrace.reset()
        LocalLibraryStoreStageTrace.isEnabled = true
        defer { LocalLibraryStoreStageTrace.isEnabled = false }
        let entered = DispatchSemaphore(value: 0)
        let holder = Task.detached { await store.holdPlaybackReadForTesting(entered: entered) }
        XCTAssertEqual(entered.wait(timeout: .now() + 5), .success)
        let transcript = try await store.transcript(for: itemID, revisionID: revisionID)
        await holder.value
        XCTAssertEqual(transcript?.text, "Exact revision survives actor contention")
        let summaries = LocalLibraryStoreStageTrace.summaries()
        let admission = try XCTUnwrap(summaries.first { $0.stage == .transcriptActorAdmission })
        let fetch = try XCTUnwrap(summaries.first { $0.stage == .transcriptFetch })
        XCTAssertEqual(admission.sampleCount, 1)
        XCTAssertGreaterThan(admission.medianMicros, 100_000,
                             "mailbox admission includes work already executing on the actor")
        XCTAssertLessThan(fetch.medianMicros, admission.medianMicros,
                          "fetch timing cannot stand in for mailbox wait")
        print(LocalLibraryStoreStageTrace.report())
    }

    func testExactPlaybackReadsAtOneAnd160ItemsPrintBothDistributions() async throws {
        let url = makeURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = try LocalLibraryStore(url: url)
        let target = try ItemID(rawValue: "playback-scale-0")
        let targetRevision = try RevisionID(rawValue: "playback-scale-revision-0")
        LocalLibraryStoreStageTrace.isEnabled = true
        defer { LocalLibraryStoreStageTrace.isEnabled = false }
        for count in [1, 160] {
            for index in (count == 1 ? 0 : 1)..<count {
                let itemID = try ItemID(rawValue: "playback-scale-\(index)")
                let revisionID = try RevisionID(rawValue: "playback-scale-revision-\(index)")
                let revision = try AudioRevision(
                    itemID: itemID, revisionID: revisionID, durationSeconds: 60, byteCount: 1024,
                    contentHash: "sha256:" + String(repeating: "a", count: 64), mediaType: "audio/mp4",
                    createdAt: Timestamp(Date()), schemaVersion: 1)
                try await store.saveReadyRevision(revision, mediaURL: url.deletingLastPathComponent()
                    .appendingPathComponent("synthetic-\(index).m4a"), transcript: Transcript(
                        itemID: itemID, revisionID: revisionID, availability: .available,
                        text: "Synthetic transcript \(index)", updatedAt: Timestamp(Date())))
            }
            LocalLibraryStoreStageTrace.reset()
            for _ in 0..<6 {
                let revision = try await store.readyRevision(for: target)
                XCTAssertEqual(revision?.revision.revisionID, targetRevision)
                let transcript = try await store.transcript(for: target, revisionID: targetRevision)
                XCTAssertEqual(transcript?.text, "Synthetic transcript 0")
            }
            let summaries = LocalLibraryStoreStageTrace.summaries()
            for stage in LocalLibraryStoreStageTrace.Stage.allCases {
                XCTAssertEqual(summaries.first { $0.stage == stage }?.sampleCount, 6)
            }
            print("catalog rows=\(count)\n" + LocalLibraryStoreStageTrace.report())
        }
    }

    func testExactRevisionReadsDoNotFallBackToOlderTranscript() async throws {
        let url = makeURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = try LocalLibraryStore(url: url)
        let itemID = try ItemID(rawValue: "exact-key-item")
        let old = try RevisionID(rawValue: "exact-key-old")
        let missing = try RevisionID(rawValue: "exact-key-missing")
        try await store.save(transcript: Transcript(
            itemID: itemID, revisionID: old, availability: .available, text: "Older text",
            updatedAt: Timestamp(Date())))
        let absent = try await store.transcript(for: itemID, revisionID: missing)
        XCTAssertNil(absent)
        let existing = try await store.transcript(for: itemID, revisionID: old)
        XCTAssertEqual(existing?.text, "Older text")
    }
}
