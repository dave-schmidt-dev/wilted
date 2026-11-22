import Foundation
import Testing
@testable import WiltedProducer

@Suite("Remote labelling policy")
struct RemoteLabellingPolicyTests {
    private func input(
        id: String = "feed-1", feed: String = "https://feeds.example.test/garden/rss",
        title: String = "Garden Hour", audio: String = "https://cdn.example.test/ep/episode-1.mp3"
    ) -> RemoteLabellingInput {
        RemoteLabellingInput(feedID: id, feedURL: URL(string: feed), feedTitle: title, audioURL: URL(string: audio))
    }

    private func context(
        on: Bool = true, key: Bool = true, confirmed: Set<String> = ["feed-1"],
        adFree: Set<String> = [], capReached: Bool = false
    ) -> RemoteLabellingContext {
        RemoteLabellingContext(
            switchOn: on, hasKey: key, confirmedFeedIDs: confirmed,
            adFreeFeedIDs: adFree, dailyCapReached: capReached)
    }

    private func route(_ i: RemoteLabellingInput, _ c: RemoteLabellingContext) -> RemoteLabellingRoute {
        RemoteLabellingPolicy.route(for: i, context: c)
    }

    @Test func confirmedPublicShowGoesRemote() {
        #expect(route(input(), context()) == .remote)
    }

    @Test func eachNotSentRuleReturnsItsReason() {
        #expect(route(input(), context(on: false)) == .notSent(.switchOff))
        #expect(route(input(), context(key: false)) == .notSent(.noKey))
        #expect(route(input(), context(confirmed: [])) == .notSent(.notConfirmed))
        #expect(route(input(), context(adFree: ["feed-1"])) == .notSent(.adRemovalOff))
        var withoutAds = input()
        withoutAds.removeAds = false
        #expect(route(withoutAds, context()) == .notSent(.adRemovalOff))
        #expect(route(input(feed: "https://u:p@feeds.example.test/rss"), context()) == .notSent(.credentialedURL))
        #expect(route(input(feed: "https://feeds.example.test/rss?token=abc"), context()) == .notSent(.credentialedURL))
        #expect(route(input(feed: "https://feeds.example.test/a8f3k2j9d0s7w1q5z4x6c8v2b1"), context()) == .notSent(.tokenLikeFeedURL))
        #expect(route(input(title: "Premium Feed"), context()) == .notSent(.privateTitle))
        #expect(route(input(), context(capReached: true)) == .notSent(.dailyCapReached))
    }

