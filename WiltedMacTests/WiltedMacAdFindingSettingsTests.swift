import SwiftUI
import Observation
import XCTest
import WiltedDomain
import WiltedProducer
@testable import WiltedMac

    /// The Ad finding card's model and views: the provider key, global switch,
    /// and read-only preview before the first online run.
/// No Keychain and no network: the key store is in memory and the shows invented.
@MainActor
final class WiltedMacAdFindingSettingsTests: XCTestCase {

    // MARK: Policy

    func testOnlineAdFindingRequiresKeyAndGlobalConfirmation() throws {
        let publicShow = show("feed-a", "Public Show")
        let shows = [publicShow]
        let (model, preferences, keyStore) = makeModel(shows: { shows })

        func routeNow() -> RemoteLabellingRoute {
            route(to: publicShow, preferences: preferences, keyStore: keyStore)
        }

        XCTAssertEqual(routeNow(), .notSent(.switchOff))
        XCTAssertEqual(model.requestsToday, 0)
        XCTAssertEqual(model.dailyCap, 60)

        model.setOnlineFinding(true)
        XCTAssertEqual(model.switchMessage, "The chosen provider is not ready. Set it up in Providers.")
        XCTAssertFalse(model.isOnlineFindingOn, "the switch is refused without a key")
        XCTAssertEqual(routeNow(), .notSent(.switchOff))

        try keyStore.save("provider-key-1")
        XCTAssertTrue(model.hasKey)
        XCTAssertEqual(routeNow(), .notSent(.switchOff), "a key alone sends nothing")

        model.setOnlineFinding(true)
        XCTAssertTrue(model.isConfirming, "turning on with nothing confirmed opens the sheet")
        XCTAssertFalse(model.isOnlineFindingOn, "the switch waits for the sheet to be confirmed")
        XCTAssertEqual(AdLabellerPreferences(preferences: preferences).confirmedFeedIDs, [],
                       "nothing is treated as remote before confirm()")
        XCTAssertEqual(model.sheetSentShows.map(\.feedID), ["feed-a"],
                       "an eligible show starts the sheet as sent")

        model.confirm()
        XCTAssertTrue(model.isOnlineFindingOn)
        XCTAssertFalse(model.isConfirming)
        XCTAssertEqual(AdLabellerPreferences(preferences: preferences).confirmedFeedIDs, ["feed-a"])
        XCTAssertEqual(routeNow(), .remote)
    }

    // MARK: Readiness

    func testHasKeyFollowsKeyStore() throws {
        let (model, _, keyStore) = makeModel(shows: { [] })

        XCTAssertFalse(model.hasKey)
        try keyStore.save("provider-key-2")
        XCTAssertTrue(model.hasKey)

        try keyStore.remove()
        XCTAssertFalse(model.hasKey)
    }

    func testRequestCountRefreshesAfterSendAndLocalDayRollover() async throws {
        let firstDay = Date()
        let clock = MutableAdFindingClock(firstDay)
        let (model, preferences, _) = makeModel(shows: { [] }, now: { clock.read() })
        let counter = LabellerRequestCounter(
            preferences: preferences,
            now: { clock.read() },
            onRequestRecorded: {
                Task { @MainActor in model.refreshRequestCount() }
            }
        )

        let requestStarted = expectation(description: "request start invalidates the visible count")
        withObservationTracking {
            XCTAssertEqual(model.requestsToday, 0)
        } onChange: {
            requestStarted.fulfill()
        }
        counter.record()
        await fulfillment(of: [requestStarted], timeout: 1)
        XCTAssertEqual(model.requestsToday, 1)

        let nextLocalDay = try XCTUnwrap(Calendar.current.date(byAdding: .day, value: 1, to: firstDay))
        let dayRollover = expectation(description: "local-day refresh invalidates the visible count")
        withObservationTracking {
            XCTAssertEqual(model.requestsToday, 1)
        } onChange: {
            dayRollover.fulfill()
        }
        clock.set(nextLocalDay)
        model.refreshRequestCount()
        await fulfillment(of: [dayRollover], timeout: 1)
        XCTAssertEqual(model.requestsToday, 0)
    }

