import Foundation
import XCTest
import WiltedDomain
import WiltedProducer
@testable import WiltedMac

extension WiltedMacModelTests {
    private func feedRenameFixture(twoFeeds: Bool = false) async throws -> WiltedMacModel {
        let directory = temporaryDirectory("feed-rename")
        let model = WiltedMacModel(
            arguments: [], stateDirectoryOverride: directory,
            storeBootstrap: { url in
                let store = try LocalLibraryStore(url: url)
                let feedURL = URL(string: "https://feeds.example.test/rename.xml")!
                let id = try ItemID.derivePodcastFeed(from: feedURL)
                let created = Timestamp(Date(timeIntervalSince1970: 1_700_000_000))
                try await store.save(feed: PodcastFeed(
                    itemID: id, canonicalURL: feedURL, title: "Publisher title", createdAt: created))
                try await store.save(subscription: PodcastSubscription(feedID: id, subscribedAt: created))
                try await store.save(episode: PodcastEpisode(
                    itemID: ItemID.derivePodcastEpisode(feedURL: feedURL, rssGUID: "rename",
                        enclosureURL: URL(string: "https://media.example.test/rename.mp3")!),
                    feedID: id, feedURL: feedURL, rssGUID: "rename", title: "Episode",
                    publishedTime: created, enclosureURL: URL(string: "https://media.example.test/rename.mp3")!,
                    enclosureMediaType: "audio/mpeg", createdAt: created))
                if twoFeeds {
                    let url = URL(string: "https://feeds.example.test/second.xml")!
                    let secondID = try ItemID.derivePodcastFeed(from: url)
                    try await store.save(feed: PodcastFeed(
                        itemID: secondID, canonicalURL: url, title: "Second publisher", createdAt: created))
                    try await store.save(subscription: PodcastSubscription(feedID: secondID, subscribedAt: created))
                }
                return store
            }, preferences: WiltedMacTestPreferences.ephemeral())
        model.startStoreBootstrap()
        await model.waitForStoreBootstrap()
        return model
    }

    func testFeedRenameDisplaysBeforeBlockedWriterAndSurvivesPendingReload() async throws {
        let model = try await feedRenameFixture()
        let store = try XCTUnwrap(model.store)
        let row = try XCTUnwrap(model.subscriptions.first)
        let gate = FeedRenameGate()
        model.subscriptionWriteHookForTesting = { await gate.hold() }
        let writer = Task { try await model.renameSubscription(row, to: "  Owner now  ") }
        await gate.waitForEntries(1)
        XCTAssertEqual(model.subscriptions.first?.title, "Owner now")
        XCTAssertEqual(model.episodes.first?.feedTitle, "Owner now")
        XCTAssertTrue(model.isFeedWritePending(row.id))
        let savedBefore = try await store.subscription(for: ItemID(rawValue: row.id))
        XCTAssertNil(savedBefore?.displayName, "the store writer is still blocked")
        await model.reloadLibraryRows()
        XCTAssertEqual(model.subscriptions.first?.title, "Owner now", "old durable title cannot replace pending display")
        await gate.release()
        try await writer.value
        let savedAfter = try await store.subscription(for: ItemID(rawValue: row.id))
        XCTAssertEqual(savedAfter?.displayName, "Owner now")
        XCTAssertFalse(model.isFeedWritePending(row.id))
        await model.close()
    }

    func testFeedRenameWriterFailureRollsBackOnlyNameAndReportsError() async throws {
        let model = try await feedRenameFixture()
        let row = try XCTUnwrap(model.subscriptions.first)
        let before = model.episodes
        model.subscriptionWriteHookForTesting = { throw FeedRenameFailure.refused }
        do { try await model.renameSubscription(row, to: "Cannot save"); XCTFail("writer failure must propagate") }
        catch { XCTAssertTrue(error is FeedRenameFailure) }
        XCTAssertEqual(model.subscriptions.first, row)
        XCTAssertEqual(model.episodes, before, "failure must not reconstruct episode state")
        XCTAssertTrue(model.podcastOperationMessage?.contains("could not be renamed") == true)
        XCTAssertFalse(model.isFeedWritePending(row.id))
        await model.close()
    }

