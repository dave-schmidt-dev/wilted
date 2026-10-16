import Foundation
import XCTest
import WiltedDomain
@testable import WiltedProducer

/// The owner's review path over synthetic, test-owned stores: unconfirmed
/// comparison evidence, captured approval consequences, stale refusal, and
/// explicit reversal with per-member inherited-protection loss. No test here
/// opens an owner database or media directory.
final class LocalLibraryEpisodeIdentityReviewTests: XCTestCase {
    let origin = Date(timeIntervalSince1970: 1_700_000_000)
    let feedURL = URL(string: "https://podcasts.example.test/review/feed.xml")!

    func makeURL(_ name: String = #function) -> URL {
        OwnedTestTemp.root
            .appendingPathComponent("wilted-review-\(name)-\(UUID().uuidString)")
            .appendingPathComponent("library.sqlite")
    }

    func episode(
        guid: String, title: String = "Reviewed Episode", feedURL: URL? = nil
    ) throws -> PodcastEpisode {
        let url = feedURL ?? self.feedURL
        let enclosure = URL(string: "https://cdn.example.test/review/\(guid).mp3")!
        return try PodcastEpisode(
            itemID: ItemID.derivePodcastEpisode(feedURL: url, rssGUID: guid, enclosureURL: enclosure),
            feedID: ItemID.derivePodcastFeed(from: url), feedURL: url, rssGUID: guid, title: title,
            publishedTime: Timestamp(origin), enclosureURL: enclosure,
            enclosureMediaType: "audio/mpeg", durationSeconds: 3_600, createdAt: Timestamp(origin)
        )
    }

    func confirmation(
        _ first: PodcastEpisode, _ second: PodcastEpisode
    ) -> PodcastEpisodePairConfirmation {
        PodcastEpisodePairConfirmation(
            confirmationID: UUID(), feedID: first.feedID, first: first.itemID, second: second.itemID,
            confirmedAt: Timestamp(origin)
        )
    }

    func associate(
        _ first: PodcastEpisode, _ second: PodcastEpisode, in store: LocalLibraryStore
    ) async throws -> PodcastEpisodeAssociation {
        let preview = try await store.previewEpisodeAssociation(
            confirming: confirmation(first, second), representativeID: first.itemID
        )
        return try await store.applyEpisodeAssociation(preview)
    }

    func completedDownload(
        for episode: PodcastEpisode, revision: AudioRevision, mediaURL: URL
    ) throws -> PodcastDownload {
        try PodcastDownload(
            episodeID: episode.itemID, status: .completed, bytesReceived: revision.byteCount,
            expectedByteCount: revision.byteCount, localURL: mediaURL, contentHash: revision.contentHash,
            updatedAt: Timestamp(origin)
        )
    }

    func assertRawStateEqual(
        _ before: LocalLibraryStore.PodcastLibrarySnapshot,
        _ after: LocalLibraryStore.PodcastLibrarySnapshot,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        XCTAssertEqual(
            Dictionary(uniqueKeysWithValues: before.episodes.map { ($0.itemID, $0) }),
            Dictionary(uniqueKeysWithValues: after.episodes.map { ($0.itemID, $0) }),
            file: file, line: line
        )
        XCTAssertEqual(before.downloads, after.downloads, file: file, line: line)
        XCTAssertEqual(before.readyRevisions, after.readyRevisions, file: file, line: line)
        XCTAssertEqual(before.playbackStates, after.playbackStates, file: file, line: line)
        XCTAssertEqual(before.listeningStates, after.listeningStates, file: file, line: line)
        XCTAssertEqual(before.episodeDecisions, after.episodeDecisions, file: file, line: line)
        XCTAssertEqual(before.retiredAtByEpisode, after.retiredAtByEpisode, file: file, line: line)
        XCTAssertEqual(before.removalKindByEpisode, after.removalKindByEpisode, file: file, line: line)
        XCTAssertEqual(before.podcastQueue, after.podcastQueue, file: file, line: line)
    }