    // MARK: Consent stays explicit

    func testShowAddedAfterConfirmationRequiresItsOwnSelection() throws {
        let first = show("feed-a", "First Show")
        let second = show("feed-b", "Second Show")
        var shows = [first, second]
        let (model, preferences, keyStore) = makeModel(shows: { shows })

        try keyStore.save("provider-key-3")
        model.setOnlineFinding(true)
        model.confirm()
        XCTAssertEqual(AdLabellerPreferences(preferences: preferences).confirmedFeedIDs, ["feed-a", "feed-b"])

        let late = show("feed-c", "Late Show")
        shows.append(late)
        XCTAssertEqual(route(to: late, preferences: preferences, keyStore: keyStore), .notSent(.notConfirmed))
        XCTAssertEqual(route(to: first, preferences: preferences, keyStore: keyStore), .remote,
                       "an earlier confirmed show keeps its route")

        AdLabellerPreferences(preferences: preferences).setConfirmed(feedID: late.feedID, true)
        XCTAssertEqual(route(to: late, preferences: preferences, keyStore: keyStore), .remote)
        XCTAssertEqual(AdLabellerPreferences(preferences: preferences).confirmedFeedIDs.sorted(),
                       ["feed-a", "feed-b", "feed-c"], "a show becomes sendable only after its own consent")
    }

    /// A show the owner kept back under the old "Mac only" choice is neither nudged as
    /// waiting nor offered as sent by default; only the owner turning it on sends it.
    func testShowInTheStoredMacOnlyListStartsNotSentInTheSheetAndIsNotWaiting() throws {
        let publicShow = show("feed-a", "Public Show")
        let keptBack = show("feed-k", "Kept Back Show")
        let shows = [publicShow, keptBack]
        let (model, preferences, keyStore) = makeModel(shows: { shows })
        let legacyKey = AdLabellerPreferences.keyPrefix + "localOnlyFeedIDs"
        preferences.set(["feed-k"], forKey: AdLabellerPreferences.keyPrefix + "confirmedFeedIDs")
        preferences.set(["feed-k"], forKey: legacyKey)

        XCTAssertEqual(AdLabellerPreferences(preferences: preferences).confirmedFeedIDs, [],
                       "a refusal in both stored sets is not current consent")

        try keyStore.save("provider-key-5")
        model.setOnlineFinding(true)
        XCTAssertTrue(model.isConfirming, "a show in both stored lists does not count as confirmed")
        XCTAssertEqual(model.sheetSentShows.map(\.feedID), ["feed-a"])
        XCTAssertEqual(model.sheetNotSentShows.map(\.feedID), ["feed-k"], "a kept-back show starts as not sent")

        model.confirm()
        XCTAssertEqual(route(to: publicShow, preferences: preferences, keyStore: keyStore), .remote)
        XCTAssertEqual(route(to: keptBack, preferences: preferences, keyStore: keyStore), .notSent(.notConfirmed))
        XCTAssertEqual(preferences.stringArray(forKey: legacyKey), ["feed-k"],
                       "confirming other shows leaves the stored list alone")

        AdLabellerPreferences(preferences: preferences).setConfirmed(feedID: "feed-k", true)
        XCTAssertEqual(route(to: keptBack, preferences: preferences, keyStore: keyStore), .remote)
        XCTAssertNil(preferences.object(forKey: legacyKey), "turning the show on removes it from the stored list")
    }

