import SwiftUI
import XCTest
import WiltedDomain
import WiltedProducer
@testable import WiltedMac

/// Per-feed automation settings and the Settings defaults they inherit. The model runs against a
/// temporary library; the views are hosted headlessly and read back as rendered text.
@MainActor
final class WiltedMacFeedPolicyViewTests: XCTestCase {
    private let feedURL = URL(string: "https://feeds.example.test/policy.xml")!

    private struct Spec {
        let guid: String
        let day: Int
        var title: String { "Episode \(guid)" }
        var enclosureURL: URL { URL(string: "https://media.example.test/\(guid).mp3")! }
        var published: Date { Date(timeIntervalSince1970: 1_704_000_000 + Double(day) * 86_400) }
    }

    private struct Fixture {
        let model: WiltedMacModel
        let directory: URL
        let preferences: UserDefaults
        let feedID: ItemID
        let ids: [String: String]
        var feed: String { feedID.rawValue }
    }

    // MARK: Done when 1: each control persists, and the summary is the resolved policy

    func testEachControlChoicePersistsThroughAFreshModelAndTheSummaryIsTheResolvedPolicy() async throws {
        let fixture = try await makeFixture()
        let board = WiltedMacFeedPolicyBoard(model: fixture.model)
        await board.reload()
        XCTAssertTrue(board.isLoaded(fixture.feed))
        XCTAssertEqual(board.policy(for: fixture.feed), FeedAutomationPolicy(), "a feed starts on Use global")

        XCTAssertTrue(board.update(fixture.feed, autoKeep: .on))
        XCTAssertTrue(board.update(fixture.feed, autoDownload: .off))
        XCTAssertTrue(board.update(fixture.feed, autoPrepare: .on))
        XCTAssertTrue(board.update(fixture.feed, keptLimit: .explicit(3)))
        await board.settle()
        let chosen = FeedAutomationPolicy(
            autoKeep: .on, autoDownload: .off, autoPrepare: .on, keptLimit: .explicit(3)
        )
        XCTAssertEqual(board.policy(for: fixture.feed), chosen)

        await fixture.model.close()
        let relaunched = try await relaunch(fixture)
        let freshBoard = WiltedMacFeedPolicyBoard(model: relaunched)
        await freshBoard.reload()
        XCTAssertEqual(freshBoard.policy(for: fixture.feed), chosen, "every choice survived a fresh model")

        let resolved = chosen.resolved(using: EpisodeAdmissionService.globalDefaults(relaunched.automationSettings))
        XCTAssertEqual(resolved, .init(autoKeep: true, autoDownload: false, autoPrepare: true, keptLimit: 3))
        XCTAssertEqual(freshBoard.summary(for: fixture.feed), WiltedFeedAutomationSummary.rows(resolved))
        XCTAssertEqual(
            freshBoard.summary(for: fixture.feed).map { "\($0.label)=\($0.value)" },
            ["Auto keep=On", "Auto download=Off", "Auto prepare=On", "Kept limit=3 episodes"]
        )

        // Back to Use global: the stored choice is the inheritance, and the summary follows the global value.
        for change in [
            { freshBoard.update(fixture.feed, autoKeep: .useGlobal) },
            { freshBoard.update(fixture.feed, autoDownload: .useGlobal) },
            { freshBoard.update(fixture.feed, autoPrepare: .useGlobal) },
            { freshBoard.update(fixture.feed, keptLimit: .useGlobal) },
        ] { XCTAssertTrue(change()) }
        await freshBoard.settle()
        await relaunched.close()
        let third = try await relaunch(fixture)
        let thirdBoard = WiltedMacFeedPolicyBoard(model: third)
        await thirdBoard.reload()
        XCTAssertEqual(thirdBoard.policy(for: fixture.feed), FeedAutomationPolicy())
        XCTAssertEqual(
            thirdBoard.summary(for: fixture.feed).map { "\($0.label)=\($0.value)" },
            ["Auto keep=Off", "Auto download=Off", "Auto prepare=On", "Kept limit=No limit"]
        )
        third.updateAutomationSettings { settings in
            WiltedAutomationSettings(
                refreshPolicy: settings.refreshPolicy, downloadPolicy: settings.downloadPolicy,
                processingPolicy: .manual, transcriptPolicy: settings.transcriptPolicy,
                removeAds: settings.removeAds, autoAddPreparedToLarder: settings.autoAddPreparedToLarder,
                downloadEverythingOnLarder: false, prepareEverythingDownloaded: false
            )
        }
        XCTAssertEqual(
            thirdBoard.summary(for: fixture.feed).first { $0.label == "Auto prepare" }?.value, "Off",
            "Use global follows the Settings value, not a copy of it"
        )
    }