    func testTwoFeedRenamesPersistIndependentlyWhileBothArePending() async throws {
        let model = try await feedRenameFixture(twoFeeds: true)
        let rows = model.subscriptions
        XCTAssertEqual(rows.count, 2)
        let gate = FeedRenameGate()
        model.subscriptionWriteHookForTesting = { await gate.hold() }
        let first = Task { try await model.renameSubscription(rows[0], to: "First owner name") }
        let second = Task { try await model.renameSubscription(rows[1], to: "Second owner name") }
        await gate.waitForEntries(2)
        XCTAssertEqual(model.pendingFeedRenames.count, 2)
        XCTAssertEqual(model.subscriptions.first { $0.id == rows[0].id }?.title, "First owner name")
        XCTAssertEqual(model.subscriptions.first { $0.id == rows[1].id }?.title, "Second owner name")
        await gate.release()
        try await first.value
        try await second.value
        let store = try XCTUnwrap(model.store)
        let firstSaved = try await store.subscription(for: ItemID(rawValue: rows[0].id))
        let secondSaved = try await store.subscription(for: ItemID(rawValue: rows[1].id))
        XCTAssertEqual(firstSaved?.displayName, "First owner name")
        XCTAssertEqual(secondSaved?.displayName, "Second owner name")
        XCTAssertTrue(model.pendingFeedRenames.isEmpty)
        await model.close()
    }

    func testRenameAndStaleReloadCannotReshowSkippedEpisodeOrLoseManualDecision() async throws {
        let model = try await feedRenameFixture()
        let row = try XCTUnwrap(model.subscriptions.first)
        let episode = try XCTUnwrap(model.episodes.first)
        let readGate = FeedRenameGate()
        model.librarySnapshotReadBarrierForTesting = { await readGate.hold() }
        let staleRead = Task { await model.reloadLibraryRows() }
        await readGate.waitForEntries(1)
        model.librarySnapshotReadBarrierForTesting = nil
        let writerGate = FeedRenameGate()
        model.subscriptionWriteHookForTesting = { await writerGate.hold() }
        let rename = Task { try await model.renameSubscription(row, to: "Saved owner") }
        await writerGate.waitForEntries(1)
        model.decideFeedEpisodes(.skip, episodes: [episode])
        let decisionTask = model.feedDecisionWriteTailToken.flatMap { model.subscriptionWriteTasks[$0] }
        await decisionTask?.value
        let skipped = try XCTUnwrap(model.episodes.first { $0.id == episode.id })
        XCTAssertNotNil(skipped.retiredAt)
        await writerGate.release()
        try await rename.value
        await readGate.release()
        await staleRead.value
        let current = try XCTUnwrap(model.episodes.first { $0.id == episode.id })
        XCTAssertEqual(current.retiredAt, skipped.retiredAt)
        XCTAssertEqual(current.removalKind, skipped.removalKind)
        XCTAssertEqual(current.feedTitle, "Saved owner")
        let store = try XCTUnwrap(model.store)
        let decision = try await store.episodeDecision(for: ItemID(rawValue: episode.id))
        XCTAssertEqual(decision?.decision, .skip)
        XCTAssertEqual(decision?.source, .manual)
        XCTAssertEqual(model.subscriptions.first?.title, "Saved owner")
        await model.close()
    }

    func testClearingFeedNameShowsPublisherWhileWriterIsStillBlocked() async throws {
        let model = try await feedRenameFixture()
        try await model.renameSubscription(try XCTUnwrap(model.subscriptions.first), to: "Owner title")
        let row = try XCTUnwrap(model.subscriptions.first)
        let gate = FeedRenameGate()
        model.subscriptionWriteHookForTesting = { await gate.hold() }
        let writer = Task { try await model.renameSubscription(row, to: " \n ") }
        await gate.waitForEntries(1)
        XCTAssertEqual(model.subscriptions.first?.title, "Publisher title")
        XCTAssertEqual(model.episodes.first?.feedTitle, "Publisher title")
        await model.reloadLibraryRows()
        XCTAssertEqual(model.subscriptions.first?.title, "Publisher title", "pending clear overrides stored alias")
        await gate.release()
        try await writer.value
        let store = try XCTUnwrap(model.store)
        let saved = try await store.subscription(for: ItemID(rawValue: row.id))
        XCTAssertNil(saved?.displayName)
        await model.close()
    }

