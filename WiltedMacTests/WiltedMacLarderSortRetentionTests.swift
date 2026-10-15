import Foundation
import WiltedDomain
import WiltedProducer
import XCTest
@testable import WiltedMac

/// Proves that the user's selected Larder sort preference (.age + .descending) persists across
/// playback operations (generic play and natural completion) and subsequent model rebuilds,
/// while explicit manual reorder operations continue to switch the sort to .custom.
@MainActor
final class WiltedMacLarderSortRetentionTests: XCTestCase {
    private struct Rig {
        let model: WiltedMacModel
        let store: LocalLibraryStore
        let directory: URL
        let preferences: UserDefaults
        let firstID: ItemID
        let secondID: ItemID
        let thirdID: ItemID
        let feedID: ItemID
    }

    private func makeRig(
        _ name: String,
        preferences: UserDefaults = WiltedMacTestPreferences.ephemeral()
    ) async throws -> Rig {
        let directory = wiltedTemporaryDirectory(name)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let feedURL = try XCTUnwrap(URL(string: "https://feeds.example.test/\(name).xml"))
        let feedID = try ItemID.derivePodcastFeed(from: feedURL)
        let baseDate = Date(timeIntervalSince1970: 1_700_000_000)
        let created = Timestamp(baseDate)

        let enc1 = try XCTUnwrap(URL(string: "https://media.example.test/\(name)-1.mp3"))
        let enc2 = try XCTUnwrap(URL(string: "https://media.example.test/\(name)-2.mp3"))
        let enc3 = try XCTUnwrap(URL(string: "https://media.example.test/\(name)-3.mp3"))

        let id1 = try ItemID.derivePodcastEpisode(feedURL: feedURL, rssGUID: "\(name)-1", enclosureURL: enc1)
        let id2 = try ItemID.derivePodcastEpisode(feedURL: feedURL, rssGUID: "\(name)-2", enclosureURL: enc2)
        let id3 = try ItemID.derivePodcastEpisode(feedURL: feedURL, rssGUID: "\(name)-3", enclosureURL: enc3)

        let model = WiltedMacModel(
            arguments: [],
            stateDirectoryOverride: directory,
            storeBootstrap: { url in
                let store = try LocalLibraryStore(url: url)
                try await store.save(feed: try PodcastFeed(
                    itemID: feedID, canonicalURL: feedURL, title: "Feed \(name)", createdAt: created
                ))
                try await store.save(subscription: PodcastSubscription(feedID: feedID, subscribedAt: created))
                try await WiltedMacModelTests.addReadyEpisode(
                    id1, guid: "\(name)-1", feedID: feedID, feedURL: feedURL,
                    enclosureURL: enc1, publishedAt: baseDate,
                    directory: directory, store: store, created: created
                )
                try await WiltedMacModelTests.addReadyEpisode(
                    id2, guid: "\(name)-2", feedID: feedID, feedURL: feedURL,
                    enclosureURL: enc2, publishedAt: baseDate.addingTimeInterval(60),
                    directory: directory, store: store, created: created
                )
                try await WiltedMacModelTests.addReadyEpisode(
                    id3, guid: "\(name)-3", feedID: feedID, feedURL: feedURL,
                    enclosureURL: enc3, publishedAt: baseDate.addingTimeInterval(120),
                    directory: directory, store: store, created: created
                )
                try await store.replacePodcastQueue(try PodcastQueueState(
                    episodeIDs: [id1, id2, id3], currentEpisodeID: nil
                ))
                return store
            },
            preferences: preferences
        )
        model.startStoreBootstrap()
        await model.waitForStoreBootstrap()
        addTeardownBlock { await model.close() }
        let store = try XCTUnwrap(model.store)
        return Rig(
            model: model, store: store, directory: directory, preferences: preferences,
            firstID: id1, secondID: id2, thirdID: id3, feedID: feedID
        )
    }

