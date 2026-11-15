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
        confirmed: Bool = true,
        hasKey: Bool = true,
        modelID: String = AdLabellerPreferences.defaultModelID,
        level: String = AdLabellerPreferences.defaultLevel,
        adFree: Bool = false,
        localOnly: Bool = false
    ) -> (AdLabellerPreferences, RemoteLabellingInput, PodcastPreparationPolicySnapshot) {
        let preferences = AdLabellerPreferences(preferences: defaults)
        preferences.isEnabled = enabled
        preferences.modelID = modelID
        preferences.level = level
        if confirmed { preferences.setConfirmed(feedID: feedID, true) }
        if localOnly { defaults.set([feedID], forKey: AdLabellerPreferences.keyPrefix + "localOnlyFeedIDs") }
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

    /// One setting for each not-sent reason, plus the stored "Mac only" list.
    enum NotSentSetup: String, CaseIterable, Sendable {
        case unknownAddress, signInDetails, privateToken, privateTitle, switchOff, noKey, notConfirmed, macOnly

        var reason: RemoteLabellingNotSent {
            switch self {
            case .unknownAddress: .unknownAddress
            case .signInDetails: .signInDetails
            case .privateToken: .privateToken
            case .privateTitle: .privateTitle
            case .switchOff: .switchOff
            case .noKey: .noKey
            case .notConfirmed, .macOnly: .notConfirmed
            }
        }
    }

    @Test(arguments: NotSentSetup.allCases)
    func everyNotSentReasonYieldsNil(setup: NotSentSetup) {
        let (defaults, name) = defaults()
        defer { defaults.removePersistentDomain(forName: name) }
        let (preferences, configured, policy) = configure(
            defaults, enabled: setup != .switchOff, confirmed: setup != .notConfirmed,
            hasKey: setup != .noKey, localOnly: setup == .macOnly)
        var input = configured
        switch setup {
        case .unknownAddress: input.feedURL = nil
        case .signInDetails: input.feedURL = URL(string: "https://feeds.example.invalid/show.xml?auth=invented")
        case .privateToken: input.feedURL = URL(string: "https://feeds.example.invalid/a1b2c3d4e5f6a7b8c9d0e1f2a3b4/show.xml")
        case .privateTitle: input.feedTitle = "Invented Members Show"
        case .switchOff, .noKey, .notConfirmed, .macOnly: break
        }
        let hasKey = setup != .noKey
        let context = RemoteLabellingContext(
            preferences: preferences, hasKey: hasKey, counter: LabellerRequestCounter(preferences: defaults))
        #expect(PodcastPreparationPipeline.labellingGate(input: input, context: context) == .notSent(setup.reason))
        #expect(LabelledPolicyDigestInForce.digest(
            policy: policy, input: input, preferences: preferences, hasKey: hasKey) == nil)
    }

    @Test(arguments: [true, false])
    func adRemovalOffOrAnAdFreeFeedYieldsNil(adFree: Bool) {
        let (defaults, name) = defaults()
        defer { defaults.removePersistentDomain(forName: name) }
        let (preferences, configured, configuredPolicy) = configure(defaults, adFree: adFree)
        var input = configured
        var policy = configuredPolicy
        if !adFree {
            policy = PodcastPreparationPolicySnapshot(transcriptPolicy: .bestAvailable, removeAds: false)
            input.removeAds = false
        }
        #expect(LabelledPolicyDigestInForce.digest(
            policy: policy, input: input, preferences: preferences, hasKey: true) == nil)
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
        let live = PodcastPreparationPipeline.labellingGate(
            input: input,
            context: RemoteLabellingContext(
                preferences: preferences, hasKey: true, counter: counter))
        #expect(live == .labelled(.dailyCap))
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
