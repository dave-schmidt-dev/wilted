import Foundation
import XCTest
import WiltedDomain
import WiltedProducer
@testable import WiltedMac

private enum StartupTestError: Error {
    case expectedFailure
}

private actor BootstrapGate {
    private var held = false
    private var holdContinuation: CheckedContinuation<Void, Never>?
    private var observers: [CheckedContinuation<Void, Never>] = []

    func hold() async {
        held = true
        observers.forEach { $0.resume() }
        observers.removeAll()
        await withCheckedContinuation { holdContinuation = $0 }
    }

    func waitUntilHeld() async {
        if held { return }
        await withCheckedContinuation { observers.append($0) }
    }

    func release() {
        holdContinuation?.resume()
        holdContinuation = nil
    }
}

private actor FailingBootstrap {
    private(set) var attempts = 0

    func run(at url: URL) throws -> LocalLibraryStore {
        attempts += 1
        if attempts == 1 {
            let retainedDirectory = url.deletingLastPathComponent()
                .appendingPathComponent("\(url.lastPathComponent).v5-test", isDirectory: true)
            try FileManager.default.createDirectory(at: retainedDirectory, withIntermediateDirectories: true)
            try Data("retained-v5".utf8).write(to: retainedDirectory.appendingPathComponent(url.lastPathComponent))
        }
        throw StartupTestError.expectedFailure
    }
}

private actor SuccessfulBootstrap {
    private(set) var attempts = 0

    func run(at url: URL) throws -> LocalLibraryStore {
        attempts += 1
        return try LocalLibraryStore(url: url)
    }
}

@MainActor
final class WiltedMacModelTests: XCTestCase {
    func testLoadingIsObservableUntilBootstrapAndInitialRefreshComplete() async throws {
        let directory = temporaryDirectory("loading")
        defer { try? FileManager.default.removeItem(at: directory) }
        let gate = BootstrapGate()
        let articleURL = try XCTUnwrap(URL(string: "https://example.test/migrated-article"))
        let itemID = try ItemID.derive(from: articleURL)
        let article = try Article(
            itemID: itemID,
            canonicalURL: articleURL,
            title: "Migrated article",
            source: "Example",
            createdAt: Timestamp(Date())
        )
        let model = WiltedMacModel(
            arguments: [],
            stateDirectoryOverride: directory,
            storeBootstrap: { url in
                await gate.hold()
                let store = try LocalLibraryStore(url: url)
                try await store.save(article: article)
                return store
            }, preferences: WiltedMacTestPreferences.ephemeral()
        )

        XCTAssertEqual(model.startupState, .loading(attempt: 0))
        XCTAssertTrue(model.articles.isEmpty)
        model.startStoreBootstrap()
        await gate.waitUntilHeld()
        XCTAssertEqual(model.startupState, .loading(attempt: 1))

        await gate.release()
        await model.waitForStoreBootstrap()

        XCTAssertEqual(model.startupState, .ready)
        XCTAssertEqual(model.articles.map(\.title), ["Migrated article"])
    }

    func testFailureExposesRetainedV5ArtifactAndInjectedRecoveryAction() async throws {
        let directory = temporaryDirectory("failure")
        defer { try? FileManager.default.removeItem(at: directory) }
        let bootstrap = FailingBootstrap()
        var presentedURL: URL?
        let model = WiltedMacModel(
            arguments: [],
            stateDirectoryOverride: directory,
            storeBootstrap: { url in try await bootstrap.run(at: url) },
            retainedArtifactPresenter: { presentedURL = $0 }, preferences: WiltedMacTestPreferences.ephemeral()
        )

        model.startStoreBootstrap()
        await model.waitForStoreBootstrap()

        guard case let .failed(failure) = model.startupState else {
            return XCTFail("A failed store bootstrap must not look like a ready empty larder")
        }
        let retainedURL = try XCTUnwrap(failure.retainedV5StoreURL)
        XCTAssertTrue(failure.detail?.contains("expectedFailure") == true)
        XCTAssertEqual(retainedURL.lastPathComponent, "library.sqlite")
        XCTAssertTrue(retainedURL.path.contains("library.sqlite.v5-test"))
        XCTAssertTrue(failure.canRetry)
        XCTAssertTrue(model.articles.isEmpty)

        model.presentRetainedV5Store()
        XCTAssertEqual(presentedURL, retainedURL)
    }

    func testRetryIsBoundedToOneRecoveryAttempt() async {
        let directory = temporaryDirectory("retry")
        defer { try? FileManager.default.removeItem(at: directory) }
        let bootstrap = FailingBootstrap()
        let model = WiltedMacModel(
            arguments: [],
            stateDirectoryOverride: directory,
            storeBootstrap: { url in try await bootstrap.run(at: url) }, preferences: WiltedMacTestPreferences.ephemeral()
        )

        model.startStoreBootstrap()
        await model.waitForStoreBootstrap()
        model.retryStoreBootstrap()
        await model.waitForStoreBootstrap()

        guard case let .failed(failure) = model.startupState else {
            return XCTFail("The second failure must remain a recovery state")
        }
        XCTAssertFalse(failure.canRetry)
        XCTAssertNil(failure.retainedV5StoreURL, "a retained copy from an earlier attempt is not this attempt's recovery artifact")
        XCTAssertTrue(failure.detail?.contains("expectedFailure") == true)
        model.retryStoreBootstrap()
        let attempts = await bootstrap.attempts
        XCTAssertEqual(attempts, 2)
    }

    func testReadyModelDoesNotBootstrapAgainWhenRootTaskReappears() async {
        let directory = temporaryDirectory("ready-terminal")
        defer { try? FileManager.default.removeItem(at: directory) }
        let bootstrap = SuccessfulBootstrap()
        let model = WiltedMacModel(
            arguments: [],
            stateDirectoryOverride: directory,
            storeBootstrap: { url in try await bootstrap.run(at: url) }, preferences: WiltedMacTestPreferences.ephemeral()
        )

        model.startStoreBootstrap()
        await model.waitForStoreBootstrap()
        XCTAssertEqual(model.startupState, .ready)

        model.startStoreBootstrap()
        await model.waitForStoreBootstrap()

        let attempts = await bootstrap.attempts
        XCTAssertEqual(attempts, 1)
        XCTAssertEqual(model.startupState, .ready)
    }

    func testFixtureModeRemainsImmediatelyUsable() {
        let directory = temporaryDirectory("fixture")
        defer { try? FileManager.default.removeItem(at: directory) }

        let model = WiltedMacModel(
            arguments: ["--wilted-ui-fixture-ready"],
            stateDirectoryOverride: directory, preferences: WiltedMacTestPreferences.ephemeral()
        )

        XCTAssertTrue(model.fixtureMode)
        XCTAssertEqual(model.startupState, .ready)
        XCTAssertEqual(model.articles.map(\.title), ["Fixture article"])
    }

    func testAudioRouteRecoveryAutomaticallyAttemptsOnceThenExposesManualRetry() async throws {
        let directory = temporaryDirectory("audio-route-recovery")
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = WiltedMacModel(
            arguments: ["--wilted-ui-fixture-ready"],
            stateDirectoryOverride: directory,
            preferences: WiltedMacTestPreferences.ephemeral()
        )
        let article = try XCTUnwrap(model.articles.first)
        model.openNowPlaying(for: article)
        try await settle(model)

        model.failNextAudioRouteRecoveryForTesting()
        model.reportAudioRouteFault("Playback is unavailable.")
        try await settle(model)

        XCTAssertTrue(model.audioRouteFault, "failed automatic recovery exposes manual retry")
        XCTAssertEqual(model.playbackError, "Audio route recovery failed.")

        model.reportAudioRouteFault("Playback is unavailable.")
        try await settle(model)
        XCTAssertTrue(model.audioRouteFault, "a repeated fault must not start another automatic retry")

        model.recoverAudioRoute()
        try await settle(model)
        XCTAssertFalse(model.audioRouteFault)
        XCTAssertNil(model.playbackError)
    }

    // MARK: - Feed management

    /// Builds a store-backed model whose library already holds `feeds`, each
    /// with one episode, so the Feeds card has something to manage.
    private func modelWithFeeds(
        _ titles: [String], directory: URL
    ) async throws -> (WiltedMacModel, [String: ItemID]) {
        var ids: [String: ItemID] = [:]
        let model = WiltedMacModel(
            arguments: [],
            stateDirectoryOverride: directory,
            storeBootstrap: { url in
                let store = try LocalLibraryStore(url: url)
                for title in titles {
                    let feedURL = URL(string: "https://feeds.example.test/\(title.lowercased()).xml")!
                    let enclosureURL = URL(string: "https://media.example.test/\(title.lowercased()).mp3")!
                    let feedID = try ItemID.derivePodcastFeed(from: feedURL)
                    let feed = try PodcastFeed(itemID: feedID, canonicalURL: feedURL, title: title,
                                               createdAt: Timestamp(Date(timeIntervalSince1970: 1_700_000_000)))
                    let episode = try PodcastEpisode(
                        itemID: ItemID.derivePodcastEpisode(feedURL: feedURL, rssGUID: title, enclosureURL: enclosureURL),
                        feedID: feedID, feedURL: feedURL, rssGUID: title, title: "\(title) episode",
                        publishedTime: Timestamp(Date(timeIntervalSince1970: 1_700_000_000)),
                        enclosureURL: enclosureURL, enclosureMediaType: "audio/mpeg",
                        createdAt: Timestamp(Date(timeIntervalSince1970: 1_700_000_000))
                    )
                    try await store.save(feed: feed)
                    try await store.save(episode: episode)
                    try await store.save(subscription: PodcastSubscription(
                        feedID: feedID, subscribedAt: Timestamp(Date(timeIntervalSince1970: 1_700_000_000))
                    ))
                }
                return store
            }, preferences: WiltedMacTestPreferences.ephemeral()
        )
        model.startStoreBootstrap()
        await model.waitForStoreBootstrap()
        for title in titles {
            let feedURL = URL(string: "https://feeds.example.test/\(title.lowercased()).xml")!
            ids[title] = try ItemID.derivePodcastFeed(from: feedURL)
        }
        return (model, ids)
    }

    /// The Feeds card was the reported gap: subscriptions existed in the store
    /// with no way to see or manage them. The model has to surface every one.
    func testEveryStoredSubscriptionAppearsInTheFeedsList() async throws {
        let directory = temporaryDirectory("feeds-list")
        defer { try? FileManager.default.removeItem(at: directory) }
        let (model, _) = try await modelWithFeeds(["Beta", "Alpha"], directory: directory)

        XCTAssertEqual(model.subscriptions.map(\.title), ["Alpha", "Beta"], "feeds list by title")
        XCTAssertEqual(model.subscriptions.map(\.episodeCount), [1, 1])
        XCTAssertTrue(model.subscriptions.allSatisfy(\.enabled))
    }

    /// Disabling a feed hides its episodes from Larder but must not discard
    /// them: re-enabling has to bring the same episodes back.
    func testDisablingAFeedHidesItsEpisodesWithoutDiscardingThem() async throws {
        let directory = temporaryDirectory("feeds-disable")
        defer { try? FileManager.default.removeItem(at: directory) }
        let (model, _) = try await modelWithFeeds(["Alpha", "Beta"], directory: directory)
        let alpha = try XCTUnwrap(model.subscriptions.first { $0.title == "Alpha" })

        model.setSubscription(alpha, enabled: false)
        try await settle(model)
        XCTAssertEqual(model.episodes.map(\.feedTitle), ["Beta"])
        XCTAssertEqual(model.subscriptions.first { $0.title == "Alpha" }?.enabled, false)
        XCTAssertEqual(model.subscriptions.first { $0.title == "Alpha" }?.episodeCount, 1,
                       "a hidden feed still keeps its episodes")

        let hidden = try XCTUnwrap(model.subscriptions.first { $0.title == "Alpha" })
        model.setSubscription(hidden, enabled: true)
        try await settle(model)
        XCTAssertEqual(model.episodes.map(\.feedTitle).sorted(), ["Alpha", "Beta"])
    }

    /// Unsubscribing removes the feed and its episodes and leaves the rest of
    /// the library alone.
    func testUnsubscribingRemovesOnlyThatFeed() async throws {
        let directory = temporaryDirectory("feeds-unsubscribe")
        defer { try? FileManager.default.removeItem(at: directory) }
        let (model, _) = try await modelWithFeeds(["Alpha", "Beta"], directory: directory)
        let alpha = try XCTUnwrap(model.subscriptions.first { $0.title == "Alpha" })

        model.unsubscribe(alpha)
        try await settle(model)
        XCTAssertEqual(model.subscriptions.map(\.title), ["Beta"])
        XCTAssertEqual(model.episodes.map(\.feedTitle), ["Beta"])
        XCTAssertEqual(model.podcastOperationMessage, "Unsubscribed from Alpha and removed 1 episode.")
    }

    /// The reported bug: episodes removed from the Larder came back. Removal
    /// was an in-memory set, so it lasted exactly as long as the process, and
    /// the store kept re-admitting the identity on every refresh.
    func testRemovingAnEpisodeOutlivesTheProcess() async throws {
        let directory = temporaryDirectory("episode-remove")
        defer { try? FileManager.default.removeItem(at: directory) }
        let (model, _) = try await modelWithFeeds(["Alpha", "Beta"], directory: directory)
        let unwanted = try XCTUnwrap(model.episodes.first { $0.feedTitle == "Alpha" })

        model.removeEpisode(unwanted)
        try await settle(model)
        XCTAssertEqual(model.episodes.map(\.feedTitle), ["Beta"])
        XCTAssertEqual(model.podcastOperationMessage, "Removed \(unwanted.title).")

        let relaunched = WiltedMacModel(
            arguments: [],
            stateDirectoryOverride: directory,
            podcastFeedClient: PodcastFeedClient(
                loader: FixedBodyLoader(body: Data()),
                now: { Date(timeIntervalSince1970: 1_700_000_000) }
            ), preferences: WiltedMacTestPreferences.ephemeral()
        )
        relaunched.startStoreBootstrap()
        await relaunched.waitForStoreBootstrap()
        try await settle(relaunched)
        XCTAssertEqual(relaunched.episodes.map(\.feedTitle), ["Beta"],
                       "a removal that only lives in memory reappears here")
    }

    /// The Undo button beside the removal message needs the removed episode's
    /// identity to restore it. `removeEpisode` must record that identity once
    /// the store confirms the dismissal, not just the optimistic hide.
    func testRemovingAnEpisodeRecordsItForUndo() async throws {
        let directory = temporaryDirectory("episode-remove-undo")
        defer { try? FileManager.default.removeItem(at: directory) }
        let (model, _) = try await modelWithFeeds(["Alpha", "Beta"], directory: directory)
        let unwanted = try XCTUnwrap(model.episodes.first { $0.feedTitle == "Alpha" })

        model.removeEpisode(unwanted)
        try await settle(model)

        XCTAssertEqual(model.undoableRemoval?.id, unwanted.id)
        XCTAssertEqual(model.podcastOperationMessage, "Removed \(unwanted.title).")
    }

    /// A second removal must replace the first's undo record: only the most
    /// recent removal is one keystroke away from being undone.
    func testASecondRemovalReplacesTheFirstsUndoRecord() async throws {
        let directory = temporaryDirectory("episode-remove-undo-replace")
        defer { try? FileManager.default.removeItem(at: directory) }
        let (model, _) = try await modelWithFeeds(["Alpha", "Beta"], directory: directory)
        let first = try XCTUnwrap(model.episodes.first { $0.feedTitle == "Alpha" })
        let second = try XCTUnwrap(model.episodes.first { $0.feedTitle == "Beta" })

        model.removeEpisode(first)
        try await settle(model)
        XCTAssertEqual(model.undoableRemoval?.id, first.id)

        model.removeEpisode(second)
        try await settle(model)
        XCTAssertEqual(model.undoableRemoval?.id, second.id,
                        "the newer removal must own the undo record, not the older one")
    }

    /// The manage actions run detached tasks, so a test has to let the
    /// MainActor drain before reading the result.
    private func settle(_ model: WiltedMacModel, iterations: Int = 40) async throws {
        for _ in 0..<iterations {
            await Task.yield()
            try await Task.sleep(nanoseconds: 5_000_000)
        }
    }

    func testStartupSurfacesHaveDistinctAccessibilityIdentifiers() {
        XCTAssertEqual(WiltedMacStartupAccessibility.loading, "wilted-mac-startup-loading")
        XCTAssertEqual(WiltedMacStartupAccessibility.recovery, "wilted-mac-startup-recovery")
        XCTAssertNotEqual(WiltedMacStartupAccessibility.loading, WiltedMacStartupAccessibility.recovery)
    }

    private func temporaryDirectory(_ suffix: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("wilted-mac-model-\(suffix)-\(UUID().uuidString)", isDirectory: true)
    }

    /// Builds one downloaded, transcript-ready podcast episode -- the
    /// minimum a row needs to qualify as "ready" for continuous playback.
    private static func addReadyEpisode(
        _ episodeID: ItemID, guid: String, feedID: ItemID, feedURL: URL, enclosureURL: URL,
        publishedAt: Date, directory: URL, store: LocalLibraryStore, created: Timestamp
    ) async throws {
        try await store.save(episode: try PodcastEpisode(
            itemID: episodeID, feedID: feedID, feedURL: feedURL, rssGUID: guid,
            title: "Episode \(guid)", publishedTime: Timestamp(publishedAt), enclosureURL: enclosureURL,
            enclosureMediaType: "audio/mpeg", createdAt: created
        ))
        let audioURL = directory.appendingPathComponent("\(guid).m4a")
        let assembled = try AudioAssembler().assemble(
            pcm: (0..<44_100).map { Float(0.2 * sin(2 * Double.pi * 220 * Double($0) / 44_100)) },
            itemID: episodeID, destinationURL: audioURL
        )
        // `AudioAssembler` derives its revision from the audio's content hash
        // alone, which is right for synthesis and wrong here: every fixture
        // episode is assembled from the same samples, so they would all land on
        // one immutable revision and the second download could not finalize.
        // A downloaded podcast revision is keyed on the episode as well, which
        // is what production stores.
        let revision = try AudioRevision(
            itemID: episodeID,
            revisionID: try RevisionID.derive(
                podcastDownloadedAudioItemID: episodeID, contentHash: assembled.revision.contentHash
            ),
            durationSeconds: assembled.revision.durationSeconds,
            byteCount: assembled.revision.byteCount,
            contentHash: assembled.revision.contentHash,
            mediaType: assembled.revision.mediaType,
            createdAt: created,
            schemaVersion: assembled.revision.schemaVersion
        )
        try await store.finalizePodcastDownload(
            revision: revision, mediaURL: audioURL,
            download: try PodcastDownload(
                episodeID: episodeID, status: .completed,
                bytesReceived: revision.byteCount, expectedByteCount: revision.byteCount,
                localURL: audioURL, contentHash: revision.contentHash, updatedAt: created
            )
        )
        try await store.save(transcript: try Transcript(
            itemID: episodeID, revisionID: revision.revisionID,
            availability: .available, text: "Line.", timing: .published,
            cues: [try TranscriptCue(startSeconds: 0, endSeconds: 0.5, text: "Line.")],
            updatedAt: created
        ))
        let requestID = WiltedMacModel.podcastRequestPrefix + episodeID.rawValue
        try await store.record(preparation: PreparationJournalEntry(
            id: requestID + "|terminal", itemID: episodeID, requestID: requestID,
            status: try PreparationStatus(
                stage: .completed, detail: "Ready · transcript synced from the feed", cancellable: false,
                terminalResult: PreparationTerminalResult(outcome: .succeeded, revisionID: revision.revisionID),
                emittedAt: created
            )
        ))
    }

    /// Adds an episode with no download at all, so it can never qualify as
    /// ready for continuous playback to pick up.
    private static func addUndownloadedEpisode(
        _ episodeID: ItemID, guid: String, feedID: ItemID, feedURL: URL, enclosureURL: URL,
        publishedAt: Date, store: LocalLibraryStore, created: Timestamp
    ) async throws {
        try await store.save(episode: try PodcastEpisode(
            itemID: episodeID, feedID: feedID, feedURL: feedURL, rssGUID: guid,
            title: "Episode \(guid)", publishedTime: Timestamp(publishedAt), enclosureURL: enclosureURL,
            enclosureMediaType: "audio/mpeg", createdAt: created
        ))
    }

