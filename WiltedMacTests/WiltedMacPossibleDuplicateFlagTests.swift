import Foundation
import WiltedDomain
import WiltedLibrary
import WiltedProducer
import XCTest
@testable import WiltedMac

/// A suspected duplicate gets a badge and is kept out of automatic preparation only. "Different" clears
/// it. Every store is test-owned and synthetic; no test touches the network.
@MainActor
final class WiltedMacPossibleDuplicateFlagTests: XCTestCase {
    let created = Date(timeIntervalSince1970: 1_700_000_000)
    let feedURL = URL(string: "https://feeds.example.test/possible-duplicate.xml")!

    private func episode(guid: String) throws -> PodcastEpisode {
        let enclosure = URL(string: "https://media.example.test/dup-\(guid).mp3")!
        return try PodcastEpisode(
            itemID: ItemID.derivePodcastEpisode(feedURL: feedURL, rssGUID: guid, enclosureURL: enclosure),
            feedID: ItemID.derivePodcastFeed(from: feedURL), feedURL: feedURL, rssGUID: guid,
            title: "Same Title", publishedTime: Timestamp(created), enclosureURL: enclosure,
            enclosureMediaType: "audio/mpeg", durationSeconds: 3_600, createdAt: Timestamp(created)
        )
    }

    private func flaggedModel() async throws -> (WiltedMacModel, ItemID, ItemID) {
        let model = WiltedMacModel(
            arguments: [], stateDirectoryOverride: wiltedTemporaryDirectory("possible-duplicate-flag"),
            storeBootstrap: { url in try LocalLibraryStore(url: url) },
            preferences: WiltedMacTestPreferences.ephemeral()
        )
        model.startStoreBootstrap()
        await model.waitForStoreBootstrap()
        addTeardownBlock { await model.close() }
        let store = try XCTUnwrap(model.store)
        let first = try episode(guid: "dup-first")
        let second = try episode(guid: "dup-second")
        try await store.save(episode: first)
        try await store.save(subscription: PodcastSubscription(
            feedID: first.feedID, subscribedAt: Timestamp(created)
        ))
        _ = try await store.admitPodcastEpisodes([first, second], admission: .incremental, claimingNewest: 5)
        await model.reloadLibraryRows()
        return (model, first.itemID, second.itemID)
    }

    func testNewcomerShowsBadgeAndStaysOutOfAutomaticPreparation() async throws {
        let (model, first, second) = try await flaggedModel()
        let flagged = try XCTUnwrap(model.episodes.first { $0.id == second.rawValue })
        let original = try XCTUnwrap(model.episodes.first { $0.id == first.rawValue })
        XCTAssertEqual(flagged.possibleDuplicateOf, "Same Title")
        XCTAssertNil(original.possibleDuplicateOf)
        let flaggedSuppressed = await model.automaticPreparationSuppressed(for: flagged)
        let originalSuppressed = await model.automaticPreparationSuppressed(for: original)
        XCTAssertTrue(flaggedSuppressed)
        XCTAssertFalse(originalSuppressed)
    }

