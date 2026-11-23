import Foundation
import WiltedDomain
import WiltedLibrary
import XCTest
@testable import WiltedMac
@testable import WiltedProducer

/// Wilted no longer links episodes, but a link an earlier version made still folds its two episodes
/// into one row. These cover the one control left for it, the Larder's "Unlink Episodes…", which
/// replaces the reversal checks of the retired review sheet: the consequences are named before
/// anything changes, a stale review is refused, and the reversal reaches the library publisher.
@MainActor
final class WiltedMacLinkedEpisodeUnlinkTests: XCTestCase {
    let created = Date(timeIntervalSince1970: 1_700_000_000)
    let feedURL = URL(string: "https://feeds.example.test/linked-unlink.xml")!

    func episode(guid: String, title: String) throws -> PodcastEpisode {
        let enclosure = URL(string: "https://media.example.test/unlink-\(guid).mp3")!
        return try PodcastEpisode(
            itemID: ItemID.derivePodcastEpisode(feedURL: feedURL, rssGUID: guid, enclosureURL: enclosure),
            feedID: ItemID.derivePodcastFeed(from: feedURL), feedURL: feedURL, rssGUID: guid,
            title: title, publishedTime: Timestamp(created), enclosureURL: enclosure,
            enclosureMediaType: "audio/mpeg", durationSeconds: 3_600, createdAt: Timestamp(created)
        )
    }

    func makeModel(_ suffix: String) -> WiltedMacModel {
        WiltedMacModel(
            arguments: [], stateDirectoryOverride: wiltedTemporaryDirectory("linked-unlink-\(suffix)"),
            storeBootstrap: { url in try LocalLibraryStore(url: url) },
            preferences: WiltedMacTestPreferences.ephemeral()
        )
    }

    private func linkedPair(
        _ suffix: String, firstDecision: EpisodeDecision? = .keep
    ) async throws -> (model: WiltedMacModel, store: LocalLibraryStore, first: ItemID, second: ItemID, association: PodcastEpisodeAssociation) {
        let model = makeModel(suffix)
        model.startStoreBootstrap()
        await model.waitForStoreBootstrap()
        addTeardownBlock { await model.close() }
        let store = try XCTUnwrap(model.store)
        let first = try episode(guid: "unlink-first", title: "Unlink Same Title")
        let second = try episode(guid: "unlink-second", title: "Unlink Same Title")
        for value in [first, second] { try await store.save(episode: value) }
        try await store.save(subscription: PodcastSubscription(feedID: first.feedID, subscribedAt: Timestamp(created)))
        if let firstDecision {
            try await store.save(episodeDecision: EpisodeDecisionRecord(
                episodeID: first.itemID, decision: firstDecision, source: .manual, decidedAt: Timestamp(created)
            ))
        }
        let confirmation = PodcastEpisodePairConfirmation(
            confirmationID: UUID(), feedID: first.feedID, first: first.itemID, second: second.itemID,
            confirmedAt: Timestamp(created)
        )
        let preview = try await store.previewEpisodeAssociation(confirming: confirmation, representativeID: first.itemID)
        let association = try await store.applyEpisodeAssociation(preview)
        await model.reloadLibraryRows()
        return (model, store, first.itemID, second.itemID, association)
    }