    // MARK: Library preferences

    func testLibraryOrderSurvivesRelaunch() throws {
        // A fixed suite: `removePersistentDomain` empties the file but leaves
        // it, so a per-run name would litter ~/Library/Preferences.
        let suite = "com.zerodelta.wilted.mac.model-tests"
        let preferences = try XCTUnwrap(UserDefaults(suiteName: suite))
        preferences.removePersistentDomain(forName: suite)
        defer { preferences.removePersistentDomain(forName: suite) }
        let directory = temporaryDirectory("order")
        defer { try? FileManager.default.removeItem(at: directory) }

        let first = WiltedMacModel(arguments: [], stateDirectoryOverride: directory, preferences: preferences)
        XCTAssertEqual(first.libraryOrder, .newest, "a fresh install lists newest first")
        first.libraryOrder = .oldest

        let second = WiltedMacModel(arguments: [], stateDirectoryOverride: directory, preferences: preferences)
        XCTAssertEqual(second.libraryOrder, .oldest, "the choice must outlive the model that made it")

        preferences.set("Sideways", forKey: WiltedMacModel.libraryOrderPreferenceKey)
        let third = WiltedMacModel(arguments: [], stateDirectoryOverride: directory, preferences: preferences)
        XCTAssertEqual(third.libraryOrder, .newest, "an unreadable stored value falls back rather than crashing")
    }

    func testPlaybackSpeedSurvivesRelaunch() throws {
        let suite = "com.zerodelta.wilted.mac.model-tests"
        let preferences = try XCTUnwrap(UserDefaults(suiteName: suite))
        preferences.removePersistentDomain(forName: suite)
        defer { preferences.removePersistentDomain(forName: suite) }
        let directory = temporaryDirectory("speed")
        defer { try? FileManager.default.removeItem(at: directory) }

        let first = WiltedMacModel(arguments: [], stateDirectoryOverride: directory, preferences: preferences)
        XCTAssertEqual(first.playbackRate, 1.25, "a fresh install listens at 1.25×, the owner's default")
        first.setPlaybackRate(1.5)

        let second = WiltedMacModel(arguments: [], stateDirectoryOverride: directory, preferences: preferences)
        XCTAssertEqual(second.playbackRate, 1.5, "the chosen speed must outlive the model that chose it")

        preferences.set(9.0, forKey: WiltedMacModel.playbackRatePreferenceKey)
        let third = WiltedMacModel(arguments: [], stateDirectoryOverride: directory, preferences: preferences)
        XCTAssertEqual(third.playbackRate, 2, "a stored value outside the picker's range is clamped, not trusted")
    }

    func testFixtureLaunchesStartFromTheDefaultOrderAndLeaveNothingBehind() {
        let directory = temporaryDirectory("fixture-order")
        defer { try? FileManager.default.removeItem(at: directory) }

        let fixture = WiltedMacModel(arguments: ["--wilted-ui-fixture-ready"], stateDirectoryOverride: directory, preferences: WiltedMacTestPreferences.ephemeral())
        XCTAssertEqual(fixture.libraryOrder, .newest)
        fixture.libraryOrder = .oldest

        let relaunched = WiltedMacModel(arguments: ["--wilted-ui-fixture-ready"], stateDirectoryOverride: directory, preferences: WiltedMacTestPreferences.ephemeral())
        XCTAssertEqual(relaunched.libraryOrder, .newest, "a fixture launch leaves nothing behind for the next one")
    }

    // MARK: Automation settings

    private func automationSettingsPreferences() throws -> UserDefaults {
        let suite = "com.zerodelta.wilted.mac.automation-settings-tests"
        let preferences = try XCTUnwrap(UserDefaults(suiteName: suite))
        preferences.removePersistentDomain(forName: suite)
        return preferences
    }

    private func offPeakWindow() throws -> WiltedAutomationOffPeakWindow {
        let start = try XCTUnwrap(WiltedAutomationLocalTime(hour: 22, minute: 30))
        let end = try XCTUnwrap(WiltedAutomationLocalTime(hour: 6, minute: 15))
        return try XCTUnwrap(WiltedAutomationOffPeakWindow(start: start, end: end))
    }

    private func localDate(hour: Int, minute: Int = 0) throws -> Date {
        try XCTUnwrap(Calendar.current.date(from: DateComponents(
            year: 2026, month: 9, day: 6, hour: hour, minute: minute
        )))
    }

    private func automationFixture(_ suffix: String) throws -> (URL, WiltedMacModel, WiltedMacEpisode) {
        let directory = temporaryDirectory(suffix)
        let model = WiltedMacModel(
            arguments: ["--wilted-ui-fixture-ready", "--wilted-ui-fixture-podcasts"],
            stateDirectoryOverride: directory,
            preferences: WiltedMacTestPreferences.ephemeral()
        )
        return (directory, model, try XCTUnwrap(model.episodes.first))
    }

    func testAutomaticAdmissionStartsImmediatePreparation() async throws {
        let (directory, model, episode) = try automationFixture("automatic-immediate")
        defer { try? FileManager.default.removeItem(at: directory) }
        model.setAutomationSettings(WiltedAutomationSettings(
            refreshPolicy: .manual, downloadPolicy: .manual, processingPolicy: .immediate,
            transcriptPolicy: .alwaysTranscribe, removeAds: false
        ))

        model.admitAutomaticPreparation(for: episode, at: try localDate(hour: 12))

        XCTAssertTrue(model.episodes.first(where: { $0.id == episode.id })?.preparationState.isRunning == true)
        XCTAssertTrue(model.deferredAutomaticPreparations.isEmpty)
        XCTAssertTrue(model.preparationQueue.isEmpty)
        try await Task.sleep(for: .milliseconds(10))
    }

    func testAutomaticAdmissionSkipsPreparationUnderManualPolicy() throws {
        let (directory, model, episode) = try automationFixture("automatic-manual")
        defer { try? FileManager.default.removeItem(at: directory) }
        model.setAutomationSettings(WiltedAutomationSettings(
            refreshPolicy: .manual, downloadPolicy: .manual, processingPolicy: .manual,
            transcriptPolicy: .alwaysTranscribe, removeAds: false
        ))

        model.admitAutomaticPreparation(for: episode, at: try localDate(hour: 12))

        XCTAssertEqual(
            model.episodes.first(where: { $0.id == episode.id })?.preparationState,
            .notPrepared
        )
        XCTAssertTrue(model.deferredAutomaticPreparations.isEmpty)
        XCTAssertTrue(model.preparationQueue.isEmpty)
    }

    func testOffPeakAdmissionKeepsItsOriginalWindowAndSnapshotUntilEligible() async throws {
        let (directory, model, episode) = try automationFixture("automatic-off-peak")
        defer { try? FileManager.default.removeItem(at: directory) }
        let originalWindow = try offPeakWindow()
        let originalSettings = WiltedAutomationSettings(
            refreshPolicy: .manual, downloadPolicy: .manual, processingPolicy: .offPeak(originalWindow),
            transcriptPolicy: .alwaysTranscribe, removeAds: false
        )
        model.setAutomationSettings(originalSettings)

        model.admitAutomaticPreparation(for: episode, at: try localDate(hour: 12))

        let admitted = try XCTUnwrap(model.deferredAutomaticPreparations.first)
        XCTAssertEqual(admitted.episodeID, episode.id)
        XCTAssertEqual(admitted.processingPolicy, .offPeak(originalWindow))
        XCTAssertEqual(admitted.policySnapshot, PodcastPreparationPolicySnapshot(
            transcriptPolicy: .alwaysTranscribe, removeAds: false
        ))
        XCTAssertEqual(model.preparationQueue.entries.map(\.id), [episode.id])
        XCTAssertEqual(
            model.episodes.first(where: { $0.id == episode.id })?.preparationState,
            .preparing(stage: WiltedMacModel.preparationQueuedStage)
        )

        model.setAutomationSettings(WiltedAutomationSettings(
            refreshPolicy: .manual, downloadPolicy: .manual, processingPolicy: .manual,
            transcriptPolicy: .noLocalSTT, removeAds: true
        ))
        model.startEligibleAutomaticPreparations(at: try localDate(hour: 21))
        XCTAssertEqual(model.deferredAutomaticPreparations, [admitted],
                       "later settings cannot skip or rewrite the admitted job")

        model.startEligibleAutomaticPreparations(at: try localDate(hour: 23))
        XCTAssertTrue(model.deferredAutomaticPreparations.isEmpty)
        XCTAssertTrue(model.preparationQueue.isEmpty)
        XCTAssertTrue(model.episodes.first(where: { $0.id == episode.id })?.preparationState.isRunning == true)
        try await Task.sleep(for: .milliseconds(10))
    }

    /// David hit a queued episode and had to press Stop and then Prepare to run
    /// it. That workaround is worse than it looks: cancelling drops the stored
    /// policy snapshot, so the job came back under whatever Settings said at
    /// the time rather than what it was admitted with.
    func testAQueuedOffPeakJobCanBeRunWithoutCancellingIt() async throws {
        let (directory, model, episode) = try automationFixture("off-peak-prepare-now")
        defer { try? FileManager.default.removeItem(at: directory) }
        model.setAutomationSettings(WiltedAutomationSettings(
            refreshPolicy: .manual, downloadPolicy: .manual,
            processingPolicy: .offPeak(try offPeakWindow()),
            transcriptPolicy: .alwaysTranscribe, removeAds: false
        ))

        model.admitAutomaticPreparation(for: episode, at: try localDate(hour: 12))
        let admitted = try XCTUnwrap(model.deferredAutomaticPreparations.first)
        XCTAssertTrue(model.isDeferredToOffPeak(episode.id),
                      "a row waiting on the clock is the one that can be started early")

        // Changing Settings afterwards must not decide anything here: this runs
        // the admitted job, not a fresh one.
        model.setAutomationSettings(WiltedAutomationSettings(
            refreshPolicy: .manual, downloadPolicy: .manual, processingPolicy: .manual,
            transcriptPolicy: .noLocalSTT, removeAds: true
        ))
        XCTAssertEqual(model.deferredAutomaticPreparations, [admitted],
                       "the snapshot is still the admitted one when the button is pressed")

        model.prepareDeferredPreparationNow(episode.id)

        XCTAssertTrue(model.episodes.first(where: { $0.id == episode.id })?.preparationState.isRunning == true,
                      "the queued job runs instead of waiting for the window")
        XCTAssertTrue(model.deferredAutomaticPreparations.isEmpty, "and is no longer deferred")
        XCTAssertTrue(model.preparationQueue.isEmpty, "and has left the visible queue")
        XCTAssertFalse(model.isDeferredToOffPeak(episode.id))
        try await Task.sleep(for: .milliseconds(10))
    }

    /// The button is offered only for the off-peak case. A row queued behind the
    /// single-run admission gate says "Queued" too, and starting it early would
    /// run two preparations at once, which is what the gate is for.
    func testARowThatIsNotWaitingOnTheClockIsNotOfferedTheButton() throws {
        let (directory, model, episode) = try automationFixture("off-peak-not-offered")
        defer { try? FileManager.default.removeItem(at: directory) }
        XCTAssertFalse(model.isDeferredToOffPeak(episode.id),
                       "nothing is deferred before anything is admitted")

        model.prepareDeferredPreparationNow(episode.id)
        XCTAssertEqual(model.episodes.first(where: { $0.id == episode.id })?.preparationState, .notPrepared,
                       "asking to run a job that was never deferred does nothing")
    }

    /// Walkthrough frame 6.4 -- an episode started while an article is playing --
    /// has never captured successfully. This is the model half of that path,
    /// held down so a future failure can be attributed to the view or the
    /// capture harness rather than re-argued from scratch.
    func testStartingAnEpisodeWhileAnArticlePlaysSwitchesCleanly() async throws {
        let directory = temporaryDirectory("article-to-episode")
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = WiltedMacModel(
            arguments: ["--wilted-ui-fixture-playing", "--wilted-ui-fixture-podcasts"],
            stateDirectoryOverride: directory,
            preferences: WiltedMacTestPreferences.ephemeral()
        )
        model.startStoreBootstrap()
        await model.waitForStoreBootstrap()
        try await settle(model)
        XCTAssertNotNil(model.selectedArticleID, "the fixture starts with an article playing")

        let episode = try XCTUnwrap(model.episodes.first)
        model.playEpisode(episode)
        await model.waitForPlaybackOperationForTesting()
        try await settle(model)

        XCTAssertEqual(model.currentEpisode?.id, episode.id,
                       "the episode takes over, which is what puts Notes in the rail")
        XCTAssertNil(model.selectedArticleID, "and the article lets go")
        XCTAssertNil(model.playbackError)
        XCTAssertNil(model.playbackOperationStatus, "a rail left spinning never goes idle for XCUITest")
    }

    func testOnlyNoLocalSpeechToTextWithRemovalOnBlocksAdRemoval() throws {
        // The pane offers the two controls side by side, so every pair a reader
        // can reach is checked, not only the one that fails.
        for policy in [WiltedAutomationTranscriptPolicy.bestAvailable, .alwaysTranscribe, .noLocalSTT] {
            for removeAds in [true, false] {
                let settings = WiltedAutomationSettings(
                    refreshPolicy: .manual, downloadPolicy: .manual, processingPolicy: .immediate,
                    transcriptPolicy: policy, removeAds: removeAds
                )
                let blocked = policy == .noLocalSTT && removeAds
                XCTAssertEqual(settings.transcriptPolicyBlocksAdRemoval, blocked,
                               "\(policy.settingsControlLabel) with removeAds \(removeAds)")
            }
        }
    }

    func testTheBlockedAdRemovalExplanationNamesTheCauseAndBothWaysOut() throws {
        let explanation = WiltedAutomationSettings.transcriptPolicyBlocksAdRemovalExplanation

        // Naming one control would leave a reader looking at the other one
        // wondering which of them is wrong.
        XCTAssertTrue(explanation.contains("Remove ads"), explanation)
        XCTAssertTrue(explanation.contains(WiltedAutomationTranscriptPolicy.noLocalSTT.settingsControlLabel),
                      explanation)
        XCTAssertTrue(explanation.contains("no episode will prepare"), explanation)
    }

    func testABlockedConfigurationStillDecodesAndSurvivesRelaunch() throws {
        // Removal once ran from a publisher's cues, so this pair is a file that
        // legitimately exists. It is reported, not rejected: refusing to decode
        // it would lose every other preference saved beside it.
        let preferences = try automationSettingsPreferences()
        defer { preferences.removePersistentDomain(forName: "com.zerodelta.wilted.mac.automation-settings-tests") }
        let directory = temporaryDirectory("blocked-transcript-policy")
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = WiltedMacModel(arguments: [], stateDirectoryOverride: directory, preferences: preferences)
        model.setAutomationSettings(WiltedAutomationSettings(
            refreshPolicy: .manual, downloadPolicy: .manual, processingPolicy: .immediate,
            transcriptPolicy: .noLocalSTT, removeAds: true
        ))

        let relaunched = WiltedMacModel(arguments: [], stateDirectoryOverride: directory, preferences: preferences)

        XCTAssertEqual(relaunched.automationSettings.transcriptPolicy, .noLocalSTT)
        XCTAssertTrue(relaunched.automationSettings.removeAds)
        XCTAssertTrue(relaunched.automationSettings.transcriptPolicyBlocksAdRemoval)
    }

    func testPreparationPolicySnapshotMapsEveryFutureWorkerChoice() throws {
        let settings = WiltedAutomationSettings(
            refreshPolicy: .manual, downloadPolicy: .manual, processingPolicy: .offPeak(try offPeakWindow()),
            transcriptPolicy: .alwaysTranscribe, removeAds: false
        )

        let snapshot = WiltedMacModel.preparationPolicySnapshot(from: settings)

        XCTAssertEqual(snapshot.transcriptPolicy, .alwaysTranscribe)
        XCTAssertFalse(snapshot.removeAds)

        let laterSettings = WiltedAutomationSettings(
            refreshPolicy: .manual, downloadPolicy: .manual, processingPolicy: .manual,
            transcriptPolicy: .noLocalSTT, removeAds: true
        )
        XCTAssertEqual(snapshot, PodcastPreparationPolicySnapshot(
            transcriptPolicy: .alwaysTranscribe, removeAds: false
        ), "a queued job retains the snapshot captured at admission")
        XCTAssertNotEqual(snapshot, WiltedMacModel.preparationPolicySnapshot(from: laterSettings))
    }

    func testDeferredAutomaticPreparationPersistsItsAdmissionOrderWindowAndSnapshot() throws {
        let preferences = try automationSettingsPreferences()
        defer { preferences.removePersistentDomain(forName: "com.zerodelta.wilted.mac.automation-settings-tests") }
        let window = try offPeakWindow()
        let firstSnapshot = PodcastPreparationPolicySnapshot(
            transcriptPolicy: .alwaysTranscribe, removeAds: false
        )
        let secondSnapshot = PodcastPreparationPolicySnapshot(
            transcriptPolicy: .noLocalSTT, removeAds: true
        )
        let jobs = [
            WiltedMacModel.DeferredAutomaticPreparation(
                episodeID: "first", processingPolicy: .offPeak(window), policySnapshot: firstSnapshot
            ),
            WiltedMacModel.DeferredAutomaticPreparation(
                episodeID: "second", processingPolicy: .offPeak(window), policySnapshot: secondSnapshot
            )
        ]

        WiltedMacModel.persistDeferredAutomaticPreparations(jobs, to: preferences)
        let restored = WiltedMacModel.loadDeferredAutomaticPreparations(from: preferences)

        XCTAssertEqual(restored, jobs)
        XCTAssertEqual(restored.map(\.episodeID), ["first", "second"])
        XCTAssertEqual(restored.first?.policySnapshot, firstSnapshot)
        XCTAssertEqual(restored.first?.processingPolicy, .offPeak(window))
    }

    func testExplicitPreparationStartsEvenWhenAutomaticProcessingIsManual() async throws {
        let directory = temporaryDirectory("manual-preparation-policy")
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = WiltedMacModel(
            arguments: ["--wilted-ui-fixture-ready", "--wilted-ui-fixture-podcasts"],
            stateDirectoryOverride: directory,
            preferences: WiltedMacTestPreferences.ephemeral()
        )
        model.setAutomationSettings(WiltedAutomationSettings(
            refreshPolicy: .manual, downloadPolicy: .manual, processingPolicy: .manual,
            transcriptPolicy: .bestAvailable, removeAds: true
        ))
        let episode = try XCTUnwrap(model.episodes.first)

        model.prepareEpisode(episode)
        XCTAssertTrue(
            model.episodes.first(where: { $0.id == episode.id })?.preparationState.isRunning == true,
            "the explicit action bypasses the automatic-processing policy"
        )
        try await Task.sleep(for: .milliseconds(10))

        XCTAssertEqual(
            model.episodes.first(where: { $0.id == episode.id })?.preparationState,
            .failed("No preparation worker in fixture mode")
        )
    }

    /// Automation is stall-prone by construction: it refreshes feeds and pulls
    /// audio with nobody watching. Every stage it can sit in has to be readable
    /// from the model, and stopping it has to say so rather than going quiet.
    func testAutomationStatusIsObservableAndCancellationIsAnnounced() throws {
        let preferences = try automationSettingsPreferences()
        defer { preferences.removePersistentDomain(forName: "com.zerodelta.wilted.mac.automation-settings-tests") }
        let directory = temporaryDirectory("automation-status")
        defer { try? FileManager.default.removeItem(at: directory) }

        let model = WiltedMacModel(arguments: [], stateDirectoryOverride: directory, preferences: preferences)
        XCTAssertEqual(model.automationStatus, .idle)

        model.cancelAutomation()
        XCTAssertEqual(model.automationStatus, .cancelled,
                       "a stop request is a state the surface can show, not silence")
    }