    /// A refusal added while the global confirmation is open must still win when confirmed.
    func testGlobalConfirmPreservesLateRefusalAndLeavesNewShowsOff() throws {
        let refused = show("feed-a", "Refused Show")
        let control = show("feed-b", "Public Control")
        var shows = [refused, control]
        let (model, preferences, keyStore) = makeModel(shows: { shows })

        try keyStore.save("provider-key-6")
        model.setOnlineFinding(true)
        XCTAssertEqual(model.sheetSentShows.map(\.feedID), ["feed-a", "feed-b"])
        AdLabellerPreferences(preferences: preferences).keepBack(feedID: refused.feedID)
        let late = show("feed-l", "Late Show")
        shows.append(late)
        XCTAssertEqual(model.sheetSentShows.map(\.feedID), ["feed-b"])
        XCTAssertEqual(model.sheetNotSentShows.map(\.feedID), ["feed-a", "feed-l"])
        model.confirm()
        XCTAssertEqual(route(to: refused, preferences: preferences, keyStore: keyStore), .notSent(.notConfirmed))
        XCTAssertEqual(route(to: control, preferences: preferences, keyStore: keyStore), .remote)
        XCTAssertEqual(route(to: late, preferences: preferences, keyStore: keyStore), .notSent(.notConfirmed))
        XCTAssertEqual(AdLabellerPreferences(preferences: preferences).keptBackFeedIDs, ["feed-a"])
        XCTAssertEqual(AdLabellerPreferences(preferences: preferences).confirmedFeedIDs, ["feed-b"])
    }

    // MARK: Confirmation sheet

    // MARK: Rendering

    func testRenderedCardHidesTheKeyAndTheGlobalConfirmPreviewsShowsWithoutPerShowToggles() async throws {
        let appModel = await WiltedMacHeadless.model(
            self, ["--wilted-ui-fixture-ready", "--wilted-ui-fixture-podcasts"], suffix: "ad-finding-confirm"
        )
        addTeardownBlock { await appModel.close() }
        let premiumURL = try XCTUnwrap(URL(string: "https://fixtures.example.test/premium.xml"))
        appModel.subscriptions.append(WiltedMacSubscription(
            id: "premium-show", title: "Premium Hour", feedURL: premiumURL,
            episodeCount: 0, subscribedAt: .distantPast, enabled: true
        ))
        let model = appModel.adFinding
        let board = WiltedMacFeedPolicyBoard(model: appModel)
        try appModel.adLabellerKeyStore.save("fixture-key-ZX9Q7")
        let cardText = try WiltedMacHeadless.recognizedText(
            WiltedMacAdFindingSettingsView(model: appModel, board: board), size: CGSize(width: 700, height: 600)
        ).joined(separator: " ")
        XCTAssertTrue(cardText.contains("Find ads with the online labeller"), cardText)
        XCTAssertFalse(cardText.contains("Ad finding model"), "model controls belong to the selected provider row: \(cardText)")
        XCTAssertFalse(cardText.contains("Set up providers"), "the obsolete provider link is removed: \(cardText)")
        XCTAssertTrue(cardText.contains("Requests today"), cardText)
        XCTAssertFalse(cardText.contains("fixture-key"), "the key is never rendered: \(cardText)")
        XCTAssertFalse(cardText.contains("ZX9Q7"), cardText)
        XCTAssertFalse(cardText.contains("Key saved"), "Key saved is no longer on Ads page: \(cardText)")
        XCTAssertFalse(cardText.contains("Provider key"), "Provider key field is no longer on Ads page: \(cardText)")
        XCTAssertFalse(cardText.contains("Selected for ad finding"),
                       "the sheet's groups stay in the sheet: \(cardText)")

        model.setOnlineFinding(true)
        let lines = try WiltedMacHeadless.recognizedLines(
            WiltedMacAdFindingConfirmSheet(model: model), size: CGSize(width: 700, height: 700))
        let texts = lines.map(\.text)
        let sentHeading = try XCTUnwrap(
            texts.firstIndex { $0.contains("Selected for ad finding") }, "sent heading missing: \(texts)")
        let otherHeading = try XCTUnwrap(
            texts.firstIndex { $0.contains("Other shows") }, "not sent heading missing: \(texts)")
        let sheetText = texts.joined(separator: " ")
        XCTAssertTrue(sheetText.contains("For shows you add later, turn on ad finding in Show settings."),
                      sheetText)
        let source = try WiltedMacHeadless.viewSource("WiltedMacAdFindingSettingsView.swift")
        let confirmStart = try XCTUnwrap(source.range(of: "struct WiltedMacAdFindingConfirmSheet"))
        let confirmSource = String(source[confirmStart.lowerBound...])
        XCTAssertFalse(confirmSource.contains("Toggle("), "the global confirmation only previews shows")
        XCTAssertFalse(confirmSource.contains("wilted-ad-finding-sheet-show-"), confirmSource)

        for (title, expectedHeading) in [
            ("Field Notes", "Selected for ad finding"), ("Premium Hour", "Selected for ad finding"),
        ] {
            let index = try XCTUnwrap(
                texts.firstIndex { $0.contains(title) }, "\(title) missing from the sheet: \(texts)")
            let heading = try XCTUnwrap(
                [sentHeading, otherHeading].filter { $0 < index }.max().map { texts[$0] },
                "\(title) sits above both headings")
            XCTAssertTrue(heading.contains(expectedHeading), "\(title) is listed under \(heading)")
            XCTAssertEqual(WiltedMacHeadless.occurrences(of: title, in: sheetText), 1,
                           "\(title) appears once, under exactly one heading")
        }
    }