    @Test func reasonsHaveStableRawStrings() {
        #expect(RemoteLabellingNotSentReason.allCases.map(\.rawValue) == [
            "switchOff", "noKey", "notConfirmed", "adRemovalOff",
            "unknownFeedURL", "credentialedURL", "tokenLikeFeedURL", "privateTitle", "dailyCapReached",
        ])
    }

    @Test func rulesAreEvaluatedInDocumentedOrder() {
        let everything = context(on: false, key: false, confirmed: [], capReached: true)
        let all = input(feed: "https://u:p@feeds.example.test/rss", title: "Private")
        var withoutAds = all
        withoutAds.removeAds = false
        #expect(route(withoutAds, everything) == .notSent(.adRemovalOff))
        #expect(route(all, context(on: false, key: false, confirmed: [], adFree: ["feed-1"],
                                   capReached: true)) == .notSent(.adRemovalOff))
        let unknown = RemoteLabellingInput(feedID: "feed-1", feedURL: nil, feedTitle: "Private", audioURL: nil)
        #expect(route(unknown, everything) == .notSent(.unknownFeedURL))
        #expect(route(all, everything) == .notSent(.credentialedURL))
        let token = input(feed: "https://feeds.example.test/a8f3k2j9d0s7w1q5z4x6c8v2b1", title: "Private")
        #expect(route(token, everything) == .notSent(.tokenLikeFeedURL))
        #expect(route(input(title: "Private"), everything) == .notSent(.privateTitle))
        #expect(route(input(), everything) == .notSent(.switchOff))
        #expect(route(input(), context(key: false, confirmed: [], capReached: true)) == .notSent(.noKey))
        #expect(route(input(), context(confirmed: [], capReached: true)) == .notSent(.notConfirmed))
        #expect(route(input(), context(capReached: true)) == .notSent(.dailyCapReached))
    }

    /// Ad removal off or an ad-free feed has nothing to send, whatever else holds.
    @Test func anAdFreeShowOrEpisodeWithAdRemovalOffStaysLocal() {
        #expect(route(input(), context(adFree: ["feed-1"])) == .notSent(.adRemovalOff))
        var withoutAds = input()
        withoutAds.removeAds = false
        #expect(route(withoutAds, context()) == .notSent(.adRemovalOff))
        #expect(route(input(), context()) == .remote)
        #expect(route(input(), context(confirmed: [])) == .notSent(.notConfirmed))
        #expect(route(withoutAds, context(confirmed: [])) == .notSent(.adRemovalOff))
        let others = [context(on: false), context(key: false), context(confirmed: [])]
        for other in others {
            #expect(route(withoutAds, other) == .notSent(.adRemovalOff))
            var adFree = other
            adFree.adFreeFeedIDs = ["feed-1"]
            #expect(route(input(), adFree) == .notSent(.adRemovalOff))
        }
        var privateWithoutAds = input(title: "Premium Feed")
        privateWithoutAds.removeAds = false
        #expect(route(privateWithoutAds, context()) == .notSent(.adRemovalOff))
        #expect(route(input(title: "Premium Feed"), context(adFree: ["feed-1"])) == .notSent(.adRemovalOff))
    }

    /// A private show names its private reason even before the owner confirms it.
    @Test func anUnconfirmedPrivateShowNamesItsPrivateReason() {
        let route = route(input(title: "Premium Feed"), context(on: false, key: false, confirmed: []))
        #expect(route == .notSent(.privateTitle))
        guard case .notSent(let reason) = route else { return }
        #expect(RemoteLabellingNotSent(reason) == .privateTitle)
        #expect(RemoteLabellingNotSent(reason)?.sentence
                == "This show's title sounds private, so it is never sent for ad finding.")
    }

    @Test func eachNotSentReasonMapsToItsNotSentKindAndSentence() {
        let expected: [RemoteLabellingNotSentReason: (kind: String, sentence: String)?] = [
            .unknownFeedURL: ("not-sent-unknown-address",
                              "This show's address is not known, so it is never sent for ad finding."),
            .credentialedURL: ("not-sent-sign-in-details",
                               "This show's address carries sign-in details, so it is never sent for ad finding."),
            .tokenLikeFeedURL: ("not-sent-private-token",
                                "This show's address carries a private token, so it is never sent for ad finding."),
            .privateTitle: ("not-sent-private-title",
                            "This show's title sounds private, so it is never sent for ad finding."),
            .switchOff: ("not-sent-switch-off", "Online ad finding is off."),
            .noKey: ("not-sent-no-key", "The chosen provider is not ready: it needs a saved key or a model."),
            .notConfirmed: ("not-sent-not-confirmed",
                            "This show is not sent for ad finding. Turn it on in the show's settings."),
            .adRemovalOff: nil,
            .dailyCapReached: nil,
        ]
        #expect(Set(expected.keys) == Set(RemoteLabellingNotSentReason.allCases))
        for (reason, value) in expected {
            let notSent = RemoteLabellingNotSent(reason)
            #expect(notSent?.kind == value?.kind, "\(reason)")
            #expect(notSent?.sentence == value?.sentence, "\(reason)")
            #expect(notSent?.warning == value.map { "original audio includes ads: \($0.sentence)" }, "\(reason)")
        }
    }

    @Test func showAddedAfterConfirmationStaysLocal() {
        let later = input(id: "feed-2")
        #expect(route(later, context(confirmed: ["feed-1"])) == .notSent(.notConfirmed))
    }

    @Test func titlesMatchWholeWordsOnly() {
        #expect(route(input(title: "Remember This"), context()) == .remote)
        #expect(route(input(title: "Membership Has Its Privileges"), context()) == .remote)
        for word in ["premium", "private", "subscriber", "patron", "member"] {
            #expect(route(input(title: "The \(word.uppercased()) Edition"), context()) == .notSent(.privateTitle))
        }
    }

    @Test func pluralPrivateWordsAndUnknownFeedAddressStayLocal() {
        #expect(route(input(title: "Garden Hour: Members Only"), context()) == .notSent(.privateTitle))
        #expect(route(input(title: "Patrons Feed"), context()) == .notSent(.privateTitle))
        #expect(route(input(title: "For Subscribers"), context()) == .notSent(.privateTitle))
        #expect(route(input(title: "Remembers Everything"), context()) == .remote)
        let unknown = RemoteLabellingInput(feedID: "feed-1", feedURL: nil, feedTitle: "Garden Hour", audioURL: nil)
        #expect(route(unknown, context()) == .notSent(.unknownFeedURL))
    }

    @Test func credentialedURLsGoLocal() {
        for query in ["token=x", "auth=x", "key=x", "sig=x", "signature=x", "Token=x"] {
            let feed = input(feed: "https://feeds.example.test/rss?\(query)")
            #expect(route(feed, context()) == .notSent(.credentialedURL))
        }
        let audio = input(audio: "https://user:secret@cdn.example.test/ep/1.mp3")
        #expect(route(audio, context()) == .notSent(.credentialedURL))
        let audioQuery = input(audio: "https://cdn.example.test/ep/1.mp3?sig=abc")
        #expect(route(audioQuery, context()) == .notSent(.credentialedURL))
    }

    @Test func tokenLikeFeedPathOrQueryGoesLocal() {
        let path = input(feed: "https://feeds.example.test/f/9a8b7c6d5e4f3a2b1c0d9e8f7a6b/rss")
        #expect(route(path, context()) == .notSent(.tokenLikeFeedURL))
        let query = input(feed: "https://feeds.example.test/rss?u=9a8b7c6d5e4f3a2b1c0d9e8f7a6b")
        #expect(route(query, context()) == .notSent(.tokenLikeFeedURL))
    }

    /// Regression: a subscriber feed whose long token contained separators went remote on
    /// 2026-11-12, because separators used to exempt a path segment from the token check.
    @Test func separatedAndVeryLongTokensGoLocal() {
        let separated = input(feed: "https://plus.example.test/podcast/Zx9Qa7Lm2Kp4Rt6Vy8Bn1Cd3Ef5Gh_7JkLmNoPq-RsTuVw.XyZ012?t=1")
        #expect(route(separated, context()) == .notSent(.tokenLikeFeedURL))
        let longPart = String(repeating: "abcdefgh", count: 8)
        #expect(route(input(feed: "https://feeds.example.test/\(longPart)/rss"), context()) == .notSent(.tokenLikeFeedURL))
        let longSlug = input(feed: "https://feeds.example.test/a-show-about-gardens-and-growing-things-2026/rss")
        #expect(route(longSlug, context()) == .remote)
    }

    @Test func plusAndAdFreeTitlesGoLocal() {
        for title in ["Garden Hour Plus", "Garden Hour (Ad-Free)", "Garden Hour ad free"] {
            #expect(route(input(title: title), context()) == .notSent(.privateTitle))
        }
        #expect(route(input(title: "Surplus Gardening"), context()) == .remote)
    }

    @Test func ordinaryShapesStayRemote() {
        #expect(route(input(feed: "https://feeds.example.test/Episode-451-Final-Mix"), context()) == .remote)
        #expect(route(input(feed: "https://feeds.example.test/shows/48213/rss"), context()) == .remote)
        let hexAudio = input(audio: "https://cdn.example.test/ep/0123456789abcdef0123456789abcdef.mp3")
        #expect(route(hexAudio, context()) == .remote)
        let longLetters = input(feed: "https://feeds.example.test/thegardeningpodcastofrecord/rss")
        #expect(route(longLetters, context()) == .remote)
    }

    // MARK: Preferences and counter

    private func withDefaults(_ body: (UserDefaults) -> Void) {
        let name = "RemoteLabellingPolicyTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        body(defaults)
    }

    @Test func preferencesDefaults() {
        withDefaults { defaults in
            let prefs = AdLabellerPreferences(preferences: defaults)
            #expect(!prefs.isEnabled)
            #expect(prefs.providerPauseCount == 0)
            #expect(prefs.providerPausedSince == nil)
            #expect(prefs.confirmedFeedIDs.isEmpty)
            #expect(prefs.modelID == "deepseek-v4.1-flash")
            #expect(prefs.level == "low")
            #expect(prefs.dailyCap == 60)
            #expect(prefs.waitLimit == 7200)
        }
    }

    @Test func preferencesRoundTripAndPruneEmptySets() {
        withDefaults { defaults in
            let prefs = AdLabellerPreferences(preferences: defaults)
            prefs.isEnabled = true
            prefs.setConfirmed(feedID: "b", true)
            prefs.setConfirmed(feedID: "a", true)
            #expect(prefs.isEnabled)
            #expect(prefs.confirmedFeedIDs == ["a", "b"])
            #expect(prefs.isConfirmed(feedID: "a"))
            prefs.setConfirmed(feedID: "a", false)
            #expect(prefs.confirmedFeedIDs == ["b"])
            prefs.setConfirmed(feedID: "b", false)
            #expect(defaults.object(forKey: AdLabellerPreferences.confirmedKey) == nil)
            prefs.dailyCap = 5
            #expect(prefs.dailyCap == 5)
            #expect(defaults.dictionaryRepresentation().keys.filter { $0.hasPrefix("wilted.adLabeller.") }.count >= 2)
        }
    }

    @Test func counterReachesCapAndResetsNextLocalDay() {
        withDefaults { defaults in
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = TimeZone(identifier: "America/New_York")!
            let start = DateComponents(
                calendar: calendar, timeZone: calendar.timeZone, year: 2026, month: 3, day: 10, hour: 23, minute: 30
            ).date!
            let counter = LabellerRequestCounter(preferences: defaults, now: { start }, calendar: calendar)
            let prefs = AdLabellerPreferences(preferences: defaults)
            prefs.dailyCap = 2
            prefs.isEnabled = true
            #expect(counter.cap == 2)
            #expect(!counter.hasReachedCap)
            counter.record()
            #expect(counter.count == 1)
            counter.record()
            #expect(counter.hasReachedCap)
            let atCap = RemoteLabellingContext(preferences: prefs, hasKey: true, counter: counter)
            prefs.setConfirmed(feedID: "feed-1", true)
            let ctx = RemoteLabellingContext(preferences: prefs, hasKey: true, counter: counter)
            #expect(atCap.dailyCapReached)
            #expect(route(input(), ctx) == .notSent(.dailyCapReached))

            let later = start.addingTimeInterval(60 * 60)  // 00:30 next local day
            let nextDay = LabellerRequestCounter(preferences: defaults, now: { later }, calendar: calendar)
            #expect(nextDay.count == 0)
            #expect(!nextDay.hasReachedCap)
            nextDay.record()
            #expect(nextDay.count == 1)
        }
    }

    /// Regression: the rule read only the publisher's title, so a show the owner renamed
    /// "(ad-free)" could be sent, while Settings judged the custom name alone.
    @Test func eitherThePublisherTitleOrTheOwnersNameKeepsAShowLocal() {
        var renamed = input(title: "Garden Hour")
        renamed.customTitle = "Garden Hour (ad-free)"
        #expect(RemoteLabellingPolicy.forcedNotSentReason(for: renamed) == .privateTitle)
        #expect(route(renamed, context()) == .notSent(.privateTitle))

        var hidden = input(title: "Garden Hour Plus")
        hidden.customTitle = "Garden Hour"
        #expect(RemoteLabellingPolicy.forcedNotSentReason(for: hidden) == .privateTitle)

        var plain = input(title: "Garden Hour")
        plain.customTitle = "My Garden Show"
        #expect(route(plain, context()) == .remote)
    }

    @Test func feedStoredInBothConfirmedAndLegacyListsRoutesNotSentUntilConfirmedTrue() {
        withDefaults { defaults in
            let legacyKey = AdLabellerPreferences.keyPrefix + "localOnlyFeedIDs"
            let confirmedKey = AdLabellerPreferences.keyPrefix + "confirmedFeedIDs"
            let enabledKey = AdLabellerPreferences.keyPrefix + "enabled"
            defaults.set(true, forKey: enabledKey)
            defaults.set(["feed-1"], forKey: confirmedKey)
            defaults.set(["feed-1"], forKey: legacyKey)

            let prefs = AdLabellerPreferences(preferences: defaults)
            let counter = LabellerRequestCounter(preferences: defaults)
            let ctx = RemoteLabellingContext(preferences: prefs, hasKey: true, counter: counter)
            #expect(route(input(), ctx) == .notSent(.notConfirmed))

            prefs.setConfirmed(feedID: "feed-1", true)
            #expect(defaults.stringArray(forKey: legacyKey) == nil)
            let updatedCtx = RemoteLabellingContext(preferences: prefs, hasKey: true, counter: counter)
            #expect(route(input(), updatedCtx) == .remote)
        }
    }

    /// Regression: an owner's "off" was only an unconfirm, so the next confirm sheet offered the show as sent.
    @Test func aShowTheOwnerKeepsBackStaysKeptBackUntilTurnedOn() {
        withDefaults { defaults in
            let legacyKey = AdLabellerPreferences.keyPrefix + "localOnlyFeedIDs"
            let prefs = AdLabellerPreferences(preferences: defaults)
            prefs.setConfirmed(feedID: "feed-1", true)

            prefs.keepBack(feedID: "feed-1")
            #expect(prefs.confirmedFeedIDs == [])
            #expect(prefs.keptBackFeedIDs == ["feed-1"])
            #expect(defaults.stringArray(forKey: legacyKey) == ["feed-1"])

            prefs.setConfirmed(feedID: "feed-1", true)
            #expect(prefs.confirmedFeedIDs == ["feed-1"])
            #expect(prefs.keptBackFeedIDs == [])
        }
    }

    @Test func counterDefaultCapIsSixty() {
        withDefaults { defaults in
            let counter = LabellerRequestCounter(preferences: defaults)
            #expect(counter.cap == 60)
            for _ in 0..<60 { counter.record() }
            #expect(counter.hasReachedCap)
        }
    }
}