    func testAKeptLimitBelowOneIsRejectedAndNothingIsStored() async throws {
        let fixture = try await makeFixture()
        let board = WiltedMacFeedPolicyBoard(model: fixture.model)
        await board.reload()
        XCTAssertFalse(board.update(fixture.feed, keptLimit: .explicit(0)))
        XCTAssertFalse(board.update(fixture.feed, keptLimit: .explicit(-2)))
        await board.settle()
        XCTAssertEqual(board.policy(for: fixture.feed).keptLimit, .useGlobal)
        let store = try XCTUnwrap(fixture.model.store)
        let stored = try await store.feedAutomationPolicy(for: fixture.feedID)
        XCTAssertEqual(stored, FeedAutomationPolicy())
    }

    func testPolicyViewHostsTheResolvedSummaryAndTheFourControls() async throws {
        let fixture = try await makeFixture(
            policy: FeedAutomationPolicy(autoKeep: .on, autoDownload: .on, autoPrepare: .off, keptLimit: .explicit(4))
        )
        let board = WiltedMacFeedPolicyBoard(model: fixture.model)
        await board.reload()
        let subscription = try XCTUnwrap(fixture.model.subscriptions.first { $0.id == fixture.feed })
        let shown = try WiltedMacHeadless.recognizedText(
            WiltedMacFeedPolicyContent(board: board, subscription: subscription),
            size: CGSize(width: 520, height: 700)
        ).joined(separator: "\n")

        for label in ["Auto keep", "Auto download", "Auto prepare", "Kept limit", "Resolved now"] {
            XCTAssertTrue(shown.contains(label), "\(label) in \(shown)")
        }
        let resolved = board.resolved(for: fixture.feed)
        XCTAssertEqual(resolved, .init(autoKeep: true, autoDownload: true, autoPrepare: false, keptLimit: 4))
        XCTAssertTrue(shown.contains("4 episodes"), shown)
        XCTAssertTrue(shown.contains("Use global") || shown.contains("On"), shown)
    }

    func testSettingsShowsTheGlobalDefaultsEveryUseGlobalFeedInherits() async throws {
        let model = WiltedMacModel(arguments: [], preferences: WiltedMacTestPreferences.ephemeral())
        addTeardownBlock { await model.close() }
        let shown = try WiltedMacHeadless.recognizedText(
            WiltedMacSettingsView(model: model), size: CGSize(width: 900, height: 2_200)
        ).joined(separator: "\n")
        XCTAssertTrue(shown.contains("Feed defaults"), shown)
        let defaults = model.automationSettings.feedAutomationDefaults
        XCTAssertEqual(
            defaults, EpisodeAdmissionService.globalDefaults(model.automationSettings),
            "Settings shows exactly the defaults admission resolves against"
        )
        let rows = WiltedFeedAutomationSummary.globalRows(model.automationSettings)
        XCTAssertEqual(rows, WiltedFeedAutomationSummary.rows(FeedAutomationPolicy().resolved(using: defaults)))
        XCTAssertEqual(rows.map(\.label), ["Auto keep", "Auto download", "Auto prepare", "Kept limit"])
        XCTAssertTrue(shown.contains("No limit"), shown)
    }

    // MARK: Done when 2: waiting episodes on Feeds, and a label on every new control

    func testHostedFeedsViewListsEpisodesWaitingForSpaceAndTheProtectionNote() async throws {
        let fixture = try await makeFixture(
            policy: FeedAutomationPolicy(autoKeep: .on, keptLimit: .explicit(2)),
            kept: [Spec(guid: "k", day: 0)],
            undecided: [Spec(guid: "a", day: 1), Spec(guid: "b", day: 2), Spec(guid: "c", day: 3)]
        )
        let board = WiltedMacFeedPolicyBoard(model: fixture.model)
        await board.reload()

        // One slot is open, so the oldest would be kept next; the two newer wait, in feed order.
        let waiting = board.waitingEpisodes(forFeed: fixture.feed)
        XCTAssertEqual(waiting.map(\.id), [fixture.ids["b"]!, fixture.ids["c"]!])

        let shown = try WiltedMacHeadless.recognizedText(
            WiltedMacFeedsView(model: fixture.model, policyBoard: board),
            size: CGSize(width: 1_000, height: 2_000)
        )
        XCTAssertEqual(shown.filter { $0 == "Waiting for space" }.count, 2, "\(shown)")
        for title in ["Episode b", "Episode c"] {
            XCTAssertTrue(shown.contains { $0.contains(title) }, "\(title) in \(shown)")
        }
        XCTAssertEqual(shown.filter { $0.contains("never removes") }.count, 1, "the note is printed once: \(shown)")
        XCTAssertTrue(shown.joined(separator: " ").contains("part-heard"), shown.joined(separator: " "))
        let queue = fixture.model.podcastQueueIDs
        XCTAssertEqual(queue, [fixture.ids["k"]!], "the kept episode is untouched")
    }