    func testUnlinkNamesEachMemberThenReversesOnlyTheLink() async throws {
        let pair = try await linkedPair("names")
        let row = try XCTUnwrap(pair.model.episodes.first { $0.id == pair.first.rawValue })
        XCTAssertNotNil(pair.model.linkedEpisodeAssociation(for: row))

        let prepared = await pair.model.prepareLinkedEpisodeUnlink(for: row)
        let unlink = try XCTUnwrap(prepared)
        XCTAssertTrue(unlink.preview.consequences.warnsAutomationMayRetire)
        let labels = WiltedMacModel.linkedEpisodeMemberLabels(for: [pair.first, pair.second], episodes: pair.model.episodes)
        let firstLabel = try XCTUnwrap(labels[pair.first.rawValue])
        let secondLabel = try XCTUnwrap(labels[pair.second.rawValue])
        XCTAssertNotEqual(firstLabel, secondLabel, "two episodes that share a title still read differently")
        XCTAssertTrue(unlink.summary.contains("\(secondLabel) has no Keep of its own and loses the pair's inherited protection"), unlink.summary)
        XCTAssertTrue(unlink.summary.contains("Later feed automation may retire it and delete its unprotected media"), unlink.summary)
        XCTAssertTrue(unlink.summary.contains("\(firstLabel) keeps its own manual choice"), unlink.summary)
        let before = try await pair.store.episodeAssociations()
        XCTAssertEqual(before.count, 1, "reviewing changes nothing")

        let reversed = await pair.model.unlinkEpisodes(unlink)
        XCTAssertTrue(reversed)
        let active = try await pair.store.episodeAssociations()
        XCTAssertTrue(active.isEmpty)
        let history = try await pair.store.episodeAssociations(includingReversed: true)
        XCTAssertEqual(history.map(\.associationID), [pair.association.associationID])
        XCTAssertFalse(try XCTUnwrap(history.first).isActive, "the reversal stays in the history, inactive")
        XCTAssertTrue(pair.model.episodeAssociations.isEmpty, "the Larder shows two rows again")
        let decisions = try await pair.store.decisions(forFeed: pair.association.feedID)
        XCTAssertEqual(decisions.first { $0.episodeID == pair.first }?.decision, .keep, "the owner's own choice survives")
    }

    func testAStaleReviewIsRefusedAndNothingChanges() async throws {
        let pair = try await linkedPair("stale")
        let row = try XCTUnwrap(pair.model.episodes.first { $0.id == pair.first.rawValue })
        let prepared = await pair.model.prepareLinkedEpisodeUnlink(for: row)
        let unlink = try XCTUnwrap(prepared)
        _ = try await pair.store.reverseEpisodeAssociation(unlink.preview)
        let again = await pair.model.unlinkEpisodes(unlink)
        XCTAssertFalse(again)
        XCTAssertNotNil(pair.model.podcastOperationMessage)
    }

    func testSummaryNamesANewerGroupChoiceOverAnOlderOpposingOne() async throws {
        let pair = try await linkedPair("override", firstDecision: nil)
        try await pair.store.save(episodeDecision: EpisodeDecisionRecord(
            episodeID: pair.second, decision: .skip, source: .manual, decidedAt: Timestamp(created)
        ))
        try await pair.store.save(episodeDecision: EpisodeDecisionRecord(
            episodeID: pair.first, decision: .keep, source: .manual,
            decidedAt: Timestamp(created.addingTimeInterval(60))
        ))
        await pair.model.reloadLibraryRows()
        let row = try XCTUnwrap(pair.model.episodes.first { $0.id == pair.first.rawValue })
        let prepared = await pair.model.prepareLinkedEpisodeUnlink(for: row)
        let unlink = try XCTUnwrap(prepared)
        XCTAssertFalse(unlink.preview.consequences.warnsAutomationMayRetire)
        let secondLabel = try XCTUnwrap(
            WiltedMacModel.linkedEpisodeMemberLabels(for: [pair.first, pair.second], episodes: pair.model.episodes)[pair.second.rawValue]
        )
        XCTAssertTrue(unlink.summary.contains("\(secondLabel) keeps its own earlier Skip"), unlink.summary)
        XCTAssertTrue(unlink.summary.contains("the pair's newer Keep no longer applies"), unlink.summary)
        XCTAssertTrue(unlink.summary.contains("still shields it from automatic rules"), unlink.summary)
        XCTAssertFalse(unlink.summary.contains("delete its unprotected media"), unlink.summary)
    }