    func testAgeDescendingSortSurvivesGenericPlay() async throws {
        let rig = try await makeRig("generic-play")
        rig.model.larderSort = .age
        rig.model.larderSortDirection = .descending
        await WiltedMacHeadless.eventually("sort settles") { !rig.model.isApplyingLarderSort }
        XCTAssertEqual(rig.model.larderSort, .age)
        XCTAssertEqual(rig.model.larderSortDirection, .descending)

        let first = try XCTUnwrap(rig.model.episodes.first { $0.id == rig.firstID.rawValue })
        rig.model.playEpisode(first)
        await rig.model.waitForPlaybackOperationForTesting()

        // Guard actual generic play path was reached
        XCTAssertEqual(rig.model.currentPodcastEpisodeID, rig.firstID.rawValue)
        XCTAssertTrue(rig.model.isPlaying)
        XCTAssertFalse(rig.model.isLarderQueuePlayback, "generic play marks isLarderQueuePlayback as false")

        // Assert sort and direction preferences survived generic play
        XCTAssertEqual(rig.model.larderSort, .age, "generic Play must not reset larderSort to .custom")
        XCTAssertEqual(rig.model.larderSortDirection, .descending)
        XCTAssertEqual(
            rig.preferences.string(forKey: WiltedMacModel.larderSortPreferenceKey),
            WiltedMacLarderSort.age.canonical.rawValue
        )
        XCTAssertEqual(
            rig.preferences.string(forKey: WiltedMacModel.larderSortDirectionPreferenceKey),
            WiltedMacLarderSortDirection.descending.rawValue
        )
    }

    func testAgeDescendingSortSurvivesNaturalCompletion() async throws {
        let rig = try await makeRig("natural-completion")
        rig.model.larderSort = .age
        rig.model.larderSortDirection = .descending
        await WiltedMacHeadless.eventually("sort settles") { !rig.model.isApplyingLarderSort }

        let first = try XCTUnwrap(rig.model.episodes.first { $0.id == rig.firstID.rawValue })
        rig.model.playEpisode(first)
        await rig.model.waitForPlaybackOperationForTesting()
        XCTAssertEqual(rig.model.currentPodcastEpisodeID, rig.firstID.rawValue)

        var decisionLogs: [String] = []
        WiltedMacModel.advanceDecisionLogObserverForTesting = { decisionLogs.append($0) }
        defer { WiltedMacModel.advanceDecisionLogObserverForTesting = nil }

        let displayedSuccessor = try XCTUnwrap(rig.model.larderUnfilteredEpisodes(in: .playable)
            .first { $0.id != rig.firstID.rawValue && rig.model.canPlayEpisode($0) })
        await rig.model.simulatePodcastPlaybackReachedEndForTesting()
        rig.model.simulatePodcastPlaybackFinishedForTesting()
        await rig.model.waitForPlaybackOperationForTesting()

        await WiltedMacHeadless.eventually("natural advance selects successor") {
            rig.model.currentPodcastEpisodeID == displayedSuccessor.id && rig.model.isPlaying
        }

        // Guard actual natural advance path reached
        XCTAssertTrue(
            decisionLogs.contains { $0.contains("advance.decision chosen=\(displayedSuccessor.id) reason=first_ready_row") },
            "natural advance reached automatic advance decision"
        )
        XCTAssertEqual(rig.model.currentPodcastEpisodeID, displayedSuccessor.id)
        XCTAssertTrue(rig.model.isPlaying)
        XCTAssertFalse(rig.model.isLarderQueuePlayback)
        XCTAssertEqual(rig.model.podcastOperationMessage, "Finished \(first.title).")

        // Assert sort and direction preferences survived natural advance
        XCTAssertEqual(rig.model.larderSort, .age, "natural advance must not reset larderSort to .custom")
        XCTAssertEqual(rig.model.larderSortDirection, .descending)
        XCTAssertEqual(
            rig.preferences.string(forKey: WiltedMacModel.larderSortPreferenceKey),
            WiltedMacLarderSort.age.canonical.rawValue
        )
        XCTAssertEqual(
            rig.preferences.string(forKey: WiltedMacModel.larderSortDirectionPreferenceKey),
            WiltedMacLarderSortDirection.descending.rawValue
        )
    }

