import Foundation
import Testing
import WiltedDomain
@testable import WiltedProducer

extension PodcastPreparationPipelineTests {
    enum FeedPolicyScenario: String, CaseIterable, Sendable {
        case adFreeConfirmedPublic
        case ownPromotionOnWhileAdFree
        case confirmedAndKeptBack
        case keptBackUntilConfirmed
        case missingFeedRecord
        case newFeed
        case confirmedPublicControl

        var feedTitle: String? { self == .missingFeedRecord ? nil : Fixture.labelledShowTitle }

        var adFree: Bool {
            self == .adFreeConfirmedPublic || self == .ownPromotionOnWhileAdFree
        }

        var confirmed: Bool {
            switch self {
            case .keptBackUntilConfirmed, .newFeed: false
            default: true
            }
        }

        var keptBack: Bool {
            self == .confirmedAndKeptBack || self == .keptBackUntilConfirmed
        }

        var ownPromotionPreference: Bool { self == .ownPromotionOnWhileAdFree }

        var admittedRemoveAds: Bool { self != .ownPromotionOnWhileAdFree }

        var sendsRemotely: Bool { self == .confirmedPublicControl || self == .missingFeedRecord }

        var notSentReason: RemoteLabellingNotSent? {
            switch self {
            case .confirmedAndKeptBack, .keptBackUntilConfirmed, .newFeed:
                .notConfirmed
            case .adFreeConfirmedPublic, .ownPromotionOnWhileAdFree, .confirmedPublicControl, .missingFeedRecord:
                nil
            }
        }
    }

    private struct SavedConsent: Equatable {
        let confirmed: [String]?
        let keptBack: [String]?
        let adFree: [String]?
        let ownPromotion: [String]?
    }

    private func savedConsent(in defaults: UserDefaults) -> SavedConsent {
        SavedConsent(
            confirmed: defaults.stringArray(forKey: AdLabellerPreferences.keyPrefix + "confirmedFeedIDs"),
            keptBack: defaults.stringArray(forKey: AdLabellerPreferences.keyPrefix + "localOnlyFeedIDs"),
            adFree: defaults.stringArray(forKey: AdLabellerPreferences.adFreeFeedsKey),
            ownPromotion: defaults.stringArray(forKey: "wilted.feeds.removeSelfPromotion"))
    }

    private func seedConsent(
        in defaults: UserDefaults,
        feedID: String,
        scenario: FeedPolicyScenario
    ) {
        let confirmedKey = AdLabellerPreferences.keyPrefix + "confirmedFeedIDs"
        let keptBackKey = AdLabellerPreferences.keyPrefix + "localOnlyFeedIDs"
        if scenario.confirmed {
            defaults.set([feedID], forKey: confirmedKey)
        } else {
            defaults.removeObject(forKey: confirmedKey)
        }
        if scenario.keptBack {
            defaults.set([feedID], forKey: keptBackKey)
        } else {
            defaults.removeObject(forKey: keptBackKey)
        }
        if scenario.adFree {
            defaults.set([feedID], forKey: AdLabellerPreferences.adFreeFeedsKey)
        } else {
            defaults.removeObject(forKey: AdLabellerPreferences.adFreeFeedsKey)
        }
        let ownPromotionKey = "wilted.feeds.removeSelfPromotion"
        if scenario.ownPromotionPreference {
            defaults.set([feedID], forKey: ownPromotionKey)
        } else {
            defaults.removeObject(forKey: ownPromotionKey)
        }
    }

    private func workerForParity(
        scenario: FeedPolicyScenario,
        audioURL: URL
    ) -> WorkerStub {
        if scenario.sendsRemotely {
            return WorkerStub(response: Fixture.cuttingStubResponse(), writesCutAudio: Fixture.cuttingAudio)
        }
        return WorkerStub(response: [
            "ok": true, "timing": "none", "audioPath": audioURL.path, "audioChanged": false
        ])
    }

    private func decodedRequests(_ worker: WorkerStub) async throws -> [[String: Any]] {
        try await worker.allRequests().map {
            try #require(try JSONSerialization.jsonObject(with: $0) as? [String: Any])
        }
    }

    private func assertWorkerRoute(
        _ requests: [[String: Any]],
        sendsRemotely: Bool
    ) throws {
        if sendsRemotely {
            #expect(requests.map { $0["adStage"] as? String } == ["transcript", "cut"])
            #expect(requests.allSatisfy { $0["removeAds"] as? Bool == true })
        } else {
            #expect(requests.count == 1)
            let request = try #require(requests.first)
            #expect(request["adStage"] == nil)
            #expect(request["removeAds"] as? Bool == false)
        }
        #expect(requests.allSatisfy { $0["removeSelfPromotion"] == nil })
    }

