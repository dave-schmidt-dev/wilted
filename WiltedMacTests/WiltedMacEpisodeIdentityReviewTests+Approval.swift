import AppKit
import Foundation
import SwiftUI
import WiltedDomain
import WiltedLibrary
import WiltedProducer
import XCTest
@testable import WiltedMac

@MainActor
extension WiltedMacEpisodeIdentityReviewTests {
    // MARK: - Explicit confirmation and captured consequences

    func testApplicationWithoutExplicitOwnerActionReturnsRefusal() async throws {
        let fixture = try await makeFixture("refusal")
        // A genuine third metadata twin exercises discovery without consent.
        try await fixture.store.save(episode: try episode(guid: "review-third", title: "Review First"))
        try await seedKeptAndCompleted(fixture)
        let review = makeReview(fixture)
        await review.load()
        XCTAssertEqual(review.stage, .ready)

        // No pair, no confirmation, no apply.
        await review.applyAssociation()
        XCTAssertEqual(review.errorMessage, WiltedMacEpisodeIdentityReviewModel.confirmationRequiredMessage)
        await review.reviewPair()
        XCTAssertEqual(review.errorMessage, WiltedMacEpisodeIdentityReviewModel.confirmationRequiredMessage)
        var associations = try await fixture.store.episodeAssociations()
        XCTAssertTrue(associations.isEmpty)

        // An explicit pair alone still has no captured preview to apply.
        await review.selectPair(
            first: fixture.first.rawValue, second: fixture.second.rawValue,
            representative: fixture.first.rawValue
        )
        XCTAssertNotNil(review.comparison)
        XCTAssertEqual(review.comparison?.ambiguities.contains(.metadataDiffers), true)
        XCTAssertEqual(review.comparison?.ambiguities.contains(.otherMetadataCandidates), true)
        XCTAssertEqual(review.comparison?.otherCandidateIDs, [fixture.third])
        XCTAssertNil(review.approvalPreview)
        associations = try await fixture.store.episodeAssociations()
        XCTAssertTrue(associations.isEmpty, "comparison writes nothing")
        await review.applyAssociation()
        XCTAssertEqual(review.errorMessage, WiltedMacEpisodeIdentityReviewModel.confirmationRequiredMessage)
        associations = try await fixture.store.episodeAssociations()
        XCTAssertTrue(associations.isEmpty)
    }

    func testCapturedConsequencesMatchApprovalTextAndApplyPreservesRawState() async throws {
        let fixture = try await makeFixture("consequences")
        try await seedKeptAndCompleted(fixture)
        let review = makeReview(fixture)
        await review.load()
        await review.selectPair(
            first: fixture.first.rawValue, second: fixture.second.rawValue,
            representative: fixture.first.rawValue
        )
        await review.reviewPair()
        let preview = try XCTUnwrap(review.approvalPreview)
        let consequences = preview.approvalConsequences
        XCTAssertTrue(consequences.isTerminal)
        XCTAssertFalse(consequences.isAdmissionEligible)
        XCTAssertFalse(consequences.isDownloadEligible)
        XCTAssertFalse(consequences.isLarderRowVisible)
        XCTAssertEqual(consequences.winningDecision, .keep)

        // Preparing the preview writes nothing.
        var associations = try await fixture.store.episodeAssociations()
        XCTAssertTrue(associations.isEmpty)

        let summary = review.approvalSummary
        XCTAssertTrue(summary.contains("counts as one finished or suppressed episode"), summary)
        XCTAssertTrue(summary.contains("newest manual choice is Keep"), summary)
        XCTAssertTrue(summary.contains("holds queue slot 1 and is current"), summary)
        XCTAssertTrue(summary.contains("the duplicate-group rule refuses a new automatic download"), summary)
        XCTAssertTrue(summary.contains("Review Second"), summary)
        XCTAssertTrue(summary.contains("stored copy kept, has a download record"), summary)
        XCTAssertFalse(summary.contains("untouched"), "implementation jargon stays out of the listener text")

        await review.applyAssociation()
        XCTAssertEqual(review.errorMessage, nil)
        XCTAssertNotNil(review.message)
        associations = try await fixture.store.episodeAssociations()
        XCTAssertEqual(associations.count, 1)
        XCTAssertNotNil(review.activeAssociation, "the reload shows the new association")
        // The parent model's own projection refreshed without a manual reload.
        XCTAssertEqual(fixture.model.episodeAssociations[fixture.second.rawValue]?.groupID,
                       associations[0].associationID)

        // A second Apply has nothing left to apply and must not duplicate.
        await review.applyAssociation()
        associations = try await fixture.store.episodeAssociations()
        XCTAssertEqual(associations.count, 1)
    }

