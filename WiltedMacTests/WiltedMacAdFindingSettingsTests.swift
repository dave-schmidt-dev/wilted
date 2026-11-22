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
        XCTAssertEqual(model.switchMessage, "Save a provider key first.")
        XCTAssertFalse(model.isOnlineFindingOn, "the switch is refused without a key")
        XCTAssertEqual(routeNow(), .notSent(.switchOff))

        model.typedKey = "  provider-key-1  "
        model.saveKey(model.typedKey)
        XCTAssertTrue(model.hasKey)
        XCTAssertEqual(model.typedKey, "", "the typed text is cleared once the key is saved")
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

    // MARK: Key

    func testKeyLifecycleTrimsRefusesEmptyAndRemoves() throws {
        let (model, _, keyStore) = makeModel(shows: { [] })

        XCTAssertFalse(model.hasKey)
        XCTAssertFalse(model.canSaveKey, "an empty draft disables Save")

        model.typedKey = "   "
        XCTAssertFalse(model.canSaveKey, "whitespace alone disables Save")
        model.saveKey(model.typedKey)
        XCTAssertFalse(model.hasKey, "empty input is refused")
        XCTAssertEqual(model.keyMessage, "Enter a provider key first.")
        XCTAssertEqual(model.typedKey, "   ", "a refused save keeps what was typed")

        model.typedKey = "  provider-key-2  "
        model.saveKey(model.typedKey)
        XCTAssertTrue(model.hasKey)
        XCTAssertNil(model.keyMessage)
        XCTAssertEqual(model.typedKey, "")
        XCTAssertEqual(try keyStore.read(), "provider-key-2", "the stored key is trimmed")

        model.removeKey()
        XCTAssertFalse(model.hasKey)
        XCTAssertNil(try keyStore.read())
    }

    // MARK: Consent stays explicit

    func testShowAddedAfterConfirmationStaysLocalUntilItsConsentIsSaved() throws {
        let first = show("feed-a", "First Show")
        let second = show("feed-b", "Second Show")
        var shows = [first, second]
        let (model, preferences, keyStore) = makeModel(shows: { shows })

        model.saveKey("provider-key-3")
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

        model.saveKey("provider-key-5")
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

        model.saveKey("provider-key-6")
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
        model.saveKey("fixture-key-ZX9Q7")
        let cardText = try WiltedMacHeadless.recognizedText(
            WiltedMacAdFindingSettingsView(model: appModel, board: board), size: CGSize(width: 700, height: 600)
        ).joined(separator: " ")
        XCTAssertTrue(cardText.contains("Key saved"), cardText)
        XCTAssertTrue(cardText.contains("Find ads with the online labeller"), cardText)
        XCTAssertTrue(cardText.contains("Requests today"), cardText)
        XCTAssertFalse(cardText.contains("fixture-key"), "the key is never rendered: \(cardText)")
        XCTAssertFalse(cardText.contains("ZX9Q7"), cardText)
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
            ("Field Notes", "Transcripts will be sent"), ("Premium Hour", "Transcripts will be sent"),
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
        XCTAssertTrue(text.contains("All shows"), text)
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

    // MARK: Helpers

    private func makeModel(shows: @escaping @MainActor () -> [WiltedMacAdFindingSettings.Show])
        -> (model: WiltedMacAdFindingSettings, preferences: UserDefaults, keyStore: InMemoryLabellerKeyStore) {
        let preferences = WiltedMacTestPreferences.ephemeral()
        let keyStore = InMemoryLabellerKeyStore()
        let model = WiltedMacAdFindingSettings(preferences: preferences, keyStore: keyStore, shows: shows)
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