    /// The approval text derives from the same captured member state apply
    /// validates: terminal, visibility, download and queue projections survive
    /// application and a reopen with raw rows untouched.
    func testCapturedApprovalConsequencesMatchAppliedStateAndReopenPreservesRawRows() async throws {
        let url = makeURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        var store = try LocalLibraryStore(url: url)
        let first = try episode(guid: "approval-a")
        let second = try episode(guid: "approval-b")
        for value in [first, second] { try await store.save(episode: value) }

        // A made the manual Keep, holds verified prepared media and a playback
        // checkpoint; B is completed (terminal) and holds the current queue slot.
        try await store.save(episodeDecision: EpisodeDecisionRecord(
            episodeID: first.itemID, decision: .keep, source: .manual, decidedAt: Timestamp(origin)
        ))
        let revision = try AudioRevision(
            itemID: first.itemID, revisionID: RevisionID(rawValue: "rev-approval-first"),
            durationSeconds: 3_600, byteCount: 4_096,
            contentHash: "sha256:" + String(repeating: "a", count: 64),
            mediaType: "audio/mp4", createdAt: Timestamp(origin), schemaVersion: 3
        )
        let media = url.deletingLastPathComponent().appendingPathComponent("approval-first.m4a")
        try Data(repeating: 4, count: Int(revision.byteCount)).write(to: media)
        try await store.finalizePodcastDownload(
            revision: revision, mediaURL: media,
            download: completedDownload(for: first, revision: revision, mediaURL: media)
        )
        try await store.save(playback: try PlaybackState(
            itemID: first.itemID, revisionID: revision.revisionID, sessionID: "review-session",
            sequence: 2, positionSeconds: 35, durationSeconds: 3_600, completed: false,
            intent: .progress, deviceID: "synthetic", updatedAt: Timestamp(origin.addingTimeInterval(5))
        ))
        let completedAt = Timestamp(origin.addingTimeInterval(30))
        try await store.saveListening(PodcastListeningState(
            episodeID: second.itemID, completedAt: completedAt,
            lastRevisionID: nil, updatedAt: completedAt
        ))
        try await store.addPodcastQueueEpisode(first.itemID)
        try await store.addPodcastQueueEpisode(second.itemID)
        try await store.setCurrentPodcastQueueEpisode(second.itemID)

        let before = try await store.podcastLibrarySnapshot()
        let preview = try await store.previewEpisodeAssociation(
            confirming: confirmation(first, second), representativeID: first.itemID
        )
        // Building the captured preview writes nothing.
        assertRawStateEqual(before, try await store.podcastLibrarySnapshot())

        let consequences = preview.approvalConsequences
        XCTAssertEqual(consequences.representativeID, first.itemID)
        XCTAssertEqual(Set(consequences.memberIDs), [first.itemID, second.itemID])
        XCTAssertEqual(consequences.winningDecision, .keep)
        XCTAssertEqual(consequences.manualDecidedAt, Timestamp(origin))
        XCTAssertFalse(consequences.hasConflictingManualChoices)
        XCTAssertTrue(consequences.isTerminal, "B's completion is newer than A's Keep")
        XCTAssertFalse(consequences.isAdmissionEligible)
        XCTAssertFalse(consequences.isDownloadEligible, "a terminal multi-member group refuses an untouched claim")
        XCTAssertFalse(consequences.isLarderRowVisible, "a terminal group is hidden from the Larder whole")
        XCTAssertTrue(consequences.hasQueueSlot)

        let firstMember = try XCTUnwrap(consequences.members.first { $0.episodeID == first.itemID })
        let secondMember = try XCTUnwrap(consequences.members.first { $0.episodeID == second.itemID })
        XCTAssertTrue(firstMember.retainsRawRow)
        XCTAssertTrue(firstMember.hasDownloadRecord)
        XCTAssertFalse(firstMember.canClaimDownload, "A's existing download record is spoken for")
        XCTAssertEqual(firstMember.queuePosition, 0)
        XCTAssertFalse(firstMember.isQueueCurrent)
        XCTAssertTrue(secondMember.retainsRawRow)
        XCTAssertFalse(secondMember.hasDownloadRecord)
        XCTAssertFalse(secondMember.canClaimDownload, "the terminal group refuses the untouched claim")
        XCTAssertEqual(secondMember.queuePosition, 1)
        XCTAssertTrue(secondMember.isQueueCurrent)

        let association = try await store.applyEpisodeAssociation(preview)
        XCTAssertEqual(association.representativeID, first.itemID)
        XCTAssertTrue(association.isActive)

        // The applied logical state is exactly what the review displayed.
        let appliedStateValue = try await store.podcastEpisodeLogicalState(for: second.itemID)
        let appliedState = try XCTUnwrap(appliedStateValue)
        XCTAssertEqual(appliedState.isTerminal, consequences.isTerminal)
        XCTAssertEqual(appliedState.manualDecision, consequences.winningDecision)
        XCTAssertEqual(appliedState.hasConflictingManualChoices, consequences.hasConflictingManualChoices)
        XCTAssertEqual(Set(appliedState.memberIDs), Set(consequences.memberIDs))

        // Raw rows, queue slots and media survive application.
        assertRawStateEqual(before, try await store.podcastLibrarySnapshot())

        // A reopened store reads the same association, the same raw state and
        // byte-identical media.
        store = try LocalLibraryStore(url: url)
        let reopenedAssociations = try await store.episodeAssociations()
        XCTAssertEqual(reopenedAssociations, [association])
        assertRawStateEqual(before, try await store.podcastLibrarySnapshot())
        let retainedMedia = try Data(contentsOf: media)
        XCTAssertEqual(retainedMedia, Data(repeating: 4, count: Int(revision.byteCount)))
    }