    func testDifferentClearsTheFlagAndLiftsTheExclusion() async throws {
        let (model, _, second) = try await flaggedModel()
        let flagged = try XCTUnwrap(model.episodes.first { $0.id == second.rawValue })
        model.clearPossibleDuplicateFlag(flagged)
        for _ in 0..<100 where model.episodes.first(where: { $0.id == second.rawValue })?.possibleDuplicateOf != nil {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        let cleared = try XCTUnwrap(model.episodes.first { $0.id == second.rawValue })
        XCTAssertNil(cleared.possibleDuplicateOf)
        let suppressed = await model.automaticPreparationSuppressed(for: cleared)
        XCTAssertFalse(suppressed)
    }

    func testGateHoldsAFlaggedEpisodeAndBlocksWhenTheListCannotBeRead() async throws {
        let (model, first, second) = try await flaggedModel()
        XCTAssertTrue(model.automaticWorkIsHeld(second.rawValue))
        XCTAssertFalse(model.automaticWorkIsHeld(first.rawValue))
        let fresh = await model.automaticWorkIsHeldFresh(second.rawValue)
        XCTAssertTrue(fresh)
        model.possibleDuplicateHeldIDs = nil
        XCTAssertTrue(model.automaticWorkIsHeld(first.rawValue), "an unreadable list blocks rather than allows")
    }

    func testAutomaticStartsLeaveAFlaggedEpisodeAlone() async throws {
        let (model, _, second) = try await flaggedModel()
        let flagged = try XCTUnwrap(model.episodes.first { $0.id == second.rawValue })
        model.downloadEpisode(flagged, automatic: true)
        model.prepareEpisode(flagged, automatic: true)
        model.admitAutomaticPreparation(for: flagged, at: Date())
        XCTAssertNil(model.podcastDownloadTasks[flagged.id])
        XCTAssertNil(model.podcastPreparationTasks[flagged.id])
        XCTAssertTrue(model.deferredAutomaticPreparations.isEmpty)
        let store = try XCTUnwrap(model.store)
        let claimed = try await store.claimPodcastDownload(episodeID: second, scope: .automaticNotInFlight)
        XCTAssertFalse(claimed)
    }

    func testAnUnreadableListBlocksButGivesUpNoWaitingWork() async throws {
        let (model, first, second) = try await flaggedModel()
        _ = model.reservePreparationRequest(for: first.rawValue)
        _ = model.reservePreparationRequest(for: second.rawValue)
        model.possibleDuplicateHeldIDs = nil
        XCTAssertEqual(model.automaticWorkGate(first.rawValue), .unknown)
        model.abandonAutomaticPreparation(for: first.rawValue)
        XCTAssertNotNil(model.preparationRequestSequences[first.rawValue], "an unrelated request stays")
        _ = await model.automaticWorkIsHeldFresh(second.rawValue)
        XCTAssertEqual(model.automaticWorkGate(first.rawValue), .clear)
        XCTAssertEqual(model.automaticWorkGate(second.rawValue), .held)
        model.abandonAutomaticPreparation(for: second.rawValue)
        XCTAssertNil(model.preparationRequestSequences[second.rawValue], "only the flagged one is given up")
        XCTAssertNotNil(model.preparationRequestSequences[first.rawValue])
    }

    func testRecoveredClaimsLeaveAFlaggedEpisodeAlone() async throws {
        let (model, _, second) = try await flaggedModel()
        let store = try XCTUnwrap(model.store)
        try await store.save(episodeDecision: EpisodeDecisionRecord(
            episodeID: second, decision: .keep, source: .manual, decidedAt: Timestamp(created)
        ))
        try await store.addPodcastQueueEpisode(second)
        try await store.save(download: PodcastDownload(episodeID: second, status: .queued, updatedAt: Timestamp(created)))
        await model.reloadLibraryRows()
        let claims = try await model.unfinishedAutomationClaims()
        XCTAssertFalse(claims.contains(second.rawValue), "a flagged claim waits for the owner")
        do {
            try await model.startClaimedDownload(second.rawValue, automatic: true)
            XCTFail("a held claim must not look like a started download")
        } catch let fault as WiltedAutomationFault {
            XCTAssertEqual(fault, .downloadHeld(second.rawValue))
        }
        XCTAssertNil(model.podcastDownloadTasks[second.rawValue])
    }

    func testDifferentOnAKeptEpisodeStartsTheHeldDownloadAndClearsItsNote() async throws {
        let (model, _, second) = try await flaggedModel()
        let store = try XCTUnwrap(model.store)
        try await store.save(episodeDecision: EpisodeDecisionRecord(
            episodeID: second, decision: .keep, source: .manual, decidedAt: Timestamp(created)
        ))
        try await store.addPodcastQueueEpisode(second)
        await model.reloadLibraryRows()
        try await store.save(
            feedAutomationPolicy: FeedAutomationPolicy(autoDownload: .on),
            for: try ItemID.derivePodcastFeed(from: feedURL)
        )
        let stillHeld = await model.catchUpAfterPossibleDuplicateCleared(second.rawValue)
        XCTAssertFalse(stillHeld, "a flag still on the row is not finished work, so the note stays")
        XCTAssertNil(model.podcastDownloadTasks[second.rawValue])
        model.notePossibleDuplicateCatchUp(second.rawValue, pending: true)
        XCTAssertEqual(model.preferences.stringArray(forKey: WiltedMacModel.possibleDuplicateCatchUpKey), [second.rawValue])
        _ = try await store.clearPodcastEpisodePossibleDuplicate(second)
        let done = await model.catchUpAfterPossibleDuplicateCleared(second.rawValue)
        XCTAssertTrue(done)
        let claims = try await store.unfinishedPodcastDownloads().map(\.episodeID)
        XCTAssertTrue(claims.contains(second) || model.podcastDownloadTasks[second.rawValue] != nil,
                      "the download Keep asked for is no longer lost")
        model.notePossibleDuplicateCatchUp(second.rawValue, pending: false)
        XCTAssertEqual(model.preferences.stringArray(forKey: WiltedMacModel.possibleDuplicateCatchUpKey) ?? [], [])
    }

    /// A quit between the noted answer and the flag deletion leaves both behind. The next launch
    /// treats the note as the owner's answer: it deletes the flag, does the held work and strikes the note.
    func testARelaunchFinishesADifferentAnswerWhoseFlagWasNeverDeleted() async throws {
        let (model, _, second) = try await flaggedModel()
        let store = try XCTUnwrap(model.store)
        try await store.save(episodeDecision: EpisodeDecisionRecord(
            episodeID: second, decision: .keep, source: .manual, decidedAt: Timestamp(created)
        ))
        try await store.addPodcastQueueEpisode(second)
        try await store.save(
            feedAutomationPolicy: FeedAutomationPolicy(autoDownload: .on),
            for: try ItemID.derivePodcastFeed(from: feedURL)
        )
        await model.reloadLibraryRows()
        model.notePossibleDuplicateCatchUp(second.rawValue, pending: true)
        let heldBefore = try await store.podcastEpisodeIdentityReviewHeldIDs()
        XCTAssertTrue(heldBefore.contains(second), "the flag survived the quit")

        model.resumePossibleDuplicateCatchUps()
        for _ in 0..<100 where !(model.preferences.stringArray(forKey: WiltedMacModel.possibleDuplicateCatchUpKey) ?? []).isEmpty {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        let heldAfter = try await store.podcastEpisodeIdentityReviewHeldIDs()
        XCTAssertFalse(heldAfter.contains(second), "the owner's answer is honoured, not discarded")
        XCTAssertEqual(model.preferences.stringArray(forKey: WiltedMacModel.possibleDuplicateCatchUpKey) ?? [], [])
        let claims = try await store.unfinishedPodcastDownloads().map(\.episodeID)
        XCTAssertTrue(claims.contains(second) || model.podcastDownloadTasks[second.rawValue] != nil)
    }

    func testACatchUpThatCannotFinishKeepsItsNote() async throws {
        let (model, _, second) = try await flaggedModel()
        model.notePossibleDuplicateCatchUp(second.rawValue, pending: true)
        model.isClosingTemporaryState = true
        let finished = await model.finishPossibleDuplicateDifferent(second.rawValue)
        XCTAssertFalse(finished, "a closing model has not done the work")
        XCTAssertEqual(model.preferences.stringArray(forKey: WiltedMacModel.possibleDuplicateCatchUpKey), [second.rawValue])
    }

    /// Makes `second` a kept, queued, downloaded episode that is still waiting for preparation.
    private func downloadedKeptEpisode(_ model: WiltedMacModel, _ second: ItemID) async throws {
        let store = try XCTUnwrap(model.store)
        try await store.save(episodeDecision: EpisodeDecisionRecord(
            episodeID: second, decision: .keep, source: .manual, decidedAt: Timestamp(created)
        ))
        try await store.addPodcastQueueEpisode(second)
        let media = wiltedTemporaryDirectory("possible-duplicate-media").appendingPathComponent("episode.m4a")
        try Data("audio".utf8).write(to: media)
        let hash = "sha256:" + String(repeating: "b", count: 64)
        try await store.finalizePodcastDownload(
            revision: try AudioRevision(
                itemID: second, revisionID: try RevisionID(rawValue: "rev-" + String(repeating: "b", count: 64)),
                durationSeconds: 12, byteCount: 5, contentHash: hash, mediaType: "audio/mpeg",
                createdAt: Timestamp(created), schemaVersion: 3),
            mediaURL: media,
            download: try PodcastDownload(
                episodeID: second, status: .completed, bytesReceived: 5, expectedByteCount: 5,
                localURL: media, contentHash: hash, updatedAt: Timestamp(created))
        )
        await model.reloadLibraryRows()
    }

    /// The flag list reads fine for the catch-up's first look but fails just before preparation would
    /// be asked for. That is not an answer about the episode, so the note must stay.
    func testAFailedSecondFlagReadKeepsTheDifferentNote() async throws {
        let (model, _, second) = try await flaggedModel()
        try await downloadedKeptEpisode(model, second)
        model.notePossibleDuplicateCatchUp(second.rawValue, pending: true)
        var reads = 0
        model.possibleDuplicateHoldReadFailsForTesting = {
            reads += 1
            return reads >= 3
        }
        let finished = await model.finishPossibleDuplicateDifferent(second.rawValue)
        XCTAssertEqual(reads, 3, "the third read, the one before preparation, is the one that failed")
        XCTAssertFalse(finished)
        XCTAssertEqual(model.preferences.stringArray(forKey: WiltedMacModel.possibleDuplicateCatchUpKey), [second.rawValue])
        model.possibleDuplicateHoldReadFailsForTesting = nil
        let retried = await model.finishPossibleDuplicateDifferent(second.rawValue)
        XCTAssertTrue(retried, "once the list reads, the same answer finishes")
    }

    /// A download lands while the flag list cannot be read: its preparation is neither admitted nor
    /// cancelled, and the next tick asks again instead of waiting for a relaunch.
    func testAnArrivalWithAnUnreadableFlagListIsRetriedLater() async throws {
        let (model, _, second) = try await flaggedModel()
        try await downloadedKeptEpisode(model, second)
        _ = try await XCTUnwrap(model.store).clearPodcastEpisodePossibleDuplicate(second)
        await model.reloadLibraryRows()
        let episode = try XCTUnwrap(model.episodes.first { $0.id == second.rawValue })
        let sequence = model.reservePreparationRequest(for: second.rawValue)
        model.possibleDuplicateHoldReadFailsForTesting = { true }
        await model.applyArrivalPreparationVerdict(for: episode)
        XCTAssertEqual(model.arrivalPreparationsAwaitingFlagList, [second.rawValue])
        XCTAssertEqual(model.preparationRequestSequences[second.rawValue], sequence, "the waiting request stays")
        model.possibleDuplicateHoldReadFailsForTesting = nil
        await model.retryArrivalPreparationsAwaitingFlagList()
        XCTAssertTrue(model.arrivalPreparationsAwaitingFlagList.isEmpty, "the retry settled it")
    }
}
