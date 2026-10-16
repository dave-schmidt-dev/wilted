import Foundation
import XCTest
import WiltedDomain
@testable import WiltedProducer

extension LocalLibraryEpisodeIdentityReviewTests {
    func testReversalPreviewNamesInheritedKeepLossAndSkipThenRetiresExactMember() async throws {
        let url = makeURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = try LocalLibraryStore(url: url)
        let first = try episode(guid: "reversal-a")
        let second = try episode(guid: "reversal-b")
        for value in [first, second] { try await store.save(episode: value) }
        try await store.save(episodeDecision: EpisodeDecisionRecord(
            episodeID: first.itemID, decision: .keep, source: .manual, decidedAt: Timestamp(origin)
        ))
        let revision = try AudioRevision(
            itemID: second.itemID, revisionID: RevisionID(rawValue: "rev-reversal-b"),
            durationSeconds: 3_600, byteCount: 4_096,
            contentHash: "sha256:" + String(repeating: "b", count: 64),
            mediaType: "audio/mp4", createdAt: Timestamp(origin), schemaVersion: 3
        )
        let media = url.deletingLastPathComponent().appendingPathComponent("reversal-b.m4a")
        try Data(repeating: 3, count: Int(revision.byteCount)).write(to: media)
        try await store.finalizePodcastDownload(
            revision: revision, mediaURL: media,
            download: completedDownload(for: second, revision: revision, mediaURL: media)
        )
        let association = try await associate(first, second, in: store)

        // While associated, A's Keep protects B from a Skip rule.
        let ruleID = UUID()
        let protectedBefore = try await store.retireEpisodeBySkipRule(
            second.itemID, ruleID: ruleID, at: Timestamp(origin.addingTimeInterval(60))
        )
        XCTAssertFalse(protectedBefore)

        let preview = try await store.previewEpisodeAssociationReversal(
            association.associationID, expectedVersion: 1
        )
        let consequences = preview.consequences
        XCTAssertEqual(consequences.associationID, association.associationID)
        XCTAssertEqual(Set(consequences.memberIDs), [first.itemID, second.itemID])
        XCTAssertTrue(consequences.warnsAutomationMayRetire)
        let firstMember = try XCTUnwrap(consequences.members.first { $0.episodeID == first.itemID })
        let secondMember = try XCTUnwrap(consequences.members.first { $0.episodeID == second.itemID })
        for member in preview.consequences.members {
            let currentValue = try await store.podcastEpisodeLogicalState(for: member.episodeID)
            let current = try XCTUnwrap(currentValue)
            XCTAssertEqual(member.resolvedManualDecision, current.manualDecision)
        }
        XCTAssertEqual(firstMember.ownManualDecision, .keep)
        XCTAssertEqual(firstMember.resolvedManualDecision, .keep)
        XCTAssertFalse(firstMember.losesNewerResolvedOverride)
        XCTAssertFalse(firstMember.losesInheritedProtection)
        XCTAssertFalse(firstMember.losesInheritedSuppression)
        XCTAssertNil(secondMember.ownManualDecision)
        XCTAssertEqual(secondMember.resolvedManualDecision, .keep)
        XCTAssertFalse(secondMember.losesNewerResolvedOverride)
        XCTAssertTrue(secondMember.losesInheritedProtection)
        XCTAssertFalse(secondMember.losesInheritedSuppression)
        XCTAssertTrue(secondMember.hasDownloadRecord)

        let reversed = try await store.reverseEpisodeAssociation(preview)
        XCTAssertFalse(reversed.isActive)
        XCTAssertEqual(reversed.version, 2)

        // Reversal copied no choice onto B, so the warned consequence is real:
        // the next Skip rule retires exactly it, never the manual member.
        let retiredAfterReversal = try await store.retireEpisodeBySkipRule(
            second.itemID, ruleID: ruleID, at: Timestamp(origin.addingTimeInterval(90))
        )
        XCTAssertTrue(retiredAfterReversal)
        let protectedStill = try await store.retireEpisodeBySkipRule(
            first.itemID, ruleID: ruleID, at: Timestamp(origin.addingTimeInterval(90))
        )
        XCTAssertFalse(protectedStill)
        let retained = try await store.episodeDecision(for: second.itemID)
        XCTAssertEqual(retained?.source, .rule, "reversal never copied the manual Keep onto B")
    }

