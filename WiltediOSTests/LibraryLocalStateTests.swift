import CryptoKit
import Foundation
import WiltedDomain
import WiltedLibrary
import XCTest
@testable import WiltediOS

/// A launch with no signal (a car, a tunnel) must still list and play what is on the phone.
@MainActor
final class LibraryLocalStateTests: XCTestCase {
    private var scratch: URL!
    private let entryID = try! ItemID(rawValue: "item-a")
    private let revisionID = try! RevisionID(rawValue: "rev-1")
    private let payload = Data((0..<2_000).map { UInt8($0 % 251) })

    override func setUp() async throws {
        scratch = FileManager.default.temporaryDirectory.appendingPathComponent("library-local-state-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    override func tearDown() async throws { try? FileManager.default.removeItem(at: scratch) }

    private func defaults() -> UserDefaults {
        let suite = "wilted.localstate.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        return defaults
    }

    func testOfflineLaunchListsTheEpisodeAlreadyOnThePhone() async throws {
        // A first session syncs once, leaving the library in the store and the audio in the cache.
        let server = InMemoryLibraryServer(writerDeviceID: "mac")
        let mac = InMemoryLibraryTransport(deviceID: "mac", server: server)
        let show = LibrarySource(id: try ItemID(rawValue: "show"), kind: .podcastFeed, title: "The Show")
        let entry = try LibraryEntry(
            id: entryID, kind: .podcastEpisode, sourceID: show.id, title: "Episode A", summary: "",
            publishedAt: Date(timeIntervalSince1970: 1_600_000_000), durationSeconds: 1_800)
        let changes: [LibraryChange] = [.source(show), .entry(entry), .slot(try QueueSlot(entryID: entryID, sortKey: 0))]
        let pending = changes.enumerated().map { PendingLibraryChange(localSeq: UInt64($0.offset + 1), change: $0.element, baseVersion: 0) }
        _ = try await mac.push(changes: pending)

        let store = InMemoryLibraryStore()
        let cache = FileMediaCache(rootURL: scratch.appendingPathComponent("cache"))
        let online = LibraryAppModel(
            transport: InMemoryLibraryTransport(deviceID: "phone", server: server), store: store, deviceID: "phone",
            mediaCache: cache, preferences: defaults())
        await online.refresh()
        XCTAssertEqual(online.queued.map(\.id), [entryID])

        let file = scratch.appendingPathComponent("incoming.mp4")
        try payload.write(to: file)
        let hash = MediaHash.prefix + SHA256.hash(data: payload).map { String(format: "%02x", $0) }.joined()
        let offer = try LibraryMediaOffer(
            entryID: entryID, revisionID: revisionID, contentHash: hash, byteCount: Int64(payload.count),
            mediaType: "audio/mp4", durationSeconds: 60)
        _ = try await cache.adopt(verifiedFile: file, for: offer)

        // A later launch with no network: nothing is fetched, yet the row and "On phone" are there.
        let offline = LibraryAppModel(
            transport: UnavailableLibraryTransport(reason: "no signal"), store: store, deviceID: "phone",
            mediaCache: cache, preferences: defaults())
        XCTAssertTrue(offline.queued.isEmpty)
        await offline.loadLocalState()

        XCTAssertEqual(offline.queued.map(\.id), [entryID])
        XCTAssertEqual(offline.media[entryID], .onPhone)
        XCTAssertEqual(offline.visibleRows.map(\.id), [entryID])
        let list = CarEpisodeList.make(model: offline, playingID: nil)
        guard case let .episodes(rows) = list.content else { return XCTFail("the car list is empty: \(list.content)") }
        XCTAssertEqual(rows.map(\.id), [entryID])
    }

    func testOfflineLaunchWithNothingOnThePhoneStaysEmpty() async {
        let model = LibraryAppModel(
            transport: UnavailableLibraryTransport(reason: "no signal"), deviceID: "phone",
            mediaCache: FileMediaCache(rootURL: scratch.appendingPathComponent("cache")), preferences: defaults())
        await model.loadLocalState()
        XCTAssertTrue(model.queued.isEmpty)
        XCTAssertTrue(model.media.isEmpty)
    }
}
