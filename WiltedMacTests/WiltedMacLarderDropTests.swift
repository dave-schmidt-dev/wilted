import Foundation
import WiltedDomain
import WiltedProducer
import XCTest
@testable import WiltedMac

/// Dragging in the Larder: every position is reachable (first, middle, and the strip after the last
/// row), a drop persists through the store, and anything that is not one queued episode is refused.
@MainActor
final class WiltedMacLarderDropTests: XCTestCase {
    private let feedURL = URL(string: "https://feeds.example.test/drop.xml")!
    private let created = Timestamp(Date(timeIntervalSince1970: 1_700_000_000))

    /// A model on a real store with episodes "a", "b", "c", "d" queued in that order.
    private func model() async throws -> (WiltedMacModel, LocalLibraryStore, [String]) {
        let model = WiltedMacModel(
            arguments: [], stateDirectoryOverride: wiltedTemporaryDirectory("larder-drop"),
            storeBootstrap: { url in try LocalLibraryStore(url: url) },
            preferences: WiltedMacTestPreferences.ephemeral())
        model.startStoreBootstrap()
        await model.waitForStoreBootstrap()
        let store = try XCTUnwrap(model.store)
        let feedID = try ItemID.derivePodcastFeed(from: feedURL)
        try await store.save(feed: try PodcastFeed(
            itemID: feedID, canonicalURL: feedURL, title: "Show", createdAt: created))
        var ids: [ItemID] = []
        for guid in ["a", "b", "c", "d"] {
            let enclosure = URL(string: "https://media.example.test/\(guid).mp3")!
            let id = try ItemID.derivePodcastEpisode(feedURL: feedURL, rssGUID: guid, enclosureURL: enclosure)
            try await store.save(episode: try PodcastEpisode(
                itemID: id, feedID: feedID, feedURL: feedURL, rssGUID: guid, title: "Episode \(guid)",
                publishedTime: created, enclosureURL: enclosure, enclosureMediaType: "audio/mpeg",
                createdAt: created))
            ids.append(id)
        }
        try await store.replacePodcastQueue(try PodcastQueueState(episodeIDs: ids))
        await model.reloadLibraryRowsForTesting()
        await model.refreshPodcastQueueState()
        XCTAssertNotNil(model.playback, "a drop writes through the playback controller")
        XCTAssertEqual(model.podcastQueueIDs, ids.map(\.rawValue))
        return (model, store, ids.map(\.rawValue))
    }

    private func durableQueue(_ store: LocalLibraryStore) async throws -> [String] {
        try await store.podcastQueueState().episodeIDs.map(\.rawValue)
    }

    /// Waits for the reorder a drop started to reach the store and the local list.
    private func expectQueue(
        _ expected: [String], _ model: WiltedMacModel, _ store: LocalLibraryStore,
        file: StaticString = #filePath, line: UInt = #line
    ) async throws {
        await WiltedMacHeadless.eventually("the reorder settles", file: file, line: line) {
            model.podcastQueueIDs == expected && model.playbackOperationStatus == nil
        }
        let durable = try await durableQueue(store)
        XCTAssertEqual(durable, expected, "the store holds the dropped order", file: file, line: line)
    }

    func testDroppingMovesAnEpisodeToFirstMiddleAndLastPositions() async throws {
        let (model, store, ids) = try await model()
        let (a, b, c, d) = (ids[0], ids[1], ids[2], ids[3])

        XCTAssertTrue(model.dropLarderEpisodes([d], before: a), "first position")
        try await expectQueue([d, a, b, c], model, store)

        XCTAssertTrue(model.dropLarderEpisodes([d], before: c), "middle position")
        try await expectQueue([a, b, d, c], model, store)

        XCTAssertTrue(model.dropLarderEpisodes([a], before: nil), "the strip after the last row")
        try await expectQueue([b, d, c, a], model, store)
    }

    func testDroppingUnderACalculatedSortSelectsCustomOrder() async throws {
        let (model, store, ids) = try await model()
        model.larderSort = .alphabetical
        await WiltedMacHeadless.eventually("the sort settles") { !model.isApplyingLarderSort }
        XCTAssertTrue(model.dropLarderEpisodes([ids[0]], before: nil))
        XCTAssertEqual(model.larderSort, .custom, "a drag is an explicit custom order")
        try await expectQueue([ids[1], ids[2], ids[3], ids[0]], model, store)
    }

    func testForeignUnknownAndMixedPayloadsAreRefusedAndChangeNothing() async throws {
        let (model, store, ids) = try await model()
        let prior = model.podcastQueueIDs
        let unknown = "item-" + String(repeating: "f", count: 64)
        let payloads: [[String]] = [
            [],
            ["file:///Users/dave/Downloads/invoice.pdf"],
            ["just some dragged text"],
            [unknown],
            [ids[0], "just some dragged text"],
            [ids[0], unknown],
            [ids[0], ids[1]],
        ]
        for payload in payloads {
            XCTAssertFalse(model.dropLarderEpisodes(payload, before: ids[2]), "row refused \(payload)")
            XCTAssertFalse(model.dropLarderEpisodes(payload, before: nil), "tail refused \(payload)")
        }
        XCTAssertFalse(model.dropLarderEpisodes([ids[0]], before: unknown), "an unknown destination is refused")
        XCTAssertEqual(model.podcastQueueIDs, prior, "the queue equals its prior order")
        XCTAssertNil(model.playbackOperationStatus, "no reorder was started")
        let durable = try await durableQueue(store)
        XCTAssertEqual(durable, prior, "the store is untouched")
    }

    /// The row and the strip are the only drop targets; both go through the validating entry point.
    func testViewsRouteEveryDropThroughTheValidatingEntryPoint() throws {
        let rows = try WiltedMacHeadless.viewSource("WiltedMacLarderView+Rows.swift")
        let sections = try WiltedMacHeadless.viewSource("WiltedMacLarderView+Sections.swift")
        XCTAssertEqual(WiltedMacHeadless.occurrences(of: "model.dropLarderEpisodes(draggedIDs, before: episode.id)", in: rows), 1)
        XCTAssertEqual(WiltedMacHeadless.occurrences(of: "model.dropLarderEpisodes(draggedIDs, before: nil)", in: sections), 1)
        for source in [rows, sections] {
            XCTAssertFalse(source.contains("draggedIDs.first"), "a drop must not read only the first payload")
        }
        XCTAssertTrue(sections.contains("wilted-larder-drop-tail"))
    }
}