    /// Automation starts from the launch path, and the shipped defaults keep it
    /// inert.
    ///
    /// Both halves matter. Without the launch wiring a persisted claim is never
    /// resumed, so "a claim survives a crash" would be true of the store and
    /// false of the product. And because the default policy is manual, a launch
    /// that reaches this point must still do nothing, which is what preserves
    /// the behaviour of every build before automation existed.
    func testLaunchStartsAutomationAndTheDefaultPolicyDoesNothing() async throws {
        let preferences = try automationSettingsPreferences()
        defer { preferences.removePersistentDomain(forName: "com.zerodelta.wilted.mac.automation-settings-tests") }
        let directory = temporaryDirectory("automation-launch")
        defer { try? FileManager.default.removeItem(at: directory) }

        let model = WiltedMacModel(arguments: [], stateDirectoryOverride: directory, preferences: preferences)
        XCTAssertEqual(model.automationSettings.refreshPolicy, .manual)
        XCTAssertEqual(model.automationSettings.downloadPolicy, .manual)

        XCTAssertEqual(model.startupState, .loading(attempt: 0))
        model.startStoreBootstrap()
        await model.waitForStoreBootstrap()
        XCTAssertEqual(model.startupState, .ready,
                       "the launch pass is started from the ready transition, so it has to be reached")
        await model.waitForAutomation()

        XCTAssertEqual(model.automationStatus, .idle,
                       "the launch pass ran and the manual policy declined it")
        XCTAssertNil(model.lastAutomationRefreshAt,
                     "a declined pass records no refresh, so an interval policy set later starts fresh")
        model.stopAutomationTicker()
    }

    /// Hiding the app checkpoints and stops the ticker. The scene has to start
    /// it again on the way back, or a window left open past the first focus dip
    /// never ticks again for the rest of the process, which is the only case the
    /// ticker exists for.
    /// Progress is written only on a transport press or a clean quit, so the
    /// periodic tick is the only thing standing between an abrupt exit and a
    /// listener sent back to wherever they last pressed a button. Unlike the
    /// automation tick it must survive the app losing focus, because audio
    /// keeps running with the window closed and that is exactly when nothing
    /// else is checkpointing.
    func testThePlaybackCheckpointTickerOutlivesFocusLoss() async throws {
        let preferences = try automationSettingsPreferences()
        defer { preferences.removePersistentDomain(forName: "com.zerodelta.wilted.mac.automation-settings-tests") }
        let directory = temporaryDirectory("playback-checkpoint-ticker")
        defer { try? FileManager.default.removeItem(at: directory) }

        let model = WiltedMacModel(arguments: [], stateDirectoryOverride: directory, preferences: preferences)
        XCTAssertFalse(model.playbackCheckpointTickerIsRunning, "nothing ticks before a store is loaded")
        model.startPlaybackCheckpointTicker()
        XCTAssertFalse(model.playbackCheckpointTickerIsRunning, "and asking early is a no-op")

        model.startStoreBootstrap()
        await model.waitForStoreBootstrap()
        await model.waitForAutomation()
        XCTAssertTrue(model.playbackCheckpointTickerIsRunning, "the ready transition starts it")

        model.startPlaybackCheckpointTicker()
        XCTAssertTrue(model.playbackCheckpointTickerIsRunning, "a repeated call is harmless")

        model.checkpointForBackground()
        XCTAssertTrue(model.playbackCheckpointTickerIsRunning,
                      "hiding the app stops the automation tick, not this one")

        // With nothing loaded the tick is a no-op rather than a write of an
        // empty position over whatever the store already holds.
        await model.checkpointPlaybackIfAdvancing()

        model.stopPlaybackCheckpointTicker()
        XCTAssertFalse(model.playbackCheckpointTickerIsRunning)
    }

    /// The unit tests run inside the app bundle, so a test that plays an
    /// episode plays it out of the machine's speakers -- which is what a gate
    /// run's unexplained tone was for days. This is the guard against it
    /// returning. Starting silent is not enough on its own: the model pushes
    /// the owner's saved volume into the backend on every load, so the check
    /// that matters is that asking for full volume changes nothing.
    func testTheTestHostNeverDrivesAudioOutput() async throws {
        let preferences = try automationSettingsPreferences()
        defer { preferences.removePersistentDomain(forName: "com.zerodelta.wilted.mac.automation-settings-tests") }
        let directory = temporaryDirectory("silent-playback")
        defer { try? FileManager.default.removeItem(at: directory) }

        let model = WiltedMacModel(arguments: [], stateDirectoryOverride: directory, preferences: preferences)
        model.startStoreBootstrap()
        await model.waitForStoreBootstrap()

        XCTAssertEqual(model.playbackOutputVolumeForTesting(), 0,
                       "a backend built inside the test host starts silent")
        model.setPlaybackVolume(1)
        XCTAssertEqual(model.playbackOutputVolumeForTesting(), 0,
                       "and the owner's saved volume does not bring the sound back")
    }

    func testTheOpenWindowTickerRestartsAfterBeingStopped() async throws {
        let preferences = try automationSettingsPreferences()
        defer { preferences.removePersistentDomain(forName: "com.zerodelta.wilted.mac.automation-settings-tests") }
        let directory = temporaryDirectory("automation-ticker-restart")
        defer { try? FileManager.default.removeItem(at: directory) }

        let model = WiltedMacModel(arguments: [], stateDirectoryOverride: directory, preferences: preferences)
        XCTAssertFalse(model.automationTickerIsRunning, "nothing ticks before a store is loaded")
        model.startAutomationTicker()
        XCTAssertFalse(model.automationTickerIsRunning,
                       "and asking early is a no-op rather than a ticker with nothing to read")

        model.startStoreBootstrap()
        await model.waitForStoreBootstrap()
        await model.waitForAutomation()
        XCTAssertTrue(model.automationTickerIsRunning, "the ready transition starts it")

        model.startAutomationTicker()
        XCTAssertTrue(model.automationTickerIsRunning, "a repeated scene callback is harmless")

        model.checkpointForBackground()
        XCTAssertFalse(model.automationTickerIsRunning, "hiding the app stops it")

        model.startAutomationTicker()
        XCTAssertTrue(model.automationTickerIsRunning, "and coming back starts it again")
        model.stopAutomationTicker()
    }

    /// Hiding the window, minimising it, or closing the last one must not stop
    /// the audio. It did: the scene-phase handler called a method that paused,
    /// because one call was serving both "not frontmost" and "quitting". David
    /// found it with Cmd-H during Mac owner acceptance.
    ///
    /// The assertion has to defeat the fire-and-forget task the checkpoint runs
    /// in. Calling the method and reading the flag immediately passes against
    /// the *old* code too, because the pause has not landed yet.
    func testHidingTheWindowCheckpointsWithoutStoppingTheAudio() async throws {
        let model = try await playingModel("background-keeps-playing")
        let before = try XCTUnwrap(model.playbackCheckpointStateForTesting())
        XCTAssertTrue(before.isPlaying, "the fixture has to be playing for this to prove anything")

        model.checkpointForBackground()
        await model.waitForPlaybackOperationForTesting()
        try await settle(model)

        let after = try XCTUnwrap(model.playbackCheckpointStateForTesting())
        XCTAssertTrue(after.isPlaying, "hiding the app must not stop the episode")
        XCTAssertGreaterThan(after.sequence, before.sequence,
                             "and it still has to write the playhead down")
        model.togglePlayback()
    }

    /// The other half of the split. Termination is the one moment stopping is
    /// right: a Now Playing entry that still claims to be playing outlives the
    /// process, which is the failure `WiltedMacApp.init` records against test
    /// runs that left the machine's media keys pointed at a dead process.
    func testQuittingStopsTheAudioAndCheckpoints() async throws {
        let model = try await playingModel("quit-stops-playing")
        let before = try XCTUnwrap(model.playbackCheckpointStateForTesting())
        XCTAssertTrue(before.isPlaying)

        model.pauseForQuit()
        await model.waitForPlaybackOperationForTesting()
        try await settle(model)

        let after = try XCTUnwrap(model.playbackCheckpointStateForTesting())
        XCTAssertFalse(after.isPlaying, "quitting stops the audio")
        XCTAssertGreaterThan(after.sequence, before.sequence, "and writes the playhead down")
    }

    /// A bootstrapped model with one ready episode already playing.
    private func playingModel(_ name: String) async throws -> WiltedMacModel {
        let directory = temporaryDirectory(name)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let feedURL = try XCTUnwrap(URL(string: "https://example.test/\(name).xml"))
        let enclosureURL = try XCTUnwrap(URL(string: "https://example.test/\(name).mp3"))
        let feedID = try ItemID.derivePodcastFeed(from: feedURL)
        let episodeID = try ItemID.derivePodcastEpisode(
            feedURL: feedURL, rssGUID: "\(name)-1", enclosureURL: enclosureURL
        )
        let created = Timestamp(Date(timeIntervalSince1970: 1_700_000_000))

        let model = WiltedMacModel(
            arguments: [], stateDirectoryOverride: directory,
            storeBootstrap: { url in
                let store = try LocalLibraryStore(url: url)
                try await store.save(feed: try PodcastFeed(
                    itemID: feedID, canonicalURL: feedURL, title: "Lifecycle", createdAt: created
                ))
                try await store.save(subscription: PodcastSubscription(feedID: feedID, subscribedAt: created))
                try await Self.addReadyEpisode(
                    episodeID, guid: "\(name)-1", feedID: feedID, feedURL: feedURL,
                    enclosureURL: enclosureURL, publishedAt: created.date,
                    directory: directory, store: store, created: created
                )
                return store
            }, preferences: WiltedMacTestPreferences.ephemeral()
        )
        model.startStoreBootstrap()
        await model.waitForStoreBootstrap()

        let episode = try XCTUnwrap(model.episodes.first)
        model.playEpisode(episode)
        try await settle(model)
        return model
    }

    /// The scheduling timestamp is the only thing standing between an interval
    /// policy and repeating its work on every tick, so it has to outlive the
    /// process. It lives in preferences rather than the store because losing it
    /// costs one extra idempotent refresh; claims, which cannot be
    /// reconstructed, live in the store.
    func testTheLastAutomaticRefreshTimeSurvivesRelaunch() throws {
        let preferences = try automationSettingsPreferences()
        defer { preferences.removePersistentDomain(forName: "com.zerodelta.wilted.mac.automation-settings-tests") }
        let directory = temporaryDirectory("automation-last-refresh")
        defer { try? FileManager.default.removeItem(at: directory) }

        let model = WiltedMacModel(arguments: [], stateDirectoryOverride: directory, preferences: preferences)
        XCTAssertNil(model.lastAutomationRefreshAt, "a first launch has nothing to space itself from")

        let refreshedAt = Date(timeIntervalSince1970: 1_700_000_000)
        preferences.set(refreshedAt, forKey: WiltedMacModel.lastAutomationRefreshPreferenceKey)
        let relaunched = WiltedMacModel(arguments: [], stateDirectoryOverride: directory, preferences: preferences)
        XCTAssertEqual(relaunched.lastAutomationRefreshAt, refreshedAt)

        // An interval that has not elapsed since that time must not fire again.
        let settings = WiltedAutomationSettings(
            refreshPolicy: .whileOpen(everyHours: 12), downloadPolicy: .newestOnePerEnabledFeed,
            processingPolicy: .immediate, transcriptPolicy: .bestAvailable,
            removeAds: true
        )
        let tooSoon = WiltedAutomationCoordinator.plan(
            settings: settings, trigger: .openWindowTick,
            lastRefreshSuccess: relaunched.lastAutomationRefreshAt,
            now: refreshedAt.addingTimeInterval(11 * 3_600)
        )
        XCTAssertFalse(tooSoon.shouldRefresh)
    }

    func testAutomationSettingsRoundTripThroughInjectedPreferences() throws {
        let preferences = try automationSettingsPreferences()
        defer { preferences.removePersistentDomain(forName: "com.zerodelta.wilted.mac.automation-settings-tests") }
        let directory = temporaryDirectory("automation-round-trip")
        defer { try? FileManager.default.removeItem(at: directory) }
        let settings = WiltedAutomationSettings(
            refreshPolicy: .whileOpen(everyHours: 12),
            downloadPolicy: .newestThreePerEnabledFeed,
            processingPolicy: .offPeak(try offPeakWindow()),
            transcriptPolicy: .alwaysTranscribe,
            removeAds: false
        )

        let model = WiltedMacModel(arguments: [], stateDirectoryOverride: directory, preferences: preferences)
        model.setAutomationSettings(settings)

        XCTAssertEqual(model.automationSettings, settings)
        XCTAssertNotNil(preferences.data(forKey: WiltedMacModel.automationSettingsPreferenceKey))
        XCTAssertEqual(WiltedAutomationDownloadPolicy.allNewlyAdmittedUpToTwenty.maximumEpisodesPerRefresh, 20)
    }

    func testLegacyReadableTranscriptSettingDecodesButIsNotReencoded() throws {
        let payload = #"{"version":1,"refreshPolicy":{"kind":"manual"},"downloadPolicy":"manual","processingPolicy":{"kind":"immediate"},"transcriptPolicy":"bestAvailable","removeAds":true,"readableTranscriptPass":false}"#

        let settings = try JSONDecoder().decode(WiltedAutomationSettings.self, from: Data(payload.utf8))
        XCTAssertEqual(settings, .defaults)

        let encoded = try JSONSerialization.jsonObject(with: JSONEncoder().encode(settings)) as? [String: Any]
        XCTAssertNil(encoded?["readableTranscriptPass"])
    }

    func testEveryAutomationControlValueMapsAndPersists() throws {
        let preferences = try automationSettingsPreferences()
        defer { preferences.removePersistentDomain(forName: "com.zerodelta.wilted.mac.automation-settings-tests") }
        let directory = temporaryDirectory("automation-control-values")
        defer { try? FileManager.default.removeItem(at: directory) }
        let window = try offPeakWindow()

        let refreshPolicies: [WiltedAutomationRefreshPolicy] = [
            .manual, .onLaunch, .whileOpen(everyHours: 6),
            .whileOpen(everyHours: 12), .whileOpen(everyHours: 24)
        ]
        let downloadPolicies: [WiltedAutomationDownloadPolicy] = [
            .manual, .newestOnePerEnabledFeed, .newestThreePerEnabledFeed, .allNewlyAdmittedUpToTwenty
        ]
        let processingPolicies: [WiltedAutomationProcessingPolicy] = [.immediate, .manual, .offPeak(window)]
        let transcriptPolicies: [WiltedAutomationTranscriptPolicy] = [.bestAvailable, .alwaysTranscribe, .noLocalSTT]

        XCTAssertEqual(Set(refreshPolicies.map(\.settingsControlLabel)).count, refreshPolicies.count)
        XCTAssertEqual(Set(downloadPolicies.map(\.settingsControlLabel)).count, downloadPolicies.count)
        XCTAssertEqual(Set(processingPolicies.map(\.settingsControlLabel)).count, processingPolicies.count)
        XCTAssertEqual(Set(transcriptPolicies.map(\.settingsControlLabel)).count, transcriptPolicies.count)
        for policy in refreshPolicies {
            XCTAssertEqual(WiltedAutomationRefreshPolicy.fromSettingsControlLabel(policy.settingsControlLabel), policy)
        }
        for policy in downloadPolicies {
            XCTAssertEqual(WiltedAutomationDownloadPolicy.fromSettingsControlLabel(policy.settingsControlLabel), policy)
        }
        for policy in processingPolicies {
            XCTAssertEqual(
                WiltedAutomationProcessingPolicy.fromSettingsControlLabel(policy.settingsControlLabel, window: window),
                policy
            )
        }
        for policy in transcriptPolicies {
            XCTAssertEqual(WiltedAutomationTranscriptPolicy.fromSettingsControlLabel(policy.settingsControlLabel), policy)
        }

        let settings = refreshPolicies.map {
            WiltedAutomationSettings(
                refreshPolicy: $0, downloadPolicy: .manual, processingPolicy: .immediate,
                transcriptPolicy: .bestAvailable, removeAds: true
            )
        } + downloadPolicies.map {
            WiltedAutomationSettings(
                refreshPolicy: .manual, downloadPolicy: $0, processingPolicy: .immediate,
                transcriptPolicy: .bestAvailable, removeAds: true
            )
        } + processingPolicies.map {
            WiltedAutomationSettings(
                refreshPolicy: .manual, downloadPolicy: .manual, processingPolicy: $0,
                transcriptPolicy: .bestAvailable, removeAds: true
            )
        } + transcriptPolicies.map {
            WiltedAutomationSettings(
                refreshPolicy: .manual, downloadPolicy: .manual, processingPolicy: .immediate,
                transcriptPolicy: $0, removeAds: true
            )
        }

        let model = WiltedMacModel(arguments: [], stateDirectoryOverride: directory, preferences: preferences)
        for candidate in settings {
            model.setAutomationSettings(candidate)
            let relaunched = WiltedMacModel(arguments: [], stateDirectoryOverride: directory, preferences: preferences)
            XCTAssertEqual(relaunched.automationSettings, candidate)
        }
    }

    func testAutomationStatusOnlyOffersStopWhileWorkCanBeInterrupted() {
        XCTAssertFalse(WiltedAutomationStatus.idle.isCancellable)
        XCTAssertFalse(WiltedAutomationStatus.failed("Network unavailable").isCancellable)
        XCTAssertFalse(WiltedAutomationStatus.cancelled.isCancellable)
        XCTAssertFalse(WiltedAutomationStatus.finished(refreshed: 2, downloaded: 1).isCancellable)
        XCTAssertTrue(WiltedAutomationStatus.refreshing(feedsRemaining: 2).isCancellable)
        XCTAssertTrue(WiltedAutomationStatus.downloading(episode: "Daily Brief", remaining: 1).isCancellable)
        XCTAssertTrue(WiltedAutomationStatus.retrying(afterSeconds: 30, attempt: 2).isCancellable)
        XCTAssertEqual(
            WiltedAutomationStatus.refreshing(feedsRemaining: 1).settingsStatusText,
            "Refreshing 1 feed"
        )
        XCTAssertEqual(WiltedAutomationStatus.failed("Network unavailable").settingsStatusText,
                       "Failed: Network unavailable")
        XCTAssertEqual(WiltedAutomationStatus.cancelled.settingsStatusText, "Stopped")
        XCTAssertEqual(WiltedAutomationStatus.finished(refreshed: 2, downloaded: 1).settingsStatusText,
                       "Finished: 2 refreshed, 1 downloaded")
    }

    func testAutomationSettingsSurviveRelaunch() throws {
        let preferences = try automationSettingsPreferences()
        defer { preferences.removePersistentDomain(forName: "com.zerodelta.wilted.mac.automation-settings-tests") }
        let directory = temporaryDirectory("automation-relaunch")
        defer { try? FileManager.default.removeItem(at: directory) }
        let settings = WiltedAutomationSettings(
            refreshPolicy: .onLaunch,
            downloadPolicy: .allNewlyAdmittedUpToTwenty,
            processingPolicy: .manual,
            transcriptPolicy: .noLocalSTT,
            removeAds: false
        )

        let first = WiltedMacModel(arguments: [], stateDirectoryOverride: directory, preferences: preferences)
        first.setAutomationSettings(settings)
        let second = WiltedMacModel(arguments: [], stateDirectoryOverride: directory, preferences: preferences)

        XCTAssertEqual(second.automationSettings, settings)
    }

    func testCorruptAutomationSettingsFallClosedToDefaults() throws {
        let preferences = try automationSettingsPreferences()
        defer { preferences.removePersistentDomain(forName: "com.zerodelta.wilted.mac.automation-settings-tests") }
        let directory = temporaryDirectory("automation-corrupt")
        defer { try? FileManager.default.removeItem(at: directory) }
        preferences.set(Data("not settings data".utf8), forKey: WiltedMacModel.automationSettingsPreferenceKey)

        let model = WiltedMacModel(arguments: [], stateDirectoryOverride: directory, preferences: preferences)

        XCTAssertEqual(model.automationSettings, .defaults)
    }