    func testNothingWaitsWithoutAutoKeepOrWithoutALimit() async throws {
        let undecided = [Spec(guid: "a", day: 1), Spec(guid: "b", day: 2)]
        for policy in [
            FeedAutomationPolicy(autoKeep: .off, keptLimit: .explicit(1)),
            FeedAutomationPolicy(autoKeep: .on, keptLimit: .useGlobal),
            FeedAutomationPolicy(),
        ] {
            let fixture = try await makeFixture(policy: policy, kept: [Spec(guid: "k", day: 0)], undecided: undecided)
            let board = WiltedMacFeedPolicyBoard(model: fixture.model)
            await board.reload()
            XCTAssertTrue(board.waitingEpisodes(forFeed: fixture.feed).isEmpty, "\(policy)")
            let shown = try WiltedMacHeadless.recognizedText(
                WiltedMacFeedsView(model: fixture.model, policyBoard: board),
                size: CGSize(width: 1_000, height: 2_000)
            )
            XCTAssertFalse(shown.contains { $0.contains("Waiting for space") }, "\(shown)")
            XCTAssertFalse(shown.contains { $0.contains("never removes") }, "\(shown)")
        }
    }

    func testRaisingTheLimitFillsOpenPlacesAndLoweringItNeverRemovesAnything() async throws {
        let fixture = try await makeFixture(
            policy: FeedAutomationPolicy(autoKeep: .on, keptLimit: .explicit(1)),
            kept: [Spec(guid: "k", day: 0)],
            undecided: [Spec(guid: "a", day: 1), Spec(guid: "b", day: 2)]
        )
        let board = WiltedMacFeedPolicyBoard(model: fixture.model)
        await board.reload()
        XCTAssertEqual(board.waitingEpisodes(forFeed: fixture.feed).count, 2)

        XCTAssertTrue(board.update(fixture.feed, keptLimit: .explicit(2)))
        await board.settle()
        XCTAssertEqual(
            fixture.model.podcastQueueIDs, [fixture.ids["k"]!, fixture.ids["a"]!],
            "the open place took the oldest waiting episode"
        )
        XCTAssertEqual(board.waitingEpisodes(forFeed: fixture.feed).map(\.id), [fixture.ids["b"]!])

        XCTAssertTrue(board.update(fixture.feed, keptLimit: .explicit(1)))
        await board.settle()
        XCTAssertEqual(
            fixture.model.podcastQueueIDs, [fixture.ids["k"]!, fixture.ids["a"]!],
            "a lower limit never removes an episode already kept"
        )
        XCTAssertEqual(board.waitingEpisodes(forFeed: fixture.feed).map(\.id), [fixture.ids["b"]!])
    }

    func testEveryNewControlCarriesAnAccessibilityLabelNamingTheFeed() throws {
        let source = try WiltedMacHeadless.viewSource("WiltedMacFeedPolicyView.swift")
        for label in [
            "Feed settings for \\(subscription.title)",
            "Auto keep for \\(subscription.title)",
            "Auto download for \\(subscription.title)",
            "Auto prepare for \\(subscription.title)",
            "Kept limit for \\(subscription.title)",
            "Number of episodes kept for \\(subscription.title)",
            "Close feed settings for \\(subscription.title)",
        ] {
            XCTAssertTrue(source.contains("\"\(label)\""), label)
        }
        // No control is added without a label: every Picker, TextField, Stepper and Button is paired with one.
        let controls = ["Picker(", "TextField(", "Stepper(", "Button("].reduce(0) {
            $0 + WiltedMacHeadless.occurrences(of: $1, in: source)
        }
        XCTAssertGreaterThan(controls, 0)
        XCTAssertGreaterThanOrEqual(WiltedMacHeadless.occurrences(of: ".accessibilityLabel(", in: source), controls)

        let feeds = try WiltedMacHeadless.viewSource("WiltedMacFeedsView.swift")
        XCTAssertTrue(feeds.contains("WiltedMacFeedPolicyButton(board: policyBoard, subscription: subscription)"))
    }

