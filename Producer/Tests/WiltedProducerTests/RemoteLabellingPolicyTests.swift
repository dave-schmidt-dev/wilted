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
        localOnly: Set<String> = [], capReached: Bool = false
    ) -> RemoteLabellingContext {
        RemoteLabellingContext(
            switchOn: on, hasKey: key, confirmedFeedIDs: confirmed,
            localOnlyFeedIDs: localOnly, dailyCapReached: capReached)
    }

    private func route(_ i: RemoteLabellingInput, _ c: RemoteLabellingContext) -> RemoteLabellingRoute {
        RemoteLabellingPolicy.route(for: i, context: c)
    }

    @Test func confirmedPublicShowGoesRemote() {
        #expect(route(input(), context()) == .remote)
    }

    @Test func eachLocalRuleReturnsItsReason() {
        #expect(route(input(), context(on: false)) == .local(.switchOff))
        #expect(route(input(), context(key: false)) == .local(.noKey))
        #expect(route(input(), context(confirmed: [])) == .local(.notConfirmed))
        #expect(route(input(), context(localOnly: ["feed-1"])) == .local(.ownerLocalOnly))
        #expect(route(input(feed: "https://u:p@feeds.example.test/rss"), context()) == .local(.credentialedURL))
        #expect(route(input(feed: "https://feeds.example.test/rss?token=abc"), context()) == .local(.credentialedURL))
        #expect(route(input(feed: "https://feeds.example.test/a8f3k2j9d0s7w1q5z4x6c8v2b1"), context()) == .local(.tokenLikeFeedURL))
        #expect(route(input(title: "Premium Feed"), context()) == .local(.privateTitle))
        #expect(route(input(), context(capReached: true)) == .local(.dailyCapReached))
    }

    @Test func reasonsHaveStableRawStrings() {
        #expect(RemoteLabellingLocalReason.allCases.map(\.rawValue) == [
            "switchOff", "noKey", "notConfirmed", "ownerLocalOnly",
            "unknownFeedURL", "credentialedURL", "tokenLikeFeedURL", "privateTitle", "dailyCapReached",
        ])
    }

    @Test func rulesAreEvaluatedInDocumentedOrder() {
        let all = input(feed: "https://u:p@feeds.example.test/rss", title: "Private")
        #expect(route(all, context(on: false, key: false, confirmed: [], localOnly: ["feed-1"], capReached: true)) == .local(.switchOff))
        #expect(route(all, context(key: false, confirmed: [], capReached: true)) == .local(.noKey))
        #expect(route(all, context(confirmed: [], capReached: true)) == .local(.notConfirmed))
        #expect(route(all, context(localOnly: ["feed-1"], capReached: true)) == .local(.ownerLocalOnly))
        #expect(route(all, context(capReached: true)) == .local(.credentialedURL))
        #expect(route(input(title: "Private"), context(capReached: true)) == .local(.privateTitle))
    }

    @Test func showAddedAfterConfirmationStaysLocal() {
        let later = input(id: "feed-2")
        #expect(route(later, context(confirmed: ["feed-1"])) == .local(.notConfirmed))
    }

    @Test func titlesMatchWholeWordsOnly() {
        #expect(route(input(title: "Remember This"), context()) == .remote)
        #expect(route(input(title: "Membership Has Its Privileges"), context()) == .remote)
        for word in ["premium", "private", "subscriber", "patron", "member"] {
            #expect(route(input(title: "The \(word.uppercased()) Edition"), context()) == .local(.privateTitle))
        }
    }

    @Test func pluralPrivateWordsAndUnknownFeedAddressStayLocal() {
        #expect(route(input(title: "Garden Hour: Members Only"), context()) == .local(.privateTitle))
        #expect(route(input(title: "Patrons Feed"), context()) == .local(.privateTitle))
        #expect(route(input(title: "For Subscribers"), context()) == .local(.privateTitle))
        #expect(route(input(title: "Remembers Everything"), context()) == .remote)
        let unknown = RemoteLabellingInput(feedID: "feed-1", feedURL: nil, feedTitle: "Garden Hour", audioURL: nil)
        #expect(route(unknown, context()) == .local(.unknownFeedURL))
    }

    @Test func credentialedURLsGoLocal() {
        for query in ["token=x", "auth=x", "key=x", "sig=x", "signature=x", "Token=x"] {
            let feed = input(feed: "https://feeds.example.test/rss?\(query)")
            #expect(route(feed, context()) == .local(.credentialedURL))
        }
        let audio = input(audio: "https://user:secret@cdn.example.test/ep/1.mp3")
        #expect(route(audio, context()) == .local(.credentialedURL))
        let audioQuery = input(audio: "https://cdn.example.test/ep/1.mp3?sig=abc")
        #expect(route(audioQuery, context()) == .local(.credentialedURL))
    }

    @Test func tokenLikeFeedPathOrQueryGoesLocal() {
        let path = input(feed: "https://feeds.example.test/f/9a8b7c6d5e4f3a2b1c0d9e8f7a6b/rss")
        #expect(route(path, context()) == .local(.tokenLikeFeedURL))
        let query = input(feed: "https://feeds.example.test/rss?u=9a8b7c6d5e4f3a2b1c0d9e8f7a6b")
        #expect(route(query, context()) == .local(.tokenLikeFeedURL))
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
            #expect(prefs.isShadow, "shadow is on until switched off")
            prefs.isShadow = false
            #expect(!prefs.isShadow)
            #expect(prefs.confirmedFeedIDs.isEmpty)
            #expect(prefs.localOnlyFeedIDs.isEmpty)
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
            prefs.setLocalOnly(feedID: "a", true)
            #expect(prefs.isEnabled)
            #expect(prefs.confirmedFeedIDs == ["a", "b"])
            #expect(prefs.isLocalOnly(feedID: "a"))
            prefs.setLocalOnly(feedID: "a", false)
            #expect(defaults.object(forKey: AdLabellerPreferences.localOnlyKey) == nil)
            prefs.dailyCap = 5
            #expect(prefs.dailyCap == 5)
            #expect(defaults.dictionaryRepresentation().keys.filter { $0.hasPrefix("wilted.adLabeller.") }.count >= 3)
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
            #expect(route(input(), ctx) == .local(.dailyCapReached))

            let later = start.addingTimeInterval(60 * 60)  // 00:30 next local day
            let nextDay = LabellerRequestCounter(preferences: defaults, now: { later }, calendar: calendar)
            #expect(nextDay.count == 0)
            #expect(!nextDay.hasReachedCap)
            nextDay.record()
            #expect(nextDay.count == 1)
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