    func testInvalidAutomationSettingsValuesFallClosedToDefaults() throws {
        let preferences = try automationSettingsPreferences()
        defer { preferences.removePersistentDomain(forName: "com.zerodelta.wilted.mac.automation-settings-tests") }
        let directory = temporaryDirectory("automation-invalid")
        defer { try? FileManager.default.removeItem(at: directory) }
        preferences.set(WiltedMacLibraryOrder.oldest.rawValue, forKey: WiltedMacModel.libraryOrderPreferenceKey)
        preferences.set(1.5, forKey: WiltedMacModel.playbackRatePreferenceKey)
        let invalidPayloads = [
            #"{"version":1,"refreshPolicy":{"kind":"whileOpen","everyHours":7},"downloadPolicy":"manual","processingPolicy":{"kind":"immediate"},"transcriptPolicy":"bestAvailable","removeAds":true,"readableTranscriptPass":true}"#,
            #"{"version":1,"refreshPolicy":{"kind":"manual"},"downloadPolicy":"manual","processingPolicy":{"kind":"offPeak","window":{"start":{"hour":24,"minute":0},"end":{"hour":6,"minute":0}}},"transcriptPolicy":"bestAvailable","removeAds":true,"readableTranscriptPass":true}"#,
            #"{"version":2,"refreshPolicy":{"kind":"manual"},"downloadPolicy":"manual","processingPolicy":{"kind":"immediate"},"transcriptPolicy":"bestAvailable","removeAds":true,"readableTranscriptPass":true}"#
        ]

        XCTAssertNil(WiltedAutomationLocalTime(hour: 24, minute: 0))
        let time = try XCTUnwrap(WiltedAutomationLocalTime(hour: 6, minute: 0))
        XCTAssertNil(WiltedAutomationOffPeakWindow(start: time, end: time))
        for payload in invalidPayloads {
            preferences.set(Data(payload.utf8), forKey: WiltedMacModel.automationSettingsPreferenceKey)
            let model = WiltedMacModel(arguments: [], stateDirectoryOverride: directory, preferences: preferences)
            XCTAssertEqual(model.automationSettings, .defaults, "invalid persisted settings must fail closed")
            XCTAssertEqual(model.libraryOrder, .oldest)
            XCTAssertEqual(model.playbackRate, 1.5)
        }
    }

    func testAbsentAutomationSettingsUseCurrentDefaults() throws {
        let preferences = try automationSettingsPreferences()
        defer { preferences.removePersistentDomain(forName: "com.zerodelta.wilted.mac.automation-settings-tests") }
        let directory = temporaryDirectory("automation-absent")
        defer { try? FileManager.default.removeItem(at: directory) }

        let model = WiltedMacModel(arguments: [], stateDirectoryOverride: directory, preferences: preferences)

        XCTAssertEqual(model.automationSettings, .defaults)
        XCTAssertNil(preferences.data(forKey: WiltedMacModel.automationSettingsPreferenceKey))
    }

    func testAutomationSettingsDoNotDisturbLegacyPreferenceKeys() throws {
        let preferences = try automationSettingsPreferences()
        defer { preferences.removePersistentDomain(forName: "com.zerodelta.wilted.mac.automation-settings-tests") }
        let directory = temporaryDirectory("automation-legacy")
        defer { try? FileManager.default.removeItem(at: directory) }
        preferences.set(WiltedMacLibraryOrder.oldest.rawValue, forKey: WiltedMacModel.libraryOrderPreferenceKey)
        preferences.set(1.5, forKey: WiltedMacModel.playbackRatePreferenceKey)

        let model = WiltedMacModel(arguments: [], stateDirectoryOverride: directory, preferences: preferences)
        model.setAutomationSettings(WiltedAutomationSettings(
            refreshPolicy: .whileOpen(everyHours: 6),
            downloadPolicy: .newestOnePerEnabledFeed,
            processingPolicy: .immediate,
            transcriptPolicy: .bestAvailable,
            removeAds: true
        ))
        let relaunched = WiltedMacModel(arguments: [], stateDirectoryOverride: directory, preferences: preferences)

        XCTAssertEqual(relaunched.libraryOrder, .oldest)
        XCTAssertEqual(relaunched.playbackRate, 1.5)
        XCTAssertEqual(relaunched.automationSettings.refreshPolicy, .whileOpen(everyHours: 6))
    }

    // MARK: Show notes

    /// The row leads with what the episode is about when the feed says so,
    /// and the fixture carries notes so the pane has something to show.
    func testEpisodeRowSummaryComesFromTheNotesOpeningParagraph() throws {
        XCTAssertEqual(
            WiltedMacModel.episodeSummary(notes: "\n\n  Hosts discuss M6.  \n\nGuest: Ada", fallback: "Leo"),
            "Hosts discuss M6."
        )
        XCTAssertEqual(WiltedMacModel.episodeSummary(notes: nil, fallback: "Leo"), "Leo")
        XCTAssertEqual(WiltedMacModel.episodeSummary(notes: "   \n ", fallback: "Leo"), "Leo")
        XCTAssertEqual(
            WiltedMacModel.episodeSummary(notes: String(repeating: "x", count: 500), fallback: "Leo").count, 180
        )

        let directory = temporaryDirectory("fixture-notes")
        defer { try? FileManager.default.removeItem(at: directory) }
        let fixture = WiltedMacModel(
            arguments: ["--wilted-ui-fixture-ready", "--wilted-ui-fixture-podcasts"], stateDirectoryOverride: directory,
            preferences: WiltedMacTestPreferences.ephemeral()
        )
        let episode = try XCTUnwrap(fixture.episodes.first)
        XCTAssertEqual(episode.notes, WiltedMacModel.fixtureEpisodeNotes)
        XCTAssertEqual(episode.summary, "A walk through the machines that keep the field office quiet.")
    }

    func testNotesLinksAreClickable() {
        let notes = "Guest: Ada (https://example.com/ada) and code WILTED at example.com/quiet."
        let linked = WiltedShowNotes.linked(notes)
        let links = linked.runs.compactMap(\.link)
        XCTAssertEqual(links.map(\.absoluteString), ["https://example.com/ada", "http://example.com/quiet"])
        XCTAssertEqual(String(linked.characters), notes, "linking must not alter the words")
    }

    // MARK: Prep page

    /// After a relaunch the row must still answer "were the advertisements
    /// removed?", not just "is there a transcript?".
    func testPreparedSummaryIsRecoveredFromTheJournal() throws {
        let itemID = try ItemID(rawValue: "item-" + String(repeating: "6", count: 64))
        let revisionID = try RevisionID(rawValue: "rev-" + String(repeating: "6", count: 64))
        let requestID = WiltedMacModel.podcastRequestPrefix + itemID.rawValue
        let when = Timestamp(Date(timeIntervalSince1970: 1_700_000_000))
        let transcript = try Transcript(
            itemID: itemID, revisionID: revisionID, availability: .available, text: "Words.", timing: .aligned,
            cues: [try TranscriptCue(startSeconds: 0, endSeconds: 1, text: "Words.")], updatedAt: when
        )
        func run(terminal: String, completion: String?, terminalRevisionID: RevisionID) throws -> PreparationRunSummary {
            var entries: [PreparationJournalEntry] = []
            if let completion {
                entries.append(PreparationJournalEntry(
                    id: requestID + "|pipeline.complete", itemID: itemID, requestID: requestID,
                    status: try PreparationStatus(stage: .preparing, detail: completion, cancellable: true, emittedAt: when)
                ))
            }
            entries.append(PreparationJournalEntry(
                id: requestID + "|terminal", itemID: itemID, requestID: requestID,
                status: try PreparationStatus(
                    stage: .completed, detail: terminal, cancellable: false,
                    terminalResult: PreparationTerminalResult(outcome: .succeeded, revisionID: terminalRevisionID),
                    emittedAt: when
                )
            ))
            return PreparationRunSummary(
                requestID: requestID, itemID: itemID, startedAt: when, updatedAt: when, stage: .completed,
                detail: terminal, fraction: nil, isTerminal: true, outcome: .succeeded, failure: nil, entries: entries
            )
        }

        // A current build journals the summary itself as the terminal row.
        XCTAssertEqual(
            WiltedMacModel.preparationState(run: try run(terminal: "Ready · 5 ads removed (7:22) · transcript synced",
                                                         completion: "5 advertisements, 1307 cues",
                                                         terminalRevisionID: revisionID),
                                            readyRevisionID: revisionID, transcript: transcript),
            .prepared(summary: "Ready · 5 ads removed (7:22) · transcript synced")
        )
        // Older builds wrote "Prepared." and counted advertisements one row
        // earlier; zero there is the honest state of an episode the broken
        // detector build marked prepared.
        XCTAssertEqual(
            WiltedMacModel.preparationState(run: try run(terminal: "Prepared.", completion: "0 advertisements, 1345 cues",
                                                         terminalRevisionID: revisionID),
                                            readyRevisionID: revisionID, transcript: transcript),
            .prepared(summary: "Ready · no ads found · transcript synced")
        )
        XCTAssertEqual(
            WiltedMacModel.preparationState(run: try run(terminal: "Prepared.", completion: "3 advertisements, 900 cues",
                                                         terminalRevisionID: revisionID),
                                            readyRevisionID: revisionID, transcript: transcript),
            .prepared(summary: "Ready · 3 ads removed · transcript synced")
        )
        // Transcript timing alone cannot prove that preparation completed.
        XCTAssertEqual(WiltedMacModel.preparationState(run: nil, readyRevisionID: revisionID, transcript: transcript),
                       .notPrepared)
        XCTAssertEqual(
            WiltedMacModel.preparationState(run: try run(terminal: "Prepared.", completion: nil,
                                                         terminalRevisionID: revisionID),
                                            readyRevisionID: revisionID, transcript: transcript),
            .prepared(summary: "Ready · transcript synced")
        )
        let staleRevisionID = try RevisionID(rawValue: "rev-" + String(repeating: "8", count: 64))
        XCTAssertEqual(
            WiltedMacModel.preparationState(
                run: try run(terminal: "Ready · transcript synced", completion: nil,
                             terminalRevisionID: staleRevisionID),
                readyRevisionID: revisionID,
                transcript: transcript
            ),
            .notPrepared,
            "A successful journal for an older audio revision cannot label the current download prepared."
        )
    }

    /// A failed run is retried from Prep, next to the reason it failed.
    func testRetryFromPrepPreparesTheRunsEpisode() throws {
        let directory = temporaryDirectory("retry-run")
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = WiltedMacModel(
            arguments: ["--wilted-ui-fixture-ready", "--wilted-ui-fixture-podcasts"],
            stateDirectoryOverride: directory, preferences: WiltedMacTestPreferences.ephemeral()
        )
        let episode = try XCTUnwrap(model.episodes.first)
        XCTAssertEqual(episode.preparationState, .notPrepared)
        let failed = WiltedMacProcessorRun(
            id: WiltedMacModel.podcastRequestPrefix + episode.id, itemID: episode.id, isPodcast: true,
            title: episode.title, source: episode.feedTitle, stage: "failed",
            detail: "the model failed 30 of 50 requests", fraction: nil, outcome: .failed, updatedAt: Date()
        )
        model.retryProcessorRun(failed)
        XCTAssertTrue(model.episodes.first?.preparationState.isRunning == true, "Retry must start a run")

        let article = WiltedMacProcessorRun(
            id: "article-request", itemID: "not-an-episode", isPodcast: false, title: "Article", source: "Web",
            stage: "failed", detail: "Could not fetch", fraction: nil, outcome: .failed, updatedAt: Date()
        )
        model.retryProcessorRun(article)  // article runs have their own path; nothing to do
    }

    /// The journal stores the coarse stage every pipeline shares; the worker's
    /// own stage name survives only in the entry key, and that is what the
    /// detailed log has to show.
    func testProcessorEventsRecoverTheWorkerStageFromTheJournalKey() throws {
        let itemID = try ItemID(rawValue: "item-" + String(repeating: "8", count: 64))
        let requestID = WiltedMacModel.podcastRequestPrefix + itemID.rawValue
        let when = Date(timeIntervalSince1970: 1_700_000_000)
        func entry(_ id: String, _ stage: PreparationStage, _ detail: String, at offset: TimeInterval) throws -> PreparationJournalEntry {
            PreparationJournalEntry(
                id: id, itemID: itemID, requestID: requestID,
                status: try PreparationStatus(stage: stage, detail: detail, cancellable: true,
                                              emittedAt: Timestamp(when.addingTimeInterval(offset)))
            )
        }
        let run = PreparationRunSummary(
            requestID: requestID, itemID: itemID, startedAt: Timestamp(when), updatedAt: Timestamp(when),
            stage: .assembling, detail: "50 requests, 0 failed", fraction: nil, isTerminal: false,
            outcome: nil, failure: nil,
            entries: [
                try entry(requestID + "|transcript.stt.start#1", .extracting, "transcript.stt.start", at: 0),
                try entry(requestID + "|ads.detect.calls#2", .assembling, "50 requests, 0 failed", at: 60),
                try entry(requestID + "|log.warning.1#3", .assembling, "wilted.ads: FA is not enabled", at: 61),
                try entry("legacy-key-without-prefix", .saving, "Storing", at: 62),
            ]
        )

        let events = WiltedMacModel.processorEvents(for: run)
        XCTAssertEqual(events.map(\.stage), ["transcript.stt.start", "ads.detect.calls", "log.warning.1", "saving"])
        XCTAssertEqual(events[0].line, "transcript.stt.start", "a status with no detail is just its stage")
        XCTAssertEqual(events[1].line, "ads.detect.calls · 50 requests, 0 failed")
        XCTAssertEqual(events[2].at, when.addingTimeInterval(61))

        // A running podcast run is narrated from its latest real stage; a
        // forwarded warning is not a stage.
        XCTAssertEqual(
            WiltedMacModel.processorNarrative(isPodcast: true, outcome: .running, detail: "wilted.ads: FA is not enabled",
                                              events: Array(events.prefix(3))),
            "Finding advertisements…"
        )
        // Finished runs, and article runs, say what the journal recorded.
        XCTAssertEqual(
            WiltedMacModel.processorNarrative(isPodcast: true, outcome: .failed, detail: "the model failed 30 of 50 requests",
                                              events: events),
            "the model failed 30 of 50 requests"
        )
        XCTAssertEqual(
            WiltedMacModel.processorNarrative(isPodcast: false, outcome: .running, detail: "Extracting the article…",
                                              events: events),
            "Extracting the article…"
        )
    }

    func testProcessorRunExposesTimelineSeamsUsingThePrepDisplayContract() throws {
        let timeline = try PreparationStatus.PreparationTimeline(
            removed: [try .init(originalStartSeconds: 2_195, originalEndSeconds: 2_361,
                                label: "self-promo", confidence: 0.91)],
            kept: [try .init(originalStartSeconds: 0, originalEndSeconds: 2_195, outputStartSeconds: 0),
                   try .init(originalStartSeconds: 2_361, originalEndSeconds: 2_500, outputStartSeconds: 2_195)]
        )
        let run = WiltedMacProcessorRun(
            id: "run", itemID: "episode", isPodcast: true, title: "Episode", source: "Show", stage: "completed",
            detail: "Ready", fraction: 1, outcome: .succeeded, updatedAt: Date(), timeline: timeline
        )
        XCTAssertEqual(run.timeline, timeline)
        XCTAssertEqual(WiltedMacModel.removedSpanLine(try XCTUnwrap(timeline.removed.first), in: timeline),
                       "36:35 in prepared · original 36:35–39:21 · 2:46 self-promo")

        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("WiltedMac/WiltedMacRootView.swift")
        let source = try String(contentsOf: root)
        XCTAssertTrue(source.contains("if let timeline = run.timeline"))
        XCTAssertTrue(source.contains("wilted-processor-removed-\\(run.id)-\\(index)"))
    }

    // MARK: Preparation presentation

    func testPreparationLabelsSpeakToTheListenerNotTheWorker() {
        let cases: [(String, String)] = [
            ("transcript.published.fetch", "Fetching the published transcript…"),
            ("transcript.stt.start", "Transcribing the audio…"),
            ("transcript.glossary.progress", "Correcting names from the show notes…"),
            ("transcript.glossary.complete", "Correcting names from the show notes…"),
            ("ads.detect.start", "Finding advertisements…"),
            ("ads.cut.refused", "Advertisements left in place."),
            ("audio.publish", "Storing the prepared audio…"),
            ("pipeline.complete", "Prepared."),
        ]
        for (stage, expected) in cases {
            XCTAssertEqual(
                WiltedMacModel.preparationLabel(for: PodcastPreparationProgress(stage: stage)),
                expected, "stage \(stage)"
            )
        }
        // An unrecognised stage still says something rather than going blank.
        XCTAssertEqual(
            WiltedMacModel.preparationLabel(for: PodcastPreparationProgress(stage: "something.new")),
            "Preparing…"
        )
    }

    /// Only a successful terminal journal for the ready revision proves that
    /// an episode is prepared; transcript timing is descriptive, not proof.
    func testPreparationStateComesFromWhatTheLibraryCanProve() throws {
        let itemID = try ItemID(rawValue: "item-" + String(repeating: "7", count: 64))
        let revisionID = try RevisionID(rawValue: "rev-" + String(repeating: "7", count: 64))
        let when = Timestamp(Date(timeIntervalSince1970: 1_700_000_000))
        func transcript(_ timing: TranscriptTiming, _ availability: TranscriptAvailability = .available) throws -> Transcript {
            try Transcript(
                itemID: itemID, revisionID: revisionID, availability: availability,
                text: availability == .available ? "Words." : nil, timing: timing,
                cues: timing == .none ? nil : [try TranscriptCue(startSeconds: 0, endSeconds: 1, text: "Words.")],
                updatedAt: when
            )
        }

        XCTAssertEqual(WiltedMacModel.preparationState(run: nil, readyRevisionID: revisionID, transcript: nil), .notPrepared)
        XCTAssertEqual(WiltedMacModel.preparationState(run: nil, readyRevisionID: revisionID,
                                                       transcript: try transcript(.published)), .notPrepared)
        XCTAssertEqual(WiltedMacModel.preparationState(run: nil, readyRevisionID: revisionID,
                                                       transcript: try transcript(.aligned)), .notPrepared)
        XCTAssertEqual(WiltedMacModel.preparationState(run: nil, readyRevisionID: revisionID,
                                                       transcript: try transcript(.none)), .notPrepared)

        let failed = PreparationRunSummary(
            requestID: "podcast-prepare|" + itemID.rawValue, itemID: itemID, startedAt: when, updatedAt: when,
            stage: .failed, detail: "Wilted could not start the preparation pipeline.",
            fraction: nil, isTerminal: true, outcome: .failed, failure: nil
        )
        // The row says only that it failed; the reason and the log are on Prep.
        XCTAssertEqual(WiltedMacModel.preparationState(run: failed, readyRevisionID: revisionID, transcript: nil),
                       .failed(WiltedMacModel.preparationFailedLabel))
        XCTAssertEqual(WiltedMacModel.preparationState(run: failed, readyRevisionID: revisionID,
                                                       transcript: try transcript(.aligned)),
                       .failed(WiltedMacModel.preparationFailedLabel))

        let running = PreparationRunSummary(
            requestID: failed.requestID, itemID: itemID, startedAt: when, updatedAt: when,
            stage: .extracting, detail: "Transcribing", fraction: nil, isTerminal: false,
            outcome: nil, failure: nil
        )
        XCTAssertEqual(WiltedMacModel.preparationState(run: running, readyRevisionID: revisionID,
                                                       transcript: try transcript(.aligned)),
                       .preparing(stage: "Preparing…"))
    }

    func testEpisodePreparationStateLarderLabelsShowOnlyProvenCompletedSummary() {
        XCTAssertNil(WiltedMacEpisodePreparationState.notPrepared.larderLabel)

        let summary = "Ready · 5 ads removed (7:22) · transcript synced"
        let prepared = WiltedMacEpisodePreparationState.prepared(summary: summary)
        XCTAssertEqual(prepared.label, summary)
        XCTAssertEqual(prepared.larderLabel, summary)

        let preparing = WiltedMacEpisodePreparationState.preparing(stage: "Preparing…")
        XCTAssertEqual(preparing.label, "Preparing…")
        XCTAssertEqual(preparing.larderLabel, "Preparing…")

        let failed = WiltedMacEpisodePreparationState.failed(WiltedMacModel.preparationFailedLabel)
        XCTAssertEqual(failed.label, WiltedMacModel.preparationFailedLabel)
        XCTAssertEqual(failed.larderLabel, WiltedMacModel.preparationFailedLabel)
    }

