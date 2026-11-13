import Foundation
import Testing
import WiltedDomain
@testable import WiltedProducer

struct LabelledPolicyDigestInForceTests {
    private let feedURL = URL(string: "https://feeds.example.invalid/show.xml")!
    private let audioURL = URL(string: "https://cdn.example.invalid/e1.mp3")!
    private let feedID: String

    init() {
        feedID = (try? ItemID.derivePodcastFeed(from: feedURL).rawValue) ?? "feed"
    }

    private func defaults() -> (UserDefaults, String) {
        let name = "LabelledPolicyDigestInForceTests.\(UUID().uuidString)"
        return (UserDefaults(suiteName: name)!, name)
    }

    private func configure(
        _ defaults: UserDefaults,
        enabled: Bool = true,
        shadow: Bool = false,
        confirmed: Bool = true,
        hasKey: Bool = true,
        modelID: String = AdLabellerPreferences.defaultModelID,
        level: String = AdLabellerPreferences.defaultLevel,
        adFree: Bool = false,
        localOnly: Bool = false
    ) -> (AdLabellerPreferences, RemoteLabellingInput, PodcastPreparationPolicySnapshot) {
        let preferences = AdLabellerPreferences(preferences: defaults)
        preferences.isEnabled = enabled
        preferences.isShadow = shadow
        preferences.modelID = modelID
        preferences.level = level
        if confirmed { preferences.setConfirmed(feedID: feedID, true) }
        if localOnly { preferences.setLocalOnly(feedID: feedID, true) }
        if adFree { defaults.set([feedID], forKey: AdLabellerPreferences.adFreeFeedsKey) }
        let policy = PodcastPreparationPolicySnapshot(transcriptPolicy: .bestAvailable, removeAds: !adFree)
        let input = RemoteLabellingInput(
            feedID: feedID, feedURL: feedURL, feedTitle: "Invented Garden Show",
            customTitle: nil, audioURL: audioURL, removeAds: policy.removeAds)
        _ = hasKey
        return (preferences, input, policy)
    }

    @Test func remoteSettingsYieldLabelledDigestMatchingCommit() {
        let (defaults, name) = defaults()
        defer { defaults.removePersistentDomain(forName: name) }
        let (preferences, input, policy) = configure(defaults)
        let digest = LabelledPolicyDigestInForce.digest(
            policy: policy, input: input, preferences: preferences, hasKey: true)
        let expected = PodcastPreparationPipeline.policyDigest(
            policy, labelled: PodcastPreparationPipeline.labelledRunProvenance(preferences: preferences))
        #expect(digest == expected)
        #expect(digest != PodcastPreparationPipeline.policyDigest(policy))
    }

    @Test func modelOrLevelChangeChangesDigest() {
        let (defaults, name) = defaults()
        defer { defaults.removePersistentDomain(forName: name) }
        let (preferences, input, policy) = configure(defaults)
        let first = LabelledPolicyDigestInForce.digest(
            policy: policy, input: input, preferences: preferences, hasKey: true)
        preferences.modelID = "invented-model-other"
        let afterModel = LabelledPolicyDigestInForce.digest(
            policy: policy, input: input, preferences: preferences, hasKey: true)
        #expect(first != afterModel)
        preferences.modelID = AdLabellerPreferences.defaultModelID
        preferences.level = "high"
        let afterLevel = LabelledPolicyDigestInForce.digest(
            policy: policy, input: input, preferences: preferences, hasKey: true)
        #expect(first != afterLevel)
    }

    @Test(arguments: [
        "switchOff", "noKey", "shadow", "localOnly", "adFree", "notConfirmed",
    ])
    func localRoutesYieldNil(mode: String) {
        let (defaults, name) = defaults()
        defer { defaults.removePersistentDomain(forName: name) }
        var enabled = true, shadow = false, confirmed = true, hasKey = true, adFree = false, localOnly = false
        switch mode {
        case "switchOff": enabled = false
        case "noKey": hasKey = false
        case "shadow": shadow = true
        case "localOnly": localOnly = true
        case "adFree": adFree = true
        case "notConfirmed": confirmed = false
        default: break
        }
        let (preferences, input, policy) = configure(
            defaults, enabled: enabled, shadow: shadow, confirmed: confirmed,
            hasKey: hasKey, adFree: adFree, localOnly: localOnly)
        #expect(LabelledPolicyDigestInForce.digest(
            policy: policy, input: input, preferences: preferences, hasKey: hasKey) == nil)
    }

    @Test func dailyCapDoesNotChangeDigestInForce() {
        let (defaults, name) = defaults()
        defer { defaults.removePersistentDomain(forName: name) }
        let (preferences, input, policy) = configure(defaults)
        preferences.dailyCap = 0
        let counter = LabellerRequestCounter(preferences: defaults)
        #expect(counter.hasReachedCap)
        let digest = LabelledPolicyDigestInForce.digest(
            policy: policy, input: input, preferences: preferences, hasKey: true)
        #expect(digest != nil)
        let live = PodcastPreparationPipeline.labelledRoutingDecision(
            isShadow: false, input: input,
            context: RemoteLabellingContext(
                preferences: preferences, hasKey: true, counter: counter))
        #expect(live == .dailyCap)
    }

    @Test func isStaleRequiresNonEmptyDifferingDigests() {
        #expect(!LabelledPolicyDigestInForce.isStale(recordedDigest: nil, digestInForce: "a"))
        #expect(!LabelledPolicyDigestInForce.isStale(recordedDigest: "", digestInForce: "a"))
        #expect(!LabelledPolicyDigestInForce.isStale(recordedDigest: "a", digestInForce: nil))
        #expect(!LabelledPolicyDigestInForce.isStale(recordedDigest: "a", digestInForce: ""))
        #expect(!LabelledPolicyDigestInForce.isStale(recordedDigest: "a", digestInForce: "a"))
        #expect(LabelledPolicyDigestInForce.isStale(recordedDigest: "a", digestInForce: "b"))
    }

    @Test func credentialedAudioForcesLocal() {
        let (defaults, name) = defaults()
        defer { defaults.removePersistentDomain(forName: name) }
        let (preferences, _, policy) = configure(defaults)
        let input = RemoteLabellingInput(
            feedID: feedID, feedURL: feedURL, feedTitle: "Invented Garden Show",
            customTitle: nil,
            audioURL: URL(string: "https://cdn.example.invalid/e1.mp3?token=secret-token-value"),
            removeAds: true)
        #expect(LabelledPolicyDigestInForce.digest(
            policy: policy, input: input, preferences: preferences, hasKey: true) == nil)
    }
}
