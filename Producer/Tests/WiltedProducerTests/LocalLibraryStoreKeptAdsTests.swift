import CryptoKit
import Foundation
import XCTest
import WiltedDomain
@testable import WiltedProducer

/// `podcastEpisodesKeepingAds()` is the Larder's only proof that an episode was
/// prepared but kept every advertisement: a succeeded run whose worker reported
/// `uncertain`. These cases pin each condition that has to hold before Wilted
/// offers to prepare the episode again.
final class LocalLibraryStoreKeptAdsTests: XCTestCase {
    // MARK: Fixtures

    private struct Library {
        let root: URL
        let store: LocalLibraryStore
        let episodeID: ItemID
        let revision: AudioRevision
        let audioURL: URL
    }

    private func makeRoot(_ name: String) -> URL {
        OwnedTestTemp.root.appendingPathComponent("wilted-kept-ads-\(name)-\(UUID().uuidString)")
    }

    /// One downloaded podcast episode, its original audio on disk, and the
    /// ready revision that audio belongs to. Nothing about its preparation is
    /// assumed here; each test records the run it means to test.
    private func makeLibrary(_ name: String) async throws -> Library {
        let root = makeRoot(name)
        let store = try LocalLibraryStore(url: root.appendingPathComponent("library.sqlite"))
        let feedURL = try XCTUnwrap(URL(string: "https://feeds.example.test/kept-ads-\(name).xml"))
        let enclosureURL = try XCTUnwrap(URL(string: "https://media.example.test/kept-ads-\(name).mp3"))
        let feedID = try ItemID.derivePodcastFeed(from: feedURL)
        let episodeID = try ItemID.derivePodcastEpisode(
            feedURL: feedURL, rssGUID: "kept-ads-\(name)", enclosureURL: enclosureURL
        )
        let created = Timestamp(Date(timeIntervalSince1970: 1_700_000_000))
        try await store.save(feed: try PodcastFeed(
            itemID: feedID, canonicalURL: feedURL, title: "Kept ads feed", createdAt: created
        ))
        try await store.save(episode: try PodcastEpisode(
            itemID: episodeID, feedID: feedID, feedURL: feedURL, rssGUID: "kept-ads-\(name)",
            title: "Kept ads episode", publishedTime: created, enclosureURL: enclosureURL,
            enclosureMediaType: "audio/mpeg", createdAt: created
        ))
        let body = Data("original-audio-bytes-\(name)".utf8)
        let audioURL = root.appendingPathComponent("original.mp3")
        try body.write(to: audioURL)
        let hash = "sha256:" + SHA256.hash(data: body).map { String(format: "%02x", $0) }.joined()
        let revision = try AudioRevision(
            itemID: episodeID, revisionID: RevisionID(rawValue: "rev-kept-ads-" + name),
            durationSeconds: 12, byteCount: Int64(body.count), contentHash: hash,
            mediaType: "audio/mpeg", createdAt: created, schemaVersion: 3
        )
        try await store.finalizePodcastDownload(
            revision: revision, mediaURL: audioURL,
            download: try PodcastDownload(
                episodeID: episodeID, status: .completed, bytesReceived: Int64(body.count),
                expectedByteCount: Int64(body.count), localURL: audioURL, contentHash: hash,
                updatedAt: created
            )
        )
        return Library(root: root, store: store, episodeID: episodeID, revision: revision, audioURL: audioURL)
    }

    private func remove(_ library: Library) {
        try? FileManager.default.removeItem(at: library.root)
    }

    /// One journalled attempt: the worker's result, then its terminal entry.
    /// `attempt` nil writes the shape older pipelines left behind.
    private func recordRun(
        _ library: Library, outcome: String, at date: Date,
        attempt: PreparationAttemptIdentity? = nil, succeeded: Bool = true
    ) async throws {
        let requestID = PodcastPreparationPipeline.requestID(for: library.episodeID)
        let generation = attempt.map { "|" + $0.key } ?? ""
        let resultEvidence = try PreparationEvidence(kind: "worker-result", fields: ["adRemovalOutcome": outcome])
        try await library.store.record(preparation: PreparationJournalEntry(
            id: requestID + generation + "|pipeline.result#2", itemID: library.episodeID, requestID: requestID,
            status: try PreparationStatus(
                stage: .assembling, detail: "audio unchanged", cancellable: true,
                emittedAt: Timestamp(date), evidence: resultEvidence, attempt: attempt
            )
        ))
        let failure: ProducerError?
        if succeeded {
            failure = nil
        } else {
            failure = try ProducerError(code: .failed, message: "worker failed", retryable: true)
        }
        let terminal = try PreparationTerminalResult(
            outcome: succeeded ? .succeeded : .failed,
            revisionID: succeeded ? library.revision.revisionID : nil,
            error: failure
        )
        try await library.store.record(preparation: PreparationJournalEntry(
            id: requestID + generation + "|terminal", itemID: library.episodeID, requestID: requestID,
            status: try PreparationStatus(
                stage: succeeded ? .completed : .failed,
                detail: succeeded ? "Prepared." : "worker failed", cancellable: false,
                terminalResult: terminal, emittedAt: Timestamp(date.addingTimeInterval(1)), attempt: attempt
            )
        ))
    }