    // MARK: Global Auto keep and kept limit

    func testGlobalAutoKeepAndKeptLimitRoundTripAndAUseGlobalFeedFollowsThem() async throws {
        let fixture = try await makeFixture(
            kept: [Spec(guid: "k", day: 0)], undecided: [Spec(guid: "a", day: 1), Spec(guid: "b", day: 2)]
        )
        XCTAssertFalse(WiltedAutomationSettings.defaults.autoKeepNewEpisodes)
        XCTAssertNil(WiltedAutomationSettings.defaults.keptLimitPerFeed)
        let board = WiltedMacFeedPolicyBoard(model: fixture.model)
        await board.reload()
        XCTAssertEqual(board.summary(for: fixture.feed).map(\.value), ["Off", "Off", "On", "No limit"])
        XCTAssertTrue(board.waitingEpisodes(forFeed: fixture.feed).isEmpty)

        fixture.model.updateAutomationSettings { $0.settingAutoKeepNewEpisodes(true) }
        fixture.model.updateAutomationSettings { $0.settingKeptLimitPerFeed(1) }
        XCTAssertEqual(board.summary(for: fixture.feed).map(\.value), ["On", "Off", "On", "1 episode"],
                       "Resolved now follows the global values for a Use global feed")
        XCTAssertEqual(board.waitingEpisodes(forFeed: fixture.feed).map(\.id), [fixture.ids["a"]!, fixture.ids["b"]!])
        XCTAssertTrue(board.update(fixture.feed, autoKeep: .off))
        XCTAssertEqual(board.summary(for: fixture.feed).first?.value, "Off", "a feed override still beats the global value")
        XCTAssertTrue(board.update(fixture.feed, autoKeep: .useGlobal, keptLimit: .explicit(7)))
        XCTAssertEqual(board.summary(for: fixture.feed).last?.value, "7 episodes")
        await board.settle()

        await fixture.model.close()
        let relaunched = try await relaunch(fixture)
        XCTAssertTrue(relaunched.automationSettings.autoKeepNewEpisodes)
        XCTAssertEqual(relaunched.automationSettings.keptLimitPerFeed, 1)
        relaunched.updateAutomationSettings { $0.settingKeptLimitPerFeed(nil) }
        XCTAssertNil(relaunched.automationSettings.keptLimitPerFeed, "No limit is storable again")
        XCTAssertEqual(
            relaunched.automationSettings.feedAutomationDefaults,
            EpisodeAdmissionService.globalDefaults(relaunched.automationSettings)
        )
        XCTAssertEqual(
            relaunched.automationSettings.feedAutomationDefaults,
            .init(autoKeep: true, autoDownload: false, autoPrepare: true, keptLimit: nil)
        )
    }