    func testStaleCapturedPreviewIsDiscardedAndNothingIsApplied() async throws {
        let fixture = try await makeFixture("stale")
        try await seedKeptAndCompleted(fixture)
        let review = makeReview(fixture)
        await review.load()
        await review.selectPair(
            first: fixture.first.rawValue, second: fixture.second.rawValue,
            representative: fixture.first.rawValue
        )
        await review.reviewPair()
        XCTAssertNotNil(review.approvalPreview)

        // A newer owner choice lands between review and apply.
        try await fixture.store.save(episodeDecision: EpisodeDecisionRecord(
            episodeID: fixture.second, decision: .keep, source: .manual,
            decidedAt: Timestamp(created.addingTimeInterval(120))
        ))
        await review.applyAssociation()
        XCTAssertEqual(review.errorMessage, WiltedMacEpisodeIdentityReviewModel.staleReviewMessage)
        XCTAssertNil(review.approvalPreview, "a stale capture must be reviewed again")
        let associations = try await fixture.store.episodeAssociations()
        XCTAssertTrue(associations.isEmpty)
    }

    // MARK: - Superseded and committed commits

    func testApplySupersededBeforeItsStoreWriteIsAbandoned() async throws {
        let fixture = try await makeFixture("apply-abandoned")
        let review = makeReview(fixture)
        await review.load()
        await review.selectPair(
            first: fixture.first.rawValue, second: fixture.second.rawValue,
            representative: fixture.first.rawValue
        )
        await review.reviewPair()
        XCTAssertNotNil(review.approvalPreview)

        let gate = ReviewGate()
        defer { Task { await gate.release() } }
        review.applyHookForTesting = { await gate.pause() }
        let apply = Task { await review.applyAssociation() }
        try await waitFor("review hook entered") { await gate.hasEntered }
        // The owner changes the pair while the commit is still parked before
        // its store write: the commit is abandoned.
        review.setVisibleCandidate(fixture.third.rawValue)
        await gate.release()
        await apply.value
        let associations = try await fixture.store.episodeAssociations()
        XCTAssertTrue(associations.isEmpty, "an abandoned commit writes nothing")
        XCTAssertNil(review.activity)
    }

    func testCommittedApplyAfterDismissalStillReportsAndRefreshesParentProjection() async throws {
        let fixture = try await makeFixture("apply-committed")
        let review = makeReview(fixture)
        await review.load()
        await review.selectPair(
            first: fixture.first.rawValue, second: fixture.second.rawValue,
            representative: fixture.first.rawValue
        )
        await review.reviewPair()

        let gate = ReviewGate()
        defer { Task { await gate.release() } }
        review.commitLandedHookForTesting = { await gate.pause() }
        let apply = Task { await review.applyAssociation() }
        try await waitFor("review hook entered") { await gate.hasEntered }
        // The store write has already committed when the hook parks.
        var associations = try await fixture.store.episodeAssociations()
        XCTAssertEqual(associations.count, 1)

        // The sheet closes while the commit is reporting. Cancellation cannot
        // undo the committed write, and the model must not claim it did.
        review.invalidatePendingReads()
        await gate.release()
        await apply.value
        XCTAssertNotNil(review.message, "a committed write is still reported")
        associations = try await fixture.store.episodeAssociations()
        XCTAssertEqual(associations.count, 1)
        XCTAssertEqual(fixture.model.episodeAssociations[fixture.second.rawValue]?.groupID,
                       associations[0].associationID,
                       "the parent projection refreshed even after dismissal")
        XCTAssertNil(review.activity)
    }

