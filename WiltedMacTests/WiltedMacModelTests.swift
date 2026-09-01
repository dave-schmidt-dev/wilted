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
            }
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
            retainedArtifactPresenter: { presentedURL = $0 }
        )

        model.startStoreBootstrap()
        await model.waitForStoreBootstrap()

        guard case let .failed(failure) = model.startupState else {
            return XCTFail("A failed store bootstrap must not look like a ready empty larder")
        }
        let retainedURL = try XCTUnwrap(failure.retainedV5StoreURL)
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
            storeBootstrap: { url in try await bootstrap.run(at: url) }
        )

        model.startStoreBootstrap()
        await model.waitForStoreBootstrap()
        model.retryStoreBootstrap()
        await model.waitForStoreBootstrap()

        guard case let .failed(failure) = model.startupState else {
            return XCTFail("The second failure must remain a recovery state")
        }
        XCTAssertFalse(failure.canRetry)
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
            storeBootstrap: { url in try await bootstrap.run(at: url) }
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
            stateDirectoryOverride: directory
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
            }
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
            )
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

    func testFixtureLaunchesStartFromTheDefaultOrderAndLeaveNothingBehind() {
        let directory = temporaryDirectory("fixture-order")
        defer { try? FileManager.default.removeItem(at: directory) }

        let fixture = WiltedMacModel(arguments: ["--wilted-ui-fixture-ready"], stateDirectoryOverride: directory)
        XCTAssertEqual(fixture.libraryOrder, .newest)
        fixture.libraryOrder = .oldest

        let relaunched = WiltedMacModel(arguments: ["--wilted-ui-fixture-ready"], stateDirectoryOverride: directory)
        XCTAssertEqual(relaunched.libraryOrder, .newest, "a fixture launch leaves nothing behind for the next one")
    }

    // MARK: Preparation presentation

    func testPreparationLabelsSpeakToTheListenerNotTheWorker() {
        let cases: [(String, String)] = [
            ("transcript.published.fetch", "Fetching the published transcript…"),
            ("transcript.stt.start", "Transcribing the audio…"),
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

    func testPreparedSummaryReportsWhatWasActuallyDone() {
        XCTAssertEqual(
            WiltedMacModel.preparedSummary(advertisements: 3, secondsRemoved: 185, timing: .aligned),
            "3 ads removed (3:05) · synced transcript"
        )
        XCTAssertEqual(
            WiltedMacModel.preparedSummary(advertisements: 1, secondsRemoved: 42, timing: .published),
            "1 ad removed (0:42) · synced transcript from the feed"
        )
        XCTAssertEqual(
            WiltedMacModel.preparedSummary(advertisements: 0, secondsRemoved: 0, timing: .none),
            "No advertisements found · no synced transcript"
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
                       .prepared(summary: "Synced transcript from the feed"))
        XCTAssertEqual(WiltedMacModel.preparationState(run: nil, transcript: try transcript(.aligned)),
                       .prepared(summary: "Synced transcript"))
        XCTAssertEqual(WiltedMacModel.preparationState(run: nil, transcript: try transcript(.none)),
                       .prepared(summary: "Transcript, not synced"))
        XCTAssertEqual(WiltedMacModel.preparationState(run: nil, transcript: try transcript(.none, .absent)),
                       .notPrepared)

        let failed = PreparationRunSummary(
            requestID: "podcast-prepare|" + itemID.rawValue, itemID: itemID, startedAt: when, updatedAt: when,
            stage: .failed, detail: "Wilted could not start the preparation pipeline.",
            fraction: nil, isTerminal: true, outcome: .failed, failure: nil
        )
        XCTAssertEqual(WiltedMacModel.preparationState(run: failed, transcript: nil),
                       .failed("Wilted could not start the preparation pipeline."))
        // A transcript outranks an old failure: the words are there.
        XCTAssertEqual(WiltedMacModel.preparationState(run: failed, transcript: try transcript(.aligned)),
                       .prepared(summary: "Synced transcript"))

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
            }
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
            pastedLinkClassifier: PastedLinkClassifier(loader: FixedBodyLoader(body: Data(document.utf8)))
        )
    }

    /// The reported complaint: a podcast address pasted into the one box has to
    /// subscribe, not be handed to the article pipeline.
    func testPastingAFeedAddressSubscribesToIt() async throws {
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

        XCTAssertEqual(model.subscriptions.map(\.title), ["Pasted show"])
        XCTAssertNil(model.preparation, "a feed must never reach the article pipeline")
        XCTAssertEqual(model.urlDraft, "", "a completed subscription clears the box")
        XCTAssertNil(model.linkDraftStatus)
    }

    /// An address ending in .xml is unmistakable, so the box must not spend a
    /// round trip to learn what it already knows.
    func testAnUnmistakableFeedAddressSubscribesWithoutSniffing() async throws {
        let directory = temporaryDirectory("pasted-feed-extension")
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = WiltedMacModel(
            arguments: [],
            stateDirectoryOverride: directory,
            podcastFeedClient: PodcastFeedClient(
                loader: FixedBodyLoader(body: Data("<rss><channel><title>Direct show</title></channel></rss>".utf8)),
                now: { Date(timeIntervalSince1970: 1_700_000_000) }
            ),
            pastedLinkClassifier: PastedLinkClassifier(loader: FailingLoader())
        )
        model.startStoreBootstrap()
        await model.waitForStoreBootstrap()

        model.urlDraft = "https://podcasts.example.test/show.xml"
        model.addPastedLink()
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

    /// A pasted address that cannot be reached is reported in the box. Guessing
    /// would send it to a pipeline that fails for a reason the reader did not
    /// cause.
    func testAnUnreachableAddressIsReportedInTheBox() async throws {
        let directory = temporaryDirectory("pasted-unreachable")
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = WiltedMacModel(
            arguments: [],
            stateDirectoryOverride: directory,
            pastedLinkClassifier: PastedLinkClassifier(loader: FailingLoader())
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
            pastedLinkClassifier: PastedLinkClassifier(loader: FailingLoader())
        )
        model.startStoreBootstrap()
        await model.waitForStoreBootstrap()

        for draft in ["", "example.com/thing", "http://example.com/thing"] {
            model.urlDraft = draft
            model.addPastedLink()
            XCTAssertEqual(model.linkDraftStatus, "Enter a complete HTTPS address.", "draft: \(draft)")
        }
    }
}

private struct FixedBodyLoader: PodcastFeedLoading {
    let body: Data
    func load(_ url: URL, maximumBytes: Int) async throws -> PodcastFeedHTTPResponse {
        PodcastFeedHTTPResponse(url: url, statusCode: 200, data: body)
    }
}

private struct FailingLoader: PodcastFeedLoading {
    func load(_ url: URL, maximumBytes: Int) async throws -> PodcastFeedHTTPResponse {
        throw URLError(.cannotConnectToHost)
    }
}