    func testSettingsSavedBeforeTheGlobalDefaultsExistReadAsOffAndUnlimited() throws {
        let current = try JSONEncoder().encode(WiltedAutomationSettings.defaults)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: current) as? [String: Any])
        object.removeValue(forKey: "autoKeepNewEpisodes")
        object.removeValue(forKey: "keptLimitPerFeed")
        let legacy = try JSONSerialization.data(withJSONObject: object)
        let decoded = try JSONDecoder().decode(WiltedAutomationSettings.self, from: legacy)
        XCTAssertEqual(decoded, WiltedAutomationSettings.defaults)
        XCTAssertFalse(decoded.autoKeepNewEpisodes)
        XCTAssertNil(decoded.keptLimitPerFeed)
        let limited = WiltedAutomationSettings.defaults.settingKeptLimitPerFeed(0)
        XCTAssertNil(limited.keptLimitPerFeed, "a limit below one is No limit, never zero")
    }

    // MARK: Narrow and wide

    func testPopoverAndPagesRenderAtTheMinimumWindowWidthAndWide() async throws {
        let fixture = try await makeFixture(
            policy: FeedAutomationPolicy(autoKeep: .on, keptLimit: .explicit(1)),
            kept: [Spec(guid: "k", day: 0)], undecided: [Spec(guid: "a", day: 1)]
        )
        let board = WiltedMacFeedPolicyBoard(model: fixture.model)
        await board.reload()
        let subscription = try XCTUnwrap(fixture.model.subscriptions.first)
        let narrowWidth = WiltedMacShellLayout.windowMinimumWidth(scale: fixture.model.textScale)
        XCTAssertGreaterThan(narrowWidth, 0)
        for width in [narrowWidth, 1_400] {
            let feeds = try WiltedMacHeadless.recognizedText(
                WiltedMacFeedsView(model: fixture.model, policyBoard: board), size: CGSize(width: width, height: 2_000)
            ).joined(separator: "\n")
            XCTAssertTrue(feeds.contains("Waiting for space"), "\(width): \(feeds)")
            XCTAssertTrue(feeds.contains("never removes"), "\(width): \(feeds)")
        }
        let popover = try WiltedMacHeadless.recognizedText(
            WiltedMacFeedPolicyContent(board: board, subscription: subscription).frame(width: 380).padding(16),
            size: CGSize(width: 412, height: 700)
        ).joined(separator: "\n")
        for text in ["Feed settings", "Resolved now", "Kept limit", "Done"] {
            XCTAssertTrue(popover.contains(text), "\(text) in \(popover)")
        }
        let settings = try WiltedMacHeadless.recognizedText(
            WiltedMacSettingsView(model: fixture.model), size: CGSize(width: narrowWidth, height: 2_600)
        ).joined(separator: "\n")
        XCTAssertTrue(settings.contains("Feed defaults"), settings)
        XCTAssertTrue(settings.contains("Auto keep"), settings)
    }

    // MARK: Fixture

    private func makeFixture(
        policy: FeedAutomationPolicy = FeedAutomationPolicy(), kept: [Spec] = [], undecided: [Spec] = []
    ) async throws -> Fixture {
        let directory = wiltedTemporaryDirectory("feed-policy")
        let feedURL = self.feedURL
        let feedID = try ItemID.derivePodcastFeed(from: feedURL)
        let subscribedAt = Timestamp(Date(timeIntervalSince1970: 1_672_531_200))
        let preferences = WiltedMacTestPreferences.ephemeral()
        let specs = kept + undecided
        let keptIDs = try kept.map { try itemID($0) }
        let model = WiltedMacModel(
            arguments: [], stateDirectoryOverride: directory,
            storeBootstrap: { url in
                let store = try LocalLibraryStore(url: url)
                try await store.save(feed: try PodcastFeed(
                    itemID: feedID, canonicalURL: feedURL, title: "Policy Feed", createdAt: subscribedAt
                ))
                try await store.save(subscription: PodcastSubscription(feedID: feedID, subscribedAt: subscribedAt))
                for spec in specs {
                    try await store.save(episode: try PodcastEpisode(
                        itemID: try ItemID.derivePodcastEpisode(
                            feedURL: feedURL, rssGUID: spec.guid, enclosureURL: spec.enclosureURL
                        ),
                        feedID: feedID, feedURL: feedURL, rssGUID: spec.guid, title: spec.title,
                        publishedTime: Timestamp(spec.published), enclosureURL: spec.enclosureURL,
                        enclosureMediaType: "audio/mpeg", createdAt: subscribedAt
                    ))
                }
                if !keptIDs.isEmpty {
                    try await store.replacePodcastQueue(
                        try PodcastQueueState(episodeIDs: keptIDs, currentEpisodeID: nil)
                    )
                    for id in keptIDs {
                        try await store.save(episodeDecision: .init(
                            episodeID: id, decision: .keep, source: .manual, decidedAt: subscribedAt
                        ))
                    }
                }
                try await store.save(feedAutomationPolicy: policy, for: feedID)
                return store
            },
            preferences: preferences
        )
        model.startStoreBootstrap()
        await model.waitForStoreBootstrap()
        addTeardownBlock { await model.close() }
        let ids = Dictionary(uniqueKeysWithValues: try specs.map { ($0.guid, try itemID($0).rawValue) })
        return Fixture(
            model: model, directory: directory, preferences: preferences, feedID: feedID, ids: ids
        )
    }

    /// A model on the same directory and defaults, the way a relaunch finds them.
    private func relaunch(_ fixture: Fixture) async throws -> WiltedMacModel {
        let model = WiltedMacModel(
            arguments: [], stateDirectoryOverride: fixture.directory, preferences: fixture.preferences
        )
        model.startStoreBootstrap()
        await model.waitForStoreBootstrap()
        addTeardownBlock { await model.close() }
        return model
    }

    private func itemID(_ spec: Spec) throws -> ItemID {
        try ItemID.derivePodcastEpisode(feedURL: feedURL, rssGUID: spec.guid, enclosureURL: spec.enclosureURL)
    }
}
