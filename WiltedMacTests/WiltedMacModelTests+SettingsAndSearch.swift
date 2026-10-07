import CryptoKit
import Foundation
import XCTest
import WiltedDomain
import WiltedProducer
@testable import WiltedMac

extension WiltedMacModelTests {
    // MARK: Settings overrides (Task 0.6)

    func testLarderOverridesAreOffByDefaultAndSurviveARebuild() {
        let suite = WiltedMacTestPreferences.suiteName("larder-overrides-tests")
        guard let preferences = UserDefaults(suiteName: suite) else {
            return XCTFail("Unable to open a preferences suite for the test")
        }
        preferences.removePersistentDomain(forName: suite)
        defer { preferences.removePersistentDomain(forName: suite) }

        let first = WiltedMacModel(arguments: [], preferences: preferences)
        XCTAssertFalse(first.automationSettings.downloadEverythingOnLarder)
        XCTAssertFalse(first.automationSettings.prepareEverythingDownloaded)

        first.updateAutomationSettings { settings in
            WiltedAutomationSettings(
                refreshPolicy: settings.refreshPolicy, downloadPolicy: settings.downloadPolicy,
                processingPolicy: settings.processingPolicy, transcriptPolicy: settings.transcriptPolicy,
                removeAds: settings.removeAds, autoAddPreparedToLarder: settings.autoAddPreparedToLarder,
                downloadEverythingOnLarder: true, prepareEverythingDownloaded: true
            )
        }

        let rebuilt = WiltedMacModel(arguments: [], preferences: preferences)
        XCTAssertTrue(rebuilt.automationSettings.downloadEverythingOnLarder,
                      "the download override must survive a model rebuild")
        XCTAssertTrue(rebuilt.automationSettings.prepareEverythingDownloaded,
                      "the prepare override must survive a model rebuild")
    }

