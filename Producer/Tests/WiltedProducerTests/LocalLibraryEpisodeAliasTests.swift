import Foundation
import SwiftData
import XCTest
import WiltedDomain
@testable import WiltedProducer

extension LocalLibraryStoreTests {
    private func aliasEpisode(_ guid: String, feedURL: URL? = nil, createdAt: Timestamp? = nil) throws -> PodcastEpisode {
        let (_, base) = try podcastValues()
        let url = feedURL ?? base.feedURL
        let enclosure = URL(string: "https://podcasts.example.test/aliases/\(guid).mp3")!
        return try PodcastEpisode(
            itemID: ItemID.derivePodcastEpisode(feedURL: url, rssGUID: guid, enclosureURL: enclosure),
            feedID: ItemID.derivePodcastFeed(from: url), feedURL: url, rssGUID: guid,
            title: "Same discovery metadata", publishedTime: base.publishedTime,
            enclosureURL: enclosure, enclosureMediaType: "audio/mpeg", durationSeconds: 120,
            episodeLink: URL(string: "https://podcasts.example.test/show"), createdAt: createdAt ?? base.createdAt
        )
    }

    private func aliasConfirmation(_ first: PodcastEpisode, _ second: PodcastEpisode) -> PodcastEpisodePairConfirmation {
        PodcastEpisodePairConfirmation(confirmationID: UUID(), feedID: first.feedID,
            first: first.itemID, second: second.itemID, confirmedAt: first.createdAt)
    }

    private func associate(_ first: PodcastEpisode, _ second: PodcastEpisode,
                           in store: LocalLibraryStore) async throws -> PodcastEpisodeAssociation {
        let preview = try await store.previewEpisodeAssociation(
            confirming: aliasConfirmation(first, second), representativeID: first.itemID)
        return try await store.applyEpisodeAssociation(preview)
    }

    private func assertAliasRawStateEqual(
        _ before: LocalLibraryStore.PodcastLibrarySnapshot, _ after: LocalLibraryStore.PodcastLibrarySnapshot,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        XCTAssertEqual(Dictionary(uniqueKeysWithValues: before.episodes.map { ($0.itemID, $0) }),
                       Dictionary(uniqueKeysWithValues: after.episodes.map { ($0.itemID, $0) }), file: file, line: line)
        XCTAssertEqual(before.downloads, after.downloads, file: file, line: line)
        XCTAssertEqual(before.readyRevisions, after.readyRevisions, file: file, line: line)
        XCTAssertEqual(before.playbackStates, after.playbackStates, file: file, line: line)
        XCTAssertEqual(before.listeningStates, after.listeningStates, file: file, line: line)
        XCTAssertEqual(before.episodeDecisions, after.episodeDecisions, file: file, line: line)
        XCTAssertEqual(before.retiredAtByEpisode, after.retiredAtByEpisode, file: file, line: line)
        XCTAssertEqual(before.removalKindByEpisode, after.removalKindByEpisode, file: file, line: line)
        XCTAssertEqual(before.podcastQueue, after.podcastQueue, file: file, line: line)
    }

