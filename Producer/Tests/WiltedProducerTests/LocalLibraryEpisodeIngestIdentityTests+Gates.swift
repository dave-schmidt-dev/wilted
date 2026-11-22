import Foundation
import SwiftData
import XCTest
import WiltedDomain
@testable import WiltedProducer

/// The store-level guards that keep a flagged lookalike untouched by rules and
/// policy until the owner answers.
extension LocalLibraryEpisodeIngestIdentityTests {
    private func flaggedPair(_ store: LocalLibraryStore) async throws -> (old: PodcastEpisode, flagged: PodcastEpisode) {
        let old = try episode(guid: "gate-old", enclosure: "https://cdn.example.test/gate-old.mp3")
        let flagged = try episode(
            guid: "gate-new", enclosure: "https://cdn.example.test/gate-new.mp3", duration: 3_602
        )
        try await store.save(episode: old)
        _ = try await store.admitPodcastEpisodes([flagged], admission: .incremental, claimingNewest: 5)
        let held = try await store.podcastEpisodeIdentityReviewHeldIDs(in: old.feedID)
        XCTAssertEqual(held, [flagged.itemID])
        return (old, flagged)
    }

    func testRuleAndPolicyAdmissionRefuseAFlaggedEpisodeUntilTheOwnerAnswers() async throws {
        let store = try makeStore()
        let (_, flagged) = try await flaggedPair(store)
        let decidedAt = Timestamp(origin.addingTimeInterval(500))

        for source in [EpisodeDecisionSource.rule, .policy] {
            do {
                _ = try await store.admitEpisode(
                    EpisodeDecisionRecord(episodeID: flagged.itemID, decision: .keep, source: source,
                                          decidedAt: decidedAt),
                    workTicketKinds: [.podcastDownload]
                )
                XCTFail("\(source) admission must not touch a flagged episode")
            } catch { XCTAssertEqual(error as? AutomaticEpisodeAdmissionError, .possibleDuplicateHeld) }
        }
        let refused = try await store.episodeDecision(for: flagged.itemID)
        XCTAssertNil(refused, "a refused admission writes no decision, queue row or ticket")

        // The owner's own Keep is never blocked by the flag.
        _ = try await store.admitEpisode(EpisodeDecisionRecord(
            episodeID: flagged.itemID, decision: .keep, source: .manual, decidedAt: decidedAt
        ))
        let manual = try await store.episodeDecision(for: flagged.itemID)
        XCTAssertEqual(manual?.source, .manual)
    }

    func testSkipRuleLeavesAFlaggedEpisodeUntilItIsCleared() async throws {
        let store = try makeStore()
        let (_, flagged) = try await flaggedPair(store)

        let whileFlagged = try await store.retireEpisodeBySkipRule(flagged.itemID, ruleID: UUID())
        let removalWhileFlagged = try await store.removalKind(for: flagged.itemID)
        XCTAssertFalse(whileFlagged)
        XCTAssertNil(removalWhileFlagged)

        let cleared = try await store.clearPodcastEpisodePossibleDuplicate(flagged.itemID)
        let afterClear = try await store.retireEpisodeBySkipRule(flagged.itemID, ruleID: UUID())
        XCTAssertTrue(cleared)
        XCTAssertTrue(afterClear, "once the owner says it is different, rules apply as usual")
    }

    func testOneUnreadableFlagDoesNotHideTheOthersAndStillHoldsItsEpisode() async throws {
        let store = try makeStore()
        let (old, flagged) = try await flaggedPair(store)
        let second = try episode(
            guid: "gate-second", enclosure: "https://cdn.example.test/gate-second.mp3",
            title: "Another show title", duration: 1_800
        )
        let secondTwin = try episode(
            guid: "gate-second-twin", enclosure: "https://cdn.example.test/gate-second-twin.mp3",
            title: "Another show title", duration: 1_801
        )
        try await store.save(episode: second)
        _ = try await store.admitPodcastEpisodes([secondTwin], admission: .incremental, claimingNewest: 5)

        let context = ModelContext(store.container)
        let records = try context.fetch(
            FetchDescriptor<LocalLibrarySchemaV20Models.EpisodeAssociationRecord>()
        )
        let victim = try XCTUnwrap(records.first { $0.representativeID == flagged.itemID.rawValue })
        victim.evidence = Data("not json".utf8)
        try context.save()

        let readable = try await store.readablePodcastPossibleDuplicateFlags()
        let held = try await store.podcastEpisodeIdentityReviewHeldIDs(in: old.feedID)
        let claim = try await store.claimPodcastDownload(episodeID: flagged.itemID, scope: .untouched)

        XCTAssertEqual(readable.map(\.incomingID), [secondTwin.itemID], "the readable flag still shows")
        XCTAssertEqual(held, [flagged.itemID, secondTwin.itemID], "the unreadable one stays held")
        XCTAssertFalse(claim)
    }
}