    func testLibraryProjectionDoesNotCapPreparationEvidenceAtThePrepDisplayLimit() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(contentsOf: root.appendingPathComponent("WiltedMac/WiltedMacModel.swift"))
        XCTAssertTrue(source.contains("store.preparationRuns(limit: Int.max)"))
    }


    // MARK: Transcript synchronisation

    /// The reading position has to track the playback clock exactly, including
    /// before the first cue, across a boundary, and past the last one.
    func testCueLookupFollowsThePlaybackClock() {
        let transcript = WiltedMacTranscript(
            availability: .available, text: "one two three",
            cues: [
                WiltedMacTranscriptCue(id: 0, startSeconds: 2, endSeconds: 4, text: "one"),
                WiltedMacTranscriptCue(id: 1, startSeconds: 4, endSeconds: 6, text: "two"),
                WiltedMacTranscriptCue(id: 2, startSeconds: 6, endSeconds: 9, text: "three"),
            ],
            timingSource: "synced"
        )
        XCTAssertNil(transcript.cueIndex(at: 0), "nothing has been said yet")
        XCTAssertNil(transcript.cueIndex(at: 1.99))
        XCTAssertEqual(transcript.cueIndex(at: 2), 0)
        XCTAssertEqual(transcript.cueIndex(at: 3.9), 0)
        XCTAssertEqual(transcript.cueIndex(at: 4), 1)
        XCTAssertEqual(transcript.cueIndex(at: 8.5), 2)
        XCTAssertEqual(transcript.cueIndex(at: 500), 2, "past the end stays on the last line")
        XCTAssertTrue(transcript.isSynchronized)
        XCTAssertEqual(transcript.disclosureTitle, "Transcript · synced")
    }

    /// Cues arrive in order but may overlap, and a large episode carries
    /// thousands of them: the lookup must stay correct at both ends.
    func testCueLookupHandlesALongEpisode() {
        let cues = (0..<5_000).map {
            WiltedMacTranscriptCue(id: $0, startSeconds: Double($0) * 2,
                                   endSeconds: Double($0) * 2 + 2.5, text: "line \($0)")
        }
        let transcript = WiltedMacTranscript(availability: .available, text: "long",
                                             cues: cues, timingSource: "synced")
        XCTAssertEqual(transcript.cueIndex(at: 0), 0)
        XCTAssertEqual(transcript.cueIndex(at: 4_999), 2_499)
        XCTAssertEqual(transcript.cueIndex(at: 9_998), 4_999)
    }

    /// A plain-text transcript is still readable; it just cannot be followed.
    func testAnUntimedTranscriptIsReadableButNotSynchronized() {
        let transcript = WiltedMacTranscript(availability: .available, text: "Words with no timing.")
        XCTAssertTrue(transcript.isReadable)
        XCTAssertFalse(transcript.isSynchronized)
        XCTAssertNil(transcript.cueIndex(at: 10))
        XCTAssertEqual(transcript.disclosureTitle, "Transcript")
    }

    /// The wiring the feature actually rests on: the player is what reads a
    /// transcript, and until this landed the episode path set `.unavailable`
    /// unconditionally, so a timed transcript in the library was unreachable.
    func testPlayingAnEpisodeSurfacesItsSyncedTranscript() async throws {
        let directory = temporaryDirectory("episode-transcript")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let audioURL = directory.appendingPathComponent("episode.m4a")

        let feedURL = try XCTUnwrap(URL(string: "https://feeds.example.test/synced.xml"))
        let enclosureURL = try XCTUnwrap(URL(string: "https://media.example.test/synced.mp3"))
        let feedID = try ItemID.derivePodcastFeed(from: feedURL)
        let episodeID = try ItemID.derivePodcastEpisode(
            feedURL: feedURL, rssGUID: "synced-1", enclosureURL: enclosureURL
        )
        let created = Timestamp(Date(timeIntervalSince1970: 1_700_000_000))

        let model = WiltedMacModel(
            arguments: [],
            stateDirectoryOverride: directory,
            storeBootstrap: { url in
                let store = try LocalLibraryStore(url: url)
                try await store.save(feed: try PodcastFeed(
                    itemID: feedID, canonicalURL: feedURL, title: "Synced", createdAt: created
                ))
                try await store.save(subscription: PodcastSubscription(feedID: feedID, subscribedAt: created))
                try await store.save(episode: try PodcastEpisode(
                    itemID: episodeID, feedID: feedID, feedURL: feedURL, rssGUID: "synced-1",
                    title: "Synced episode", publishedTime: created, enclosureURL: enclosureURL,
                    enclosureMediaType: "audio/mpeg", createdAt: created
                ))
                let assembled = try AudioAssembler().assemble(
                    pcm: (0..<44_100).map { Float(0.2 * sin(2 * Double.pi * 220 * Double($0) / 44_100)) },
                    itemID: episodeID, destinationURL: audioURL
                )
                try await store.finalizePodcastDownload(
                    revision: assembled.revision, mediaURL: audioURL,
                    download: try PodcastDownload(
                        episodeID: episodeID, status: .completed,
                        bytesReceived: assembled.revision.byteCount,
                        expectedByteCount: assembled.revision.byteCount,
                        localURL: audioURL, contentHash: assembled.revision.contentHash,
                        updatedAt: created
                    )
                )
                try await store.save(transcript: try Transcript(
                    itemID: episodeID, revisionID: assembled.revision.revisionID,
                    availability: .available, text: "First line. Second line.",
                    timing: .published,
                    cues: [try TranscriptCue(startSeconds: 0, endSeconds: 0.5, text: "First line."),
                           try TranscriptCue(startSeconds: 0.5, endSeconds: 1.0, text: "Second line.")],
                    updatedAt: created
                ))
                try await store.record(preparation: PreparationJournalEntry(
                    id: "prep-synced", itemID: episodeID, requestID: "podcast-prepare|synced",
                    status: try PreparationStatus(
                        stage: .completed, detail: "ready", fraction: 1, cancellable: false,
                        terminalResult: try PreparationTerminalResult(
                            outcome: .succeeded, revisionID: assembled.revision.revisionID
                        ),
                        emittedAt: created,
                        timeline: try PreparationStatus.PreparationTimeline(
                            removed: [try .init(originalStartSeconds: 30, originalEndSeconds: 90,
                                                label: "advertisement", confidence: 0.9)],
                            kept: [try .init(originalStartSeconds: 0, originalEndSeconds: 30, outputStartSeconds: 0),
                                   try .init(originalStartSeconds: 90, originalEndSeconds: 200, outputStartSeconds: 30)]
                        )
                    )
                ))
                return store
            }, preferences: WiltedMacTestPreferences.ephemeral()
        )
        model.startStoreBootstrap()
        await model.waitForStoreBootstrap()

        let episode = try XCTUnwrap(model.episodes.first)
        model.playEpisode(episode)
        try await settle(model)
        defer { model.togglePlayback() }

        let transcript = try XCTUnwrap(model.currentTranscript)
        XCTAssertTrue(transcript.isSynchronized, "playing an episode has to surface its timed transcript")
        XCTAssertEqual(transcript.cues.map(\.text), ["First line.", "Second line."])
        XCTAssertEqual(transcript.disclosureTitle, "Transcript \u{00B7} synced from the feed")
        XCTAssertEqual(transcript.cueIndex(at: 0.6), 1)

        // What preparation cut, placed where the listener meets it: the
        // seam is on the prepared clock the cues are stamped in, and the
        // span it names is on the original clock, which is what Prep reports
        // for the same run.
        let spans = model.currentRemovedSpans
        XCTAssertEqual(spans.count, 1, "a prepared episode says what came out of it")
        XCTAssertEqual(spans.first?.preparedSeconds, 30)
        XCTAssertEqual(spans.first?.originalStartSeconds, 30)
        XCTAssertEqual(spans.first?.originalEndSeconds, 90)
        XCTAssertEqual(spans.first?.summary, "Ad removed \u{00B7} 1:00 \u{00B7} original 0:30–1:30")
    }

    /// An episode the listener is finished with early has no other way to
    /// close out: progress is written from where the audio is, so it stays at
    /// the abandoned position for good and the Larder goes on offering it.
    /// The press has to reach the durable record and retire the row, the same
    /// as playing the episode to its end does -- a control whose only effect
    /// is a scrubber jumping to the end is indistinguishable from one that
    /// did nothing.
    func testMarkingTheCurrentEpisodeCompletedRetiresItFromTheLarder() async throws {
        let directory = temporaryDirectory("episode-mark-completed")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let audioURL = directory.appendingPathComponent("episode.m4a")

        let feedURL = try XCTUnwrap(URL(string: "https://feeds.example.test/completed.xml"))
        let enclosureURL = try XCTUnwrap(URL(string: "https://media.example.test/completed.mp3"))
        let feedID = try ItemID.derivePodcastFeed(from: feedURL)
        let episodeID = try ItemID.derivePodcastEpisode(
            feedURL: feedURL, rssGUID: "completed-1", enclosureURL: enclosureURL
        )
        let created = Timestamp(Date(timeIntervalSince1970: 1_700_000_000))

        let model = WiltedMacModel(
            arguments: [],
            stateDirectoryOverride: directory,
            storeBootstrap: { url in
                let store = try LocalLibraryStore(url: url)
                try await store.save(feed: try PodcastFeed(
                    itemID: feedID, canonicalURL: feedURL, title: "Finished", createdAt: created
                ))
                try await store.save(subscription: PodcastSubscription(feedID: feedID, subscribedAt: created))
                try await store.save(episode: try PodcastEpisode(
                    itemID: episodeID, feedID: feedID, feedURL: feedURL, rssGUID: "completed-1",
                    title: "Finished episode", publishedTime: created, enclosureURL: enclosureURL,
                    enclosureMediaType: "audio/mpeg", createdAt: created
                ))
                let assembled = try AudioAssembler().assemble(
                    pcm: (0..<44_100).map { Float(0.2 * sin(2 * Double.pi * 220 * Double($0) / 44_100)) },
                    itemID: episodeID, destinationURL: audioURL
                )
                try await store.finalizePodcastDownload(
                    revision: assembled.revision, mediaURL: audioURL,
                    download: try PodcastDownload(
                        episodeID: episodeID, status: .completed,
                        bytesReceived: assembled.revision.byteCount,
                        expectedByteCount: assembled.revision.byteCount,
                        localURL: audioURL, contentHash: assembled.revision.contentHash,
                        updatedAt: created
                    )
                )
                return store
            }, preferences: WiltedMacTestPreferences.ephemeral()
        )
        model.startStoreBootstrap()
        await model.waitForStoreBootstrap()

        let episode = try XCTUnwrap(model.episodes.first)
        XCTAssertFalse(episode.isPlayed)
        model.playEpisode(episode)
        try await settle(model)
        XCTAssertFalse(model.playbackCompleted)

        model.markCurrentPlaybackCompleted()
        try await settle(model)
        XCTAssertTrue(model.playbackCompleted, "the player has to stop offering to mark what it just marked")
        XCTAssertFalse(model.isPlaying, "marking an episode finished stops the audio")

        XCTAssertLessThan(model.playbackPositionSeconds, model.playbackDurationSeconds,
                          "the playhead stays where the listener left it; only the completed flag is written")

        XCTAssertFalse(model.episodes.contains { $0.id == episodeID.rawValue },
                       "saying \"I am done with this\" retires the row, the same as playing it to the end")
        XCTAssertTrue(model.dismissedEpisodes.contains { $0.id == episodeID.rawValue },
                      "and durably, so the next feed refresh cannot put it back")
        XCTAssertEqual(model.podcastOperationMessage, "Removed \(episode.title).")
        XCTAssertTrue(model.playbackCompletionIsSettled,
                      "both halves are done, so the control has nothing left to offer")
    }

    /// Reported 2026-09-07: an episode marked completed on a build that wrote
    /// the record without retiring the row stayed in the Larder, and the
    /// control that would have retired it read "Completed" and was disabled.
    /// The record and the shelf can disagree for reasons that outlive that
    /// build -- a dismissal that fails after the completion sticks, a
    /// completion synced from iPhone that never runs this handler -- so the
    /// press has to remain available until the row is actually gone, and it
    /// has to finish the half that was skipped rather than repeat the half
    /// that was not.
    func testAnEpisodeAlreadyMarkedCompletedCanStillBeRetired() async throws {
        let directory = temporaryDirectory("episode-completed-not-retired")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let audioURL = directory.appendingPathComponent("episode.m4a")

        let feedURL = try XCTUnwrap(URL(string: "https://feeds.example.test/stranded.xml"))
        let enclosureURL = try XCTUnwrap(URL(string: "https://media.example.test/stranded.mp3"))
        let feedID = try ItemID.derivePodcastFeed(from: feedURL)
        let episodeID = try ItemID.derivePodcastEpisode(
            feedURL: feedURL, rssGUID: "stranded-1", enclosureURL: enclosureURL
        )
        let created = Timestamp(Date(timeIntervalSince1970: 1_700_000_000))

        let model = WiltedMacModel(
            arguments: [],
            stateDirectoryOverride: directory,
            storeBootstrap: { url in
                let store = try LocalLibraryStore(url: url)
                try await store.save(feed: try PodcastFeed(
                    itemID: feedID, canonicalURL: feedURL, title: "Stranded", createdAt: created
                ))
                try await store.save(subscription: PodcastSubscription(feedID: feedID, subscribedAt: created))
                try await store.save(episode: try PodcastEpisode(
                    itemID: episodeID, feedID: feedID, feedURL: feedURL, rssGUID: "stranded-1",
                    title: "Stranded episode", publishedTime: created, enclosureURL: enclosureURL,
                    enclosureMediaType: "audio/mpeg", createdAt: created
                ))
                let assembled = try AudioAssembler().assemble(
                    pcm: (0..<44_100).map { Float(0.2 * sin(2 * Double.pi * 220 * Double($0) / 44_100)) },
                    itemID: episodeID, destinationURL: audioURL
                )
                try await store.finalizePodcastDownload(
                    revision: assembled.revision, mediaURL: audioURL,
                    download: try PodcastDownload(
                        episodeID: episodeID, status: .completed,
                        bytesReceived: assembled.revision.byteCount,
                        expectedByteCount: assembled.revision.byteCount,
                        localURL: audioURL, contentHash: assembled.revision.contentHash,
                        updatedAt: created
                    )
                )
                // The state the old build left behind: finished on the record,
                // with no dismissal to take the row off the shelf.
                try await store.save(playback: try PlaybackState(
                    itemID: episodeID, revisionID: assembled.revision.revisionID,
                    sessionID: "stranded-session", sequence: 3,
                    positionSeconds: assembled.revision.durationSeconds,
                    durationSeconds: assembled.revision.durationSeconds,
                    completed: true, intent: .progress, deviceID: "stranded-device",
                    updatedAt: created
                ))
                return store
            }, preferences: WiltedMacTestPreferences.ephemeral()
        )
        model.startStoreBootstrap()
        await model.waitForStoreBootstrap()

        let episode = try XCTUnwrap(model.episodes.first)
        XCTAssertTrue(episode.isPlayed, "the record survived; only the retirement was missed")
        model.playEpisode(episode)
        try await settle(model)

        XCTAssertTrue(model.playbackCompleted, "the loaded record still says finished")
        XCTAssertFalse(model.playbackCompletionIsSettled,
                       "the row is still on the shelf, so the press still has work to do")

        model.markCurrentPlaybackCompleted()
        try await settle(model)

        XCTAssertFalse(model.episodes.contains { $0.id == episodeID.rawValue },
                       "pressing it a second time has to retire the row the first press never did")
        XCTAssertTrue(model.dismissedEpisodes.contains { $0.id == episodeID.rawValue })
        XCTAssertTrue(model.playbackCompletionIsSettled,
                      "and then stop offering, because there is nothing left to finish")
    }

    /// Placement is the whole point: a cut is meaningless unless it sits where
    /// the audio jumps. The seam is the end of the last kept interval carried
    /// onto the output clock, so the second cut of an episode has to account
    /// for everything removed ahead of it rather than reporting its original
    /// time.
    func testRemovedSpansArePlacedOnThePreparedClock() throws {
        let timeline = try PreparationStatus.PreparationTimeline(
            removed: [try .init(originalStartSeconds: 60, originalEndSeconds: 120, label: "advertisement", confidence: 0.9),
                      try .init(originalStartSeconds: 600, originalEndSeconds: 690, label: "sponsor", confidence: 0.8)],
            kept: [try .init(originalStartSeconds: 0, originalEndSeconds: 60, outputStartSeconds: 0),
                   try .init(originalStartSeconds: 120, originalEndSeconds: 600, outputStartSeconds: 60),
                   try .init(originalStartSeconds: 690, originalEndSeconds: 1_200, outputStartSeconds: 540)]
        )
        let spans = WiltedMacModel.removedSpans(in: timeline)
        XCTAssertEqual(spans.map(\.preparedSeconds), [60, 540],
                       "the second cut lands a minute earlier than its original time, because the first was removed")
        XCTAssertEqual(spans.map(\.originalStartSeconds), [60, 600])
        XCTAssertEqual(spans.map(\.summary), [
            "Ad removed \u{00B7} 1:00 \u{00B7} original 1:00–2:00",
            "Ad removed \u{00B7} 1:30 \u{00B7} original 10:00–11:30",
        ])
    }

    /// A cut that opens the episode has nothing kept ahead of it, so it sits
    /// at the very start rather than being dropped or placed by a fallback
    /// that happens to also be zero for a different reason.
    func testACutAtTheStartOfAnEpisodeSitsAtZero() throws {
        let timeline = try PreparationStatus.PreparationTimeline(
            removed: [try .init(originalStartSeconds: 0, originalEndSeconds: 30, label: "advertisement", confidence: 0.9)],
            kept: [try .init(originalStartSeconds: 30, originalEndSeconds: 600, outputStartSeconds: 0)]
        )
        XCTAssertEqual(WiltedMacModel.removedSpans(in: timeline).map(\.preparedSeconds), [0])
    }

    /// The transcript pane merges cues and cuts onto one clock. A marker
    /// belongs before the first line that starts at or after it: it describes
    /// audio the listener is about to not hear, so interrupting the line
    /// already in progress would put it a beat too late.
    func testRemovedMarkersAreMergedBeforeTheLineTheyPrecede() {
        let cues = [
            WiltedTranscriptCueLine(id: 0, startSeconds: 0, text: "Before."),
            WiltedTranscriptCueLine(id: 1, startSeconds: 60, text: "After."),
            WiltedTranscriptCueLine(id: 2, startSeconds: 90, text: "Later."),
        ]
        let markers = [
            WiltedTranscriptMarkerLine(id: 1, atSeconds: 95, text: "Ad removed"),
            WiltedTranscriptMarkerLine(id: 0, atSeconds: 60, text: "Ad removed"),
        ]
        let view = WiltedSyncedTranscriptView(cues: cues, markers: markers, activeCueID: nil,
                                              identifier: "test") { _ in }
        XCTAssertEqual(view.rows.map(\.id), ["cue-0", "marker-0", "cue-1", "cue-2", "marker-1"],
                       "markers sort into the cues by time, and one past the last line still shows")

        let withoutMarkers = WiltedSyncedTranscriptView(cues: cues, activeCueID: nil, identifier: "test") { _ in }
        XCTAssertEqual(withoutMarkers.rows.map(\.id), ["cue-0", "cue-1", "cue-2"])
    }

    /// A name is drawn where the voice changes, not on every line. An
    /// interview alternates two people for an hour, and repeating both names
    /// down the whole transcript is noise the reader reads past to find words.
    func testTheSpeakerIsLabelledOnlyWhereItChanges() {
        let cues = [
            WiltedTranscriptCueLine(id: 0, startSeconds: 0, text: "Welcome.", speaker: "Angie"),
            WiltedTranscriptCueLine(id: 1, startSeconds: 5, text: "Still me.", speaker: "Angie"),
            WiltedTranscriptCueLine(id: 2, startSeconds: 10, text: "Thanks.", speaker: "Chris"),
            WiltedTranscriptCueLine(id: 3, startSeconds: 15, text: "Back again.", speaker: "Angie"),
        ]
        let view = WiltedSyncedTranscriptView(cues: cues, activeCueID: nil,
                                              identifier: "test") { _ in }
        XCTAssertEqual(view.speakerHeadingCueIDs, [0, 2, 3],
                       "the first attributed line always says who is talking, then only changes do")
    }

    /// Publishers attribute the line that changes hands and leave the rest
    /// bare. Treating a bare line as "unknown speaker" would redraw the name
    /// on every line after it.
    func testAnUnattributedLineDoesNotEndTheSpeakersRun() {
        let cues = [
            WiltedTranscriptCueLine(id: 0, startSeconds: 0, text: "Welcome.", speaker: "Angie"),
            WiltedTranscriptCueLine(id: 1, startSeconds: 5, text: "No attribution here."),
            WiltedTranscriptCueLine(id: 2, startSeconds: 10, text: "Still Angie.", speaker: "Angie"),
        ]
        let view = WiltedSyncedTranscriptView(cues: cues, activeCueID: nil,
                                              identifier: "test") { _ in }
        XCTAssertEqual(view.speakerHeadingCueIDs, [0])
    }

    func testATranscriptThatNamesNobodyLabelsNothing() {
        let cues = [
            WiltedTranscriptCueLine(id: 0, startSeconds: 0, text: "One."),
            WiltedTranscriptCueLine(id: 1, startSeconds: 5, text: "Two."),
        ]
        let view = WiltedSyncedTranscriptView(cues: cues, activeCueID: nil,
                                              identifier: "test") { _ in }
        XCTAssertTrue(view.speakerHeadingCueIDs.isEmpty)
    }

    /// The visual heading is `accessibilityHidden` so the name is not read
    /// twice. That makes the spoken label the only place a reader using
    /// VoiceOver learns the voice changed.
    func testTheSpokenLabelCarriesTheNameExactlyWhereTheHeadingDoes() {
        let named = WiltedTranscriptCueLine(id: 0, startSeconds: 65, text: "Welcome.", speaker: "Angie")
        let view = WiltedSyncedTranscriptView(cues: [named], activeCueID: nil,
                                              identifier: "test") { _ in }
        XCTAssertEqual(view.spokenLabel(named, showsSpeaker: true), "1:05. Angie. Welcome.")
        XCTAssertEqual(view.spokenLabel(named, showsSpeaker: false), "1:05. Welcome.")
    }

    // MARK: - One add box

    /// Builds a store-backed model whose add box classifies against `document`
    /// and whose feed client is fed `feedXML` when a subscription follows.
    private func modelForPastedLink(
        directory: URL, document: String, feedXML: String = ""
    ) -> WiltedMacModel {
        WiltedMacModel(
            arguments: [],
            stateDirectoryOverride: directory,
            podcastFeedClient: PodcastFeedClient(
                loader: FixedBodyLoader(body: Data(feedXML.utf8)),
                now: { Date(timeIntervalSince1970: 1_700_000_000) }
            ),
            pastedLinkClassifier: PastedLinkClassifier(loader: FixedBodyLoader(body: Data(document.utf8))), preferences: WiltedMacTestPreferences.ephemeral()
        )
    }

    /// The reported complaint: a podcast address pasted into the article box has
    /// to reach the subscription flow, not the article pipeline. Larder no longer
    /// subscribes on its own -- it moves the address to the page that owns feeds
    /// and shows it there, so the listener sees what they are about to follow.
    func testPastingAFeedAddressHandsItToTheSubscriptionComposer() async throws {
        let directory = temporaryDirectory("pasted-feed")
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = modelForPastedLink(
            directory: directory,
            document: "<?xml version=\"1.0\"?><rss><channel><title>Pasted show</title></channel></rss>",
            feedXML: "<rss><channel><title>Pasted show</title></channel></rss>"
        )
        model.startStoreBootstrap()
        await model.waitForStoreBootstrap()

        model.urlDraft = "https://podcasts.example.test/show"
        model.addPastedLink()
        await model.waitForPodcastOperations()

        XCTAssertTrue(model.subscriptions.isEmpty, "the handoff subscribes to nothing on its own")
        XCTAssertNil(model.preparation, "a feed must never reach the article pipeline")
        XCTAssertEqual(model.selectedNavigation, .feeds, "the listener is taken to the page that owns feeds")
        XCTAssertEqual(model.podcastFeedDraft, "https://podcasts.example.test/show")
        XCTAssertEqual(model.urlDraft, "", "the address moved rather than being left in both boxes")
        XCTAssertNil(model.linkDraftStatus)

        // Confirming in the composer it landed in is what subscribes.
        model.addPodcastFeedDraft()
        await model.waitForPodcastOperations()
        XCTAssertEqual(model.subscriptions.map(\.title), ["Pasted show"])
        XCTAssertEqual(model.podcastFeedDraft, "", "a completed subscription clears the box")
    }

    /// An address ending in .xml is unmistakable, so neither box may spend a
    /// round trip to learn what it already knows. The classifier here cannot
    /// fetch anything, so a subscription proves the shortcut ran in both.
    func testAnUnmistakableFeedAddressReachesTheComposerWithoutSniffing() async throws {
        let directory = temporaryDirectory("pasted-feed-extension")
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = WiltedMacModel(
            arguments: [],
            stateDirectoryOverride: directory,
            podcastFeedClient: PodcastFeedClient(
                loader: FixedBodyLoader(body: Data("<rss><channel><title>Direct show</title></channel></rss>".utf8)),
                now: { Date(timeIntervalSince1970: 1_700_000_000) }
            ),
            pastedLinkClassifier: PastedLinkClassifier(loader: FailingLoader()), preferences: WiltedMacTestPreferences.ephemeral()
        )
        model.startStoreBootstrap()
        await model.waitForStoreBootstrap()

        model.urlDraft = "https://podcasts.example.test/show.xml"
        model.addPastedLink()
        await model.waitForPodcastOperations()

        XCTAssertEqual(model.selectedNavigation, .feeds)
        XCTAssertEqual(model.podcastFeedDraft, "https://podcasts.example.test/show.xml")
        XCTAssertTrue(model.subscriptions.isEmpty)

        model.addPodcastFeedDraft()
        await model.waitForPodcastOperations()
        XCTAssertEqual(model.subscriptions.map(\.title), ["Direct show"])
    }

    /// A page that publishes a feed is still the article that was pasted. The
    /// feed is offered, and only subscribes when the offer is accepted.
    func testAPageThatPublishesAFeedOffersItRatherThanSubscribing() async throws {
        let directory = temporaryDirectory("pasted-advertised")
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = modelForPastedLink(
            directory: directory,
            document: """
            <!doctype html><html><head>
            <link rel="alternate" type="application/rss+xml" href="https://blog.example.test/Feed.xml">
            </head><body>Words</body></html>
            """,
            feedXML: "<rss><channel><title>Blog cast</title></channel></rss>"
        )
        model.startStoreBootstrap()
        await model.waitForStoreBootstrap()

        model.urlDraft = "https://blog.example.test/posts/one"
        model.addPastedLink()
        await model.waitForPodcastOperations()

        XCTAssertEqual(model.advertisedFeed?.absoluteString, "https://blog.example.test/Feed.xml")
        XCTAssertTrue(model.subscriptions.isEmpty, "an advertised feed is an offer, not a subscription")

        model.subscribeToAdvertisedFeed()
        await model.waitForPodcastOperations()
        XCTAssertNil(model.advertisedFeed)
        XCTAssertEqual(model.subscriptions.map(\.title), ["Blog cast"])
    }

    /// The Feeds composer refuses an incomplete address before it starts any
    /// work, so a typo never reads as a network problem.
    func testTheSubscriptionComposerRefusesAnIncompleteAddressWithoutChecking() async throws {
        let directory = temporaryDirectory("composer-invalid")
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = modelForPastedLink(
            directory: directory,
            document: "<rss><channel><title>Unused</title></channel></rss>",
            feedXML: "<rss><channel><title>Unused</title></channel></rss>"
        )
        model.startStoreBootstrap()
        await model.waitForStoreBootstrap()

        model.podcastFeedDraft = "podcasts.example.test/show"
        model.addPodcastFeedDraft()

        XCTAssertFalse(model.isCheckingPodcastSubscription)
        XCTAssertEqual(
            model.podcastFeedDraftStatus,
            "Enter a complete HTTPS podcast feed or show-page address."
        )
        XCTAssertTrue(model.subscriptions.isEmpty)
    }

    /// A show page is not a feed. The composer says which feed it found and
    /// waits, because following a site's whole feed is a separate decision from
    /// the address that was pasted.
    func testTheSubscriptionComposerOffersAShowPagesFeedBeforeFollowingIt() async throws {
        let directory = temporaryDirectory("composer-advertised")
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = modelForPastedLink(
            directory: directory,
            document: """
            <!doctype html><html><head>
            <link rel="alternate" type="application/rss+xml" href="https://blog.example.test/Feed.xml">
            </head><body>Words</body></html>
            """,
            feedXML: "<rss><channel><title>Blog cast</title></channel></rss>"
        )
        model.startStoreBootstrap()
        await model.waitForStoreBootstrap()

        model.podcastFeedDraft = "https://blog.example.test/posts/one"
        model.addPodcastFeedDraft()
        await model.waitForPodcastOperations()

        XCTAssertEqual(model.advertisedFeed?.absoluteString, "https://blog.example.test/Feed.xml")
        XCTAssertTrue(model.subscriptions.isEmpty, "an advertised feed is an offer, not a subscription")
        XCTAssertEqual(
            model.podcastFeedDraftStatus,
            "This page advertises one podcast feed. Confirm before subscribing."
        )

        model.subscribeToAdvertisedFeed()
        await model.waitForPodcastOperations()
        XCTAssertNil(model.advertisedFeed)
        XCTAssertEqual(model.subscriptions.map(\.title), ["Blog cast"])
    }

    /// Subscribing to a feed already followed adds nothing, so the answer is the
    /// row that already exists rather than a second subscription or an error the
    /// listener cannot act on.
    func testSubscribingTwiceKeepsOneFeedAndPointsAtTheOneAlreadyFollowed() async throws {
        let directory = temporaryDirectory("composer-duplicate")
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = modelForPastedLink(
            directory: directory,
            document: "<rss><channel><title>Repeat show</title></channel></rss>",
            feedXML: "<rss><channel><title>Repeat show</title></channel></rss>"
        )
        model.startStoreBootstrap()
        await model.waitForStoreBootstrap()

        model.podcastFeedDraft = "https://podcasts.example.test/repeat"
        model.addPodcastFeedDraft()
        await model.waitForPodcastOperations()
        XCTAssertEqual(model.subscriptions.map(\.title), ["Repeat show"])
        XCTAssertNil(model.selectedPodcastFeedID, "a first subscription points at nothing")

        // The same feed through an equivalent spelling of its address.
        model.podcastFeedDraft = "https://Podcasts.Example.test/repeat#latest"
        model.addPodcastFeedDraft()
        await model.waitForPodcastOperations()

        XCTAssertEqual(model.subscriptions.count, 1, "one feed, however many times it is offered")
        XCTAssertEqual(model.selectedPodcastFeedID, model.subscriptions.first?.id)
        XCTAssertEqual(model.podcastOperationMessage, "Already following this podcast.")
    }

    /// A cancelled check still resumes; by then the listener may have started
    /// another. The cancelled one must write nothing, or it clears the live
    /// check's progress and replaces its answer with a stale one.
    func testACancelledSubscriptionCheckCannotWriteOverTheNextOne() async throws {
        let directory = temporaryDirectory("composer-cancel-race")
        defer { try? FileManager.default.removeItem(at: directory) }
        let pageURL = URL(string: "https://pages.example.test/plain")!
        let feedURL = URL(string: "https://podcasts.example.test/gated")!
        let gate = GatedRoutingLoader(documents: [
            pageURL: Data("<!doctype html><html><body>Just words</body></html>".utf8),
            feedURL: Data("<rss><channel><title>Gated show</title></channel></rss>".utf8),
        ])
        let model = WiltedMacModel(
            arguments: [],
            stateDirectoryOverride: directory,
            podcastFeedClient: PodcastFeedClient(
                loader: FixedBodyLoader(body: Data("<rss><channel><title>Gated show</title></channel></rss>".utf8)),
                now: { Date(timeIntervalSince1970: 1_700_000_000) }
            ),
            pastedLinkClassifier: PastedLinkClassifier(loader: gate),
            preferences: WiltedMacTestPreferences.ephemeral()
        )
        model.startStoreBootstrap()
        await model.waitForStoreBootstrap()

        model.podcastFeedDraft = pageURL.absoluteString
        model.addPodcastFeedDraft()
        XCTAssertTrue(model.isCheckingPodcastSubscription)
        XCTAssertEqual(model.podcastFeedDraftStatus, WiltedMacModel.podcastCheckInProgressStatus)

        model.cancelPodcastSubscriptionCheck()
        XCTAssertFalse(model.isCheckingPodcastSubscription)
        XCTAssertEqual(model.podcastFeedDraftStatus, WiltedMacModel.podcastCheckCancelledStatus)

        model.podcastFeedDraft = feedURL.absoluteString
        model.addPodcastFeedDraft()
        XCTAssertTrue(model.isCheckingPodcastSubscription, "the next check starts on its own terms")

        // Both classifications complete now, the cancelled one first.
        await gate.release()
        await model.waitForPodcastOperations()

        XCTAssertEqual(model.subscriptions.map(\.title), ["Gated show"])
        XCTAssertNil(model.podcastFeedDraftStatus,
                     "the cancelled check must not report on the address that replaced it")
        XCTAssertFalse(model.isCheckingPodcastSubscription)
    }

    /// A pasted address that cannot be reached is reported in the box. Guessing
    /// would send it to a pipeline that fails for a reason the reader did not
    /// cause.
    func testAnUnreachableAddressIsReportedInTheBox() async throws {
        let directory = temporaryDirectory("pasted-unreachable")
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = WiltedMacModel(
            arguments: [],
            stateDirectoryOverride: directory,
            pastedLinkClassifier: PastedLinkClassifier(loader: FailingLoader()), preferences: WiltedMacTestPreferences.ephemeral()
        )
        model.startStoreBootstrap()
        await model.waitForStoreBootstrap()

        model.urlDraft = "https://unreachable.example.test/thing"
        model.addPastedLink()
        await model.waitForPodcastOperations()

        XCTAssertEqual(
            model.linkDraftStatus,
            "Wilted could not reach that address. Check it, or retry when online."
        )
        XCTAssertTrue(model.subscriptions.isEmpty)
        XCTAssertNil(model.preparation)
    }

    func testAnIncompleteAddressIsRefusedWithoutAnyFetch() async throws {
        let directory = temporaryDirectory("pasted-invalid")
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = WiltedMacModel(
            arguments: [],
            stateDirectoryOverride: directory,
            pastedLinkClassifier: PastedLinkClassifier(loader: FailingLoader()), preferences: WiltedMacTestPreferences.ephemeral()
        )
        model.startStoreBootstrap()
        await model.waitForStoreBootstrap()

        for draft in ["", "example.com/thing", "http://example.com/thing"] {
            model.urlDraft = draft
            model.addPastedLink()
            XCTAssertEqual(model.linkDraftStatus, "Enter a complete HTTPS address.", "draft: \(draft)")
        }
    }

    /// Restore fetches the known feed first, then commits the old target and
    /// the feed's genuinely new entry while removing the durable dismissal.
    func testKnownFeedRestoreReappearsInLarderAndClearsRemovedAfterEvidence() async throws {
        let directory = temporaryDirectory("restore-known-feed")
        defer { try? FileManager.default.removeItem(at: directory) }
        let libraryURL = directory.appendingPathComponent("library.sqlite")
        let store = try LocalLibraryStore(url: libraryURL)
        let feedURL = URL(string: "https://podcasts.example.test/restore.xml")!
        let feedID = try ItemID.derivePodcastFeed(from: feedURL)
        let targetURL = URL(string: "https://cdn.example.test/old.mp3")!
        let targetID = try ItemID.derivePodcastEpisode(feedURL: feedURL, rssGUID: "old", enclosureURL: targetURL)
        let feed = try PodcastFeed(
            itemID: feedID, canonicalURL: feedURL, title: "Restore Show",
            createdAt: Timestamp(Date(timeIntervalSince1970: 1_700_000_000))
        )
        let target = try PodcastEpisode(
            itemID: targetID, feedID: feedID, feedURL: feedURL, rssGUID: "old", title: "Old episode",
            publishedTime: Timestamp(Date(timeIntervalSince1970: 1_600_000_000)),
            enclosureURL: targetURL, enclosureMediaType: "audio/mpeg",
            createdAt: Timestamp(Date(timeIntervalSince1970: 1_600_000_000))
        )
        try await store.save(feed: feed)
        try await store.save(subscription: PodcastSubscription(
            feedID: feedID, subscribedAt: Timestamp(Date(timeIntervalSince1970: 1_700_000_000))
        ))
        try await store.save(episode: target)
        try await store.record(preparation: PreparationJournalEntry(
            id: "prep-removed", itemID: targetID, requestID: WiltedMacModel.podcastRequestPrefix + targetID.rawValue,
            status: try PreparationStatus(
                stage: .assembling, detail: "Detector started", cancellable: true,
                emittedAt: Timestamp(Date(timeIntervalSince1970: 1_700_000_010))
            )
        ))
        try await store.dismissPodcastEpisode(targetID)
        let xml = """
        <rss><channel><title>Restore Show</title>
        <item><title>Old episode</title><guid>old</guid><pubDate>Sun, 13 Sep 2020 12:26:40 GMT</pubDate><enclosure url="https://cdn.example.test/old.mp3" type="audio/mpeg" /></item>
        <item><title>New episode</title><guid>new</guid><pubDate>Tue, 14 Nov 2023 22:14:20 GMT</pubDate><enclosure url="https://cdn.example.test/new.mp3" type="audio/mpeg" /></item>
        </channel></rss>
        """
        let model = WiltedMacModel(
            arguments: [], stateDirectoryOverride: directory,
            podcastFeedClient: PodcastFeedClient(
                loader: FixedBodyLoader(body: Data(xml.utf8)), now: { Date(timeIntervalSince1970: 1_700_000_100) }
            ), preferences: WiltedMacTestPreferences.ephemeral()
        )
        model.startStoreBootstrap()
        await model.waitForStoreBootstrap()

        let removed = try XCTUnwrap(model.dismissedEpisodes.first)
        XCTAssertEqual(removed.title, "Old episode")
        XCTAssertEqual(removed.feedTitle, "Restore Show")
        XCTAssertTrue(removed.hasPreparationHistory, "Removed metadata must retain the link to its Prep run")
        model.withheldPodcastEpisodeCount = 7
        model.restoreEpisode(removed)
        await model.waitForPodcastOperations()

        XCTAssertTrue(model.dismissedEpisodes.isEmpty)
        XCTAssertEqual(Set(model.episodes.map(\.title)), ["Old episode", "New episode"])
        XCTAssertEqual(model.podcastOperationMessage, "Restored Old episode to Larder.")
        XCTAssertEqual(model.withheldPodcastEpisodeCount, 7, "restore must not replace the last full-refresh summary")
        let reopened = try LocalLibraryStore(url: libraryURL)
        let persistedDismissals = try await reopened.dismissedPodcastEpisodes()
        XCTAssertTrue(persistedDismissals.isEmpty)
    }

    /// The reported bug (2026-09-05): skipping the Waveform episode, then
    /// restoring it in the same session, left the store saying "Restored X to
    /// Larder." while the row stayed off screen until relaunch. `removeEpisode`
    /// hides the row through `hiddenEpisodeIDs` immediately, ahead of the
    /// store round-trip that `restoreEpisode` waits on, and nothing cleared
    /// that id when the store confirmed the restore. The fixture above
    /// dismisses with `store.dismissPodcastEpisode` directly, which never
    /// populates the set and so never reproduces this; this one dismisses
    /// through the model, the way Skip actually does.
    func testRestoringAnEpisodeSkippedThisSessionReturnsItToTheLarder() async throws {
        let directory = temporaryDirectory("restore-same-session")
        defer { try? FileManager.default.removeItem(at: directory) }
        let libraryURL = directory.appendingPathComponent("library.sqlite")
        let store = try LocalLibraryStore(url: libraryURL)
        let feedURL = URL(string: "https://podcasts.example.test/waveform.xml")!
        let feedID = try ItemID.derivePodcastFeed(from: feedURL)
        let targetURL = URL(string: "https://cdn.example.test/waveform.mp3")!
        let targetID = try ItemID.derivePodcastEpisode(feedURL: feedURL, rssGUID: "wave", enclosureURL: targetURL)
        let feed = try PodcastFeed(
            itemID: feedID, canonicalURL: feedURL, title: "Waveform",
            createdAt: Timestamp(Date(timeIntervalSince1970: 1_700_000_000))
        )
        let target = try PodcastEpisode(
            itemID: targetID, feedID: feedID, feedURL: feedURL, rssGUID: "wave", title: "Wave episode",
            publishedTime: Timestamp(Date(timeIntervalSince1970: 1_600_000_000)),
            enclosureURL: targetURL, enclosureMediaType: "audio/mpeg",
            createdAt: Timestamp(Date(timeIntervalSince1970: 1_600_000_000))
        )
        try await store.save(feed: feed)
        try await store.save(subscription: PodcastSubscription(
            feedID: feedID, subscribedAt: Timestamp(Date(timeIntervalSince1970: 1_700_000_000))
        ))
        try await store.save(episode: target)
        let xml = """
        <rss><channel><title>Waveform</title>
        <item><title>Wave episode</title><guid>wave</guid><pubDate>Sun, 13 Sep 2020 12:26:40 GMT</pubDate><enclosure url="https://cdn.example.test/waveform.mp3" type="audio/mpeg" /></item>
        </channel></rss>
        """
        let model = WiltedMacModel(
            arguments: [], stateDirectoryOverride: directory,
            podcastFeedClient: PodcastFeedClient(
                loader: FixedBodyLoader(body: Data(xml.utf8)), now: { Date(timeIntervalSince1970: 1_700_000_100) }
            ), preferences: WiltedMacTestPreferences.ephemeral()
        )
        model.startStoreBootstrap()
        await model.waitForStoreBootstrap()

        let episode = try XCTUnwrap(model.episodes.first { $0.id == targetID.rawValue })
        XCTAssertTrue(model.libraryItems.contains { $0.id == episode.id })

        model.removeEpisode(episode)
        try await settle(model)
        XCTAssertFalse(model.libraryItems.contains { $0.id == episode.id },
                        "Skip must hide the row this session, not just once the store round-trip lands")

        let dismissal = try XCTUnwrap(model.dismissedEpisodes.first { $0.id == episode.id })
        model.restoreEpisode(dismissal)
        await model.waitForPodcastOperations()

        XCTAssertTrue(model.dismissedEpisodes.isEmpty)
        XCTAssertTrue(model.libraryItems.contains { $0.id == episode.id },
                       "Restoring a same-session dismissal must clear the in-memory hide, not just the store record")
    }

    /// The reported bug (2026-09-05): an episode that had been prepared (ads
    /// removed, transcript aligned), then skipped and restored from the
    /// Removed list, came back with no media -- Download button showing,
    /// `downloadState` `.notDownloaded` -- while still reading "Ready · 3 ads
    /// removed (4:38) · transcript synced". `dismissPodcastEpisode` deleted
    /// the episode, queue, download, speed, and artwork rows but left the
    /// revision, transcript, and playback records behind, so `loadLibrary`
    /// found the surviving revision and transcript after restore and reported
    /// the old finished cut as ready. The fix deletes those three record kinds
    /// too, while keeping the preparation journal so the Removed list can
    /// still say a preparation happened.
    func testARestoredEpisodeDoesNotPresentItsOldFinishedCutAsReady() async throws {
        let directory = temporaryDirectory("restore-clears-old-cut")
        defer { try? FileManager.default.removeItem(at: directory) }
        let libraryURL = directory.appendingPathComponent("library.sqlite")
        let store = try LocalLibraryStore(url: libraryURL)
        let feedURL = URL(string: "https://podcasts.example.test/waveform.xml")!
        let feedID = try ItemID.derivePodcastFeed(from: feedURL)
        let targetURL = URL(string: "https://cdn.example.test/waveform.mp3")!
        let targetID = try ItemID.derivePodcastEpisode(feedURL: feedURL, rssGUID: "wave", enclosureURL: targetURL)
        let feed = try PodcastFeed(
            itemID: feedID, canonicalURL: feedURL, title: "Waveform",
            createdAt: Timestamp(Date(timeIntervalSince1970: 1_700_000_000))
        )
        let target = try PodcastEpisode(
            itemID: targetID, feedID: feedID, feedURL: feedURL, rssGUID: "wave", title: "Wave episode",
            publishedTime: Timestamp(Date(timeIntervalSince1970: 1_600_000_000)),
            enclosureURL: targetURL, enclosureMediaType: "audio/mpeg",
            createdAt: Timestamp(Date(timeIntervalSince1970: 1_600_000_000))
        )
        try await store.save(feed: feed)
        try await store.save(subscription: PodcastSubscription(
            feedID: feedID, subscribedAt: Timestamp(Date(timeIntervalSince1970: 1_700_000_000))
        ))
        try await store.save(episode: target)

        let created = Timestamp(Date(timeIntervalSince1970: 1_600_000_500))
        let revision = try AudioRevision(
            itemID: targetID,
            revisionID: try RevisionID.derive(podcastDownloadedAudioItemID: targetID, contentHash: "sha256:\(String(repeating: "d", count: 64))"),
            durationSeconds: 278, byteCount: 4_096,
            contentHash: "sha256:\(String(repeating: "d", count: 64))", mediaType: "audio/mp4",
            createdAt: created, schemaVersion: 1
        )
        let mediaURL = directory.appendingPathComponent("wave.m4a")
        try await store.finalizePodcastDownload(
            revision: revision, mediaURL: mediaURL,
            download: try PodcastDownload(
                episodeID: targetID, status: .completed,
                bytesReceived: revision.byteCount, expectedByteCount: revision.byteCount,
                localURL: mediaURL, contentHash: revision.contentHash, updatedAt: created
            )
        )
        try await store.save(transcript: try Transcript(
            itemID: targetID, revisionID: revision.revisionID, availability: .available,
            text: "Aligned words.", timing: .aligned,
            cues: [try TranscriptCue(startSeconds: 0, endSeconds: 1, text: "Aligned words.")],
            updatedAt: created
        ))
        let requestID = WiltedMacModel.podcastRequestPrefix + targetID.rawValue
        try await store.record(preparation: PreparationJournalEntry(
            id: requestID + "|terminal", itemID: targetID, requestID: requestID,
            status: try PreparationStatus(
                stage: .completed, detail: "Ready · 3 ads removed (4:38) · transcript synced",
                fraction: 1, cancellable: false,
                terminalResult: try PreparationTerminalResult(outcome: .succeeded, revisionID: revision.revisionID),
                emittedAt: created
            )
        ))

        let xml = """
        <rss><channel><title>Waveform</title>
        <item><title>Wave episode</title><guid>wave</guid><pubDate>Sun, 13 Sep 2020 12:26:40 GMT</pubDate><enclosure url="https://cdn.example.test/waveform.mp3" type="audio/mpeg" /></item>
        </channel></rss>
        """
        let model = WiltedMacModel(
            arguments: [], stateDirectoryOverride: directory,
            podcastFeedClient: PodcastFeedClient(
                loader: FixedBodyLoader(body: Data(xml.utf8)), now: { Date(timeIntervalSince1970: 1_700_000_100) }
            ), preferences: WiltedMacTestPreferences.ephemeral()
        )
        model.startStoreBootstrap()
        await model.waitForStoreBootstrap()

        let prepared = try XCTUnwrap(model.episodes.first { $0.id == targetID.rawValue })
        XCTAssertEqual(prepared.downloadState, .completed)
        XCTAssertEqual(prepared.preparationState, .prepared(summary: "Ready · 3 ads removed (4:38) · transcript synced"))

        model.removeEpisode(prepared)
        try await settle(model)
        let dismissal = try XCTUnwrap(model.dismissedEpisodes.first { $0.id == prepared.id })
        XCTAssertTrue(dismissal.hasPreparationHistory, "the journal must survive so the Removed list can still say a preparation happened")

        model.restoreEpisode(dismissal)
        await model.waitForPodcastOperations()

        let restored = try XCTUnwrap(model.episodes.first { $0.id == targetID.rawValue })
        XCTAssertEqual(restored.downloadState, .notDownloaded)
        XCTAssertEqual(restored.preparationState, .notPrepared)
        XCTAssertNil(restored.preparationState.label)
    }

    /// The Undo button beside the removal message calls
    /// `restoreEpisode(model.undoableRemoval!)`. Undo must clear the record it
    /// used, so the button does not linger offering to restore an episode a
    /// second time, and must actually bring the episode back to the Larder.
    func testUndoingARemovalClearsTheRecordAndRestoresTheEpisode() async throws {
        let directory = temporaryDirectory("restore-same-session-undo")
        defer { try? FileManager.default.removeItem(at: directory) }
        let libraryURL = directory.appendingPathComponent("library.sqlite")
        let store = try LocalLibraryStore(url: libraryURL)
        let feedURL = URL(string: "https://podcasts.example.test/waveform.xml")!
        let feedID = try ItemID.derivePodcastFeed(from: feedURL)
        let targetURL = URL(string: "https://cdn.example.test/waveform.mp3")!
        let targetID = try ItemID.derivePodcastEpisode(feedURL: feedURL, rssGUID: "wave", enclosureURL: targetURL)
        let feed = try PodcastFeed(
            itemID: feedID, canonicalURL: feedURL, title: "Waveform",
            createdAt: Timestamp(Date(timeIntervalSince1970: 1_700_000_000))
        )
        let target = try PodcastEpisode(
            itemID: targetID, feedID: feedID, feedURL: feedURL, rssGUID: "wave", title: "Wave episode",
            publishedTime: Timestamp(Date(timeIntervalSince1970: 1_600_000_000)),
            enclosureURL: targetURL, enclosureMediaType: "audio/mpeg",
            createdAt: Timestamp(Date(timeIntervalSince1970: 1_600_000_000))
        )
        try await store.save(feed: feed)
        try await store.save(subscription: PodcastSubscription(
            feedID: feedID, subscribedAt: Timestamp(Date(timeIntervalSince1970: 1_700_000_000))
        ))
        try await store.save(episode: target)
        let xml = """
        <rss><channel><title>Waveform</title>
        <item><title>Wave episode</title><guid>wave</guid><pubDate>Sun, 13 Sep 2020 12:26:40 GMT</pubDate><enclosure url="https://cdn.example.test/waveform.mp3" type="audio/mpeg" /></item>
        </channel></rss>
        """
        let model = WiltedMacModel(
            arguments: [], stateDirectoryOverride: directory,
            podcastFeedClient: PodcastFeedClient(
                loader: FixedBodyLoader(body: Data(xml.utf8)), now: { Date(timeIntervalSince1970: 1_700_000_100) }
            ), preferences: WiltedMacTestPreferences.ephemeral()
        )
        model.startStoreBootstrap()
        await model.waitForStoreBootstrap()

        let episode = try XCTUnwrap(model.episodes.first { $0.id == targetID.rawValue })
        model.removeEpisode(episode)
        try await settle(model)

        let undoable = try XCTUnwrap(model.undoableRemoval)
        XCTAssertEqual(undoable.id, episode.id)

        model.restoreEpisode(undoable)
        XCTAssertNil(model.undoableRemoval, "Undo must clear the record it just used")
        await model.waitForPodcastOperations()

        XCTAssertTrue(model.libraryItems.contains { $0.id == episode.id },
                       "Undo must actually bring the episode back to the Larder")
    }

    /// A legacy dismissal without a feed searches subscriptions sequentially;
    /// one broken feed does not prevent a later feed from restoring the item.
    func testFeedlessRestoreToleratesAnIndividualFeedFailure() async throws {
        let directory = temporaryDirectory("restore-feedless")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try LocalLibraryStore(url: directory.appendingPathComponent("library.sqlite"))
        let badURL = URL(string: "https://podcasts.example.test/bad.xml")!
        let goodURL = URL(string: "https://podcasts.example.test/good.xml")!
        for (url, title) in [(badURL, "Broken"), (goodURL, "Working")] {
            let feed = try PodcastFeed(
                itemID: ItemID.derivePodcastFeed(from: url), canonicalURL: url, title: title,
                createdAt: Timestamp(Date(timeIntervalSince1970: 1_700_000_000))
            )
            try await store.save(feed: feed)
            try await store.save(subscription: PodcastSubscription(
                feedID: feed.itemID, subscribedAt: Timestamp(Date(timeIntervalSince1970: 1_600_000_000))
            ))
        }
        let enclosure = URL(string: "https://cdn.example.test/legacy.mp3")!
        let targetID = try ItemID.derivePodcastEpisode(feedURL: goodURL, rssGUID: "legacy", enclosureURL: enclosure)
        try await store.dismissPodcastEpisode(targetID)
        let goodXML = "<rss><channel><title>Working</title><item><title>Legacy episode</title><guid>legacy</guid><enclosure url=\"https://cdn.example.test/legacy.mp3\" type=\"audio/mpeg\" /></item></channel></rss>"
        let loader = RoutingPodcastFeedLoader(documents: [goodURL: Data(goodXML.utf8)])
        let model = WiltedMacModel(
            arguments: [], stateDirectoryOverride: directory,
            podcastFeedClient: PodcastFeedClient(loader: loader, now: { Date(timeIntervalSince1970: 1_700_000_000) }),
            preferences: WiltedMacTestPreferences.ephemeral()
        )
        model.startStoreBootstrap()
        await model.waitForStoreBootstrap()
        model.restoreEpisode(try XCTUnwrap(model.dismissedEpisodes.first))
        await model.waitForPodcastOperations()

        XCTAssertEqual(model.episodes.map(\.title), ["Legacy episode"])
        XCTAssertTrue(model.dismissedEpisodes.isEmpty)
        let requestedURLs = await loader.requestedURLs()
        XCTAssertEqual(Set(requestedURLs), [badURL, goodURL])
    }

    func testFeedlessRestoreWithNoSubscriptionsIsVisibleAndPreservesDismissal() async throws {
        let directory = temporaryDirectory("restore-no-subscriptions")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try LocalLibraryStore(url: directory.appendingPathComponent("library.sqlite"))
        let episodeID = try ItemID(rawValue: "legacy-" + String(repeating: "1", count: 64))
        try await store.dismissPodcastEpisode(episodeID)
        let model = WiltedMacModel(
            arguments: [], stateDirectoryOverride: directory, preferences: WiltedMacTestPreferences.ephemeral()
        )
        model.startStoreBootstrap()
        await model.waitForStoreBootstrap()
        model.restoreEpisode(try XCTUnwrap(model.dismissedEpisodes.first))
        await model.waitForPodcastOperations()

        XCTAssertTrue(model.podcastOperationMessage?.contains("No subscribed feed") == true)
        XCTAssertEqual(model.dismissedEpisodes.map(\.id), [episodeID.rawValue])
        let reopened = try LocalLibraryStore(url: directory.appendingPathComponent("library.sqlite"))
        let persisted = try await reopened.dismissedPodcastEpisodes()
        XCTAssertEqual(persisted.map(\.episodeID), [episodeID])
    }

    func testKnownFeedFailureIsRetryableAndMissingEpisodeRemainsRemoved() async throws {
        func seededModel(
            suffix: String, client: PodcastFeedClient
        ) async throws -> (URL, WiltedMacModel, ItemID) {
            let directory = temporaryDirectory(suffix)
            let store = try LocalLibraryStore(url: directory.appendingPathComponent("library.sqlite"))
            let feedURL = URL(string: "https://podcasts.example.test/\(suffix).xml")!
            let feedID = try ItemID.derivePodcastFeed(from: feedURL)
            let enclosure = URL(string: "https://cdn.example.test/\(suffix).mp3")!
            let episodeID = try ItemID.derivePodcastEpisode(
                feedURL: feedURL, rssGUID: suffix, enclosureURL: enclosure
            )
            try await store.save(feed: PodcastFeed(
                itemID: feedID, canonicalURL: feedURL, title: "Restore Show",
                createdAt: Timestamp(Date(timeIntervalSince1970: 1_700_000_000))
            ))
            try await store.save(subscription: PodcastSubscription(
                feedID: feedID, subscribedAt: Timestamp(Date(timeIntervalSince1970: 1_700_000_000))
            ))
            try await store.save(episode: PodcastEpisode(
                itemID: episodeID, feedID: feedID, feedURL: feedURL, rssGUID: suffix,
                title: "Missing episode", enclosureURL: enclosure, enclosureMediaType: "audio/mpeg",
                createdAt: Timestamp(Date(timeIntervalSince1970: 1_600_000_000))
            ))
            try await store.dismissPodcastEpisode(episodeID)
            let model = WiltedMacModel(
                arguments: [], stateDirectoryOverride: directory, podcastFeedClient: client,
                preferences: WiltedMacTestPreferences.ephemeral()
            )
            model.startStoreBootstrap()
            await model.waitForStoreBootstrap()
            return (directory, model, episodeID)
        }

        let failed = try await seededModel(
            suffix: "restore-failed", client: PodcastFeedClient(loader: FailingLoader())
        )
        defer { try? FileManager.default.removeItem(at: failed.0) }
        failed.1.restoreEpisode(try XCTUnwrap(failed.1.dismissedEpisodes.first))
        await failed.1.waitForPodcastOperations()
        XCTAssertTrue(failed.1.podcastOperationMessage?.contains("Retry Restore") == true)
        XCTAssertEqual(failed.1.dismissedEpisodes.map(\.id), [failed.2.rawValue])

        let missing = try await seededModel(
            suffix: "restore-missing",
            client: PodcastFeedClient(loader: FixedBodyLoader(
                body: Data("<rss><channel><title>Restore Show</title></channel></rss>".utf8)
            ))
        )
        defer { try? FileManager.default.removeItem(at: missing.0) }
        missing.1.restoreEpisode(try XCTUnwrap(missing.1.dismissedEpisodes.first))
        await missing.1.waitForPodcastOperations()
        XCTAssertTrue(missing.1.podcastOperationMessage?.contains("no longer published") == true)
        XCTAssertEqual(missing.1.dismissedEpisodes.map(\.id), [missing.2.rawValue])
    }

    func testRetryForRemovedPrepRunPublishesActionableProcessorMessage() {
        let directory = temporaryDirectory("removed-prep-retry")
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = WiltedMacModel(
            arguments: ["--wilted-ui-fixture-ready"], stateDirectoryOverride: directory,
            preferences: WiltedMacTestPreferences.ephemeral()
        )
        let run = WiltedMacProcessorRun(
            id: "removed-run", itemID: "removed-item", isPodcast: true, title: "Removed episode",
            source: "Show", stage: "failed", detail: "Failed", fraction: nil, outcome: .failed, updatedAt: Date()
        )
        model.retryProcessorRun(run)
        XCTAssertEqual(
            model.processorOperationMessage,
            "Removed episode is no longer in Larder. Add it again before retrying preparation."
        )
    }

    // MARK: Continuing across the Larder when playback runs out

    /// `.oldest` puts the second episode after the first in the Larder's own
    /// displayed order, matching what "next" means to a listener: forward
    /// through the feed, not `.newest`'s reversal of it.
    func testANaturallyFinishedEpisodeStartsTheNextReadyOneAndRemovesItself() async throws {
        let directory = temporaryDirectory("continue-ready")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let feedURL = try XCTUnwrap(URL(string: "https://feeds.example.test/continue-ready.xml"))
        let feedID = try ItemID.derivePodcastFeed(from: feedURL)
        let created = Timestamp(Date(timeIntervalSince1970: 1_700_000_000))
        let firstEnclosure = try XCTUnwrap(URL(string: "https://media.example.test/continue-ready-1.mp3"))
        let secondEnclosure = try XCTUnwrap(URL(string: "https://media.example.test/continue-ready-2.mp3"))
        let firstID = try ItemID.derivePodcastEpisode(
            feedURL: feedURL, rssGUID: "continue-ready-1", enclosureURL: firstEnclosure
        )
        let secondID = try ItemID.derivePodcastEpisode(
            feedURL: feedURL, rssGUID: "continue-ready-2", enclosureURL: secondEnclosure
        )

        let model = WiltedMacModel(
            arguments: [], stateDirectoryOverride: directory,
            storeBootstrap: { url in
                let store = try LocalLibraryStore(url: url)
                try await store.save(feed: try PodcastFeed(
                    itemID: feedID, canonicalURL: feedURL, title: "Continuing", createdAt: created
                ))
                try await store.save(subscription: PodcastSubscription(feedID: feedID, subscribedAt: created))
                try await Self.addReadyEpisode(
                    firstID, guid: "continue-ready-1", feedID: feedID, feedURL: feedURL,
                    enclosureURL: firstEnclosure, publishedAt: created.date,
                    directory: directory, store: store, created: created
                )
                try await Self.addReadyEpisode(
                    secondID, guid: "continue-ready-2", feedID: feedID, feedURL: feedURL,
                    enclosureURL: secondEnclosure, publishedAt: created.date.addingTimeInterval(60),
                    directory: directory, store: store, created: created
                )
                return store
            }, preferences: WiltedMacTestPreferences.ephemeral()
        )
        model.libraryOrder = .oldest
        model.startStoreBootstrap()
        await model.waitForStoreBootstrap()

        let first = try XCTUnwrap(model.episodes.first { $0.id == firstID.rawValue })
        model.playEpisode(first)
        try await settle(model)
        XCTAssertEqual(model.currentEpisode?.id, firstID.rawValue)

        model.simulatePodcastPlaybackReachedEndForTesting()
        try await settle(model)
        model.simulatePodcastPlaybackFinishedForTesting()
        try await settle(model)

        XCTAssertEqual(model.currentEpisode?.id, secondID.rawValue,
                       "the next ready episode should start once the current one runs out with nothing queued")
        XCTAssertFalse(model.episodes.contains { $0.id == firstID.rawValue },
                       "the episode that was listened to all the way through is gone from the Larder")
        XCTAssertTrue(model.dismissedEpisodes.contains { $0.id == firstID.rawValue },
                      "and gone durably, so the next feed refresh cannot put it back")
        XCTAssertEqual(model.podcastOperationMessage, "Removed \(first.title).")
    }

    /// The undownloaded middle episode is never a candidate; the search has
    /// to keep going past it rather than stopping at the first row after the
    /// one that finished.
    func testNaturalCompletionSkipsAnUndownloadedEpisodeToReachTheNextReadyOne() async throws {
        let directory = temporaryDirectory("continue-skip")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let feedURL = try XCTUnwrap(URL(string: "https://feeds.example.test/continue-skip.xml"))
        let feedID = try ItemID.derivePodcastFeed(from: feedURL)
        let created = Timestamp(Date(timeIntervalSince1970: 1_700_000_000))
        let firstEnclosure = try XCTUnwrap(URL(string: "https://media.example.test/continue-skip-1.mp3"))
        let secondEnclosure = try XCTUnwrap(URL(string: "https://media.example.test/continue-skip-2.mp3"))
        let thirdEnclosure = try XCTUnwrap(URL(string: "https://media.example.test/continue-skip-3.mp3"))
        let firstID = try ItemID.derivePodcastEpisode(
            feedURL: feedURL, rssGUID: "continue-skip-1", enclosureURL: firstEnclosure
        )
        let secondID = try ItemID.derivePodcastEpisode(
            feedURL: feedURL, rssGUID: "continue-skip-2", enclosureURL: secondEnclosure
        )
        let thirdID = try ItemID.derivePodcastEpisode(
            feedURL: feedURL, rssGUID: "continue-skip-3", enclosureURL: thirdEnclosure
        )

        let model = WiltedMacModel(
            arguments: [], stateDirectoryOverride: directory,
            storeBootstrap: { url in
                let store = try LocalLibraryStore(url: url)
                try await store.save(feed: try PodcastFeed(
                    itemID: feedID, canonicalURL: feedURL, title: "Skipping", createdAt: created
                ))
                try await store.save(subscription: PodcastSubscription(feedID: feedID, subscribedAt: created))
                try await Self.addReadyEpisode(
                    firstID, guid: "continue-skip-1", feedID: feedID, feedURL: feedURL,
                    enclosureURL: firstEnclosure, publishedAt: created.date,
                    directory: directory, store: store, created: created
                )
                try await Self.addUndownloadedEpisode(
                    secondID, guid: "continue-skip-2", feedID: feedID, feedURL: feedURL,
                    enclosureURL: secondEnclosure, publishedAt: created.date.addingTimeInterval(60),
                    store: store, created: created
                )
                try await Self.addReadyEpisode(
                    thirdID, guid: "continue-skip-3", feedID: feedID, feedURL: feedURL,
                    enclosureURL: thirdEnclosure, publishedAt: created.date.addingTimeInterval(120),
                    directory: directory, store: store, created: created
                )
                return store
            }, preferences: WiltedMacTestPreferences.ephemeral()
        )
        model.libraryOrder = .oldest
        model.startStoreBootstrap()
        await model.waitForStoreBootstrap()

        let first = try XCTUnwrap(model.episodes.first { $0.id == firstID.rawValue })
        model.playEpisode(first)
        try await settle(model)

        model.simulatePodcastPlaybackReachedEndForTesting()
        try await settle(model)
        model.simulatePodcastPlaybackFinishedForTesting()
        try await settle(model)

        XCTAssertEqual(model.currentEpisode?.id, thirdID.rawValue,
                       "an undownloaded episode in between has to be skipped, not offered")
        XCTAssertFalse(model.episodes.contains { $0.id == firstID.rawValue },
                       "the episode that finished is removed")
        XCTAssertTrue(model.episodes.contains { $0.id == secondID.rawValue },
                      "the one merely passed over is not -- it was never listened to")
    }

    /// Nothing else in the Larder is ready, so playback has to stop and the
    /// operation message has to say why -- silence with no explanation reads
    /// as a stall, not as "nothing to play."
    func testNaturalCompletionWithNoReadyEpisodeLeftStopsAndSaysSo() async throws {
        let directory = temporaryDirectory("continue-none")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let feedURL = try XCTUnwrap(URL(string: "https://feeds.example.test/continue-none.xml"))
        let feedID = try ItemID.derivePodcastFeed(from: feedURL)
        let created = Timestamp(Date(timeIntervalSince1970: 1_700_000_000))
        let onlyEnclosure = try XCTUnwrap(URL(string: "https://media.example.test/continue-none-1.mp3"))
        let onlyID = try ItemID.derivePodcastEpisode(
            feedURL: feedURL, rssGUID: "continue-none-1", enclosureURL: onlyEnclosure
        )

        let model = WiltedMacModel(
            arguments: [], stateDirectoryOverride: directory,
            storeBootstrap: { url in
                let store = try LocalLibraryStore(url: url)
                try await store.save(feed: try PodcastFeed(
                    itemID: feedID, canonicalURL: feedURL, title: "Alone", createdAt: created
                ))
                try await store.save(subscription: PodcastSubscription(feedID: feedID, subscribedAt: created))
                try await Self.addReadyEpisode(
                    onlyID, guid: "continue-none-1", feedID: feedID, feedURL: feedURL,
                    enclosureURL: onlyEnclosure, publishedAt: created.date,
                    directory: directory, store: store, created: created
                )
                return store
            }, preferences: WiltedMacTestPreferences.ephemeral()
        )
        model.startStoreBootstrap()
        await model.waitForStoreBootstrap()

        let only = try XCTUnwrap(model.episodes.first { $0.id == onlyID.rawValue })
        model.playEpisode(only)
        try await settle(model)

        model.simulatePodcastPlaybackReachedEndForTesting()
        try await settle(model)
        model.simulatePodcastPlaybackFinishedForTesting()
        try await settle(model)

        // Removing what was playing empties the player, exactly as removing it
        // by hand from the Larder does; there is no episode left to show.
        XCTAssertNil(model.currentEpisode, "the finished episode was removed and nothing replaced it")
        XCTAssertFalse(model.episodes.contains { $0.id == onlyID.rawValue })
        XCTAssertEqual(model.podcastOperationMessage,
                       "Removed \(only.title). No other downloaded, prepared episode is ready to play next.")
    }

    /// The handler is podcast-specific; an article running out must not go
    /// looking through the Larder at all.
    func testArticleCompletionDoesNotSearchForANextPodcastEpisode() {
        let directory = temporaryDirectory("continue-article")
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = WiltedMacModel(
            arguments: [], stateDirectoryOverride: directory, preferences: WiltedMacTestPreferences.ephemeral()
        )
        let article = WiltedMacArticle(
            id: "article-1", title: "A Long Read", source: "example.com",
            url: URL(string: "https://example.com/read")!, isReady: true,
            durationSeconds: 300, createdAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        model.installPlaybackStateForTesting(article: article, isPlaying: true, position: 300, duration: 300)

        model.simulatePodcastPlaybackFinishedForTesting()

        XCTAssertNil(model.podcastOperationMessage, "an article finishing has nothing to do with the podcast queue")
    }

    /// `applyPodcastPlaybackObservation` also covers `PlaybackController`'s
    /// own within-queue advance, which already wrote the outgoing episode's
    /// completed record before this fires; the in-memory Larder rows would
    /// otherwise not know until something else happened to reload them.
    func testMovingToAnotherPodcastEpisodeRefreshesTheLibraryRows() async throws {
        let directory = temporaryDirectory("continue-move-reload")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let feedURL = try XCTUnwrap(URL(string: "https://feeds.example.test/continue-move.xml"))
        let feedID = try ItemID.derivePodcastFeed(from: feedURL)
        let created = Timestamp(Date(timeIntervalSince1970: 1_700_000_000))
        let firstEnclosure = try XCTUnwrap(URL(string: "https://media.example.test/continue-move-1.mp3"))
        let secondEnclosure = try XCTUnwrap(URL(string: "https://media.example.test/continue-move-2.mp3"))
        let firstID = try ItemID.derivePodcastEpisode(
            feedURL: feedURL, rssGUID: "continue-move-1", enclosureURL: firstEnclosure
        )
        let secondID = try ItemID.derivePodcastEpisode(
            feedURL: feedURL, rssGUID: "continue-move-2", enclosureURL: secondEnclosure
        )

        let model = WiltedMacModel(
            arguments: [], stateDirectoryOverride: directory,
            storeBootstrap: { url in
                let store = try LocalLibraryStore(url: url)
                try await store.save(feed: try PodcastFeed(
                    itemID: feedID, canonicalURL: feedURL, title: "Moving", createdAt: created
                ))
                try await store.save(subscription: PodcastSubscription(feedID: feedID, subscribedAt: created))
                try await Self.addReadyEpisode(
                    firstID, guid: "continue-move-1", feedID: feedID, feedURL: feedURL,
                    enclosureURL: firstEnclosure, publishedAt: created.date,
                    directory: directory, store: store, created: created
                )
                try await Self.addReadyEpisode(
                    secondID, guid: "continue-move-2", feedID: feedID, feedURL: feedURL,
                    enclosureURL: secondEnclosure, publishedAt: created.date.addingTimeInterval(60),
                    directory: directory, store: store, created: created
                )
                return store
            }, preferences: WiltedMacTestPreferences.ephemeral()
        )
        model.startStoreBootstrap()
        await model.waitForStoreBootstrap()

        let first = try XCTUnwrap(model.episodes.first { $0.id == firstID.rawValue })
        model.playEpisode(first)
        try await settle(model)

        let phantom = WiltedMacEpisode(
            id: "phantom-episode", title: "Not really in the store", feedTitle: "Moving",
            summary: "", artworkURL: nil, releasedAt: created.date, durationSeconds: 60,
            playbackSeconds: 0, downloadState: .completed
        )
        model.installEpisodeForTesting(phantom)
        XCTAssertTrue(model.episodes.contains { $0.id == phantom.id })

        model.applyPodcastPlaybackObservationForTesting(itemID: secondID, fault: nil)
        try await settle(model)

        XCTAssertEqual(model.currentEpisode?.id, secondID.rawValue)
        XCTAssertFalse(model.episodes.contains { $0.id == phantom.id },
                       "moving to another episode has to reload the Larder from the store, not keep stale rows")
    }

    /// Pure enumeration logic, but it is the one line that decides whether an
    /// episode still preparing or one that failed can be handed to
    /// continuous playback, so it earns its own direct check.
    func testEpisodePreparationStateReportsWhetherItIsPrepared() {
        XCTAssertTrue(WiltedMacEpisodePreparationState.prepared(summary: "Ready").isPrepared)
        XCTAssertFalse(WiltedMacEpisodePreparationState.notPrepared.isPrepared)
        XCTAssertFalse(WiltedMacEpisodePreparationState.preparing(stage: "Preparing…").isPrepared)
        XCTAssertFalse(WiltedMacEpisodePreparationState.failed("Failed").isPrepared)
    }

    // MARK: - Interrupted preparation runs

    /// The bug this covers: an install quit Wilted at 18:59 while an episode
    /// downloaded at 18:56 was still transcribing. The pipeline writes a run's
    /// terminal entry from inside the run, so the journal kept a live entry
    /// with nothing behind it, and the next launch read it back as
    /// "Preparing…" with a Stop that stopped nothing.
    func testBootstrapClosesARunTheJournalStillCallsLive() async throws {
        let directory = temporaryDirectory("interrupted-run")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try LocalLibraryStore(url: directory.appendingPathComponent("library.sqlite"))
        let created = Timestamp(Date(timeIntervalSince1970: 1_700_000_000))
        let feedURL = URL(string: "https://podcasts.example.test/interrupted.xml")!
        let feedID = try ItemID.derivePodcastFeed(from: feedURL)
        try await store.save(feed: try PodcastFeed(itemID: feedID, canonicalURL: feedURL, title: "Waveform", createdAt: created))
        try await store.save(subscription: PodcastSubscription(feedID: feedID, subscribedAt: created))
        func episode(_ guid: String) async throws -> ItemID {
            let enclosure = URL(string: "https://cdn.example.test/\(guid).mp3")!
            let id = try ItemID.derivePodcastEpisode(feedURL: feedURL, rssGUID: guid, enclosureURL: enclosure)
            try await store.save(episode: try PodcastEpisode(
                itemID: id, feedID: feedID, feedURL: feedURL, rssGUID: guid, title: "Episode \(guid)",
                publishedTime: created, enclosureURL: enclosure, enclosureMediaType: "audio/mpeg", createdAt: created
            ))
            return id
        }
        let interrupted = try await episode("interrupted")
        let finished = try await episode("finished")
        let interruptedRequest = WiltedMacModel.podcastRequestPrefix + interrupted.rawValue
        let finishedRequest = WiltedMacModel.podcastRequestPrefix + finished.rawValue
        // What the journal held when the process died: a start and a stage,
        // no terminal.
        try await store.record(preparation: PreparationJournalEntry(
            id: interruptedRequest + "|pipeline.start#1", itemID: interrupted, requestID: interruptedRequest,
            status: try PreparationStatus(stage: .preparing, detail: "Episode interrupted", cancellable: true, emittedAt: created)
        ))
        try await store.record(preparation: PreparationJournalEntry(
            id: interruptedRequest + "|transcript.stt.start#2", itemID: interrupted, requestID: interruptedRequest,
            status: try PreparationStatus(stage: .extracting, detail: "rev-abc.mp3", cancellable: true,
                                          emittedAt: Timestamp(created.date.addingTimeInterval(1)))
        ))
        // A run that did finish is not this launch's business.
        try await store.record(preparation: PreparationJournalEntry(
            id: finishedRequest + "|terminal", itemID: finished, requestID: finishedRequest,
            status: try PreparationStatus(stage: .completed, detail: "Prepared.", cancellable: false,
                                          terminalResult: try PreparationTerminalResult(
                                              outcome: .succeeded,
                                              revisionID: try RevisionID(rawValue: "rev-" + String(repeating: "a", count: 64))
                                          ),
                                          emittedAt: created)
        ))

        let model = WiltedMacModel(arguments: [], stateDirectoryOverride: directory,
                                   preferences: WiltedMacTestPreferences.ephemeral())
        model.startStoreBootstrap()
        await model.waitForStoreBootstrap()

        let runs = Dictionary(uniqueKeysWithValues: try await store.preparationRuns().map { ($0.requestID, $0) })
        let closed = try XCTUnwrap(runs[interruptedRequest])
        XCTAssertTrue(closed.isTerminal, "a run no process is running must not stay live across a launch")
        XCTAssertEqual(closed.outcome, .failed)
        XCTAssertEqual(closed.failure?.message, WiltedMacModel.preparationInterruptedMessage)
        XCTAssertEqual(closed.entries.count, 3, "the run's own entries stay; one closing entry is added")
        let untouched = try XCTUnwrap(runs[finishedRequest])
        XCTAssertEqual(untouched.outcome, .succeeded)
        XCTAssertEqual(untouched.entries.count, 1)

        let row = try XCTUnwrap(model.episodes.first { $0.id == interrupted.rawValue })
        XCTAssertEqual(row.preparationState, .failed(WiltedMacModel.preparationFailedLabel),
                       "the row says the run failed and points at Prep, where the retry is")
        XCTAssertEqual(model.episodes.first { $0.id == finished.rawValue }?.preparationState.isRunning, false)
    }

    /// The closing entry is written only for a run that has no terminal
    /// entry, and it is one the journal reader recognises as a failure.
    func testInterruptedEntryIsWrittenOnlyForALiveRun() throws {
        let itemID = try ItemID(rawValue: "item-" + String(repeating: "c", count: 64))
        let requestID = WiltedMacModel.podcastRequestPrefix + itemID.rawValue
        let when = Timestamp(Date(timeIntervalSince1970: 1_700_000_000))
        func run(isTerminal: Bool) -> PreparationRunSummary {
            PreparationRunSummary(requestID: requestID, itemID: itemID, startedAt: when, updatedAt: when,
                                  stage: isTerminal ? .completed : .extracting, detail: "x", fraction: nil,
                                  isTerminal: isTerminal, outcome: isTerminal ? .succeeded : nil, failure: nil)
        }
        XCTAssertNil(WiltedMacModel.interruptedPreparationEntry(for: run(isTerminal: true), at: when))
        let entry = try XCTUnwrap(WiltedMacModel.interruptedPreparationEntry(for: run(isTerminal: false), at: when))
        XCTAssertEqual(entry.id, requestID + "|interrupted")
        XCTAssertEqual(entry.requestID, requestID)
        XCTAssertTrue(entry.status.terminal)
        XCTAssertEqual(entry.status.terminalResult?.outcome, .failed)
        XCTAssertEqual(entry.status.terminalResult?.error?.retryable, true)
        XCTAssertEqual(entry.status.detail, WiltedMacModel.preparationInterruptedMessage)
    }
}

