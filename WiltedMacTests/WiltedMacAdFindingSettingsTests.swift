import SwiftUI
import XCTest
import WiltedProducer
@testable import WiltedMac

/// The Ad finding card's model and views: the provider key, the global switch,
/// the confirm sheet that decides which shows are sent, and the waiting count.
/// No Keychain and no network: the key store is in memory and the shows invented.
@MainActor
final class WiltedMacAdFindingSettingsTests: XCTestCase {

    // MARK: Policy

    func testEveryFeedStaysLocalUntilKeySwitchAndListAreConfirmed() throws {
        let publicShow = show("feed-a", "Public Show")
        let shows = [publicShow]
        let (model, preferences, keyStore) = makeModel(shows: { shows })

        func routeNow() -> RemoteLabellingRoute {
            route(to: publicShow, preferences: preferences, keyStore: keyStore)
        }

        XCTAssertEqual(routeNow(), .local(.switchOff))
        XCTAssertEqual(model.requestsToday, 0)
        XCTAssertEqual(model.dailyCap, 60)

        model.setOnlineFinding(true)
        XCTAssertEqual(model.switchMessage, "Save a provider key first.")
        XCTAssertFalse(model.isOnlineFindingOn, "the switch is refused without a key")
        XCTAssertEqual(routeNow(), .local(.switchOff))

        model.typedKey = "  provider-key-1  "
        model.saveKey(model.typedKey)
        XCTAssertTrue(model.hasKey)
        XCTAssertEqual(model.typedKey, "", "the typed text is cleared once the key is saved")
        XCTAssertEqual(routeNow(), .local(.switchOff), "a key alone sends nothing")

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

    // MARK: Waiting shows

    func testShowSubscribedAfterwardsWaitsAndConfirmingKeepsEarlierShows() throws {
        let first = show("feed-a", "First Show")
        let second = show("feed-b", "Second Show")
        var shows = [first, second]
        let (model, preferences, keyStore) = makeModel(shows: { shows })

        model.saveKey("provider-key-3")
        model.setOnlineFinding(true)
        model.confirm()
        XCTAssertEqual(model.waitingShowCount, 0)

        let late = show("feed-c", "Late Show")
        shows.append(late)
        XCTAssertEqual(model.waitingShowCount, 1)
        XCTAssertEqual(route(to: late, preferences: preferences, keyStore: keyStore), .local(.notConfirmed))
        XCTAssertEqual(route(to: first, preferences: preferences, keyStore: keyStore), .remote,
                       "an earlier confirmed show keeps its route")

        model.reviewWaitingShows()
        XCTAssertEqual(model.sheetShows.map(\.feedID), ["feed-c"],
                       "the review sheet lists only the waiting show")
        XCTAssertEqual(model.sheetSentShows.map(\.feedID), ["feed-c"])

        model.confirm()
        XCTAssertEqual(model.waitingShowCount, 0)
        XCTAssertEqual(route(to: late, preferences: preferences, keyStore: keyStore), .remote)
        XCTAssertEqual(AdLabellerPreferences(preferences: preferences).confirmedFeedIDs.sorted(),
                       ["feed-a", "feed-b", "feed-c"], "confirming adds to, never replaces, the confirmed set")
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
        XCTAssertEqual(model.forcedLocalReason(for: hidden), .privateTitle)
        XCTAssertEqual(model.forcedLocalReason(for: named), .privateTitle)
        XCTAssertNil(model.forcedLocalReason(for: plain))
    }

    func testPolicyForcedShowCannotBeMovedToSent() throws {
        let publicShow = show("feed-a", "Public Show")
        let premium = show("feed-p", "Premium Hour")
        let shows = [publicShow, premium]
        let (model, preferences, keyStore) = makeModel(shows: { shows })

        model.saveKey("provider-key-4")
        model.setOnlineFinding(true)
        XCTAssertTrue(model.isConfirming)
        XCTAssertEqual(model.sheetSentShows.map(\.feedID), ["feed-a"],
                       "a forced show does not start as sent")
        XCTAssertEqual(model.sheetLocalShows.map(\.feedID), ["feed-p"])
        XCTAssertEqual(model.forcedLocalMessage(for: premium),
                       "This show's title sounds private, so its transcripts always stay on this Mac.")

        model.setSheetSent(true, for: premium)
        XCTAssertFalse(model.sheetSent.contains("feed-p"), "a policy-forced show cannot be toggled to sent")

        model.confirm()
        XCTAssertEqual(model.forcedLocalReason(for: premium), .privateTitle)
        // The policy answers notConfirmed before the forced reason, because the
        // forced show never reaches the confirmed set; the forced reason is what
        // keeps it out of the sent group and locks its toggle.
        XCTAssertEqual(route(to: premium, preferences: preferences, keyStore: keyStore), .local(.notConfirmed))
        XCTAssertEqual(route(to: publicShow, preferences: preferences, keyStore: keyStore), .remote)
        XCTAssertEqual(AdLabellerPreferences(preferences: preferences).confirmedFeedIDs, ["feed-a"])
        XCTAssertEqual(AdLabellerPreferences(preferences: preferences).localOnlyFeedIDs, [],
                       "a forced show is not written to the local-only set")
    }

    // MARK: Rendering

    func testRenderedCardHidesTheKeyAndTheSheetListsEachShowUnderOneHeading() throws {
        let publicShow = show("feed-a", "Public Show")
        let premium = show("feed-p", "Premium Hour")
        let shows = [publicShow, premium]
        let (model, _, _) = makeModel(shows: { shows })

        model.saveKey("fixture-key-ZX9Q7")
        let cardText = try WiltedMacHeadless.recognizedText(
            WiltedMacAdFindingSettingsView(model: model), size: CGSize(width: 700, height: 600)
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
            texts.firstIndex { $0.contains("Stays on this Mac") }, "local heading missing: \(texts)")
        let sheetText = texts.joined(separator: " ")
        XCTAssertTrue(sheetText.contains("Shows you add later stay on this Mac until you confirm them here."),
                      sheetText)

        for (title, expectedHeading) in [
            ("Public Show", "Transcripts will be sent"), ("Premium Hour", "Stays on this Mac"),
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
