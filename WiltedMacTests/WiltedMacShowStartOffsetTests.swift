import XCTest
import WiltedDomain
import WiltedLibrary
import WiltedProducer
@testable import WiltedMac

@MainActor
final class WiltedMacShowStartOffsetTests: XCTestCase {
    func testResetAllPersistsAndUndoRestoresThePerShowOffset() async throws {
        let created = Timestamp(Date(timeIntervalSince1970: 1_700_000_000))
        let url = URL(string: "https://offset.example.test/feed.xml")!
        let feedID = try ItemID.derivePodcastFeed(from: url)
        let feed = try PodcastFeed(itemID: feedID, canonicalURL: url, title: "Offset Show", createdAt: created)
        let model = WiltedMacModel(
            arguments: [], stateDirectoryOverride: wiltedTemporaryDirectory("show-start-offset-reset"),
            storeBootstrap: { url in
                let store = try LocalLibraryStore(url: url)
                try await store.save(feed: feed)
                try await store.save(subscription: PodcastSubscription(feedID: feedID, subscribedAt: created))
                return store
            }, preferences: WiltedMacTestPreferences.ephemeral())
        addTeardownBlock { await model.close() }
        model.startStoreBootstrap()
        await model.waitForStoreBootstrap()

        let board = WiltedMacFeedPolicyBoard(model: model)
        await board.reload()
        let saved = await board.setStartOffsetSeconds(45, for: feedID.rawValue)
        XCTAssertEqual(saved?.seconds, 45)
        XCTAssertEqual(board.customizedSettingNames(for: feedID.rawValue), ["Start new episodes at"])
        let undo = try XCTUnwrap(board.resetAllOverrides(for: feedID.rawValue))
        await board.showStartOffsetEditTasks[feedID.rawValue]?.value
        XCTAssertEqual(board.startOffsetSeconds(for: feedID.rawValue), 0)

        let restored = await board.undoResetAllOverrides(undo)
        XCTAssertTrue(restored)
        XCTAssertEqual(board.startOffsetSeconds(for: feedID.rawValue), 45)
        let store = try XCTUnwrap(model.store)
        let savedOffsets = try await WiltedMacShowStartOffsetStore(store: store).offsets(owner: "local-library")
        XCTAssertEqual(savedOffsets[feedID.rawValue]?.seconds, 45)
    }

    func testUndoDoesNotOverwriteAnOffsetEditedAfterReset() async throws {
        let created = Timestamp(Date(timeIntervalSince1970: 1_700_000_000))
        let url = URL(string: "https://offset-later.example.test/feed.xml")!
        let feedID = try ItemID.derivePodcastFeed(from: url)
        let feed = try PodcastFeed(itemID: feedID, canonicalURL: url, title: "Offset Show", createdAt: created)
        let model = WiltedMacModel(
            arguments: [], stateDirectoryOverride: wiltedTemporaryDirectory("show-start-offset-later-edit"),
            storeBootstrap: { url in
                let store = try LocalLibraryStore(url: url)
                try await store.save(feed: feed)
                try await store.save(subscription: PodcastSubscription(feedID: feedID, subscribedAt: created))
                return store
            }, preferences: WiltedMacTestPreferences.ephemeral())
        addTeardownBlock { await model.close() }
        model.startStoreBootstrap()
        await model.waitForStoreBootstrap()

        let board = WiltedMacFeedPolicyBoard(model: model)
        await board.reload()
        _ = await board.setStartOffsetSeconds(45, for: feedID.rawValue)
        let undo = try XCTUnwrap(board.resetAllOverrides(for: feedID.rawValue))
        await board.showStartOffsetEditTasks[feedID.rawValue]?.value
        _ = await board.setStartOffsetSeconds(90, for: feedID.rawValue)

        let restored = await board.undoResetAllOverrides(undo)
        XCTAssertTrue(restored)
        XCTAssertEqual(board.startOffsetSeconds(for: feedID.rawValue), 90)
    }
}