    @Test(arguments: FeedPolicyScenario.allCases)
    func savedFeedPolicyAndWorkerRouteStayInParityThroughPrepareAndPrepareAgain(
        scenario: FeedPolicyScenario
    ) async throws {
        let fixture = try await Fixture(
            labelled: true,
            showTitle: scenario.feedTitle)
        defer { fixture.remove() }

        let services = try #require(fixture.labelling)
        let episode = try #require(try await fixture.store.podcastEpisode(for: fixture.episodeID))
        let feedID = episode.feedID.rawValue
        seedConsent(in: services.preferences.preferences, feedID: feedID, scenario: scenario)
        var policy = PodcastPreparationPolicySnapshot(
            transcriptPolicy: .bestAvailable,
            removeAds: scenario.admittedRemoveAds,
            removeSelfPromotion: false)
        let oldEngine = Self.olderEngine

        // This queued job retains the old admission snapshot. Marking the show
        // ad-free while it waits must still keep it out of remote ad finding.
        var oldJobAttempt: PreparationAttemptIdentity?
        if scenario == .adFreeConfirmedPublic {
            services.preferences.preferences.removeObject(forKey: AdLabellerPreferences.adFreeFeedsKey)
            let snapshot = try JSONEncoder().encode(policy)
            let now = Timestamp(Date(timeIntervalSince1970: 1_700_000_150))
            let queued = try await fixture.store.issueWorkTicket(
                kind: .podcastPreparation,
                subjectID: fixture.episodeID.rawValue,
                resolvedItemID: fixture.episodeID.rawValue,
                policySnapshot: snapshot,
                requestedAt: now)
            services.preferences.preferences.set([feedID], forKey: AdLabellerPreferences.adFreeFeedsKey)
            let running = try await fixture.store.applyWorkTicketTransition(
                kind: .podcastPreparation,
                subjectID: fixture.episodeID.rawValue,
                requestSequence: queued.requestSequence,
                resolvedItemID: fixture.episodeID.rawValue,
                to: .running,
                at: now)
            let storedSnapshot = try #require(running.policySnapshot)
            policy = try JSONDecoder().decode(PodcastPreparationPolicySnapshot.self, from: storedSnapshot)
            #expect(policy.removeAds)
            oldJobAttempt = try PreparationAttemptIdentity(
                requestSequence: running.requestSequence,
                attemptCount: running.attemptCount)
        }
        let consentBefore = savedConsent(in: services.preferences.preferences)

        let initialWorker = workerForParity(scenario: scenario, audioURL: fixture.audioURL)
        let initialPipeline = fixture.pipeline(initialWorker, engineVersion: oldEngine)
        let initialRoute = await initialPipeline.labelledAttemptRoute(episode: episode, policy: policy)
        #expect((initialRoute.routing != nil) == scenario.sendsRemotely)
        #expect(initialRoute.notSent == scenario.notSentReason)

        let initialResult = try await initialPipeline.prepare(
            episodeID: fixture.episodeID,
            policy: policy,
            attempt: oldJobAttempt)
        let firstRequests = try await decodedRequests(initialWorker)
        try assertWorkerRoute(firstRequests, sendsRemotely: scenario.sendsRemotely)
        #expect(fixture.sender?.requestCount == (scenario.sendsRemotely ? 1 : 0))
        #expect(savedConsent(in: services.preferences.preferences) == consentBefore)
        #expect(services.preferences.keptBackFeedIDs == (scenario.keptBack ? [feedID] : []))
        #expect(services.preferences.confirmedFeedIDs == (scenario.confirmed && !scenario.keptBack ? [feedID] : []))

        if scenario.sendsRemotely {
            #expect(initialResult.adRemovalOutcome == "cut")
            #expect(try Data(contentsOf: initialResult.mediaURL) == Fixture.cuttingAudio)
        } else if scenario.adFree {
            #expect(initialResult.adRemovalOutcome == "disabled")
            #expect(try Data(contentsOf: initialResult.mediaURL) == Fixture.originalBody)
        } else {
            #expect(initialResult.adRemovalOutcome == "uncertain")
            #expect(initialResult.warning == scenario.notSentReason?.warning)
            #expect(try Data(contentsOf: initialResult.mediaURL) == Fixture.originalBody)
        }

        let candidate = try #require(try await fixture.store.podcastEpisodesToPrepareAgain().first)
        let staged = try fixture.staged(Fixture.originalBody)
        let repeatWorker = workerForParity(scenario: scenario, audioURL: staged.url)
        let repeatPipeline = fixture.pipeline(repeatWorker)
        let currentPolicy = PodcastPreparationPolicySnapshot(
            transcriptPolicy: .bestAvailable, removeAds: !scenario.adFree, removeSelfPromotion: false)
        let repeatRoute = await repeatPipeline.labelledAttemptRoute(episode: episode, policy: currentPolicy)
        #expect((repeatRoute.routing != nil) == scenario.sendsRemotely)
        #expect(repeatRoute.notSent == scenario.notSentReason)

        let repeatOutcome = try await repeatPipeline.prepareAgain(
            candidate: candidate,
            stage: { staged },
            policy: currentPolicy)
        let repeatRequests = try await decodedRequests(repeatWorker)
        try assertWorkerRoute(repeatRequests, sendsRemotely: scenario.sendsRemotely)
        #expect(fixture.sender?.requestCount == (scenario.sendsRemotely ? 2 : 0))
        #expect(savedConsent(in: services.preferences.preferences) == consentBefore)

        if scenario.sendsRemotely {
            guard case .prepared(let result) = repeatOutcome else {
                Issue.record("the confirmed public control should prepare again")
                return
            }
            #expect(result.adRemovalOutcome == "cut")
            #expect(try Data(contentsOf: result.mediaURL) == Fixture.cuttingAudio)
        } else if scenario.adFree {
            guard case .prepared(let result) = repeatOutcome else {
                Issue.record("an ad-free show should take the plain Prepare Again path")
                return
            }
            #expect(result.adRemovalOutcome == "disabled")
            #expect(try Data(contentsOf: result.mediaURL) == Fixture.originalBody)
        } else {
            guard case .keptExisting = repeatOutcome else {
                Issue.record("an excluded show should keep its existing audio")
                return
            }
            #expect(try Data(contentsOf: candidate.readyRevision.mediaURL) == Fixture.originalBody)
        }
    }
}