    /// Turning an override on takes the same bulk step the Larder's matching
    /// group action takes; the override is not a second enqueue path.
    func testLarderOverridesReuseTheLarderBulkAdmissionFunctions() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let source = try WiltedMacSource.model(root: root)
        let start = try XCTUnwrap(source.range(of: "func setAutomationSettings"))
        let end = try XCTUnwrap(source.range(of: "func updateAutomationSettings",
                                             range: start.upperBound..<source.endIndex))
        let body = source[start.lowerBound..<end.lowerBound]
        XCTAssertTrue(body.contains("downloadAllAvailableLarderEpisodes()"),
                      "the download override must reuse the Larder's bulk admission")
        XCTAssertTrue(body.contains("prepareAllDownloadedLarderEpisodes()"),
                      "the prepare override must reuse the Larder's bulk admission")
    }

    /// The download override admits the whole Available group, not just later
    /// arrivals: turning it on against a Larder that already holds episodes
    /// leaves nothing available and disables the bulk action.
    func testDownloadEverythingOverrideAdmitsTheWholeAvailableGroup() async throws {
        let directory = temporaryDirectory("download-everything-override")

        let feedURL = try XCTUnwrap(URL(string: "https://feeds.example.test/download-everything.xml"))
        let feedID = try ItemID.derivePodcastFeed(from: feedURL)
        let created = Timestamp(Date(timeIntervalSince1970: 1_700_000_000))
        let downloads = try (0..<2).map { index -> (enclosure: URL, id: ItemID) in
            let enclosure = try XCTUnwrap(
                URL(string: "https://media.example.test/download-everything-\(index).mp3")
            )
            return (enclosure, try ItemID.derivePodcastEpisode(
                feedURL: feedURL, rssGUID: "override-\(index)", enclosureURL: enclosure
            ))
        }
        let enclosures = downloads.map(\.enclosure)
        let episodeIDs = downloads.map(\.id)
        let eventsByURL = Dictionary(uniqueKeysWithValues: enclosures.map { url in
            (url, [
                PodcastDownloadEvent.response(.init(
                    url: url, statusCode: 200, mediaType: "audio/mpeg", expectedByteCount: 4
                )),
                PodcastDownloadEvent.data(Data("body".utf8))
            ])
        })
        let transport = ConcurrencyTrackingPodcastDownloadTransport(eventsByURL: eventsByURL)

        let model = WiltedMacModel(
            arguments: [], stateDirectoryOverride: directory,
            storeBootstrap: { url in
                let store = try LocalLibraryStore(url: url)
                try await store.save(feed: try PodcastFeed(
                    itemID: feedID, canonicalURL: feedURL, title: "Override feed", createdAt: created
                ))
                try await store.save(subscription: PodcastSubscription(feedID: feedID, subscribedAt: created))
                for (index, id) in episodeIDs.enumerated() {
                    try await store.save(episode: try PodcastEpisode(
                        itemID: id, feedID: feedID, feedURL: feedURL, rssGUID: "override-\(index)",
                        title: "Override episode \(index)", publishedTime: created,
                        enclosureURL: enclosures[index], enclosureMediaType: "audio/mpeg", createdAt: created
                    ))
                }
                return store
            },
            podcastDownloadTransportFactory: { transport },
            podcastMediaValidatorFactory: { StubPodcastMediaValidator(duration: 12) },
            preferences: WiltedMacTestPreferences.ephemeral()
        )
        model.startStoreBootstrap()
        await model.waitForStoreBootstrap()

        let episodes = episodeIDs.compactMap { id in
            model.episodes.first(where: { $0.id == id.rawValue })
        }
        XCTAssertEqual(episodes.count, 2)
        for episode in episodes { model.keepEpisode(episode) }
        await waitForFeedDecisionWriters(model)
        XCTAssertEqual(model.larderDownloadableEpisodes.count, 2, "both rows are Available before the override")

        model.updateAutomationSettings { settings in
            WiltedAutomationSettings(
                refreshPolicy: settings.refreshPolicy, downloadPolicy: settings.downloadPolicy,
                processingPolicy: .manual, transcriptPolicy: settings.transcriptPolicy,
                removeAds: settings.removeAds, autoAddPreparedToLarder: settings.autoAddPreparedToLarder,
                downloadEverythingOnLarder: true, prepareEverythingDownloaded: false
            )
        }
        await model.waitForPodcastOperations()

        XCTAssertTrue(model.larderEpisodes(in: .available).isEmpty,
                      "everything available was admitted, not hidden")
        XCTAssertTrue(model.larderDownloadableEpisodes.isEmpty,
                      "the disabled bulk action has no set left")
        for id in episodeIDs {
            XCTAssertEqual(model.episodes.first { $0.id == id.rawValue }?.downloadState, .completed,
                           "admission goes through the real download path")
        }
    }

    /// The prepare override starts the whole eligible Downloaded group and
    /// leaves the other groups alone.
    func testPrepareEverythingOverridePreparesTheWholeDownloadedGroup() {
        let model = WiltedMacModel(
            arguments: ["--wilted-ui-fixture-ready"], stateDirectoryOverride: wiltedTemporaryDirectory("fixture"), preferences: WiltedMacTestPreferences.ephemeral()
        )
        let downloaded = destinationEpisode(
            "override-prepare-downloaded", download: .completed, preparation: .notPrepared
        )
        let available = destinationEpisode(
            "override-prepare-available", download: .notDownloaded, preparation: .notPrepared
        )
        for value in [downloaded, available] {
            model.installEpisodeForTesting(value)
            model.seedPodcastQueueMembershipForTesting(value)
        }

        model.updateAutomationSettings { settings in
            WiltedAutomationSettings(
                refreshPolicy: settings.refreshPolicy, downloadPolicy: settings.downloadPolicy,
                processingPolicy: settings.processingPolicy, transcriptPolicy: settings.transcriptPolicy,
                removeAds: settings.removeAds, autoAddPreparedToLarder: settings.autoAddPreparedToLarder,
                downloadEverythingOnLarder: false, prepareEverythingDownloaded: true
            )
        }

        XCTAssertEqual(model.episodes.first { $0.id == downloaded.id }?.preparationState,
                       .preparing(stage: WiltedMacModel.preparingStage),
                       "the downloaded row starts on the override")
        XCTAssertEqual(model.episodes.first { $0.id == available.id }?.preparationState, .notPrepared,
                       "an Available row is not prepared")
    }

    // MARK: Larder search (Task 0.8)

    /// A query matching an episode's show notes keeps that row on the Larder.
    func testLarderSearchKeepsTheRowWhoseShowNotesMatch() {
        let model = WiltedMacModel(arguments: [], preferences: WiltedMacTestPreferences.ephemeral())
        let matching = searchEpisode("search-matching", notes: "The winter garden survives")
        let other = searchEpisode("search-other", notes: "A different subject")
        for value in [matching, other] {
            model.installEpisodeForTesting(value)
            model.seedPodcastQueueMembershipForTesting(value)
        }

        model.librarySearchQuery = "winter garden"

        XCTAssertEqual(model.larderSearchResults.map(\.id), [matching.id])
        XCTAssertEqual(model.larderEpisodes(in: .downloaded).map(\.id), [matching.id])
    }

    /// A transcript-only match admits exactly the row the store named, and
    /// shows no row the set does not name.
    func testLarderSearchShowsTranscriptNamedRowsAndNothingElse() {
        let model = WiltedMacModel(arguments: [], preferences: WiltedMacTestPreferences.ephemeral())
        let named = searchEpisode("search-transcript-named", notes: "Nothing visible matches")
        let other = searchEpisode("search-transcript-other", notes: "Nothing visible matches")
        for value in [named, other] {
            model.installEpisodeForTesting(value)
            model.seedPodcastQueueMembershipForTesting(value)
        }
        model.librarySearchQuery = "cormorant"
        model.installTranscriptSearchMatchesForTesting([named.id])

        XCTAssertEqual(model.larderSearchResults.map(\.id), [named.id],
                       "the transcript set admits the row it names")
        XCTAssertFalse(model.larderSearchResults.contains { $0.id == other.id },
                       "the transcript set does not licence any other row")
    }

    /// A query below the floor never schedules a transcript read at all.
    func testAShortQueryNeverSchedulesATranscriptRead() async throws {
        let directory = temporaryDirectory("short-query")

        let model = WiltedMacModel(
            arguments: [], stateDirectoryOverride: directory,
            storeBootstrap: { url in try LocalLibraryStore(url: url) },
            preferences: WiltedMacTestPreferences.ephemeral()
        )
        model.startStoreBootstrap()
        await model.waitForStoreBootstrap()

        model.librarySearchQuery = "co"
        XCTAssertFalse(model.isSearchingTranscripts)
        XCTAssertTrue(model.transcriptSearchMatches.isEmpty)
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertFalse(model.isSearchingTranscripts,
                       "a two-character query must not reach the store")
        XCTAssertTrue(model.transcriptSearchMatches.isEmpty)
    }

    /// Clearing the field returns every row even when a transcript answer is
    /// still held from the previous query.
    func testAnEmptyQueryReturnsEveryRowDespiteAStaleTranscriptSet() {
        let model = WiltedMacModel(arguments: [], preferences: WiltedMacTestPreferences.ephemeral())
        let first = searchEpisode("search-clear-first", notes: "One")
        let second = searchEpisode("search-clear-second", notes: "Two")
        for value in [first, second] {
            model.installEpisodeForTesting(value)
            model.seedPodcastQueueMembershipForTesting(value)
        }
        model.librarySearchQuery = "cormorant"
        model.installTranscriptSearchMatchesForTesting([first.id])
        XCTAssertEqual(model.larderSearchResults.map(\.id), [first.id])

        model.librarySearchQuery = ""
        XCTAssertFalse(model.isSearchingLarder)
        XCTAssertEqual(Set(model.larderSearchResults.map(\.id)), Set([first.id, second.id]))
    }

    /// While a search is active every group's bulk action is disabled, and
    /// the control says why; with the field clear the sets are non-empty.
    func testSearchDisablesEveryLarderBulkAction() throws {
        let model = WiltedMacModel(arguments: [], preferences: WiltedMacTestPreferences.ephemeral())
        let available = destinationEpisode(
            "search-bulk-available", download: .notDownloaded, preparation: .notPrepared
        )
        let downloaded = destinationEpisode(
            "search-bulk-downloaded", download: .completed, preparation: .notPrepared
        )
        for value in [available, downloaded] {
            model.installEpisodeForTesting(value)
            model.seedPodcastQueueMembershipForTesting(value)
        }

        XCTAssertFalse(model.isSearchingLarder)
        XCTAssertFalse(model.larderDownloadableEpisodes.isEmpty,
                       "the Available bulk action has work with a clear field")
        XCTAssertFalse(model.larderPreparableEpisodes.isEmpty,
                       "the Prepare bulk action has work with a clear field")

        model.librarySearchQuery = "nothing matches this"
        XCTAssertTrue(model.isSearchingLarder)

        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let view = try WiltedMacSource.views(root: root)
        XCTAssertTrue(view.contains("wilted-larder-search-suppresses-bulk"),
                      "the disabled control must say a search is active")
        // Every Download-all and Prepare-all control goes through `bulkAction`,
        // and that one helper is what a search disables.
        let helper = try XCTUnwrap(view.range(of: "private func bulkAction("))
        let helperEnd = try XCTUnwrap(view.range(
            of: "private func ", range: helper.upperBound..<view.endIndex
        )?.lowerBound)
        XCTAssertTrue(view[helper.lowerBound..<helperEnd].contains(".disabled(model.isSearchingLarder)"),
                      "every bulk action must be disabled by an active search")
        for title in ["Button(\"Download all", "Button(\"Prepare all"] {
            XCTAssertFalse(view.contains(title), "\(title) must go through bulkAction")
        }
        XCTAssertTrue(view.contains("|| model.isSearchingLarder)"),
                      "Play the first is a bulk action too")
        XCTAssertTrue(view.contains(".disabled(model.isSearchingLarder)"),
                      "the group clear is a bulk action too")
        XCTAssertTrue(view.contains(".searchable(text: $model.librarySearchQuery,"),
                      "the Larder must expose the search field")
    }

    /// The sidebar totals describe the Larder, not the current search.
    func testLarderSearchLeavesTheSidebarTotalsUnchanged() {
        let model = WiltedMacModel(arguments: [], preferences: WiltedMacTestPreferences.ephemeral())
        let ready = destinationEpisode(
            "search-sidebar-ready", download: .completed, preparation: .prepared(summary: "Ready")
        )
        let downloaded = destinationEpisode(
            "search-sidebar-downloaded", download: .completed, preparation: .notPrepared
        )
        for value in [ready, downloaded] {
            model.installEpisodeForTesting(value)
            model.seedPodcastQueueMembershipForTesting(value)
        }
        let playableTotal = model.larderGroupAudioSummary(.playable)
        let larderTotal = model.larderAudioSummary

        model.librarySearchQuery = "no episode matches this"

        XCTAssertTrue(model.larderSearchResults.isEmpty)
        XCTAssertEqual(model.larderGroupAudioSummary(.playable), playableTotal)
        XCTAssertEqual(model.larderAudioSummary, larderTotal)
        XCTAssertEqual(model.larderAudioSummary.seconds, 1200)
    }

    private func searchEpisode(_ id: String, notes: String) -> WiltedMacEpisode {
        WiltedMacEpisode(
            id: id, title: id, feedTitle: "Show", summary: "",
            notes: notes, artworkURL: nil, releasedAt: Date(timeIntervalSince1970: 1_700_000_000),
            durationSeconds: 600, playbackSeconds: 0,
            downloadState: .completed, preparationState: .notPrepared
        )
    }

}