    func testUnlinkFlowsThroughTheExistingDebouncedPublisher() async throws {
        let model = makeModel("sync")
        addTeardownBlock { await model.close() }
        model.startStoreBootstrap()
        await model.waitForStoreBootstrap()
        let store = try XCTUnwrap(model.store)
        let device = model.libraryDeviceID()
        let server = InMemoryLibraryServer(writerDeviceID: device)
        let account = WiltedMacLibraryAccountFixture()
        XCTAssertTrue(model.startLibrarySyncIfEnabled(
            environment: ["WILTED_LIBRARY_SYNC": "1"],
            transport: InMemoryLibraryTransport(deviceID: device, server: server),
            debounce: .milliseconds(20), account: account.source
        ))
        account.signIn(recordName: "unlink-owner")
        await WiltedMacHeadless.eventually("account gate open") { model.libraryAccountStatus == .active }
        let first = try episode(guid: "sync-first", title: "Sync First")
        let second = try episode(guid: "sync-second", title: "Sync Second")
        for value in [first, second] { try await store.save(episode: value) }
        try await store.save(subscription: PodcastSubscription(feedID: first.feedID, subscribedAt: Timestamp(created)))
        await model.reloadLibraryRows()
        let controller = try XCTUnwrap(model.librarySyncController)
        await controller.tickRound()
        try await waitFor("baseline publication") {
            await server.currentSnapshot.entries[first.itemID] != nil
        }
        let confirmation = PodcastEpisodePairConfirmation(
            confirmationID: UUID(), feedID: first.feedID, first: first.itemID, second: second.itemID,
            confirmedAt: Timestamp(created)
        )
        let preview = try await store.previewEpisodeAssociation(confirming: confirmation, representativeID: first.itemID)
        let association = try await store.applyEpisodeAssociation(preview)
        await model.reloadLibraryRows()
        model.librarySyncController?.requestPublish()
        try await waitFor("association published") {
            await server.currentSnapshot.entries[second.itemID]?.episodeAssociation?.groupID == association.associationID
        }
        let row = try XCTUnwrap(model.episodes.first { $0.id == first.itemID.rawValue })
        let prepared = await model.prepareLinkedEpisodeUnlink(for: row)
        let unlink = try XCTUnwrap(prepared)
        let reversed = await model.unlinkEpisodes(unlink)
        XCTAssertTrue(reversed)
        try await waitFor("reversal published") {
            let entries = await server.currentSnapshot.entries
            return entries[second.itemID]?.episodeAssociation == nil && entries[first.itemID]?.episodeAssociation == nil
        }
        model.stopLibrarySync()
        await model.waitForLibrarySyncShutdown()
        XCTAssertGreaterThanOrEqual(controller.passCount, 1)
    }

    /// A link must be undoable wherever its episodes are: a pair that is not waiting has no Larder row,
    /// and a finished pair has none in the Larder or in Feeds. The Linked episodes list names both.
    func testEveryLinkIsReachableWhateverStateItsEpisodesAreIn() async throws {
        let pair = try await linkedPair("reachable")
        XCTAssertTrue(pair.model.larderWaitingEpisodes.isEmpty, "an unqueued pair has no Larder row")
        var listed = pair.model.linkedEpisodePairs
        XCTAssertEqual(listed.map(\.id), [pair.association.associationID])
        XCTAssertEqual(Set(listed[0].memberLabels).count, 2, "both members are named apart")

        let finished = try XCTUnwrap(pair.model.episodeAssociations[pair.first.rawValue])
        pair.model.episodeAssociations[pair.first.rawValue] = LibraryEpisodeAssociation(
            groupID: finished.groupID, representativeID: finished.representativeID, memberIDs: finished.memberIDs,
            associationVersion: finished.associationVersion, isTerminal: true
        )
        pair.model.episodeAssociations[pair.second.rawValue] = pair.model.episodeAssociations[pair.first.rawValue]
        XCTAssertTrue(pair.model.larderVisibleEpisodes.filter { [pair.first.rawValue, pair.second.rawValue].contains($0.id) }.isEmpty,
                      "a finished pair is hidden from the Larder")
        XCTAssertTrue(pair.model.feedsEpisodes.filter { [pair.first.rawValue, pair.second.rawValue].contains($0.id) }.isEmpty,
                      "and from Feeds")
        listed = pair.model.linkedEpisodePairs
        XCTAssertEqual(listed.map(\.id), [pair.association.associationID], "the list still carries it")
        XCTAssertTrue(listed[0].association.isTerminal)

        await pair.model.reloadLibraryRows()
        let prepared = await pair.model.prepareLinkedEpisodeUnlink(for: listed[0].association)
        let unlink = try XCTUnwrap(prepared)
        let reversed = await pair.model.unlinkEpisodes(unlink)
        XCTAssertTrue(reversed)
        XCTAssertTrue(pair.model.linkedEpisodePairs.isEmpty)
    }

    private func waitFor(
        _ what: String, timeout: Duration = .seconds(10), _ condition: @MainActor () async -> Bool
    ) async throws {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(25))
        }
        if await condition() { return }
        XCTFail("timed out waiting for \(what)")
    }
}