    func testAgeDescendingSortSurvivesModelRebuild() async throws {
        let suite = WiltedMacTestPreferences.suiteName("rebuild-retention")
        guard let preferences = UserDefaults(suiteName: suite) else {
            return XCTFail("Unable to create test preferences suite")
        }
        preferences.removePersistentDomain(forName: suite)
        defer { preferences.removePersistentDomain(forName: suite) }

        let rig = try await makeRig("rebuild-rig", preferences: preferences)
        rig.model.larderSort = .age
        rig.model.larderSortDirection = .descending
        await WiltedMacHeadless.eventually("sort settles") { !rig.model.isApplyingLarderSort }

        let first = try XCTUnwrap(rig.model.episodes.first { $0.id == rig.firstID.rawValue })
        rig.model.playEpisode(first)
        await rig.model.waitForPlaybackOperationForTesting()


        let displayedSuccessor = try XCTUnwrap(rig.model.larderUnfilteredEpisodes(in: .playable)
            .first { $0.id != rig.firstID.rawValue && rig.model.canPlayEpisode($0) })
        await rig.model.simulatePodcastPlaybackReachedEndForTesting()
        rig.model.simulatePodcastPlaybackFinishedForTesting()
        await rig.model.waitForPlaybackOperationForTesting()

        await WiltedMacHeadless.eventually("natural advance selects successor") {
            rig.model.currentPodcastEpisodeID == displayedSuccessor.id && rig.model.isPlaying
        }

        let durableBeforeRebuild = try await rig.store.podcastQueueState()
        XCTAssertEqual(durableBeforeRebuild.currentEpisodeID?.rawValue, displayedSuccessor.id)
        await rig.model.close()
        // Rebuild model with the same real library URL and test-only preferences suite.
        let rebuilt = WiltedMacModel(
            arguments: [],
            stateDirectoryOverride: rig.directory,
            storeBootstrap: { url in try LocalLibraryStore(url: url) },
            preferences: preferences
        )
        rebuilt.startStoreBootstrap()
        await rebuilt.waitForStoreBootstrap()
        addTeardownBlock { await rebuilt.close() }

        XCTAssertEqual(Set(rebuilt.episodes.map(\.id)), [rig.firstID.rawValue, rig.secondID.rawValue, rig.thirdID.rawValue])
        XCTAssertEqual(rebuilt.podcastQueueIDs, durableBeforeRebuild.episodeIDs.map(\.rawValue))
        XCTAssertEqual(rebuilt.currentPodcastEpisodeID, durableBeforeRebuild.currentEpisodeID?.rawValue)
        XCTAssertEqual(rebuilt.playback?.itemID?.rawValue, displayedSuccessor.id)
        // Guard actual rebuild read persisted preferences after the real queue/current restore.
        XCTAssertEqual(rebuilt.larderSort, .age, "rebuilt model restores Age sort preference")
        XCTAssertEqual(rebuilt.larderSortDirection, .descending, "rebuilt model restores descending direction")
        XCTAssertEqual(rebuilt.larderSort.displayName, "Age")
        XCTAssertEqual(rebuilt.larderSortDirection.displayName, "Descending")
    }

    func testExplicitManualMoveSelectsCustomSort() async throws {
        let rig = try await makeRig("manual-move")
        rig.model.larderSort = .age
        rig.model.larderSortDirection = .descending
        await WiltedMacHeadless.eventually("sort settles") { !rig.model.isApplyingLarderSort }
        XCTAssertEqual(rig.model.larderSort, .age)
        XCTAssertEqual(rig.model.larderSortDirection, .descending)

        let thirdID = rig.thirdID.rawValue
        let firstID = rig.firstID.rawValue
        let secondID = rig.secondID.rawValue

        // Verify initial queue order is [firstID, secondID, thirdID]
        XCTAssertEqual(rig.model.podcastQueueIDs, [firstID, secondID, thirdID])

        // Explicit manual move of the third episode to the first position
        let moved = rig.model.moveLarderEpisode(thirdID, before: firstID)
        XCTAssertTrue(moved, "explicit manual move must be accepted")

        await WiltedMacHeadless.eventually("queue reorder settles") {
            rig.model.playbackOperationStatus == nil && rig.model.podcastQueueIDs.first == thirdID
        }

        // Guard actual manual move path was reached
        XCTAssertEqual(rig.model.podcastQueueIDs, [thirdID, firstID, secondID])

        // Verify explicit manual move switches larderSort to .custom and persists it
        XCTAssertEqual(rig.model.larderSort, .custom, "explicit manual move must switch sort to .custom")
        XCTAssertEqual(
            rig.preferences.string(forKey: WiltedMacModel.larderSortPreferenceKey),
            WiltedMacLarderSort.custom.canonical.rawValue,
            "explicit manual move must persist .custom to preferences"
        )
    }
}
