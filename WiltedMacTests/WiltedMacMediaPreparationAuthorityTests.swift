import Foundation
import XCTest
import WiltedDomain
import WiltedLibrary
import WiltedProducer
@testable import WiltedMac

/// Real producer rows must authorize export; a generic ready revision is not preparation proof.
@MainActor
final class WiltedMacMediaPreparationAuthorityTests: XCTestCase {
    func testRawDownloadedQueuedEpisodeHasNoPreparedExportAuthority() async throws {
        let rig = try await makeRig("raw-download")
        let snapshot = try await rig.store.podcastLibrarySnapshot()
        XCTAssertNotNil(snapshot.readyRevisions[rig.entryID])
        XCTAssertEqual(snapshot.downloads[rig.entryID]?.status, .completed)
        XCTAssertNil(snapshot.preparationOutcomes[outcomeKey(rig.entryID, rig.raw.revisionID)])

        try await assertRefused(rig)
        XCTAssertTrue(FileManager.default.fileExists(atPath: rig.rawURL.path))
    }

    func testMatchingPreparedOutcomeAllowsUnchangedDownloadedBytes() async throws {
        let rig = try await makeRig("unchanged-prepared")
        try await prepareUnchanged(rig)

        try await assertExported(rig, revision: rig.raw, url: rig.rawURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: rig.rawURL.path),
                      "successful preparation need not cut or rename the original bytes")
    }

    func testChangedPreparedCutExportsAfterOriginalReclaimed() async throws {
        let rig = try await makeRig("cut-prepared")
        let (cut, cutURL) = try makeRevision(rig, name: "cut", byte: 2, offset: 10)
        let transcript = try Transcript(itemID: rig.entryID, revisionID: cut.revisionID,
                                        availability: .absent, updatedAt: cut.createdAt)
        try await rig.store.replaceReadyRevision(
            cut, mediaURL: cutURL, transcript: transcript,
            download: try completedDownload(rig.entryID, revision: cut, url: cutURL),
            superseding: rig.raw.revisionID, outcome: outcome(rig.entryID, revision: cut))
        // The real pipeline reclaims the source only after this atomic replacement succeeds.
        try FileManager.default.removeItem(at: rig.rawURL)
        let snapshot = try await rig.store.podcastLibrarySnapshot()
        XCTAssertEqual(snapshot.downloads[rig.entryID]?.localURL, cutURL)
        XCTAssertEqual(snapshot.readyRevisions[rig.entryID]?.revision.revisionID, cut.revisionID)
        XCTAssertNotEqual(cut.contentHash, rig.raw.contentHash)
        XCTAssertFalse(FileManager.default.fileExists(atPath: rig.rawURL.path))

        try await assertExported(rig, revision: cut, url: cutURL)
    }

    func testOutcomeForOlderRevisionCannotAuthorizeNewRawDownload() async throws {
        let rig = try await makeRig("wrong-revision")
        try await prepareUnchanged(rig)
        let (newRaw, newURL) = try makeRevision(rig, name: "new-raw", byte: 3, offset: 20)
        try await rig.store.finalizePodcastDownload(
            revision: newRaw, mediaURL: newURL,
            download: try completedDownload(rig.entryID, revision: newRaw, url: newURL))
        let snapshot = try await rig.store.podcastLibrarySnapshot()
        XCTAssertEqual(snapshot.readyRevisions[rig.entryID]?.revision.revisionID, newRaw.revisionID)
        XCTAssertNil(snapshot.preparationOutcomes[outcomeKey(rig.entryID, newRaw.revisionID)])

        try await assertRefused(rig)
    }

    func testInvalidOutcomeRefusesButEligibleOutcomeAdmits() async throws {
        let rig = try await makeRig("invalid-outcome")
        try await prepareUnchanged(rig, eligibility: .invalid)
        let snapshot = try await rig.store.podcastLibrarySnapshot()
        XCTAssertEqual(snapshot.preparationOutcomes[outcomeKey(rig.entryID, rig.raw.revisionID)]?.eligibility, .invalid)
        try await assertRefused(rig)

        try await prepareUnchanged(rig, eligibility: .eligible)
        try await assertExported(rig, revision: rig.raw, url: rig.rawURL)
    }

    func testPreparedButOffLarderRefusesDirectAndStandingExport() async throws {
        let rig = try await makeRig("off-larder")
        try await prepareUnchanged(rig)
        try await assertExported(rig, revision: rig.raw, url: rig.rawURL)
        try await rig.store.removePodcastQueueEpisode(rig.entryID)
        let queue = try await rig.store.podcastQueueState()
        XCTAssertFalse(queue.episodeIDs.contains(rig.entryID))
        let snapshot = try await rig.store.podcastLibrarySnapshot()
        XCTAssertNotNil(snapshot.readyRevisions[rig.entryID])
        XCTAssertNotNil(snapshot.preparationOutcomes[outcomeKey(rig.entryID, rig.raw.revisionID)])

        try await assertRefused(rig)
    }

    func testCompletionRetirementRefusesRetainedPreparedBytes() async throws {
        let rig = try await makeRig("retired-prepared")
        try await prepareUnchanged(rig)
        let retired = try await rig.store.completeAndRetireEpisode(listening: .init(
            episodeID: rig.entryID, completedAt: rig.raw.createdAt,
            lastRevisionID: nil, updatedAt: rig.raw.createdAt))
        XCTAssertTrue(retired)
        let snapshot = try await rig.store.podcastLibrarySnapshot()
        XCTAssertEqual(snapshot.removalKindByEpisode[rig.entryID], .retired)
        XCTAssertNotNil(snapshot.readyRevisions[rig.entryID])
        XCTAssertEqual(snapshot.downloads[rig.entryID]?.status, .completed)
        let queue = try await rig.store.podcastQueueState()
        XCTAssertTrue(queue.episodeIDs.contains(rig.entryID), "residual queue membership cannot defeat retirement")
        XCTAssertTrue(FileManager.default.fileExists(atPath: rig.rawURL.path))

        try await assertRefused(rig)
    }

    func testFailedOrMismatchedDownloadCannotAuthorizePreparedRevision() async throws {
        for mismatch in ["failed", "path", "hash", "bytes"] {
            let rig = try await makeRig("download-\(mismatch)")
            try await prepareUnchanged(rig)
            let alternate = try makeRevision(rig, name: "alternate", byte: 4, offset: 30)
            let download = try PodcastDownload(
                episodeID: rig.entryID, status: mismatch == "failed" ? .failed : .completed,
                bytesReceived: rig.raw.byteCount + (mismatch == "bytes" ? 1 : 0),
                expectedByteCount: nil,
                localURL: mismatch == "path" ? alternate.1 : rig.rawURL,
                contentHash: mismatch == "hash" ? alternate.0.contentHash : rig.raw.contentHash,
                updatedAt: rig.raw.createdAt)
            try await rig.store.save(download: download)
            let snapshot = try await rig.store.podcastLibrarySnapshot()
            XCTAssertNotNil(snapshot.preparationOutcomes[outcomeKey(rig.entryID, rig.raw.revisionID)])
            try await assertRefused(rig)
        }
    }

    func testShippingReadyAndStandingOffersSerializeTheRealPreparationEvent() async throws {
        let rig = try await makeRig("wire-preparation-event")
        let preparedAt = Timestamp(rig.raw.createdAt.date.addingTimeInterval(120))
        let transcript = try Transcript(itemID: rig.entryID, revisionID: rig.raw.revisionID,
                                        availability: .absent, updatedAt: preparedAt)
        let proof = PodcastPreparationOutcome(
            episodeID: rig.entryID, revisionID: rig.raw.revisionID,
            policyDigest: "fixture-policy", pipelineFingerprint: "fixture-pipeline",
            semanticVersion: "fixture-1", producedAt: preparedAt, eligibility: .current)
        try await rig.store.saveReadyRevision(rig.raw, mediaURL: rig.rawURL, transcript: transcript, outcome: proof)
        let snapshot = try await rig.store.podcastLibrarySnapshot()
        XCTAssertEqual(snapshot.preparationOutcomes[outcomeKey(rig.entryID, rig.raw.revisionID)]?.producedAt, preparedAt)
        XCTAssertNotEqual(preparedAt, rig.raw.createdAt, "publication clock and raw-download clock cannot substitute")

        let reconciled = await rig.runtime.service.reconcileAvailable()
        XCTAssertTrue(reconciled)
        let standing = try await rig.phone.mediaOffers()
        let available = try XCTUnwrap(standing.first { $0.entryID == rig.entryID })
        XCTAssertEqual(available.state, .available)
        try assertPreparationJSON(available, preparedAt: preparedAt, hash: rig.raw.contentHash)
        await rig.runtime.consume(try LibraryIntent.requestMedia(
            entryID: rig.entryID, deviceID: "authority-phone",
            createdAt: Date(timeIntervalSince1970: 1_800_000_000), id: UUID().uuidString))
        let offers = try await rig.phone.mediaOffers()
        let ready = try XCTUnwrap(offers.first { $0.entryID == rig.entryID })
        XCTAssertEqual(ready.state, .ready)
        try assertPreparationJSON(ready, preparedAt: preparedAt, hash: rig.raw.contentHash)
    }

    private func assertPreparationJSON(_ offer: LibraryMediaOffer, preparedAt: Timestamp, hash: String,
                                       file: StaticString = #filePath, line: UInt = #line) throws {
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(offer)) as? [String: Any],
                                   file: file, line: line)
        XCTAssertEqual(object["contentHash"] as? String, hash, file: file, line: line)
        let proof = try XCTUnwrap(object["preparation"] as? [String: Any], file: file, line: line)
        XCTAssertEqual(proof["schemaVersion"] as? Int, 1, file: file, line: line)
        XCTAssertEqual(proof["preparedAt"] as? String, preparedAt.description, file: file, line: line)
        XCTAssertTrue(offer.isPrepared, file: file, line: line)
    }

    private struct Rig {
        let directory: URL
        let store: LocalLibraryStore
        let source: WiltedMacLocalReadyAudioSource
        let runtime: WiltedMacInboundRuntime
        let phone: InMemoryLibraryTransport
        let entryID: ItemID
        let raw: AudioRevision
        let rawURL: URL
    }

    private func makeRig(_ name: String) async throws -> Rig {
        let directory = wiltedTemporaryDirectory("media-authority-\(name)")
        let feedURL = URL(string: "https://fixtures.example.test/media-authority.xml")!
        let enclosure = URL(string: "https://fixtures.example.test/original.mp3")!
        let feedID = try ItemID.derivePodcastFeed(from: feedURL)
        let entryID = try ItemID.derivePodcastEpisode(feedURL: feedURL, rssGUID: "authority-episode", enclosureURL: enclosure)
        let timestamp = Timestamp(Date(timeIntervalSince1970: 1_800_000_000))
        let store = try LocalLibraryStore(url: directory.appendingPathComponent("library.sqlite"))
        try await store.save(feed: try PodcastFeed(itemID: feedID, canonicalURL: feedURL,
                                                 title: "Authority feed", createdAt: timestamp))
        try await store.save(subscription: PodcastSubscription(feedID: feedID, subscribedAt: timestamp))
        try await store.save(episode: try PodcastEpisode(
            itemID: entryID, feedID: feedID, feedURL: feedURL, rssGUID: "authority-episode",
            title: "Authority episode", publishedTime: timestamp, enclosureURL: enclosure,
            enclosureMediaType: "audio/mpeg", createdAt: timestamp))
        try await store.replacePodcastQueue(try PodcastQueueState(episodeIDs: [entryID], currentEpisodeID: nil))
        let rawURL = directory.appendingPathComponent("original.mp3")
        try Data(repeating: 1, count: 4096).write(to: rawURL)
        let hash = try MediaHash.sha256(fileAt: rawURL)
        let raw = try AudioRevision(
            itemID: entryID, revisionID: RevisionID(rawValue: "rev-" + String(hash.dropFirst(MediaHash.prefix.count))),
            durationSeconds: 60, byteCount: 4096, contentHash: hash, mediaType: "audio/mpeg",
            createdAt: timestamp, schemaVersion: 3)
        try await store.finalizePodcastDownload(
            revision: raw, mediaURL: rawURL, download: try completedDownload(entryID, revision: raw, url: rawURL))
        let source = WiltedMacLocalReadyAudioSource(store: store)
        let server = InMemoryLibraryServer(writerDeviceID: "authority-mac")
        let mac = InMemoryLibraryTransport(deviceID: "authority-mac", server: server)
        let phone = InMemoryLibraryTransport(deviceID: "authority-phone", server: server)
        let runtime = WiltedMacInboundRuntime(source: source, transport: mac, directory: directory,
                                             now: { Date(timeIntervalSince1970: 1_800_000_000) })
        return Rig(directory: directory, store: store, source: source, runtime: runtime,
                   phone: phone, entryID: entryID, raw: raw, rawURL: rawURL)
    }

    private func makeRevision(_ rig: Rig, name: String, byte: UInt8, offset: TimeInterval) throws -> (AudioRevision, URL) {
        let url = rig.directory.appendingPathComponent("\(name).mp3")
        try Data(repeating: byte, count: 2048).write(to: url)
        let hash = try MediaHash.sha256(fileAt: url)
        let revision = try AudioRevision(
            itemID: rig.entryID, revisionID: RevisionID(rawValue: "rev-" + String(hash.dropFirst(MediaHash.prefix.count))),
            durationSeconds: 30, byteCount: 2048, contentHash: hash, mediaType: "audio/mpeg",
            createdAt: Timestamp(rig.raw.createdAt.date.addingTimeInterval(offset)), schemaVersion: 3)
        return (revision, url)
    }

    private func completedDownload(_ id: ItemID, revision: AudioRevision, url: URL) throws -> PodcastDownload {
        try PodcastDownload(episodeID: id, status: .completed, bytesReceived: revision.byteCount,
                            expectedByteCount: revision.byteCount, localURL: url, contentHash: revision.contentHash,
                            updatedAt: revision.createdAt)
    }

    private func outcome(_ id: ItemID, revision: AudioRevision,
                         eligibility: PodcastPreparationEligibility = .current) -> PodcastPreparationOutcome {
        PodcastPreparationOutcome(episodeID: id, revisionID: revision.revisionID,
                                  policyDigest: "fixture-policy", pipelineFingerprint: "fixture-pipeline",
                                  semanticVersion: "fixture-1", producedAt: revision.createdAt, eligibility: eligibility)
    }

    private func outcomeKey(_ id: ItemID, _ revision: RevisionID) -> String { "\(id.rawValue)|\(revision.rawValue)" }

    private func prepareUnchanged(_ rig: Rig, eligibility: PodcastPreparationEligibility = .current) async throws {
        let transcript = try Transcript(itemID: rig.entryID, revisionID: rig.raw.revisionID,
                                        availability: .absent, updatedAt: rig.raw.createdAt)
        try await rig.store.saveReadyRevision(rig.raw, mediaURL: rig.rawURL, transcript: transcript,
                                             outcome: outcome(rig.entryID, revision: rig.raw, eligibility: eligibility))
    }

    private func assertRefused(_ rig: Rig, file: StaticString = #filePath, line: UInt = #line) async throws {
        let direct = try await rig.source.readyAudio(for: rig.entryID)
        let prepared = try await rig.source.preparedQueuedAudio()
        XCTAssertNil(direct, "a retained generic ready revision is not export authority", file: file, line: line)
        XCTAssertNil(prepared[rig.entryID], file: file, line: line)
        let reconciled = await rig.runtime.service.reconcileAvailable()
        XCTAssertTrue(reconciled, file: file, line: line)
        let standing = try await rig.phone.mediaOffers()
        XCTAssertFalse(standing.contains { $0.entryID == rig.entryID && $0.isPrepared }, file: file, line: line)
        await rig.runtime.consume(try LibraryIntent.requestMedia(
            entryID: rig.entryID, deviceID: "authority-phone", createdAt: Date(timeIntervalSince1970: 1_800_000_000),
            id: UUID().uuidString))
        let offers = try await rig.phone.mediaOffers()
        let answer = try XCTUnwrap(offers.first { $0.entryID == rig.entryID }, file: file, line: line)
        XCTAssertEqual(answer.state, .notReady, file: file, line: line)
        XCTAssertNil(answer.revisionID, file: file, line: line)
        XCTAssertEqual(answer.byteCount, 0, file: file, line: line)
        let held = await rig.runtime.service.accountedAssetCount
        XCTAssertEqual(held, 0, "refused audio must not become an uploaded asset", file: file, line: line)
    }

    private func assertExported(_ rig: Rig, revision: AudioRevision, url: URL,
                                file: StaticString = #filePath, line: UInt = #line) async throws {
        let direct = try await rig.source.readyAudio(for: rig.entryID)
        let prepared = try await rig.source.preparedQueuedAudio()
        XCTAssertEqual(direct?.revisionID, revision.revisionID, file: file, line: line)
        XCTAssertEqual(direct?.fileURL, url, file: file, line: line)
        XCTAssertEqual(prepared[rig.entryID]?.revisionID, revision.revisionID, file: file, line: line)
        let reconciled = await rig.runtime.service.reconcileAvailable()
        XCTAssertTrue(reconciled, file: file, line: line)
        let standing = try await rig.phone.mediaOffers()
        let available = try XCTUnwrap(standing.first { $0.entryID == rig.entryID }, file: file, line: line)
        XCTAssertEqual(available.state, .available, file: file, line: line)
        XCTAssertEqual(available.revisionID, revision.revisionID, file: file, line: line)
        await rig.runtime.consume(try LibraryIntent.requestMedia(
            entryID: rig.entryID, deviceID: "authority-phone", createdAt: Date(timeIntervalSince1970: 1_800_000_000),
            id: UUID().uuidString))
        let offers = try await rig.phone.mediaOffers()
        let ready = try XCTUnwrap(offers.first { $0.entryID == rig.entryID }, file: file, line: line)
        XCTAssertEqual(ready.state, .ready, file: file, line: line)
        XCTAssertEqual(ready.revisionID, revision.revisionID, file: file, line: line)
        XCTAssertEqual(ready.contentHash, revision.contentHash, file: file, line: line)
        let delivered = try await rig.phone.fetchMedia(ready) { _ in }
        defer { try? FileManager.default.removeItem(at: delivered) }
        XCTAssertTrue(delivered.isFileURL, file: file, line: line)
        XCTAssertEqual(try MediaHash.sha256(fileAt: delivered), revision.contentHash, file: file, line: line)
        XCTAssertEqual(try Data(contentsOf: delivered), try Data(contentsOf: url), file: file, line: line)
    }
}