    // MARK: - Presentation agreement with the real Larder projection

    func testPresentationAgreesWithActualLarderProjectionForPositiveTerminalAndRemovedFixtures() async throws {
        // Positive: nothing terminal, nothing removed.
        let positive = try await makeFixture("projection-positive")
        let positiveReview = makeReview(positive)
        await positiveReview.load()
        await positiveReview.selectPair(
            first: positive.first.rawValue, second: positive.second.rawValue,
            representative: positive.first.rawValue
        )
        await positiveReview.reviewPair()
        XCTAssertTrue(positiveReview.approvalSummary.contains("shows that row even if one stored copy was retired"),
                      positiveReview.approvalSummary)
        await positiveReview.applyAssociation()
        XCTAssertEqual(positiveReview.errorMessage, nil)
        XCTAssertEqual(
            larderRows(positive, of: [positive.first, positive.second]).map(\.id),
            [positive.first.rawValue],
            "the active pair projects exactly one row at the representative"
        )

        // Terminal: second completed, so the group row is hidden whole.
        let terminal = try await makeFixture("projection-terminal")
        try await seedKeptAndCompleted(terminal)
        let terminalReview = makeReview(terminal)
        await terminalReview.load()
        await terminalReview.selectPair(
            first: terminal.first.rawValue, second: terminal.second.rawValue,
            representative: terminal.first.rawValue
        )
        await terminalReview.reviewPair()
        XCTAssertTrue(terminalReview.approvalSummary.contains("does not show that row"),
                      terminalReview.approvalSummary)
        XCTAssertFalse(terminalReview.approvalSummary.contains("will show one row"),
                       terminalReview.approvalSummary)
        await terminalReview.applyAssociation()
        XCTAssertEqual(terminalReview.errorMessage, nil)
        XCTAssertTrue(larderRows(terminal, of: [terminal.first, terminal.second]).isEmpty)

        let absent = try await makeFixture("projection-all-removed")
        for id in [absent.first, absent.second] {
            try await absent.store.retireEpisode(id, at: Timestamp(created.addingTimeInterval(10)))
        }
        try await absent.store.save(episodeDecision: EpisodeDecisionRecord(
            episodeID: absent.first, decision: .keep, source: .manual,
            decidedAt: Timestamp(created.addingTimeInterval(20))
        ))
        let absentReview = makeReview(absent)
        await absentReview.load()
        await absentReview.selectPair(
            first: absent.first.rawValue, second: absent.second.rawValue,
            representative: absent.first.rawValue
        )
        await absentReview.reviewPair()
        XCTAssertTrue(absentReview.approvalSummary.contains("Larder shows no row"), absentReview.approvalSummary)
        XCTAssertFalse(absentReview.approvalSummary.contains("will show one row"), absentReview.approvalSummary)
        await absentReview.applyAssociation()
        XCTAssertTrue(larderRows(absent, of: [absent.first, absent.second]).isEmpty)

        // Removed member: the representative's raw copy was retired, but the
        // newer Keep keeps the group active and the Larder row survives.
        let removed = try await makeFixture("projection-removed")
        try await removed.store.retireEpisode(
            removed.second, at: Timestamp(created.addingTimeInterval(10))
        )
        try await removed.store.save(episodeDecision: EpisodeDecisionRecord(
            episodeID: removed.first, decision: .keep, source: .manual,
            decidedAt: Timestamp(created.addingTimeInterval(20))
        ))
        await removed.model.reloadLibraryRows()
        let removedReview = makeReview(removed)
        await removedReview.load()
        await removedReview.selectPair(
            first: removed.first.rawValue, second: removed.second.rawValue,
            representative: removed.second.rawValue
        )
        await removedReview.reviewPair()
        let summary = removedReview.approvalSummary
        XCTAssertTrue(summary.contains("shows that row even if one stored copy was retired or dismissed"), summary)
        XCTAssertTrue(summary.contains("\(removedReview.pickerLabel(for: removed.second.rawValue)): stored copy was retired or dismissed"), summary)
        await removedReview.applyAssociation()
        XCTAssertEqual(removedReview.errorMessage, nil)
        let rows = larderRows(removed, of: [removed.first, removed.second])
        XCTAssertEqual(rows.map(\.id), [removed.second.rawValue],
                       "the row is revived at the removed representative while the pair is active")
        XCTAssertNil(rows.first?.retiredAt)
        let rawRemoval = try await removed.store.removalKind(for: removed.second)
        XCTAssertEqual(rawRemoval, .retired, "the raw removal is preserved, only the logical row revives")
    }

