import Foundation
import XCTest
@testable import WiltedProducer

final class FeedAdmissionPlannerTests: XCTestCase {
    func testAtLimitWaitsAndFreedSlotKeepsOldestWaitingCandidateFirst() {
        let policy = EffectiveFeedAutomationPolicy(
            autoKeep: true, autoDownload: false, autoPrepare: true, keptLimit: 2
        )
        let older = candidate("older", day: 1)
        let newer = candidate("newer", day: 2)

        let atLimit = FeedAdmissionPlanner.plan(
            candidates: [newer, older], keptEpisodeIDs: ["kept-1", "kept-2"],
            playingEpisodeID: nil, partHeardEpisodeIDs: [], manualDecisions: [:], policy: policy
        )
        XCTAssertEqual(atLimit.map(\.outcome), [.wait, .wait])
        XCTAssertEqual(atLimit.map(\.candidate.id), ["older", "newer"])

        let oneSlotFree = FeedAdmissionPlanner.plan(
            candidates: [newer, older], keptEpisodeIDs: ["kept-1"],
            playingEpisodeID: nil, partHeardEpisodeIDs: [], manualDecisions: [:], policy: policy
        )
        XCTAssertEqual(oneSlotFree.map(\.outcome), [.keepNow, .wait])
        XCTAssertEqual(oneSlotFree.map(\.candidate.id), ["older", "newer"])
    }

    func testNeverReturnsRemovalOrTouchesProtectedOrManualCandidates() {
        let policy = EffectiveFeedAutomationPolicy(
            autoKeep: true, autoDownload: false, autoPrepare: true, keptLimit: 1
        )
        let candidates = [candidate("playing", day: 1), candidate("part-heard", day: 2),
                          candidate("manual-keep", day: 3), candidate("manual-skip", day: 4),
                          candidate("eligible", day: 5)]
        let decisions = FeedAdmissionPlanner.plan(
            candidates: candidates, keptEpisodeIDs: ["kept-1", "kept-2"],
            playingEpisodeID: "playing", partHeardEpisodeIDs: ["part-heard"],
            manualDecisions: ["manual-keep": .keep, "manual-skip": .skip], policy: policy
        )

        XCTAssertEqual(decisions.map(\.candidate.id), ["eligible"])
        XCTAssertEqual(decisions.map(\.outcome), [.wait])
    }

    func testOverridesResolveEachFlagAndKeptLimit() {
        XCTAssertEqual(FeedAutomationGlobalDefaults.standard,
                       FeedAutomationGlobalDefaults(autoKeep: false, autoDownload: false,
                                                    autoPrepare: true, keptLimit: nil))
        let defaults = FeedAutomationGlobalDefaults(
            autoKeep: false, autoDownload: true, autoPrepare: false, keptLimit: 8
        )
        XCTAssertEqual(FeedAutomationPolicy().resolved(using: defaults),
                       EffectiveFeedAutomationPolicy(autoKeep: false, autoDownload: true,
                                                      autoPrepare: false, keptLimit: 8))
        XCTAssertEqual(FeedAutomationPolicy(autoKeep: .on, autoDownload: .off, autoPrepare: .on)
            .resolved(using: defaults),
            EffectiveFeedAutomationPolicy(autoKeep: true, autoDownload: false, autoPrepare: true, keptLimit: 8))
        XCTAssertEqual(FeedAutomationPolicy(autoKeep: .off, autoDownload: .on, autoPrepare: .off,
                                            keptLimit: .explicit(3)).resolved(using: defaults),
                       EffectiveFeedAutomationPolicy(autoKeep: false, autoDownload: true,
                                                      autoPrepare: false, keptLimit: 3))
    }

    private func candidate(_ id: String, day: TimeInterval) -> FeedAdmissionCandidate {
        FeedAdmissionCandidate(id: id, releaseDate: Date(timeIntervalSince1970: day))
    }
}