    func testProviderPauseRetryStaysPausedUntilTheCheckSucceeds() async throws {
        let (model, preferences, _) = makeModel(shows: { [] })
        let labeller = AdLabellerPreferences(preferences: preferences)
        XCTAssertNil(model.providerPausedSentence)

        let since = Date(timeIntervalSince1970: 1_700_000_000)
        labeller.recordProviderWaitLimitStop(at: since)
        labeller.recordProviderWaitLimitStop(at: since)
        labeller.recordProviderWaitLimitStop(at: since)
        let sentence = try XCTUnwrap(model.providerPausedSentence)
        XCTAssertEqual(
            sentence,
            LabellerStopReason.providerPaused(since: since).sentence(formatTime: {
                $0.formatted(date: .omitted, time: .shortened)
            })
        )

        await model.retryProviderPause { false }
        XCTAssertNotNil(model.providerPausedSentence, "a failed check must keep Retry available")

        await model.retryProviderPause { true }
        XCTAssertNil(model.providerPausedSentence)
        XCTAssertEqual(labeller.providerPauseCount, 0)
    }

    func testAdFindingSummaryCountsConfirmedPodcastsAndExcludesArticleFeeds() async throws {
        let appModel = await WiltedMacHeadless.model(
            self, ["--wilted-ui-fixture-ready", "--wilted-ui-fixture-podcasts"], suffix: "ad-finding-summary"
        )
        addTeardownBlock { await appModel.close() }
        let podcast = try XCTUnwrap(appModel.subscriptions.first)
        let refusedPodcast = try XCTUnwrap(appModel.subscriptions.first { $0.id != podcast.id })
        let articleURL = try XCTUnwrap(URL(string: "https://fixtures.example.test/articles.xml"))
        let articleID = try ItemID.articleFeed(canonicalFeedURL: articleURL)
        appModel.subscriptions.append(WiltedMacSubscription(
            id: articleID.rawValue, title: "Articles", feedURL: articleURL,
            episodeCount: 0, subscribedAt: .distantPast, enabled: true
        ))

        appModel.preferences.set(
            [podcast.id, refusedPodcast.id, articleID.rawValue, "outside-library"],
            forKey: AdLabellerPreferences.keyPrefix + "confirmedFeedIDs"
        )
        appModel.preferences.set(
            [refusedPodcast.id, "outside-library"],
            forKey: AdLabellerPreferences.keyPrefix + "localOnlyFeedIDs"
        )
        let board = WiltedMacFeedPolicyBoard(model: appModel)
        let text = try WiltedMacHeadless.recognizedText(
            WiltedMacAdFindingSettingsView(model: appModel, board: board),
            size: CGSize(width: 900, height: 1_200)
        ).joined(separator: " ")

        XCTAssertTrue(text.contains("1 of 2 podcasts selected for ad finding"), text)
        XCTAssertTrue(text.range(of: #"\bA[l1]{2} shows\b"#, options: .regularExpression) != nil, text)
    }

    func testAdsSummaryFitsAtSnapshotWidth() async throws {
        let model = await WiltedMacHeadless.model(self, ["--wilted-ui-fixture-ready"], suffix: "ads-summary-fit")
        addTeardownBlock { await model.close() }
        model.selectedNavigation = .settings
        model.settingsSection = .general
        await model.waitForLifetimeStatisticsForTesting()
        let mounted = WiltedMacHeadless.hosted(WiltedMacRootView(model: model))
        defer { withExtendedLifetime(mounted.window) {} }
        let scrollView = try XCTUnwrap(WiltedMacHeadless.destinationScrollView(in: mounted.view))
        let initialOrigin = scrollView.contentView.bounds.origin
        model.settingsSection = .ads
        let reachedAds = await WiltedMacHeadless.eventually("the Ads section scrolls into view") {
            mounted.window.displayIfNeeded()
            mounted.view.layoutSubtreeIfNeeded()
            return scrollView.contentView.bounds.origin != initialOrigin
        }
        XCTAssertTrue(reachedAds, "the hosted Settings page must scroll to its selected section")
        let text = try WiltedMacHeadless.recognizedText(in: mounted.view).joined(separator: " ")
        XCTAssertTrue(text.contains("0 of 0 podcasts selected for ad finding"), text)
        XCTAssertTrue(text.contains("All shows"), text)
    }

    func testHeadlessRenderAdsAndProvidersPagesAndAdsHasNoKeyField() async throws {
        let appModel = await WiltedMacHeadless.model(
            self, ["--wilted-ui-fixture-ready", "--wilted-ui-fixture-podcasts"], suffix: "headless-pages"
        )
        addTeardownBlock { await appModel.close() }
        let board = WiltedMacFeedPolicyBoard(model: appModel)
        let labeller = AdLabellerPreferences(preferences: appModel.preferences)
        let pauseTime = Date(timeIntervalSince1970: 1_700_000_000)
        labeller.recordProviderWaitLimitStop(at: pauseTime)
        labeller.recordProviderWaitLimitStop(at: pauseTime)
        labeller.recordProviderWaitLimitStop(at: pauseTime)

        let adsText = try WiltedMacHeadless.recognizedText(
            WiltedMacAdFindingSettingsView(model: appModel, board: board),
            size: CGSize(width: 700, height: 700)
        ).joined(separator: " ")
        XCTAssertTrue(adsText.contains("Find ads with the online labeller"), adsText)
        XCTAssertFalse(adsText.contains("Ad finding model"), "model controls belong to the selected provider row: \(adsText)")
        XCTAssertFalse(adsText.contains("Set up providers"), "the obsolete provider link is removed: \(adsText)")
        XCTAssertTrue(adsText.contains("Requests today"), adsText)
        XCTAssertTrue(adsText.contains("Retry"), "a paused service needs an action: \(adsText)")
        XCTAssertFalse(adsText.contains("Provider key"), "Ads page must not have key field: \(adsText)")
        XCTAssertFalse(adsText.contains("Key saved"), "Ads page must not have Key saved: \(adsText)")

        appModel.providers.setProvider(.openAIKey)
        appModel.providers.setModel("gpt-4o")
        let fixtureKey = "invented-for-the-render"
        appModel.providers.saveKey(fixtureKey, for: .openAIKey)
        await appModel.adFinding.retryProviderPause {
            await appModel.providers.check(.openAIKey)
        }
        XCTAssertNil(appModel.adFinding.providerPausedSentence)
        appModel.providerEpisodeReplies[.openAIKey] = WiltedMacProviderEpisodeReply(
            provider: .openAIKey, modelID: "gpt-4o",
            occurredAt: Date(timeIntervalSince1970: 1_700_000_000),
            outcome: .reply(breakCount: 2, rejectedCount: 1)
        )
        let lines = try WiltedMacHeadless.recognizedLines(
            WiltedMacProvidersSettingsView(model: appModel),
            size: CGSize(width: 700, height: 700)
        )
        let providersText = lines.map(\.text).joined(separator: " ")
        XCTAssertTrue(providersText.contains("Command-line tools (use your subscription)"), providersText)
        XCTAssertTrue(providersText.contains("Keys"), providersText)
        XCTAssertTrue(providersText.contains("Ad finding model"), providersText)
        XCTAssertTrue(providersText.contains("Ready"), providersText)
        XCTAssertTrue(providersText.localizedCaseInsensitiveContains("Last provider check: Passed"), providersText)
        XCTAssertTrue(providersText.contains("Last episode result: Found 2 ad breaks. 1 label could not be used."), providersText)
        for provider in ["OpenCode", "Claude Code", "Codex", "OpenCode Go", "OpenRouter", "OpenAI", "Anthropic"] {
            // The row draws "OpenAI", but in the system font a capital I and a lowercase l are the
            // same glyph and Vision (no language correction) reads it as "OpenAl".
            let spellings = provider == "OpenAI" ? ["OpenAI", "OpenAl"] : [provider]
            let name = try XCTUnwrap(lines.first { line in spellings.contains { line.text.localizedCaseInsensitiveContains($0) } }, provider)
            // The selection symbol can raise Vision’s bounding box above the text baseline.
            let check = lines.first { $0.text.contains("Check") && abs($0.top - name.top) * 700 < 15 }
            XCTAssertNotNil(check, "Missing Check beside \(provider) at \(name.top): \(lines)")
        }
        XCTAssertTrue(providersText.contains("Thinking level"), providersText)
        XCTAssertTrue(providersText.contains("gpt-4o") || providersText.contains("gpt-40"), providersText)
        XCTAssertTrue(providersText.contains("Key saved"), providersText)
        XCTAssertTrue(providersText.contains("Remove"), providersText)
        XCTAssertTrue(providersText.contains("Save"), providersText)
        XCTAssertFalse(providersText.contains(fixtureKey))
        XCTAssertFalse(providersText.contains("Kind"), providersText)
        XCTAssertFalse(providersText.contains("Command-line tool "), providersText)
    }

    // MARK: Helpers

    private func makeModel(
        shows: @escaping @MainActor () -> [WiltedMacAdFindingSettings.Show],
        now: @escaping @Sendable () -> Date = Date.init
    )
        -> (model: WiltedMacAdFindingSettings, preferences: UserDefaults, keyStore: InMemoryLabellerKeyStore) {
        let preferences = WiltedMacTestPreferences.ephemeral()
        let keyStore = InMemoryLabellerKeyStore()
        let model = WiltedMacAdFindingSettings(preferences: preferences, keyStore: keyStore, now: now, shows: shows)
        return (model, preferences, keyStore)
    }

    /// An invented show with a stable HTTPS address.
    private func show(_ feedID: String, _ title: String) -> WiltedMacAdFindingSettings.Show {
        WiltedMacAdFindingSettings.Show(
            feedID: feedID, title: title,
            feedURL: URL(string: "https://feeds.example.test/\(feedID).xml"))
    }

    /// Where the policy sends one show right now, from the same preferences,
    /// key presence and counter the app builds its context from.
    private func route(
        to show: WiltedMacAdFindingSettings.Show,
        preferences: UserDefaults, keyStore: InMemoryLabellerKeyStore
    ) -> RemoteLabellingRoute {
        RemoteLabellingPolicy.route(
            for: RemoteLabellingInput(
                feedID: show.feedID),
            context: RemoteLabellingContext(
                preferences: AdLabellerPreferences(preferences: preferences),
                hasKey: keyStore.hasKey(),
                counter: LabellerRequestCounter(preferences: preferences)))
    }
}

private final class MutableAdFindingClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Date

    init(_ value: Date) {
        self.value = value
    }

    func read() -> Date {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func set(_ value: Date) {
        lock.lock()
        defer { lock.unlock() }
        self.value = value
    }
}