    // MARK: - Explicit reversal

    func testReversalRequiresItsOwnReviewAndNamesEachMemberBeforeReversing() async throws {
        let fixture = try await makeFixture("reversal", sameTitle: true)
        try await fixture.store.save(episodeDecision: EpisodeDecisionRecord(
            episodeID: fixture.first, decision: .keep, source: .manual, decidedAt: Timestamp(created)
        ))
        let association = try await associate(first: fixture.first, second: fixture.second, in: fixture.store)
        let review = makeReview(fixture)
        await review.load()
        XCTAssertEqual(review.activeAssociation?.associationID, association.associationID)

        // Reversal without its own review is refused.
        await review.applyReversal()
        XCTAssertEqual(review.errorMessage, WiltedMacEpisodeIdentityReviewModel.reversalRequiredMessage)
        let stillActive = try await fixture.store.episodeAssociations()
        XCTAssertEqual(stillActive.count, 1)

        await review.reviewReversal()
        let reversal = try XCTUnwrap(review.reversalPreview)
        XCTAssertTrue(reversal.consequences.warnsAutomationMayRetire)
        let summary = review.reversalSummary
        let secondLabel = review.pickerLabel(for: fixture.second.rawValue)
        XCTAssertNotEqual(secondLabel, review.pickerLabel(for: fixture.first.rawValue))
        XCTAssertTrue(summary.contains("\(secondLabel) has no Keep of its own and loses the pair's inherited protection"), summary)
        XCTAssertTrue(summary.contains("Later feed automation may retire it and delete its unprotected media"), summary)
        XCTAssertTrue(summary.contains("\(review.pickerLabel(for: fixture.first.rawValue)) keeps its own manual choice"), summary)

        // The reversal preview alone changes nothing.
        let beforeReversal = try await fixture.store.episodeAssociations()
        XCTAssertEqual(beforeReversal.count, 1)
        await review.applyReversal()
        XCTAssertEqual(review.errorMessage, nil)
        XCTAssertNotNil(review.message)
        let active = try await fixture.store.episodeAssociations()
        XCTAssertTrue(active.isEmpty)
        let history = try await fixture.store.episodeAssociations(includingReversed: true)
        XCTAssertEqual(history.map(\.associationID), [association.associationID])
        XCTAssertFalse(try XCTUnwrap(history.first).isActive)
        XCTAssertNil(review.activeAssociation, "the reload shows the reversal")
        XCTAssertTrue(fixture.model.episodeAssociations.isEmpty,
                      "the parent projection withdrew the reversed association")
    }

