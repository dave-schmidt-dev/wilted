import Foundation
import XCTest
import WiltedDomain
import WiltedProducer
@testable import WiltedMac

extension WiltedMacModelTests {
    private func feedRenameFixture() async throws -> WiltedMacModel {
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
                return store
            }, preferences: WiltedMacTestPreferences.ephemeral())
        model.startStoreBootstrap()
        await model.waitForStoreBootstrap()
        return model
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
