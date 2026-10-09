import Foundation
import XCTest
import WiltedDomain
import WiltedProducer
@testable import WiltedMac

/// The Larder continuation that runs after an episode ends is an automatic
/// advance owned by the playback command owner: a deliberate selection or an
/// explicit Pause issued while it is still awaiting supersedes it.
extension WiltedMacModelTests {
    func testSelectionDuringContinuationAwaitsWinsOverAutoAdvance() async throws {
        let (model, episodes) = try await makeThreeReadyEpisodeModel("continue-own-select")
        let (first, second, third) = (episodes[0], episodes[1], episodes[2])
        try await playToEnd(model, first)

        model.simulatePodcastPlaybackFinishedForTesting()
        // The listener picks the third episode before the continuation's
        // reload and retirement awaits have finished.
        model.playEpisode(third)
        await model.waitForPlaybackOperationForTesting()
        try await settle(model)
        await model.waitForPlaybackOperationForTesting()

        XCTAssertEqual(model.currentEpisode?.id, third.id, "the deliberate selection wins")
        XCTAssertEqual(model.playback?.itemID?.rawValue, third.id)
        XCTAssertNotEqual(model.currentPodcastEpisodeID, second.id, "the auto-advance never started")
        let finished = try XCTUnwrap(model.episodes.first { $0.id == first.id })
        XCTAssertNotNil(finished.retiredAt, "the finished episode is still retired")
    }

    func testExplicitPauseDuringContinuationAwaitsPlaysNothingNext() async throws {
        let (model, episodes) = try await makeThreeReadyEpisodeModel("continue-own-pause")
        try await playToEnd(model, episodes[0])

        model.simulatePodcastPlaybackFinishedForTesting()
        model.handleRemoteCommand(.pause)
        try await settle(model)
        await model.waitForPlaybackOperationForTesting()

        XCTAssertNil(model.currentPodcastEpisodeID, "Pause means nothing plays next")
        XCTAssertFalse(model.isPlaying)
        XCTAssertNil(model.playbackCommands.automaticAdvance)
        let finished = try XCTUnwrap(model.episodes.first { $0.id == episodes[0].id })
        XCTAssertNotNil(finished.retiredAt)
    }

    // MARK: Helpers

    private func playToEnd(_ model: WiltedMacModel, _ episode: WiltedMacEpisode) async throws {
        model.playEpisode(episode)
        await model.waitForPlaybackOperationForTesting()
        try await settle(model)
        XCTAssertEqual(model.currentEpisode?.id, episode.id)
        await model.simulatePodcastPlaybackReachedEndForTesting()
        try await settle(model)
    }

    private func makeThreeReadyEpisodeModel(
        _ name: String
    ) async throws -> (WiltedMacModel, [WiltedMacEpisode]) {
        let directory = temporaryDirectory(name)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let feedURL = try XCTUnwrap(URL(string: "https://feeds.example.test/\(name).xml"))
        let feedID = try ItemID.derivePodcastFeed(from: feedURL)
        let created = Timestamp(Date(timeIntervalSince1970: 1_700_000_000))
        let enclosures = try (1...3).map { index in
            try XCTUnwrap(URL(string: "https://media.example.test/\(name)-\(index).mp3"))
        }
        let ids = try enclosures.enumerated().map { index, enclosure in
            try ItemID.derivePodcastEpisode(
                feedURL: feedURL, rssGUID: "\(name)-\(index + 1)", enclosureURL: enclosure
            )
        }
        let model = WiltedMacModel(
            arguments: [], stateDirectoryOverride: directory,
            storeBootstrap: { url in
                let store = try LocalLibraryStore(url: url)
                try await store.save(feed: try PodcastFeed(
                    itemID: feedID, canonicalURL: feedURL, title: "Owned", createdAt: created
                ))
                try await store.save(subscription: PodcastSubscription(feedID: feedID, subscribedAt: created))
                for index in 0..<3 {
                    try await Self.addReadyEpisode(
                        ids[index], guid: "\(name)-\(index + 1)", feedID: feedID, feedURL: feedURL,
                        enclosureURL: enclosures[index],
                        publishedAt: created.date.addingTimeInterval(Double(index) * 60),
                        directory: directory, store: store, created: created
                    )
                }
                return store
            }, preferences: WiltedMacTestPreferences.ephemeral()
        )
        model.libraryOrder = .oldest
        model.startStoreBootstrap()
        await model.waitForStoreBootstrap()
        let episodes = try ids.map { id in try XCTUnwrap(model.episodes.first { $0.id == id.rawValue }) }
        return (model, episodes)
    }
}