    func testEpisodeAssociationRetainsBackingIDsGUIDsRevisionsMediaProgressAndReopens() async throws {
        let url = makeURL(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        var store = try LocalLibraryStore(url: url)
        let first = try aliasEpisode("backing-a"), second = try aliasEpisode("backing-b")
        for episode in [first, second] {
            try await store.save(episode: episode)
            try await store.addPodcastQueueEpisode(episode.itemID)
            let revision = try podcastRevision(itemID: episode.itemID, id: episode.rssGUID!, hashDigit: "a")
            let media = url.deletingLastPathComponent().appendingPathComponent(episode.rssGUID! + ".m4a")
            try Data(repeating: 17, count: Int(revision.byteCount)).write(to: media)
            try await store.finalizePodcastDownload(revision: revision, mediaURL: media,
                download: completedPodcastDownload(episodeID: episode.itemID, revision: revision, mediaURL: media))
            try await store.save(playback: PlaybackState(itemID: episode.itemID, revisionID: revision.revisionID,
                sessionID: "session", sequence: 2, positionSeconds: episode == first ? 35 : 70,
                durationSeconds: 120, completed: false, intent: .progress, deviceID: "synthetic",
                updatedAt: episode.createdAt))
        }
        try await store.setCurrentPodcastQueueEpisode(second.itemID)
        let before = try await store.podcastLibrarySnapshot()
        let counts = try LocalLibraryStore.tableRowCounts(at: url)
        let association = try await associate(first, second, in: store)
        XCTAssertEqual(association.representativeID, first.itemID)
        XCTAssertEqual(Set(association.memberIDs), [first.itemID, second.itemID])
        store = try LocalLibraryStore(url: url)
        let reopened = try await store.episodeAssociations()
        XCTAssertEqual(reopened, [association])
        let after = try await store.podcastLibrarySnapshot()
        assertAliasRawStateEqual(before, after)
        let afterCounts = try LocalLibraryStore.tableRowCounts(at: url)
        for (table, count) in counts where table != "ZEPISODEASSOCIATIONRECORD" {
            XCTAssertEqual(afterCounts[table], count, table)
        }
        let reversal = try await store.previewEpisodeAssociationReversal(association.associationID, expectedVersion: 1)
        let reversed = try await store.reverseEpisodeAssociation(reversal)
        XCTAssertEqual(reversed.version, 2)
        XCTAssertFalse(reversed.isActive)
        let final = try await store.podcastLibrarySnapshot()
        assertAliasRawStateEqual(before, final)
        for download in final.downloads.values {
            let media = try XCTUnwrap(download.localURL)
            XCTAssertEqual(try Data(contentsOf: media), Data(repeating: 17, count: Int(download.bytesReceived)))
        }
        let active = try await store.episodeAssociations()
        let history = try await store.episodeAssociations(includingReversed: true)
        XCTAssertTrue(active.isEmpty)
        XCTAssertEqual(history, [reversed])
        do { _ = try await store.reverseEpisodeAssociation(reversal); XCTFail("stale version must refuse") }
        catch { XCTAssertEqual(error as? PodcastEpisodeAssociationError, .staleVersion) }
    }

    func testEpisodeAssociationRejectsCrossFeedInvalidPairOverlapAndProofReplay() async throws {
        let url = makeURL(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = try LocalLibraryStore(url: url)
        let first = try aliasEpisode("proof-a"), second = try aliasEpisode("proof-b"), third = try aliasEpisode("proof-c")
        let moved = try aliasEpisode("proof-a", feedURL: URL(string: "https://podcasts.example.test/moved.xml")!)
        for episode in [first, second, third, moved] { try await store.save(episode: episode) }
        do {
            _ = try await store.previewEpisodeAssociation(confirming: aliasConfirmation(first, moved), representativeID: first.itemID)
            XCTFail("same GUID across feeds is not proof")
        } catch { XCTAssertEqual(error as? PodcastEpisodeAssociationError, .crossFeed) }
        do {
            _ = try await store.previewEpisodeAssociation(confirming: aliasConfirmation(first, first), representativeID: first.itemID)
            XCTFail("a pair must name distinct source IDs")
        } catch { XCTAssertEqual(error as? PodcastEpisodeAssociationError, .invalidPair) }
        let association = try await associate(first, second, in: store)
        do {
            _ = try await store.previewEpisodeAssociation(confirming: aliasConfirmation(second, third), representativeID: second.itemID)
            XCTFail("overlapping mappings must refuse")
        } catch { XCTAssertEqual(error as? PodcastEpisodeAssociationError, .overlappingAssociation) }
        let reversal = try await store.previewEpisodeAssociationReversal(association.associationID, expectedVersion: 1)
        _ = try await store.reverseEpisodeAssociation(reversal)
        do {
            _ = try await store.previewEpisodeAssociation(confirming: association.confirmation, representativeID: first.itemID)
            XCTFail("a reversed confirmation cannot be replayed as new consent")
        } catch { XCTAssertEqual(error as? PodcastEpisodeAssociationError, .confirmationAlreadyUsed) }
    }

    func testEpisodeAssociationStalePreviewRefusesNewManualProgressAndAssociationState() async throws {
        let url = makeURL(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = try LocalLibraryStore(url: url)
        let first = try aliasEpisode("stale-a"), second = try aliasEpisode("stale-b")
        for episode in [first, second] { try await store.save(episode: episode) }
        let preview = try await store.previewEpisodeAssociation(confirming: aliasConfirmation(first, second), representativeID: first.itemID)
        try await store.save(episodeDecision: EpisodeDecisionRecord(episodeID: second.itemID,
            decision: .keep, source: .manual, decidedAt: Timestamp(first.createdAt.date.addingTimeInterval(10))))
        do { _ = try await store.applyEpisodeAssociation(preview); XCTFail("new manual state must refuse") }
        catch { XCTAssertEqual(error as? PodcastEpisodeAssociationError, .stalePreview) }
        let next = try await store.previewEpisodeAssociation(confirming: aliasConfirmation(first, second), representativeID: first.itemID)
        try await store.save(playback: PlaybackState(itemID: first.itemID, revisionID: RevisionID(rawValue: "stale-revision"),
            sessionID: "session", sequence: 1, positionSeconds: 12, durationSeconds: 120,
            completed: false, intent: .progress, deviceID: "synthetic", updatedAt: first.createdAt))
        do { _ = try await store.applyEpisodeAssociation(next); XCTFail("new progress must refuse") }
        catch { XCTAssertEqual(error as? PodcastEpisodeAssociationError, .stalePreview) }
        let competing = try await store.previewEpisodeAssociation(confirming: aliasConfirmation(first, second), representativeID: second.itemID)
        _ = try await associate(first, second, in: store)
        do { _ = try await store.applyEpisodeAssociation(competing); XCTFail("a competing association must refuse") }
        catch { XCTAssertEqual(error as? PodcastEpisodeAssociationError, .stalePreview) }
    }

    func testTerminalAssociationBlocksAdmissionClaimsAndAutomationUntilNewerManualKeep() async throws {
        let url = makeURL(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = try LocalLibraryStore(url: url)
        let first = try aliasEpisode("terminal-a"), second = try aliasEpisode("terminal-b")
        for episode in [first, second] { try await store.save(episode: episode) }
        let finishedAt = Timestamp(first.createdAt.date.addingTimeInterval(10))
        _ = try await store.manuallyCompleteEpisodes([first.itemID], at: finishedAt)
        _ = try await associate(first, second, in: store)
        let terminal = try await store.podcastEpisodeLogicalState(for: second.itemID)
        XCTAssertTrue(try XCTUnwrap(terminal).isTerminal)
        let refreshed = try await store.admitPodcastEpisodes([first, second], admission: .incremental, claimingNewest: 2)
        XCTAssertTrue(refreshed.admission.saved.isEmpty)
        XCTAssertTrue(refreshed.claimed.isEmpty)
        let claimed = try await store.claimPodcastDownload(episodeID: second.itemID)
        XCTAssertFalse(claimed)
        do {
            _ = try await store.admitEpisode(EpisodeDecisionRecord(episodeID: second.itemID,
                decision: .keep, source: .policy, decidedAt: Timestamp(finishedAt.date.addingTimeInterval(1))))
            XCTFail("automation must not reverse the other member's completion")
        } catch { XCTAssertEqual(error as? AutomaticEpisodeAdmissionError, .manualDecisionExists) }
        let newer = Timestamp(finishedAt.date.addingTimeInterval(20))
        let kept = try await store.save(episodeDecision: EpisodeDecisionRecord(episodeID: second.itemID,
            decision: .keep, source: .manual, decidedAt: newer))
        XCTAssertEqual(kept, .applied)
        let state = try await store.podcastEpisodeLogicalState(for: first.itemID)
        XCTAssertFalse(try XCTUnwrap(state).isTerminal)
        XCTAssertEqual(state?.manualDecision, .keep)
        let admitted = try await store.admitPodcastEpisodes([first, second], admission: .incremental, claimingNewest: 0)
        XCTAssertEqual(Set(admitted.admission.saved), [first.itemID, second.itemID])
        let old = try await store.save(episodeDecision: EpisodeDecisionRecord(episodeID: first.itemID,
            decision: .skip, source: .manual, decidedAt: finishedAt))
        XCTAssertEqual(old, .superseded)
        let automated = try await store.save(episodeDecision: EpisodeDecisionRecord(episodeID: second.itemID,
            decision: .skip, source: .rule, ruleID: UUID(), decidedAt: Timestamp(newer.date.addingTimeInterval(10))))
        XCTAssertEqual(automated, .superseded)
        let retired = try await store.retireEpisodeBySkipRule(second.itemID, ruleID: UUID())
        XCTAssertFalse(retired)
        let unchanged = try await store.episodeDecision(for: second.itemID)
        XCTAssertEqual(unchanged?.decidedAt, newer)
    }

    func testEqualTimestampManualConflictPreservesKeepAndSurfacesConflict() async throws {
        let url = makeURL(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = try LocalLibraryStore(url: url)
        let first = try aliasEpisode("tie-a"), second = try aliasEpisode("tie-b")
        for episode in [first, second] { try await store.save(episode: episode) }
        try await store.save(episodeDecision: EpisodeDecisionRecord(episodeID: first.itemID,
            decision: .skip, source: .manual, decidedAt: first.createdAt))
        try await store.save(episodeDecision: EpisodeDecisionRecord(episodeID: second.itemID,
            decision: .keep, source: .manual, decidedAt: first.createdAt))
        _ = try await associate(first, second, in: store)
        let state = try await store.podcastEpisodeLogicalState(for: first.itemID)
        XCTAssertEqual(state?.manualDecision, .keep)
        XCTAssertFalse(try XCTUnwrap(state).isTerminal)
        XCTAssertTrue(try XCTUnwrap(state).hasConflictingManualChoices)
        let skip = try await store.save(episodeDecision: EpisodeDecisionRecord(episodeID: second.itemID,
            decision: .skip, source: .manual, decidedAt: first.createdAt))
        XCTAssertEqual(skip, .superseded)
    }

    func testFreshAssociationReversalPreservesNewerManualAndProgressWhileOldPreviewRefuses() async throws {
        let url = makeURL(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = try LocalLibraryStore(url: url)
        let first = try aliasEpisode("reverse-a"), second = try aliasEpisode("reverse-b")
        for episode in [first, second] { try await store.save(episode: episode) }
        let association = try await associate(first, second, in: store)
        let old = try await store.previewEpisodeAssociationReversal(association.associationID, expectedVersion: 1)
        try await store.save(episodeDecision: EpisodeDecisionRecord(episodeID: second.itemID,
            decision: .keep, source: .manual, decidedAt: Timestamp(first.createdAt.date.addingTimeInterval(20))))
        try await store.save(playback: PlaybackState(itemID: second.itemID, revisionID: RevisionID(rawValue: "new-revision"),
            sessionID: "new-session", sequence: 3, positionSeconds: 88, durationSeconds: 120,
            completed: false, intent: .progress, deviceID: "synthetic", updatedAt: first.createdAt))
        let before = try await store.podcastLibrarySnapshot()
        do { _ = try await store.reverseEpisodeAssociation(old); XCTFail("stale reversal must refuse") }
        catch { XCTAssertEqual(error as? PodcastEpisodeAssociationError, .conflictingOwnerState) }
        let fresh = try await store.previewEpisodeAssociationReversal(association.associationID, expectedVersion: 1)
        _ = try await store.reverseEpisodeAssociation(fresh)
        let after = try await store.podcastLibrarySnapshot()
        assertAliasRawStateEqual(before, after)
    }

    func testEqualTimeOppositeChoicesOnSameAssociatedMemberRetainConflictEvidence() async throws {
        let url = makeURL(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = try LocalLibraryStore(url: url)
        let first = try aliasEpisode("same-tie-a"), second = try aliasEpisode("same-tie-b")
        for episode in [first, second] { try await store.save(episode: episode) }
        _ = try await associate(first, second, in: store)
        try await store.save(episodeDecision: EpisodeDecisionRecord(episodeID: first.itemID,
            decision: .skip, source: .manual, decidedAt: first.createdAt))
        try await store.save(episodeDecision: EpisodeDecisionRecord(episodeID: first.itemID,
            decision: .keep, source: .manual, decidedAt: first.createdAt))
        let state = try await store.podcastEpisodeLogicalState(for: second.itemID)
        XCTAssertEqual(state?.manualDecision, .keep)
        XCTAssertTrue(try XCTUnwrap(state).hasConflictingManualChoices)
        let rejected = try await store.save(episodeDecision: EpisodeDecisionRecord(episodeID: first.itemID,
            decision: .skip, source: .manual, decidedAt: first.createdAt))
        XCTAssertEqual(rejected, .superseded)
        let reopened = try LocalLibraryStore(url: url)
        let retained = try await reopened.podcastEpisodeLogicalState(for: first.itemID)
        XCTAssertTrue(try XCTUnwrap(retained).hasConflictingManualChoices)
        try await reopened.save(episodeDecision: EpisodeDecisionRecord(episodeID: second.itemID,
            decision: .keep, source: .manual, decidedAt: Timestamp(first.createdAt.date.addingTimeInterval(10))))
        let resolved = try await reopened.podcastEpisodeLogicalState(for: first.itemID)
        XCTAssertFalse(try XCTUnwrap(resolved).hasConflictingManualChoices)
    }

    func testAutomaticRollbackCannotReplaceNewerLogicalOwnerDecisionOrQueueMembership() async throws {
        let url = makeURL(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = try LocalLibraryStore(url: url)
        let first = try aliasEpisode("rollback-a"), second = try aliasEpisode("rollback-b")
        for episode in [first, second] { try await store.save(episode: episode) }
        _ = try await associate(first, second, in: store)
        try await store.save(episodeDecision: EpisodeDecisionRecord(episodeID: first.itemID,
            decision: .keep, source: .manual, decidedAt: first.createdAt))
        try await store.addPodcastQueueEpisode(second.itemID)
        try await store.setCurrentPodcastQueueEpisode(second.itemID)
        let before = try await store.podcastLibrarySnapshot()
        try await store.restoreEpisodeDecisions([second.itemID: nil], queue: PodcastQueueState(episodeIDs: []))
        let after = try await store.podcastLibrarySnapshot()
        assertAliasRawStateEqual(before, after)
    }

    func testUnsubscribeClearsOnlyFeedAssociationsAndNewGenerationsStayUnassociated() async throws {
        let url = makeURL(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = try LocalLibraryStore(url: url)
        let first = try aliasEpisode("unsubscribe-a"), second = try aliasEpisode("unsubscribe-b")
        let otherURL = URL(string: "https://podcasts.example.test/other-feed.xml")!
        let otherFirst = try aliasEpisode("other-a", feedURL: otherURL)
        let otherSecond = try aliasEpisode("other-b", feedURL: otherURL)
        for episode in [first, second, otherFirst, otherSecond] { try await store.save(episode: episode) }
        let association = try await associate(first, second, in: store)
        let other = try await associate(otherFirst, otherSecond, in: store)
        do {
            _ = try await LocalLibraryStore.$removalStageObserver.withValue({ stage in
                if stage == .save { throw InjectedMigrationFailure() }
            }) {
                try await store.unsubscribeFromPodcast(feedID: first.feedID)
            }
            XCTFail("A staged save failure must roll back the association cascade")
        } catch { XCTAssertTrue(error is LocalLibraryRemovalError) }
        let afterFailure = try await store.episodeAssociations()
        XCTAssertEqual(Set(afterFailure.map(\.associationID)), [association.associationID, other.associationID])
        let firstAfterFailure = try await store.podcastEpisode(for: first.itemID)
        XCTAssertEqual(firstAfterFailure, first)
        let removed = try await store.unsubscribeFromPodcast(feedID: first.feedID)
        XCTAssertEqual(removed, 2)
        let retained = try await store.episodeAssociations(includingReversed: true)
        XCTAssertEqual(retained, [other])
        let generation = Timestamp(first.createdAt.date.addingTimeInterval(100))
        let freshFirst = try aliasEpisode("unsubscribe-a", createdAt: generation)
        let freshSecond = try aliasEpisode("unsubscribe-b", createdAt: generation)
        XCTAssertEqual(freshFirst.itemID, first.itemID)
        XCTAssertEqual(freshSecond.itemID, second.itemID)
        let admitted = try await store.admitPodcastEpisodes([freshFirst, freshSecond],
            admission: .incremental, claimingNewest: 2)
        XCTAssertEqual(Set(admitted.admission.newlyAdmitted), [first.itemID, second.itemID])
        XCTAssertEqual(Set(admitted.claimed), [first.itemID, second.itemID])
        let freshState = try await store.podcastEpisodeLogicalState(for: first.itemID)
        XCTAssertEqual(freshState?.memberIDs, [first.itemID])
        XCTAssertFalse(try XCTUnwrap(freshState).isTerminal)
        let otherState = try await store.podcastEpisodeLogicalState(for: otherSecond.itemID)
        XCTAssertEqual(Set(try XCTUnwrap(otherState).memberIDs), [otherFirst.itemID, otherSecond.itemID])
    }

    @MainActor
    func testBrokenAssociationsDegradeToRawSingletonsWithoutChangingOtherGroups() async throws {
        for damage in ["members", "evidence", "captured", "ties", "missing", "generation"] {
            let url = makeURL(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
            let store = try LocalLibraryStore(url: url)
            let first = try aliasEpisode("broken-a"), second = try aliasEpisode("broken-b")
            let healthyFirst = try aliasEpisode("healthy-a"), healthySecond = try aliasEpisode("healthy-b")
            for episode in [first, second, healthyFirst, healthySecond] { try await store.save(episode: episode) }
            let brokenPreview = try await store.previewEpisodeAssociation(
                confirming: aliasConfirmation(first, second), representativeID: first.itemID)
            let broken = try await store.applyEpisodeAssociation(brokenPreview)
            let healthyPreview = try await store.previewEpisodeAssociation(
                confirming: aliasConfirmation(healthyFirst, healthySecond), representativeID: healthyFirst.itemID)
            let healthy = try await store.applyEpisodeAssociation(healthyPreview)
            try await store.save(episodeDecision: EpisodeDecisionRecord(episodeID: second.itemID,
                decision: .skip, source: .manual, decidedAt: second.createdAt))
            try await store.addPodcastQueueEpisode(first.itemID)
            let context = ModelContext(store.container)
            let record = try XCTUnwrap(context.fetch(FetchDescriptor<LocalLibrarySchemaV20Models.EpisodeAssociationRecord>())
                .first { $0.associationID == broken.associationID })
            switch damage {
            case "members": record.members = Data("invalid".utf8)
            case "evidence": record.evidence = Data("invalid".utf8)
            case "captured": record.capturedMemberState = Data("[]".utf8)
            case "ties": record.manualChoiceConflicts = Data("invalid".utf8)
            default:
                let member = try XCTUnwrap(context.fetch(FetchDescriptor<LocalLibrarySchemaV13Models.PodcastEpisodeRecord>())
                    .first { $0.id == second.itemID.rawValue })
                if damage == "missing" { context.delete(member) }
                else { member.createdAt = member.createdAt.addingTimeInterval(1) }
            }
            try context.save()
            let before = try await store.podcastLibrarySnapshot(profile: .publication)
            let reads = AssociationReadRecorder()
            let identity = try await LocalLibraryStore.$invalidAssociationReadObserver.withValue({ reads.invalid($0) }) {
                try await store.podcastLibraryIdentitySnapshot(profile: .publication)
            }
            XCTAssertEqual(reads.invalidIDs, [broken.associationID], damage)
            XCTAssertEqual(identity.associations.map(\.associationID), [healthy.associationID], damage)
            XCTAssertEqual(identity.states.count, 1, damage)
            assertAliasRawStateEqual(before, identity.library)
            let raw = try await store.podcastEpisodeLogicalState(for: first.itemID)
            XCTAssertEqual(raw?.memberIDs, [first.itemID], damage)
            XCTAssertFalse(try XCTUnwrap(raw).isTerminal, damage)
            let expanded = try await store.logicalEpisodeIDs([first.itemID, healthySecond.itemID])
            XCTAssertEqual(Set(expanded), [first.itemID, healthyFirst.itemID, healthySecond.itemID], damage)
            let allowed = try await store.episodeDecisionWouldApply(EpisodeDecisionRecord(episodeID: first.itemID,
                decision: .keep, source: .policy, decidedAt: first.createdAt))
            XCTAssertTrue(allowed, damage)
            let retained = try context.fetch(FetchDescriptor<LocalLibrarySchemaV20Models.EpisodeAssociationRecord>())
            XCTAssertEqual(retained.count, 2, "reads must never delete damaged records")
            XCTAssertTrue(retained.allSatisfy(\.isActive))
        }
    }

    func testBulkLogicalIdentityReadsMaterializeAssociationTablesOnce() async throws {
        let url = makeURL(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = try LocalLibraryStore(url: url)
        var requested: [ItemID] = []
        for index in 0..<12 {
            let first = try aliasEpisode("bulk-\(index)-a"), second = try aliasEpisode("bulk-\(index)-b")
            for episode in [first, second] { try await store.save(episode: episode); requested.append(episode.itemID) }
            _ = try await associate(first, second, in: store)
        }
        let reads = AssociationReadRecorder()
        let expanded = try await LocalLibraryStore.$associationReadObserver.withValue({ reads.read($0, $1) }) {
            try await store.logicalEpisodeIDs(requested)
        }
        XCTAssertEqual(Set(expanded), Set(requested))
        XCTAssertEqual(reads.fetches, 4)
        XCTAssertEqual(reads.associationRows, 12)
        let exportReads = AssociationReadRecorder()
        let export = try await LocalLibraryStore.$associationReadObserver.withValue({ exportReads.read($0, $1) }) {
            try await store.podcastLibraryIdentitySnapshot(profile: .publication)
        }
        XCTAssertEqual(export.associations.count, 12)
        XCTAssertEqual(export.states.count, 12)
        XCTAssertEqual(exportReads.fetches, 4)
        XCTAssertEqual(exportReads.associationRows, 12)
        for id in requested { try await store.addPodcastQueueEpisode(id) }
        let candidate = try aliasEpisode("bulk-candidate")
        try await store.save(episode: candidate)
        let admissionReads = AssociationReadRecorder()
        do {
            _ = try await LocalLibraryStore.$associationReadObserver.withValue({ admissionReads.read($0, $1) }) {
                try await store.admitEpisode(EpisodeDecisionRecord(episodeID: candidate.itemID,
                    decision: .keep, source: .policy, decidedAt: candidate.createdAt), automaticKeptLimit: 12)
            }
            XCTFail("Twenty-four raw members occupy twelve logical capacity slots")
        } catch { XCTAssertEqual(error as? AutomaticEpisodeAdmissionError, .capacityUnavailable) }
        XCTAssertEqual(admissionReads.fetches, 4)
        XCTAssertEqual(admissionReads.associationRows, 12)
        let completionReads = AssociationReadRecorder()
        let completion = try await LocalLibraryStore.$associationReadObserver.withValue({ completionReads.read($0, $1) }) {
            try await store.manuallyCompleteEpisodes(requested,
                at: Timestamp(candidate.createdAt.date.addingTimeInterval(20)))
        }
        XCTAssertEqual(Set(completion.committed), Set(requested))
        XCTAssertEqual(completionReads.fetches, 4)
        XCTAssertEqual(completionReads.associationRows, 12)
        let reservationReads = AssociationReadRecorder()
        let reservations = try await LocalLibraryStore.$associationReadObserver.withValue({ reservationReads.read($0, $1) }) {
            try await store.manualCompletionCapacityReservations()
        }
        XCTAssertEqual(reservations[candidate.feedID], 12)
        XCTAssertEqual(reservationReads.fetches, 4)
        XCTAssertEqual(reservationReads.associationRows, 12)
        let claimReads = AssociationReadRecorder()
        let claimed = try await LocalLibraryStore.$associationReadObserver.withValue({ claimReads.read($0, $1) }) {
            try await store.claimPodcastDownload(episodeID: requested[0])
        }
        XCTAssertFalse(claimed)
        XCTAssertEqual(claimReads.fetches, 4)
        XCTAssertEqual(claimReads.associationRows, 12)
    }

    func testDatedManualKeepAdmissionBatchSkipsSupersededItemAndContinues() async throws {
        let url = makeURL(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = try LocalLibraryStore(url: url)
        let first = try aliasEpisode("batch-first"), stale = try aliasEpisode("batch-stale"), last = try aliasEpisode("batch-last")
        for episode in [first, stale, last] { try await store.save(episode: episode) }
        let newer = Timestamp(stale.createdAt.date.addingTimeInterval(100))
        try await store.save(episodeDecision: EpisodeDecisionRecord(episodeID: stale.itemID,
            decision: .skip, source: .manual, decidedAt: newer))
        var results: [[WorkTicket]] = []
        for episode in [first, stale, last] {
            do {
                results.append(try await store.admitEpisode(EpisodeDecisionRecord(episodeID: episode.itemID,
                    decision: .keep, source: .manual, decidedAt: episode.createdAt), workTicketKinds: [.podcastDownload]))
            } catch AutomaticEpisodeAdmissionError.supersededManualDecision { results.append([]) }
        }
        XCTAssertTrue(results[1].isEmpty)
        let snapshot = try await store.podcastLibrarySnapshot(profile: .publication)
        XCTAssertEqual(snapshot.podcastQueue.episodeIDs, [first.itemID, last.itemID])
        XCTAssertEqual(snapshot.episodeDecisions[first.itemID]?.decision, .keep)
        XCTAssertEqual(snapshot.episodeDecisions[last.itemID]?.decision, .keep)
        XCTAssertEqual(snapshot.episodeDecisions[stale.itemID]?.decision, .skip)
        XCTAssertEqual(snapshot.episodeDecisions[stale.itemID]?.decidedAt, newer)
    }

    func testNoOpRestorePreservesPolicyDecisionProvenance() async throws {
        let url = makeURL(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = try LocalLibraryStore(url: url)
        let episode = try aliasEpisode("restore-noop")
        try await store.save(episode: episode)
        let decision = EpisodeDecisionRecord(episodeID: episode.itemID, decision: .keep,
            source: .policy, decidedAt: episode.createdAt)
        try await store.save(episodeDecision: decision)
        let restored = try await store.restoreEpisode(episode.itemID)
        let retained = try await store.episodeDecision(for: episode.itemID)
        XCTAssertFalse(restored)
        XCTAssertEqual(retained, decision)
    }
}

private final class AssociationReadRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var counts = (fetches: 0, rows: 0)
    private var invalidRecords: [UUID] = []
    func read(_ fetches: Int, _ rows: Int) {
        lock.lock(); defer { lock.unlock() }
        counts.fetches += fetches; counts.rows += rows
    }
    func invalid(_ id: UUID) {
        lock.lock(); defer { lock.unlock() }
        invalidRecords.append(id)
    }
    var fetches: Int { lock.lock(); defer { lock.unlock() }; return counts.fetches }
    var associationRows: Int { lock.lock(); defer { lock.unlock() }; return counts.rows }
    var invalidIDs: [UUID] { lock.lock(); defer { lock.unlock() }; return invalidRecords }
}
