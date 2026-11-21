import SwiftUI
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

    func testEveryFeedStaysLocalUntilKeyAndGlobalConfirmationAreConfirmed() throws {
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

    // MARK: Consent stays explicit

    func testShowAddedAfterConfirmationStaysLocalUntilItsConsentIsSaved() throws {
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

    /// A show the policy forces not sent is not the owner's choice, so it is not kept back:
    /// once the reason is gone it waits for a decision like any new show.
    func testPolicyForcedShowLeftUnsentIsNotRecordedAsKeptBack() throws {
        let publicShow = show("feed-a", "Public Show")
        let premium = show("feed-p", "Premium Hour")
        let (model, preferences, keyStore) = makeModel(shows: { [publicShow, premium] })

        try keyStore.save("provider-key-7")
        model.setOnlineFinding(true)
        model.confirm()
        XCTAssertEqual(AdLabellerPreferences(preferences: preferences).keptBackFeedIDs, [])
    }

    // MARK: Forced-local shows

    /// Regression: Settings judged only the custom name, so a renamed paid feed looked sendable.
    func testRenamedShowIsForcedLocalByEitherName() throws {
        let hidden = WiltedMacAdFindingSettings.Show(
            feedID: "feed-h", title: "Media Hour",
            feedURL: URL(string: "https://feeds.example.test/feed-h.xml"), publisherTitle: "Media Hour (Premium Feed)")
        let named = WiltedMacAdFindingSettings.Show(
            feedID: "feed-n", title: "Garden (ad-free)",
            feedURL: URL(string: "https://feeds.example.test/feed-n.xml"), publisherTitle: "Garden Hour")
        let plain = WiltedMacAdFindingSettings.Show(
            feedID: "feed-q", title: "Nickname",
            feedURL: URL(string: "https://feeds.example.test/feed-q.xml"), publisherTitle: "Garden Hour")
        let (model, _, _) = makeModel(shows: { [hidden, named, plain] })
        XCTAssertEqual(model.forcedNotSentReason(for: hidden), .privateTitle)
        XCTAssertEqual(model.forcedNotSentReason(for: named), .privateTitle)
        XCTAssertNil(model.forcedNotSentReason(for: plain))
    }

    func testPolicyForcedShowCannotBeMovedToSent() throws {
        let publicShow = show("feed-a", "Public Show")
        let premium = show("feed-p", "Premium Hour")
        let shows = [publicShow, premium]
        let (model, preferences, keyStore) = makeModel(shows: { shows })

        try keyStore.save("provider-key-4")
        model.setOnlineFinding(true)
        XCTAssertTrue(model.isConfirming)
        XCTAssertEqual(model.sheetSentShows.map(\.feedID), ["feed-a"],
                       "a forced show does not start as sent")
        XCTAssertEqual(model.sheetNotSentShows.map(\.feedID), ["feed-p"])
        XCTAssertEqual(model.forcedNotSentMessage(for: premium),
                       "This show's title sounds private, so it is never sent for ad finding.")

        XCTAssertFalse(model.sheetSent.contains("feed-p"), "the read-only preview keeps a policy-forced show local")

        model.confirm()
        XCTAssertEqual(model.forcedNotSentReason(for: premium), .privateTitle)
        // The policy answers the private reason before notConfirmed, so a private
        // show names why it is never sent whatever the owner's switches say.
        XCTAssertEqual(route(to: premium, preferences: preferences, keyStore: keyStore), .notSent(.privateTitle))
        XCTAssertEqual(route(to: publicShow, preferences: preferences, keyStore: keyStore), .remote)
        XCTAssertEqual(AdLabellerPreferences(preferences: preferences).confirmedFeedIDs, ["feed-a"])
    }

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
        XCTAssertTrue(cardText.contains("Ad finding model"), cardText)
        XCTAssertTrue(cardText.contains("Requests today"), cardText)
        XCTAssertFalse(cardText.contains("fixture-key"), "the key is never rendered: \(cardText)")
        XCTAssertFalse(cardText.contains("ZX9Q7"), cardText)
        XCTAssertFalse(cardText.contains("Key saved"), "Key saved is no longer on Ads page: \(cardText)")
        XCTAssertFalse(cardText.contains("Provider key"), "Provider key field is no longer on Ads page: \(cardText)")
        XCTAssertFalse(cardText.contains("Transcripts will be sent"),
                       "the sheet's groups stay in the sheet: \(cardText)")

        model.setOnlineFinding(true)
        let lines = try WiltedMacHeadless.recognizedLines(
            WiltedMacAdFindingConfirmSheet(model: model), size: CGSize(width: 700, height: 700))
        let texts = lines.map(\.text)
        let sentHeading = try XCTUnwrap(
            texts.firstIndex { $0.contains("Transcripts will be sent") }, "sent heading missing: \(texts)")
        let localHeading = try XCTUnwrap(
            texts.firstIndex { $0.contains("Not sent") }, "not sent heading missing: \(texts)")
        let sheetText = texts.joined(separator: " ")
        XCTAssertTrue(sheetText.contains("Shows you add later are not sent until you turn them on in Show settings."),
                      sheetText)
        let source = try WiltedMacHeadless.viewSource("WiltedMacAdFindingSettingsView.swift")
        let confirmStart = try XCTUnwrap(source.range(of: "struct WiltedMacAdFindingConfirmSheet"))
        let confirmSource = String(source[confirmStart.lowerBound...])
        XCTAssertFalse(confirmSource.contains("Toggle("), "the global confirmation only previews shows")
        XCTAssertFalse(confirmSource.contains("wilted-ad-finding-sheet-show-"), confirmSource)

        for (title, expectedHeading) in [
            ("Field Notes", "Transcripts will be sent"), ("Premium Hour", "Not sent"),
        ] {
            let index = try XCTUnwrap(
                texts.firstIndex { $0.contains(title) }, "\(title) missing from the sheet: \(texts)")
            let heading = try XCTUnwrap(
                [sentHeading, localHeading].filter { $0 < index }.max().map { texts[$0] },
                "\(title) sits above both headings")
            XCTAssertTrue(heading.contains(expectedHeading), "\(title) is listed under \(heading)")
            XCTAssertEqual(WiltedMacHeadless.occurrences(of: title, in: sheetText), 1,
                           "\(title) appears once, under exactly one heading")
        }
    }

    func testProviderPausedSentenceAppearsOnlyWhilePausedSinceIsStored() throws {
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

        labeller.clearProviderPause()
        XCTAssertNil(model.providerPausedSentence)
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

        XCTAssertTrue(text.contains("1 of 2 shows allowed for ad finding"), text)
        XCTAssertTrue(text.contains("All shows") || text.contains("A11 shows"), text)
    }

    func testAdsSummaryFitsAtSnapshotWidth() async throws {
        let model = await WiltedMacHeadless.model(self, ["--wilted-ui-fixture-ready"], suffix: "ads-summary-fit")
        addTeardownBlock { await model.close() }
        model.selectedNavigation = .settings
        model.settingsSection = .ads
        await model.waitForLifetimeStatisticsForTesting()
        let size = WiltedMacHeadless.windowCanvas
        let text = try WiltedMacHeadless.recognizedText(
            WiltedMacRootView(model: model).frame(width: size.width, height: size.height),
            size: CGSize(width: size.width + 48, height: size.height + 48)
        ).joined(separator: " ")
        XCTAssertTrue(text.contains("0 of 0 shows allowed for ad finding"), text)
        XCTAssertTrue(text.contains("All shows"), text)
    }

    func testHeadlessRenderAdsAndProvidersPagesAndAdsHasNoKeyField() async throws {
        let appModel = await WiltedMacHeadless.model(
            self, ["--wilted-ui-fixture-ready", "--wilted-ui-fixture-podcasts"], suffix: "headless-pages"
        )
        addTeardownBlock { await appModel.close() }
        let board = WiltedMacFeedPolicyBoard(model: appModel)

        let adsText = try WiltedMacHeadless.recognizedText(
            WiltedMacAdFindingSettingsView(model: appModel, board: board),
            size: CGSize(width: 700, height: 700)
        ).joined(separator: " ")
        XCTAssertTrue(adsText.contains("Find ads with the online labeller"), adsText)
        XCTAssertTrue(adsText.contains("Ad finding model"), adsText)
        XCTAssertTrue(adsText.contains("Requests today"), adsText)
        XCTAssertFalse(adsText.contains("Provider key"), "Ads page must not have key field: \(adsText)")
        XCTAssertFalse(adsText.contains("Key saved"), "Ads page must not have Key saved: \(adsText)")

        let providersText = try WiltedMacHeadless.recognizedText(
            WiltedMacProvidersSettingsView(model: appModel),
            size: CGSize(width: 700, height: 1_200)
        ).joined(separator: " ")
        XCTAssertTrue(providersText.contains("Command-line tools (use your subscription)"), providersText)
        XCTAssertTrue(providersText.contains("Keys"), providersText)
        XCTAssertTrue(providersText.contains("OpenCode"), providersText)
        XCTAssertTrue(providersText.contains("Claude Code"), providersText)
        XCTAssertTrue(providersText.contains("Codex"), providersText)
        XCTAssertTrue(providersText.contains("In use for ad finding"), providersText)
    }

    // MARK: Helpers

    private func makeModel(shows: @escaping @MainActor () -> [WiltedMacAdFindingSettings.Show])
        -> (model: WiltedMacAdFindingSettings, preferences: UserDefaults, keyStore: InMemoryLabellerKeyStore) {
        let preferences = WiltedMacTestPreferences.ephemeral()
        let keyStore = InMemoryLabellerKeyStore()
        let model = WiltedMacAdFindingSettings(preferences: preferences, keyStore: keyStore, shows: shows)
        return (model, preferences, keyStore)
    }

    /// An invented public show whose address carries no credentials or tokens.
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
                feedID: show.feedID, feedURL: show.feedURL, feedTitle: show.title, audioURL: nil),
            context: RemoteLabellingContext(
                preferences: AdLabellerPreferences(preferences: preferences),
                hasKey: keyStore.hasKey(),
                counter: LabellerRequestCounter(preferences: preferences)))
    }
}