    /// A comparison may report an existing association as ambiguity, but the
    /// read never writes and the capture path still refuses overlap.
    func testComparisonReportsExistingAssociationAsAmbiguityWithoutWriting() async throws {
        let url = makeURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = try LocalLibraryStore(url: url)
        let first = try episode(guid: "ambiguity-a")
        let second = try episode(guid: "ambiguity-b")
        let third = try episode(guid: "ambiguity-c")
        for value in [first, second, third] { try await store.save(episode: value) }
        let association = try await associate(first, second, in: store)
        let before = try await store.podcastLibrarySnapshot()

        let comparison = try await store.podcastEpisodeAssociationComparison(
            first: first.itemID, second: third.itemID
        )
        XCTAssertEqual(comparison.existingAssociationIDs, [association.associationID])
        XCTAssertTrue(comparison.ambiguities.contains(.existingAssociation))
        XCTAssertTrue(comparison.ambiguities.contains(.otherMetadataCandidates),
                      "the associated twin remains a metadata hint")
        XCTAssertEqual(comparison.otherCandidateIDs, [second.itemID])
        XCTAssertTrue(comparison.sharesMetadata)

        // Comparison wrote nothing, and the capture path refuses the overlap.
        assertRawStateEqual(before, try await store.podcastLibrarySnapshot())
        let active = try await store.episodeAssociations()
        XCTAssertEqual(active, [association])
        do {
            _ = try await store.previewEpisodeAssociation(
                confirming: confirmation(first, third), representativeID: first.itemID
            )
            XCTFail("an overlap must refuse at preview time")
        } catch { XCTAssertEqual(error as? PodcastEpisodeAssociationError, .overlappingAssociation) }
    }

    /// An explicitly chosen same-feed pair may proceed even when its metadata
    /// differs and other candidates exist: discovery hints never gate a
    /// confirmed owner choice, and nothing else is associated by the act.
    func testExplicitSameFeedPairWithDifferingMetadataIsNotHeuristicallyGated() async throws {
        let url = makeURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = try LocalLibraryStore(url: url)
        let first = try episode(guid: "gate-a")
        let second = try episode(guid: "gate-b", title: "Different Title")
        let hint = try episode(guid: "gate-c")
        for value in [first, second, hint] { try await store.save(episode: value) }

        let comparison = try await store.podcastEpisodeAssociationComparison(
            first: first.itemID, second: second.itemID
        )
        XCTAssertFalse(comparison.sharesMetadata)
        XCTAssertTrue(comparison.ambiguities.contains(.metadataDiffers))
        XCTAssertEqual(comparison.otherCandidateIDs, [hint.itemID])

        // The owner's explicit pair and representative still proceed.
        let preview = try await store.previewEpisodeAssociation(
            confirming: confirmation(first, second), representativeID: second.itemID
        )
        let association = try await store.applyEpisodeAssociation(preview)
        XCTAssertTrue(association.isActive)
        XCTAssertEqual(association.representativeID, second.itemID)
        let active = try await store.episodeAssociations()
        XCTAssertEqual(active.map(\.associationID), [association.associationID])

        // The hint episode stays unassociated and untouched.
        let hintState = try await store.podcastEpisodeLogicalState(for: hint.itemID)
        XCTAssertEqual(hintState?.memberIDs, [hint.itemID])
    }

