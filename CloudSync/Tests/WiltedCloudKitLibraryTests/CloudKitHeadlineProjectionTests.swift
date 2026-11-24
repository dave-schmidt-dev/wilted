import CloudKit
import XCTest
import WiltedLibrary
@testable import WiltedCloudKitLibrary

final class CloudKitHeadlineProjectionTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func story(_ index: Int, saved: Bool = false) throws -> LibraryHeadlineStory {
        try LibraryHeadlineStory(
            id: "story-\(index)", title: "Story \(index)", publisherID: "feed-1", publisherName: "Example",
            link: URL(string: "https://example.com/story-\(index)"), publishedAt: now,
            firstSeenAt: now, lastSeenAt: now, savedAt: saved ? now : nil, savedRevision: saved ? 1 : 0)
    }

    private func endpoint(
        writer: Bool,
        server: FakeMediaServer,
        outbox: CloudKitLibraryOutbox
    ) throws -> CloudKitLibraryTransport {
        let driver = FakeMediaDriver(server: server, outbox: outbox)
        return try CloudKitLibraryTransport(
            deviceID: writer ? "mac" : "phone", isLibraryWriter: writer, driver: driver,
            driverFactory: { _ in FakeMediaDriver(server: server, outbox: outbox) }, outbox: outbox)
    }

    func testProductionProjectionEndpointPublishesAndReadsBoundedPages() async throws {
        let server = FakeMediaServer()
        let outbox = CloudKitLibraryOutbox()
        let writer = try endpoint(writer: true, server: server, outbox: outbox)
        let recent = try (0..<25).map { try story($0) }
            .sorted { ($0.recentAnchorAt, $0.id) > ($1.recentAnchorAt, $1.id) }
        let saved = [try story(90, saved: true)]
        let publishers = [
            try LibraryHeadlinePublisher(id: "feed-a", name: "Zulu News", isMuted: true, revision: 2),
            try LibraryHeadlinePublisher(id: "feed-b", name: "Alpha News", isMuted: false, revision: 0)
        ]
        let expired = try (0..<49).map {
            try LibraryHeadlineStoryIdentity(
                id: "old-\($0)", publisherID: "feed-1", link: URL(string: "https://example.com/old-\($0)"),
                savedRevision: Int64($0 % 4))
        }.sorted { $0.id < $1.id }
        let projection = try LibraryHeadlineProjection(
            revision: 8, updatedAt: now, recent: recent, saved: saved, publishers: publishers,
            expiredIdentities: expired)

        try await writer.publishHeadlineProjection(projection)
        let reader = try endpoint(writer: false, server: server, outbox: outbox)
        let fetched = try await reader.fetchHeadlineProjection()
        let initialRecordCount = await server.allRecords().count
        XCTAssertEqual(fetched, projection)
        XCTAssertEqual(initialRecordCount, 7, "one index plus bounded recent/saved/publisher/expiry pages")

        let next = try LibraryHeadlineProjection(
            revision: 9, updatedAt: now.addingTimeInterval(1), recent: [try story(91)], saved: [],
            publishers: publishers, expiredIdentities: [])
        try await writer.publishHeadlineProjection(next)
        let refetched = try await reader.fetchHeadlineProjection()
        let finalRecordCount = await server.allRecords().count
        XCTAssertEqual(refetched, next)
        XCTAssertEqual(finalRecordCount, 3, "the new index replaces and removes every retired page")
    }

    func testFollowerCannotPublishMacOwnedProjection() async throws {
        let server = FakeMediaServer()
        let transport = try endpoint(writer: false, server: server, outbox: CloudKitLibraryOutbox())
        let empty = try LibraryHeadlineProjection(revision: 0, updatedAt: now, recent: [], saved: [], publishers: [])

        do {
            try await transport.publishHeadlineProjection(empty)
            XCTFail("only the Mac library writer can publish the projection")
        } catch let error as LibraryTransportError {
            guard case .ownershipViolation = error else { return XCTFail("unexpected error: \(error)") }
        }
    }

    func testPublisherOrderingMatchesTheCanonicalProjectionOrder() async throws {
        let server = FakeMediaServer()
        let outbox = CloudKitLibraryOutbox()
        let writer = try endpoint(writer: true, server: server, outbox: outbox)
        let projection = try LibraryHeadlineProjection(
            revision: 1, updatedAt: now, recent: [], saved: [], publishers: [
                try LibraryHeadlinePublisher(id: "feed-a", name: "Zulu News", isMuted: false, revision: 0),
                try LibraryHeadlinePublisher(id: "feed-b", name: "Alpha News", isMuted: false, revision: 0)
            ])

        try await writer.publishHeadlineProjection(projection)
        let reader = try endpoint(writer: false, server: server, outbox: outbox)

        let fetched = try await reader.fetchHeadlineProjection()
        XCTAssertEqual(fetched, projection)
    }

    func testSameGenerationRevisionMismatchReportsTheRevisionError() async throws {
        let server = FakeMediaServer()
        let outbox = CloudKitLibraryOutbox()
        let writer = try endpoint(writer: true, server: server, outbox: outbox)
        let first = try LibraryHeadlineProjection(revision: 3, updatedAt: now, recent: [], saved: [], publishers: [])
        try await writer.publishHeadlineProjection(first)
        let changedRevision = try LibraryHeadlineProjection(
            generationID: first.generationID, revision: 4, updatedAt: now.addingTimeInterval(1),
            recent: [], saved: [], publishers: [])

        do {
            try await writer.publishHeadlineProjection(changedRevision)
            XCTFail("a generation cannot be reused with a different revision")
        } catch let error as LibraryTransportError {
            XCTAssertEqual(error, .transport("headline projection revision changed within a generation"))
        }
    }
}