    func testFeedRenameReturnSavesAndEmptyRestoresPublisherTitle() async throws {
        let model = try await feedRenameFixture()
        let subscription = try XCTUnwrap(model.subscriptions.first)
        var draft = WiltedMacFeedRenameDraft()
        draft.begin(subscription)
        draft.text = "  Owner title  "
        XCTAssertTrue(draft.beginSaving())
        try await model.renameSubscription(subscription, to: draft.text)
        draft.finish()
        XCTAssertNil(draft.feedID)
        XCTAssertEqual(model.subscriptions.first?.title, "Owner title")
        XCTAssertEqual(model.episodes.first?.feedTitle, "Owner title")
        let store = try XCTUnwrap(model.store)
        let id = try ItemID(rawValue: subscription.id)
        let publisher = try await store.podcastFeed(for: id)
        XCTAssertEqual(publisher?.title, "Publisher title")
        try await model.renameSubscription(try XCTUnwrap(model.subscriptions.first), to: " \n ")
        XCTAssertEqual(model.subscriptions.first?.title, "Publisher title")
        XCTAssertEqual(model.episodes.first?.feedTitle, "Publisher title")
        let saved = try await store.subscription(for: id)
        XCTAssertNil(saved?.displayName)
        await model.close()
    }

    func testFeedRenameEscapeCancelsWithoutWriting() async throws {
        let model = try await feedRenameFixture()
        let subscription = try XCTUnwrap(model.subscriptions.first)
        var draft = WiltedMacFeedRenameDraft()
        draft.begin(subscription)
        draft.text = "Discarded title"
        draft.cancel()
        XCTAssertNil(draft.feedID)
        XCTAssertFalse(draft.beginSaving())
        XCTAssertEqual(model.subscriptions.first?.title, "Publisher title")
        let store = try XCTUnwrap(model.store)
        let saved = try await store.subscription(for: ItemID(rawValue: subscription.id))
        XCTAssertNil(saved?.displayName)
        await model.close()
    }

    func testFeedRenameFailureKeepsDraftAndUnsubscribeStillRequestsConfirmation() async throws {
        let model = try await feedRenameFixture()
        let subscription = try XCTUnwrap(model.subscriptions.first)
        var draft = WiltedMacFeedRenameDraft()
        draft.begin(subscription)
        draft.text = "Retry title"
        XCTAssertTrue(draft.beginSaving())
        draft.finish(error: "Could not save")
        XCTAssertEqual(draft.text, "Retry title")
        XCTAssertEqual(draft.feedID, subscription.id)
        XCTAssertFalse(draft.isSaving)
        let removal = WiltedMacRemovalFlow()
        removal.request(.feed(subscription))
        XCTAssertEqual(removal.requested, .feed(subscription))
        XCTAssertEqual(removal.requested?.confirmLabel, "Confirm unsubscribe")
        XCTAssertEqual(model.subscriptions.count, 1)
        removal.cancel()
        XCTAssertNil(removal.requested)
        XCTAssertEqual(model.subscriptions.count, 1)
        await model.close()
    }
}

private enum FeedRenameFailure: Error { case refused }

private actor FeedRenameGate {
    private var entries = 0
    private var released = false
    private var writers: [CheckedContinuation<Void, Never>] = []
    private var observers: [(Int, CheckedContinuation<Void, Never>)] = []

    func hold() async {
        entries += 1
        let ready = observers.filter { $0.0 <= entries }
        observers.removeAll { $0.0 <= entries }
        ready.forEach { $0.1.resume() }
        if released { return }
        await withCheckedContinuation { writers.append($0) }
    }

    func waitForEntries(_ count: Int) async {
        if entries >= count { return }
        await withCheckedContinuation { observers.append((count, $0)) }
    }

    func release() {
        released = true
        writers.forEach { $0.resume() }
        writers.removeAll()
    }
}