    /// A captured preview is bound to its exact state: a newer owner decision
    /// between review and apply refuses, writing no association history.
    func testStalePreviewRefusesAfterOwnerDecisionWithoutWriting() async throws {
        let url = makeURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = try LocalLibraryStore(url: url)
        let first = try episode(guid: "stale-a")
        let second = try episode(guid: "stale-b")
        for value in [first, second] { try await store.save(episode: value) }
        let preview = try await store.previewEpisodeAssociation(
            confirming: confirmation(first, second), representativeID: first.itemID
        )
        try await store.save(episodeDecision: EpisodeDecisionRecord(
            episodeID: second.itemID, decision: .keep, source: .manual,
            decidedAt: Timestamp(origin.addingTimeInterval(45))
        ))
        do {
            _ = try await store.applyEpisodeAssociation(preview)
            XCTFail("a newer manual choice must refuse the captured preview")
        } catch { XCTAssertEqual(error as? PodcastEpisodeAssociationError, .stalePreview) }
        let history = try await store.episodeAssociations(includingReversed: true)
        XCTAssertTrue(history.isEmpty)
    }

    /// Reversal names the member that never made the group's Keep, warns that
    /// later automation may retire it, and copying no choice is exactly why
    /// the warned Skip then retires that member alone.
    /// Raw removal and the logical Larder projection are separate facts. An
    /// active pair whose representative raw copy was retired still shows one
    /// folded Larder row; when every stored copy is removed, the active pair
    /// shows no row at all. The capture states both without conflating them.
    func testApprovalConsequencesSeparateRawRemovalFromTheLogicalLarderProjection() async throws {
        let url = makeURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = try LocalLibraryStore(url: url)
        let first = try episode(guid: "projection-a")
        let second = try episode(guid: "projection-b")
        for value in [first, second] { try await store.save(episode: value) }
        try await store.retireEpisode(second.itemID, at: Timestamp(origin.addingTimeInterval(10)))
        // The Keep is newer than the retirement, so the pair is not terminal.
        try await store.save(episodeDecision: EpisodeDecisionRecord(
            episodeID: first.itemID, decision: .keep, source: .manual,
            decidedAt: Timestamp(origin.addingTimeInterval(20))
        ))

        let preview = try await store.previewEpisodeAssociation(
            confirming: confirmation(first, second), representativeID: second.itemID
        )
        let consequences = preview.approvalConsequences
        XCTAssertFalse(consequences.isTerminal)
        XCTAssertTrue(consequences.isLarderRowVisible, "one retained copy keeps the active group row")
        XCTAssertEqual(consequences.representativeID, second.itemID)
        let firstMember = try XCTUnwrap(consequences.members.first { $0.episodeID == first.itemID })
        let secondMember = try XCTUnwrap(consequences.members.first { $0.episodeID == second.itemID })
        XCTAssertTrue(firstMember.retainsRawRow)
        XCTAssertFalse(secondMember.retainsRawRow, "the representative's own raw copy was retired")

        // The applied logical state agrees with the capture, and the raw
        // retirement survives: the display revives, the row is not restored.
        let association = try await store.applyEpisodeAssociation(preview)
        XCTAssertEqual(association.representativeID, second.itemID)
        let stateValue = try await store.podcastEpisodeLogicalState(for: second.itemID)
        let state = try XCTUnwrap(stateValue)
        XCTAssertFalse(state.isTerminal)
        let secondRemoval = try await store.removalKind(for: second.itemID)
        XCTAssertEqual(secondRemoval, .retired)

        // With every stored copy removed, the active pair has no Larder row.
        let third = try episode(guid: "projection-c")
        let fourth = try episode(guid: "projection-d")
        for value in [third, fourth] { try await store.save(episode: value) }
        try await store.retireEpisode(third.itemID, at: Timestamp(origin.addingTimeInterval(30)))
        try await store.retireEpisode(fourth.itemID, at: Timestamp(origin.addingTimeInterval(31)))
        try await store.save(episodeDecision: EpisodeDecisionRecord(
            episodeID: third.itemID, decision: .keep, source: .manual,
            decidedAt: Timestamp(origin.addingTimeInterval(40))
        ))
        let preview2 = try await store.previewEpisodeAssociation(
            confirming: confirmation(third, fourth), representativeID: third.itemID
        )
        XCTAssertFalse(preview2.approvalConsequences.isTerminal)
        XCTAssertFalse(preview2.approvalConsequences.isLarderRowVisible, "no stored copy, no row")
        XCTAssertTrue(preview2.approvalConsequences.members.allSatisfy { !$0.retainsRawRow })
    }

    /// A newer group Keep on one member overrides another member's older
    /// opposing manual Skip. Reversal keeps that member's raw Skip, drops the
    /// newer resolved Keep, and never warns about automation deleting a choice
    /// whose own manual protection survives.

}