    /// A newer group Keep over an older opposing manual Skip: reversal names
    /// the resolved change and never claims automation may delete a member
    /// whose own manual choice still protects it.
    func testReversalSummaryNamesNewerResolvedOverrideForAnOlderOpposingChoice() async throws {
        let fixture = try await makeFixture("reversal-override")
        try await fixture.store.save(episodeDecision: EpisodeDecisionRecord(
            episodeID: fixture.second, decision: .skip, source: .manual, decidedAt: Timestamp(created)
        ))
        try await fixture.store.save(episodeDecision: EpisodeDecisionRecord(
            episodeID: fixture.first, decision: .keep, source: .manual,
            decidedAt: Timestamp(created.addingTimeInterval(60))
        ))
        _ = try await associate(first: fixture.first, second: fixture.second, in: fixture.store)
        let review = makeReview(fixture)
        await review.load()
        await review.reviewReversal()
        let reversal = try XCTUnwrap(review.reversalPreview)
        XCTAssertFalse(reversal.consequences.warnsAutomationMayRetire)
        let summary = review.reversalSummary
        XCTAssertTrue(summary.contains("\(review.pickerLabel(for: fixture.second.rawValue)) keeps its own earlier Skip"), summary)
        XCTAssertTrue(summary.contains("the pair's newer Keep no longer applies"), summary)
        XCTAssertTrue(summary.contains("still shields it from automatic rules"), summary)
        XCTAssertFalse(summary.contains("delete its unprotected media"), summary)
    }

    // MARK: - Parent publication through the existing debounced publisher

    func testApplyAndReversalFlowThroughTheExistingDebouncedPublisher() async throws {
        let model = makeModel("sync")
        addTeardownBlock { await model.close() }
        model.startStoreBootstrap()
        await model.waitForStoreBootstrap()
        let store = try XCTUnwrap(model.store)
        // The first owner binds an empty library; seed after the gate opens.
        let device = model.libraryDeviceID()
        let server = InMemoryLibraryServer(writerDeviceID: device)
        let account = WiltedMacLibraryAccountFixture()
        XCTAssertTrue(model.startLibrarySyncIfEnabled(
            environment: ["WILTED_LIBRARY_SYNC": "1"],
            transport: InMemoryLibraryTransport(deviceID: device, server: server),
            debounce: .milliseconds(20), account: account.source
        ))
        account.signIn(recordName: "review-owner")
        await WiltedMacHeadless.eventually("account gate open") { model.libraryAccountStatus == .active }
        let controller = try XCTUnwrap(model.librarySyncController)

        let first = try episode(guid: "sync-first", title: "Sync First")
        let second = try episode(guid: "sync-second", title: "Sync Second")
        for value in [first, second] { try await store.save(episode: value) }
        try await store.save(subscription: PodcastSubscription(
            feedID: first.feedID, subscribedAt: Timestamp(created)
        ))
        await model.reloadLibraryRows()
        await controller.tickRound()
        try await waitFor("baseline publication") {
            await server.currentSnapshot.entries[first.itemID] != nil
        }

        let review = WiltedMacEpisodeIdentityReviewModel(model: model, anchorID: first.itemID.rawValue)
        await review.load()
        await review.selectPair(
            first: first.itemID.rawValue, second: second.itemID.rawValue,
            representative: first.itemID.rawValue
        )
        await review.reviewPair()
        await review.applyAssociation()
        XCTAssertEqual(review.errorMessage, nil)
        let appliedGroupID = try XCTUnwrap(review.activeAssociation?.associationID)
        try await waitFor("association published") {
            await server.currentSnapshot.entries[second.itemID]?.episodeAssociation?.groupID == appliedGroupID
        }

        await review.reviewReversal()
        await review.applyReversal()
        XCTAssertEqual(review.errorMessage, nil)
        try await waitFor("reversal published") {
            let entries = await server.currentSnapshot.entries
            return entries[second.itemID]?.episodeAssociation == nil
                && entries[first.itemID]?.episodeAssociation == nil
        }
        model.stopLibrarySync()
        await model.waitForLibrarySyncShutdown()
        XCTAssertGreaterThanOrEqual(controller.passCount, 1)
    }
}
