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
        try await model.startClaimedDownload(second.rawValue, automatic: true)
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
        XCTAssertTrue(stillHeld, "while it is flagged nothing is owed")
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
}