private struct FixedBodyLoader: PodcastFeedLoading {
    let body: Data
    func load(_ url: URL, maximumBytes: Int) async throws -> PodcastFeedHTTPResponse {
        PodcastFeedHTTPResponse(url: url, statusCode: 200, data: body)
    }
}

/// Serves a document per URL, but only once released.
///
/// Holding every request open is what lets a test place two classifications in
/// flight at a chosen moment instead of racing them.
private actor GatedRoutingLoader: PodcastFeedLoading {
    private let documents: [URL: Data]
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var released = false

    init(documents: [URL: Data]) { self.documents = documents }

    func release() {
        released = true
        let pending = waiters
        waiters.removeAll()
        for waiter in pending { waiter.resume() }
    }

    func load(_ url: URL, maximumBytes: Int) async throws -> PodcastFeedHTTPResponse {
        if !released {
            await withCheckedContinuation { waiters.append($0) }
        }
        guard let body = documents[url] else { throw URLError(.fileDoesNotExist) }
        return PodcastFeedHTTPResponse(url: url, statusCode: 200, data: body)
    }
}

private struct FailingLoader: PodcastFeedLoading {
    func load(_ url: URL, maximumBytes: Int) async throws -> PodcastFeedHTTPResponse {
        throw URLError(.cannotConnectToHost)
    }
}

private actor RoutingPodcastFeedLoader: PodcastFeedLoading {
    let documents: [URL: Data]
    private var requests: [URL] = []

    init(documents: [URL: Data]) { self.documents = documents }

    func load(_ url: URL, maximumBytes: Int) async throws -> PodcastFeedHTTPResponse {
        requests.append(url)
        guard let document = documents[url] else { throw URLError(.cannotConnectToHost) }
        return PodcastFeedHTTPResponse(url: url, statusCode: 200, data: document)
    }

    func requestedURLs() -> [URL] { requests }
}