    /// The suppression side of the same rule: a group Skip silences a member
    /// that made no choice, and reversal lifts exactly that inheritance.
    func testReversalLiftsInheritedSkipSuppressionWithoutCopyingTheChoice() async throws {
        let url = makeURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = try LocalLibraryStore(url: url)
        let first = try episode(guid: "suppression-a")
        let second = try episode(guid: "suppression-b")
        for value in [first, second] { try await store.save(episode: value) }
        try await store.save(episodeDecision: EpisodeDecisionRecord(
            episodeID: first.itemID, decision: .skip, source: .manual, decidedAt: Timestamp(origin)
        ))
        let association = try await associate(first, second, in: store)
        let suppressedValue = try await store.podcastEpisodeLogicalState(for: second.itemID)
        let suppressed = try XCTUnwrap(suppressedValue)
        XCTAssertTrue(suppressed.isTerminal, "A's manual Skip suppresses B while associated")
        XCTAssertEqual(suppressed.manualDecision, .skip)

        let preview = try await store.previewEpisodeAssociationReversal(
            association.associationID, expectedVersion: 1
        )
        XCTAssertFalse(preview.consequences.warnsAutomationMayRetire)
        let secondMember = try XCTUnwrap(preview.consequences.members.first { $0.episodeID == second.itemID })
        for member in preview.consequences.members {
            let currentValue = try await store.podcastEpisodeLogicalState(for: member.episodeID)
            let current = try XCTUnwrap(currentValue)
            XCTAssertEqual(member.resolvedManualDecision, current.manualDecision)
        }
        XCTAssertTrue(secondMember.losesInheritedSuppression)
        XCTAssertFalse(secondMember.losesInheritedProtection)
        XCTAssertFalse(secondMember.losesNewerResolvedOverride)
        XCTAssertEqual(secondMember.resolvedManualDecision, .skip)

        _ = try await store.reverseEpisodeAssociation(preview)
        let releasedValue = try await store.podcastEpisodeLogicalState(for: second.itemID)
        let released = try XCTUnwrap(releasedValue)
        XCTAssertFalse(released.isTerminal, "reversal lifts the inherited suppression")
        XCTAssertNil(released.manualDecision)
        let copied = try await store.episodeDecision(for: second.itemID)
        XCTAssertNil(copied, "reversal copied no Skip onto the member that never chose")
    }

    func testReversalNamesNewerResolvedOverrideForAnOlderOpposingManualChoice() async throws {
        let url = makeURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = try LocalLibraryStore(url: url)
        let first = try episode(guid: "override-a")
        let second = try episode(guid: "override-b")
        for value in [first, second] { try await store.save(episode: value) }
        try await store.save(episodeDecision: EpisodeDecisionRecord(
            episodeID: second.itemID, decision: .skip, source: .manual, decidedAt: Timestamp(origin)
        ))
        try await store.save(episodeDecision: EpisodeDecisionRecord(
            episodeID: first.itemID, decision: .keep, source: .manual,
            decidedAt: Timestamp(origin.addingTimeInterval(60))
        ))
        let association = try await associate(first, second, in: store)

        // While associated, the newer Keep overrides B's older Skip.
        let groupedValue = try await store.podcastEpisodeLogicalState(for: second.itemID)
        let grouped = try XCTUnwrap(groupedValue)
        XCTAssertEqual(grouped.manualDecision, .keep)
        XCTAssertFalse(grouped.hasConflictingManualChoices)

        let preview = try await store.previewEpisodeAssociationReversal(
            association.associationID, expectedVersion: 1
        )
        XCTAssertFalse(preview.consequences.warnsAutomationMayRetire,
                       "B's own raw choice still protects it; no deletion warning")
        let firstMember = try XCTUnwrap(preview.consequences.members.first { $0.episodeID == first.itemID })
        let secondMember = try XCTUnwrap(preview.consequences.members.first { $0.episodeID == second.itemID })
        for member in preview.consequences.members {
            let currentValue = try await store.podcastEpisodeLogicalState(for: member.episodeID)
            let current = try XCTUnwrap(currentValue)
            XCTAssertEqual(member.resolvedManualDecision, current.manualDecision)
        }
        XCTAssertEqual(firstMember.ownManualDecision, .keep)
        XCTAssertEqual(firstMember.resolvedManualDecision, .keep)
        XCTAssertFalse(firstMember.losesNewerResolvedOverride)
        XCTAssertEqual(secondMember.ownManualDecision, .skip)
        XCTAssertEqual(secondMember.resolvedManualDecision, .keep)
        XCTAssertTrue(secondMember.losesNewerResolvedOverride)
        XCTAssertFalse(secondMember.losesInheritedProtection)
        XCTAssertFalse(secondMember.losesInheritedSuppression)

        _ = try await store.reverseEpisodeAssociation(preview)

        // B keeps its raw manual Skip; the newer resolved Keep is gone.
        let raw = try await store.episodeDecision(for: second.itemID)
        XCTAssertEqual(raw?.source, .manual)
        XCTAssertEqual(raw?.decision, .skip)
        let releasedValue = try await store.podcastEpisodeLogicalState(for: second.itemID)
        let released = try XCTUnwrap(releasedValue)
        XCTAssertEqual(released.manualDecision, .skip)

        // The raw manual protection itself survives: a later Skip rule is
        // refused exactly as it was before the association existed.
        let retired = try await store.retireEpisodeBySkipRule(
            second.itemID, ruleID: UUID(), at: Timestamp(origin.addingTimeInterval(90))
        )
        XCTAssertFalse(retired)
        let retainedRemoval = try await store.removalKind(for: second.itemID)
        XCTAssertNil(retainedRemoval)
    }
}
