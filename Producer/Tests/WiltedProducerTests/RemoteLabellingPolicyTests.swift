import Foundation
import Testing
@testable import WiltedProducer

@Suite("Remote labelling policy")
struct RemoteLabellingPolicyTests {
    private func input(
        id: String = "feed-1"
    ) -> RemoteLabellingInput {
        RemoteLabellingInput(feedID: id)
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
        #expect(route(input(), context(capReached: true)) == .notSent(.dailyCapReached))
    }

    @Test func reasonsHaveStableRawStrings() {
        #expect(RemoteLabellingNotSentReason.allCases.map(\.rawValue) == [
            "switchOff", "noKey", "notConfirmed", "adRemovalOff",
            "dailyCapReached",
        ])
    }

    @Test func rulesAreEvaluatedInDocumentedOrder() {
        let everything = context(on: false, key: false, confirmed: [], capReached: true)
        let all = input()
        var withoutAds = all
        withoutAds.removeAds = false
        #expect(route(withoutAds, everything) == .notSent(.adRemovalOff))
        #expect(route(all, context(on: false, key: false, confirmed: [], adFree: ["feed-1"],
                                   capReached: true)) == .notSent(.adRemovalOff))
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
    }

    @Test func eachNotSentReasonMapsToItsNotSentKindAndSentence() {
        let expected: [RemoteLabellingNotSentReason: (kind: String, sentence: String)?] = [
            .switchOff: ("not-sent-switch-off", "Online ad finding is off."),
            .noKey: ("not-sent-no-key", "No provider key is saved."),
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

    @Test func ownerSwitchesAndConfirmationControlRouting() {
        #expect(route(input(), context()) == .remote)
        #expect(route(input(), context(on: false)) == .notSent(.switchOff))
        #expect(route(input(), context(key: false)) == .notSent(.noKey))
        #expect(route(input(), context(confirmed: [])) == .notSent(.notConfirmed))
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