    private func runningAttempt(
        _ library: Library, sequence: Int, at date: Date
    ) async throws -> PreparationAttemptIdentity {
        let ticket = try await library.store.readmitWorkTicket(
            kind: .podcastPreparation, subjectID: library.episodeID.rawValue,
            requestSequence: sequence, to: .running, at: Timestamp(date)
        )
        return try PreparationAttemptIdentity(
            requestSequence: ticket.requestSequence, attemptCount: ticket.attemptCount
        )
    }

    // MARK: Cases

    func testAnUncertainPreparationOverTheOriginalIsEligible() async throws {
        let library = try await makeLibrary("eligible")
        defer { remove(library) }
        try await recordRun(library, outcome: "uncertain", at: Date(timeIntervalSince1970: 1_700_000_100))

        let keeping = try await library.store.podcastEpisodesKeepingAds()
        XCTAssertEqual(keeping, [library.episodeID])
    }

    /// The same succeeded run with a cut outcome means the ads were removed;
    /// there is nothing to prepare again.
    func testACutOutcomeIsNotEligible() async throws {
        let library = try await makeLibrary("cut")
        defer { remove(library) }
        try await recordRun(library, outcome: "cut", at: Date(timeIntervalSince1970: 1_700_000_100))

        let keeping = try await library.store.podcastEpisodesKeepingAds()
        XCTAssertEqual(keeping, [])
    }

    /// A cut revision on top of the original: `prepare` would read the original
    /// file but take its source identity and carried playback from the cut
    /// revision, so the position would map through the wrong timeline.
    func testACutRevisionOnTopIsNotEligible() async throws {
        let library = try await makeLibrary("cut-revision")
        defer { remove(library) }
        try await recordRun(library, outcome: "uncertain", at: Date(timeIntervalSince1970: 1_700_000_100))
        let beforeCut = try await library.store.podcastEpisodesKeepingAds()
        XCTAssertEqual(beforeCut, [library.episodeID])

        let cutBytes = Data("shorter-audio-bytes".utf8)
        let cut = try AudioRevision(
            itemID: library.episodeID, revisionID: RevisionID(rawValue: "rev-kept-ads-cut-output"),
            durationSeconds: 7.5, byteCount: Int64(cutBytes.count),
            contentHash: "sha256:" + String(repeating: "b", count: 64),
            mediaType: "audio/mpeg",
            createdAt: Timestamp(Date(timeIntervalSince1970: 1_700_000_200)), schemaVersion: 3
        )
        let cutURL = library.root.appendingPathComponent("cut.mp3")
        try cutBytes.write(to: cutURL)
        try await library.store.saveReadyRevision(cut, mediaURL: cutURL)

        let keeping = try await library.store.podcastEpisodesKeepingAds()
        XCTAssertEqual(keeping, [], "the newest revision is no longer the downloaded original")
    }

    func testAMissingDownloadFileIsNotEligible() async throws {
        let library = try await makeLibrary("missing-file")
        defer { remove(library) }
        try await recordRun(library, outcome: "uncertain", at: Date(timeIntervalSince1970: 1_700_000_100))
        try FileManager.default.removeItem(at: library.audioURL)

        let keeping = try await library.store.podcastEpisodesKeepingAds()
        XCTAssertEqual(keeping, [], "there is no source audio left to prepare")
    }

    /// A failed retry after an uncertain success is the newest attempt, so the
    /// episode has work outstanding under its own Retry, not a re-preparation.
    func testAFailedNewestAttemptIsNotEligible() async throws {
        let library = try await makeLibrary("retried")
        defer { remove(library) }
        let start = Date(timeIntervalSince1970: 1_700_000_100)
        let firstAttempt = try await runningAttempt(library, sequence: 1, at: start)
        try await recordRun(library, outcome: "uncertain", at: start, attempt: firstAttempt)
        let afterFirst = try await library.store.podcastEpisodesKeepingAds()
        XCTAssertEqual(afterFirst, [library.episodeID], "the older success alone would qualify")
        let secondAttempt = try await runningAttempt(library, sequence: 2, at: start.addingTimeInterval(60))
        try await recordRun(library, outcome: "uncertain", at: start.addingTimeInterval(61),
                            attempt: secondAttempt, succeeded: false)

        let keeping = try await library.store.podcastEpisodesKeepingAds()
        XCTAssertEqual(keeping, [], "the newest attempt failed, so nothing is left to re-prepare")
    }

    /// A dismissed episode keeps its journal and download, but it is not in the
    /// library to act on.
    func testARetiredEpisodeIsNotEligible() async throws {
        let library = try await makeLibrary("retired")
        defer { remove(library) }
        try await recordRun(library, outcome: "uncertain", at: Date(timeIntervalSince1970: 1_700_000_100))
        try await library.store.dismissPodcastEpisode(library.episodeID)

        let keeping = try await library.store.podcastEpisodesKeepingAds()
        XCTAssertEqual(keeping, [])
    }
}
