import Foundation
import XCTest
import WiltedDomain
import WiltedLibrary
@testable import WiltediOS

final class LibraryListenNextOutboxTests: XCTestCase {
    func testStoryCommandsUseTheirOwnVersionedFileAndRetainCancellationTombstones() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("listen-next-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let story = try LibraryHeadlineStory(
            id: "story-17", title: "A story", publisherID: "feed-5", publisherName: "Publisher",
            link: URL(string: "https://example.invalid/story"), publishedAt: now,
            firstSeenAt: now, lastSeenAt: now
        )
        let intent = try LibraryIntent.listenNext(
            story: story, anchorID: nil, deviceID: "phone-1", createdAt: now, id: "request-1"
        )
        let cancelled = try LibraryListenNextRequestSnapshot(
            requestID: intent.id, story: story, requesterDeviceID: "phone-1", ownerToken: "owner-1",
            operationGeneration: 7, anchorID: nil, createdAt: now, status: .cancelled
        )
        let entry = LibraryListenNextPhoneEntry(
            snapshot: cancelled, requestIntent: nil,
            cancellationIntent: try .cancelListenNext(
                requestID: intent.id, deviceID: "phone-1", createdAt: now, id: "cancel-1"
            ),
            requestAttempted: true, requestSent: true, audioCached: false, remoteStatusRevision: 4
        )
        let outbox = LibraryListenNextPhoneOutbox(url: url)
        let saved = LibraryListenNextPhoneOutbox.Saved(
            version: LibraryListenNextPhoneOutbox.version, ownerToken: "owner-1", entries: [entry]
        )

        try outbox.save(saved)

        guard case let .saved(restored) = outbox.load() else {
            return XCTFail("The cancellation tombstone did not survive reopening.")
        }
        XCTAssertEqual(restored, saved)
        XCTAssertEqual(restored.entries[0].snapshot.status, .cancelled)
        XCTAssertEqual(restored.entries[0].cancellationIntent?.id, "cancel-1")
    }

    func testUnsupportedNewActionDoesNotEnterTheExistingDecisionOutbox() throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let story = try LibraryHeadlineStory(
            id: "story-18", title: "A second story", publisherID: "feed-5", publisherName: "Publisher",
            link: URL(string: "https://example.invalid/story-2"), publishedAt: now,
            firstSeenAt: now, lastSeenAt: now
        )
        let request = try LibraryIntent.listenNext(
            story: story, anchorID: nil, deviceID: "phone-1", createdAt: now, id: "request-2"
        )
        let priorURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("intent-outbox-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: priorURL) }
        guard let feedURL = URL(string: "https://example.invalid/feed") else {
            return XCTFail("Fixture feed URL is invalid.")
        }
        let ordinary = try LibraryIntent.addLink(
            url: feedURL, deviceID: "phone-1", createdAt: now, id: "add-1"
        )
        let oldOutbox = LibraryIntentOutbox(url: priorURL)
        try oldOutbox.save(.init(ownerToken: "owner-1", adds: [.init(intent: ordinary, title: "Feed")]))
        guard case let .saved(preserved) = oldOutbox.load() else {
            return XCTFail("The existing decision outbox could not reopen.")
        }
        XCTAssertEqual(preserved.adds.first?.intent.id, "add-1")
        XCTAssertEqual(request.id, "request-2")
        XCTAssertEqual(LibraryListenNextPhoneOutbox.version, 1)
    }

    func testVersionOneOutboxInfersAnAttemptFromItsDurableRequestIntent() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("listen-next-legacy-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let story = try LibraryHeadlineStory(
            id: "story-19", title: "A legacy request", publisherID: "feed-5", publisherName: "Publisher",
            link: URL(string: "https://example.invalid/story-19"), publishedAt: now,
            firstSeenAt: now, lastSeenAt: now
        )
        let intent = try LibraryIntent.listenNext(
            story: story, anchorID: nil, deviceID: "phone-1", createdAt: now, id: "request-legacy"
        )
        let snapshot = try LibraryListenNextRequestSnapshot(
            requestID: intent.id, story: story, requesterDeviceID: "phone-1", ownerToken: "owner-1",
            operationGeneration: 1, anchorID: nil, createdAt: now, status: .pending
        )
        let entry = LibraryListenNextPhoneEntry(
            snapshot: snapshot, requestIntent: intent, cancellationIntent: nil,
            requestAttempted: true, requestSent: false, audioCached: false, remoteStatusRevision: 0
        )
        let outbox = LibraryListenNextPhoneOutbox(url: url)
        try outbox.save(.init(version: 1, ownerToken: "owner-1", entries: [entry]))
        let savedData = try Data(contentsOf: url)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: savedData) as? [String: Any])
        var rows = try XCTUnwrap(object["entries"] as? [[String: Any]])
        rows[0].removeValue(forKey: "requestAttempted")
        object["entries"] = rows
        try JSONSerialization.data(withJSONObject: object).write(to: url, options: .atomic)

        guard case let .saved(restored) = outbox.load() else { return XCTFail("The older outbox did not reopen.") }
        XCTAssertTrue(restored.entries.first?.requestAttempted == true)
    }
}
