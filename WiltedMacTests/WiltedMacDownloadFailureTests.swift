import XCTest
import WiltedDomain
import WiltedProducer
@testable import WiltedMac

/// Answers 503 to the first request and a clean four-byte transfer after it.
private struct FailsOnceThenServesTransport: PodcastDownloadTransporting {
    let counter: DownloadAttemptCounter
    func events(for url: URL) -> AsyncThrowingStream<PodcastDownloadEvent, Error> {
        counter.increment()
        let first = counter.count == 1
        return AsyncThrowingStream { continuation in
            continuation.yield(.response(.init(url: url, statusCode: first ? 503 : 200,
                                               mediaType: "audio/mpeg", expectedByteCount: first ? nil : 4)))
            if !first { continuation.yield(.data(Data("body".utf8))) }
            continuation.finish()
        }
    }
}

@MainActor
final class WiltedMacDownloadFailureTests: XCTestCase {
    func testTypedCausesMapToDistinctPlainMessages() {
        let online = WiltedMacModel.downloadFailureMessage(
            for: PodcastDownloadCoordinatorError.transport("offline")
        )
        XCTAssertEqual(online, "Download failed. Retry when you are online.")

        let hash = WiltedMacModel.downloadFailureMessage(
            for: PodcastDownloadCoordinatorError.hashMismatch(expected: "a", actual: "b")
        )
        XCTAssertFalse(hash.contains("online"))
        XCTAssertNotEqual(hash, online)

        let format = WiltedMacModel.downloadFailureMessage(
            for: PodcastDownloadCoordinatorError.unsupportedMediaType("video/mp4")
        )
        XCTAssertFalse(format.contains("online"))
        XCTAssertNotEqual(format, hash)

        let size = WiltedMacModel.downloadFailureMessage(
            for: PodcastDownloadCoordinatorError.streamedSizeTooLarge(1_000)
        )
        XCTAssertNotEqual(size, online)
        XCTAssertNotEqual(size, hash)

        let redirect = WiltedMacModel.downloadFailureMessage(
            for: PodcastDownloadCoordinatorError.insecureRedirect
        )
        XCTAssertNotEqual(redirect, online)
        XCTAssertNotEqual(redirect, hash)
    }

    /// A manual retry of a failed download is a new request: its ticket leaves
    /// the terminal state and records the attempt, instead of the retry's
    /// transfer finishing under a ticket that still says failed.
    func testManualRetryOfAFailedDownloadReadmitsItsTicket() async throws {
        let directory = wiltedTemporaryDirectory("download-retry-readmission")
        let feedURL = try XCTUnwrap(URL(string: "https://feeds.example.test/retry.xml"))
        let feedID = try ItemID.derivePodcastFeed(from: feedURL)
        let enclosureURL = try XCTUnwrap(URL(string: "https://media.example.test/retry.mp3"))
        let episodeID = try ItemID.derivePodcastEpisode(feedURL: feedURL, rssGUID: "retry", enclosureURL: enclosureURL)
        let created = Timestamp(Date(timeIntervalSince1970: 1_700_000_000))
        let counter = DownloadAttemptCounter()
        let model = WiltedMacModel(
            arguments: [], stateDirectoryOverride: directory,
            storeBootstrap: { url in
                let store = try LocalLibraryStore(url: url)
                try await store.save(feed: try PodcastFeed(
                    itemID: feedID, canonicalURL: feedURL, title: "Retry feed", createdAt: created
                ))
                try await store.save(subscription: PodcastSubscription(feedID: feedID, subscribedAt: created))
                try await store.save(episode: try PodcastEpisode(
                    itemID: episodeID, feedID: feedID, feedURL: feedURL, rssGUID: "retry",
                    title: "Retry episode", publishedTime: created, enclosureURL: enclosureURL,
                    enclosureMediaType: "audio/mpeg", createdAt: created
                ))
                return store
            },
            podcastDownloadTransportFactory: { FailsOnceThenServesTransport(counter: counter) },
            podcastMediaValidatorFactory: { StubPodcastMediaValidator(duration: 12) },
            preferences: WiltedMacTestPreferences.ephemeral()
        )
        model.startStoreBootstrap()
        await model.waitForStoreBootstrap()
        let episode = try XCTUnwrap(model.episodes.first(where: { $0.id == episodeID.rawValue }))

        model.downloadEpisode(episode)
        await model.waitForPodcastOperations()
        let storeURL = directory.appendingPathComponent("library.sqlite")
        let failed = try await LocalLibraryStore(url: storeURL).workTicket(kind: .podcastDownload, subjectID: episodeID.rawValue)
        XCTAssertEqual(failed?.state, .failed)
        XCTAssertEqual(model.podcastOperationMessage, "Download failed. Retry when you are online.")

        model.downloadEpisode(episode)
        await model.waitForPodcastOperations()
        let retried = try await LocalLibraryStore(url: storeURL).workTicket(kind: .podcastDownload, subjectID: episodeID.rawValue)
        XCTAssertEqual(counter.count, 2)
        XCTAssertEqual(retried?.state, .succeeded, "the retry's ticket left the terminal failure")
        XCTAssertGreaterThan(retried?.attemptCount ?? 0, failed?.attemptCount ?? 0)
        XCTAssertGreaterThan(retried?.requestSequence ?? 0, failed?.requestSequence ?? 0)
    }
}
