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
        XCTAssertEqual(model.podcastOperationMessage,
                       "Removed \(unwanted.title). Refreshing will not bring it back.")

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
            removeAds: true, readableTranscriptPass: true
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
            removeAds: false,
            readableTranscriptPass: false
        )

        let model = WiltedMacModel(arguments: [], stateDirectoryOverride: directory, preferences: preferences)
        model.setAutomationSettings(settings)

        XCTAssertEqual(model.automationSettings, settings)
        XCTAssertNotNil(preferences.data(forKey: WiltedMacModel.automationSettingsPreferenceKey))
        XCTAssertEqual(WiltedAutomationDownloadPolicy.allNewlyAdmittedUpToTwenty.maximumEpisodesPerRefresh, 20)
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
            removeAds: false,
            readableTranscriptPass: true
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
            removeAds: true,
            readableTranscriptPass: true
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
        let linked = WiltedMacCompactPlayer.linkedNotes(notes)
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
        func run(terminal: String, completion: String?) throws -> PreparationRunSummary {
            var entries: [PreparationJournalEntry] = []
            if let completion {
                entries.append(PreparationJournalEntry(
                    id: requestID + "|pipeline.complete", itemID: itemID, requestID: requestID,
                    status: try PreparationStatus(stage: .preparing, detail: completion, cancellable: true, emittedAt: when)
                ))
            }
            return PreparationRunSummary(
                requestID: requestID, itemID: itemID, startedAt: when, updatedAt: when, stage: .completed,
                detail: terminal, fraction: nil, isTerminal: true, outcome: .succeeded, failure: nil, entries: entries
            )
        }

        // A current build journals the summary itself as the terminal row.
        XCTAssertEqual(
            WiltedMacModel.preparationState(run: try run(terminal: "Ready · 5 ads removed (7:22) · transcript synced",
                                                         completion: "5 advertisements, 1307 cues"), transcript: transcript),
            .prepared(summary: "Ready · 5 ads removed (7:22) · transcript synced")
        )
        // Older builds wrote "Prepared." and counted advertisements one row
        // earlier; zero there is the honest state of an episode the broken
        // detector build marked prepared.
        XCTAssertEqual(
            WiltedMacModel.preparationState(run: try run(terminal: "Prepared.", completion: "0 advertisements, 1345 cues"),
                                            transcript: transcript),
            .prepared(summary: "Ready · no ads found · transcript synced")
        )
        XCTAssertEqual(
            WiltedMacModel.preparationState(run: try run(terminal: "Prepared.", completion: "3 advertisements, 900 cues"),
                                            transcript: transcript),
            .prepared(summary: "Ready · 3 ads removed · transcript synced")
        )
        // No journal at all: the transcript is the only evidence.
        XCTAssertEqual(WiltedMacModel.preparationState(run: nil, transcript: transcript),
                       .prepared(summary: "Ready · transcript synced"))
        XCTAssertEqual(
            WiltedMacModel.preparationState(run: try run(terminal: "Prepared.", completion: nil), transcript: transcript),
            .prepared(summary: "Ready · transcript synced")
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
            ("transcript.stt.readable.start", "Transcribing again for reading…"),
            ("transcript.stt.readable.rejected", "Keeping the plain transcript."),
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

    /// The stored transcript is what survives a relaunch, so it decides
    /// whether an episode reads as prepared.
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

        XCTAssertEqual(WiltedMacModel.preparationState(run: nil, transcript: nil), .notPrepared)
        XCTAssertEqual(WiltedMacModel.preparationState(run: nil, transcript: try transcript(.published)),
                       .prepared(summary: "Ready · transcript synced from the feed"))
        XCTAssertEqual(WiltedMacModel.preparationState(run: nil, transcript: try transcript(.aligned)),
                       .prepared(summary: "Ready · transcript synced"))
        XCTAssertEqual(WiltedMacModel.preparationState(run: nil, transcript: try transcript(.none)),
                       .prepared(summary: "Ready · transcript not synced"))
        XCTAssertEqual(WiltedMacModel.preparationState(run: nil, transcript: try transcript(.none, .absent)),
                       .notPrepared)

        let failed = PreparationRunSummary(
            requestID: "podcast-prepare|" + itemID.rawValue, itemID: itemID, startedAt: when, updatedAt: when,
            stage: .failed, detail: "Wilted could not start the preparation pipeline.",
            fraction: nil, isTerminal: true, outcome: .failed, failure: nil
        )
        // The row says only that it failed; the reason and the log are on Prep.
        XCTAssertEqual(WiltedMacModel.preparationState(run: failed, transcript: nil),
                       .failed(WiltedMacModel.preparationFailedLabel))
        // A transcript outranks an old failure: the words are there.
        XCTAssertEqual(WiltedMacModel.preparationState(run: failed, transcript: try transcript(.aligned)),
                       .prepared(summary: "Ready · transcript synced"))

        let running = PreparationRunSummary(
            requestID: failed.requestID, itemID: itemID, startedAt: when, updatedAt: when,
            stage: .extracting, detail: "Transcribing", fraction: nil, isTerminal: false,
            outcome: nil, failure: nil
        )
        XCTAssertEqual(WiltedMacModel.preparationState(run: running, transcript: try transcript(.aligned)),
                       .preparing(stage: "Preparing…"))
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
