import Foundation
import XCTest
import WiltedDomain
@testable import WiltedProducer

final class LocalLibraryStoreFeedDisplayNameTests: XCTestCase {
    func testSubscriptionDisplayNameSurvivesCodableStoreRefreshAndRelaunch() async throws {
        let directory = OwnedTestTemp.root.appendingPathComponent("wilted-feed-name-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("library.sqlite")
        let feedURL = try XCTUnwrap(URL(string: "https://feeds.example.test/display-name.xml"))
        let feedID = try ItemID.derivePodcastFeed(from: feedURL)
        let timestamp = Timestamp(Date(timeIntervalSince1970: 1_700_000_000))
        let original = PodcastSubscription(feedID: feedID, subscribedAt: timestamp)
        let encoded = try JSONEncoder().encode(original)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object["displayName"] = "Owner's title"
        let named = try JSONDecoder().decode(PodcastSubscription.self, from: JSONSerialization.data(withJSONObject: object))
        let store = try LocalLibraryStore(url: url)
        try await store.save(subscription: named)
        try await store.save(feed: PodcastFeed(itemID: feedID, canonicalURL: feedURL, title: "Publisher refresh", createdAt: timestamp))
        let reopened = try LocalLibraryStore(url: url)
        let stored = try await reopened.subscription(for: feedID)
        let saved = try XCTUnwrap(stored)
        let savedObject = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(saved)) as? [String: Any])
        XCTAssertEqual(savedObject["displayName"] as? String, "Owner's title",
                       "the optional display name must survive Codable, storage, publisher refresh, and relaunch")
    }
    func testRenameAndEmptyClearUseLatestPublisherTitleWithoutChangingFeedMetadata() async throws {
        try await withFollowedFeed { store, id, url in
            try await store.setSubscriptionDisplayName(feedID: id, displayName: "  Owner name  ")
            let named = try await store.subscription(for: id)
            XCTAssertEqual(named?.displayName, "Owner name")
            let time = Timestamp(Date(timeIntervalSince1970: 1_700_000_000))
            try await store.save(feed: PodcastFeed(itemID: id, canonicalURL: url, title: "New publisher title", createdAt: time))
            let refreshed = try await store.subscription(for: id)
            let publisher = try await store.podcastFeed(for: id)
            XCTAssertEqual(refreshed?.displayName, "Owner name")
            XCTAssertEqual(publisher?.title, "New publisher title")
            try await store.setSubscriptionDisplayName(feedID: id, displayName: " \n ")
            let cleared = try await store.subscription(for: id)
            XCTAssertNil(cleared?.displayName)
            XCTAssertEqual(cleared?.displayName ?? publisher?.title, "New publisher title")
        }
    }

    func testToggleAndDuplicateAdmissionKeepDisplayNameAndOriginalAdmissionDate() async throws {
        try await withFollowedFeed { store, id, _ in
            try await store.setSubscriptionDisplayName(feedID: id, displayName: "Owner name")
            let original = try await store.subscription(for: id)
            let saved = try XCTUnwrap(original)
            try await store.save(subscription: PodcastSubscription(feedID: id, subscribedAt: saved.subscribedAt, enabled: false))
            let added = try await store.subscribeIfNeeded(PodcastSubscription(
                feedID: id, subscribedAt: Timestamp(Date()), enabled: true))
            XCTAssertFalse(added)
            let toggled = try await store.subscription(for: id)
            XCTAssertEqual(toggled?.displayName, "Owner name")
            XCTAssertEqual(toggled?.subscribedAt, saved.subscribedAt)
            XCTAssertEqual(toggled?.enabled, false)
        }
    }

    func testRenamingAnUnknownFeedDoesNotInventASubscription() async throws {
        try await withFollowedFeed { store, _, _ in
            let unknown = try ItemID.derivePodcastFeed(from: URL(string: "https://feeds.example.test/unknown-name.xml")!)
            do {
                try await store.setSubscriptionDisplayName(feedID: unknown, displayName: "Unknown")
                XCTFail("an unknown subscription must refuse rename")
            } catch {
                XCTAssertEqual(error as? LocalLibraryStoreError, .invalidPodcastState("subscription does not exist"))
            }
            let value = try await store.subscription(for: unknown)
            XCTAssertNil(value)
        }
    }

    func testOldSubscriptionPayloadWithoutDisplayNameStillDecodes() throws {
        let id = try ItemID.derivePodcastFeed(from: URL(string: "https://feeds.example.test/old-name.xml")!)
        let original = PodcastSubscription(feedID: id, subscribedAt: Timestamp(Date(timeIntervalSince1970: 1_700_000_000)))
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(original)) as? [String: Any])
        object.removeValue(forKey: "displayName")
        let decoded = try JSONDecoder().decode(PodcastSubscription.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertEqual(decoded, original)
        XCTAssertNil(decoded.displayName)
    }

    private func withFollowedFeed(
        _ operation: (LocalLibraryStore, ItemID, URL) async throws -> Void
    ) async throws {
        let directory = OwnedTestTemp.root.appendingPathComponent("wilted-feed-name-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = try XCTUnwrap(URL(string: "https://feeds.example.test/name-policy.xml"))
        let id = try ItemID.derivePodcastFeed(from: url)
        let time = Timestamp(Date(timeIntervalSince1970: 1_700_000_000))
        let store = try LocalLibraryStore(url: directory.appendingPathComponent("library.sqlite"))
        try await store.save(feed: PodcastFeed(itemID: id, canonicalURL: url, title: "Publisher", createdAt: time))
        try await store.save(subscription: PodcastSubscription(feedID: id, subscribedAt: time))
        try await operation(store, id, url)
    }

}
