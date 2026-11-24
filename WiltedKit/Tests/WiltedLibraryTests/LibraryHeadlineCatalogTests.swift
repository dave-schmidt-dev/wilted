import Foundation
import XCTest
@testable import WiltedLibrary

final class LibraryHeadlineCatalogTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 100_000)

    private func story(
        id: String = "story-1",
        link: URL? = URL(string: "http://example.com/story"),
        savedAt: Date? = nil,
        savedRevision: Int64 = 0
    ) throws -> LibraryHeadlineStory {
        try LibraryHeadlineStory(
            id: id,
            title: "A story",
            publisherID: "feed-1",
            publisherName: "Example",
            link: link,
            publishedAt: now,
            firstSeenAt: now,
            lastSeenAt: now,
            savedAt: savedAt,
            savedRevision: savedRevision)
    }

    func testStoryPreservesOriginalHTTPLinkAndSavedRevisionAcrossJSON() throws {
        let value = try story(savedAt: now, savedRevision: 3)
        XCTAssertTrue(value.isSaved)
        XCTAssertEqual(value.link?.absoluteString, "http://example.com/story")
        XCTAssertEqual(try JSONDecoder().decode(LibraryHeadlineStory.self, from: JSONEncoder().encode(value)), value)
    }

    func testStoryRejectsCredentialedLinksAndNegativeRevision() throws {
        XCTAssertThrowsError(try story(link: URL(string: "https://user:pass@example.com/story")))
        XCTAssertThrowsError(try story(savedRevision: -1))
    }

    func testProjectionRequiresUniqueIDsAndSavedStorySnapshots() throws {
        let one = try story()
        XCTAssertThrowsError(try LibraryHeadlineProjection(
            revision: 0, updatedAt: now, recent: [one, one], saved: [], publishers: []))
        XCTAssertThrowsError(try LibraryHeadlineProjection(
            revision: 0, updatedAt: now, recent: [], saved: [one], publishers: []))
    }

    func testProjectionPageEnforcesBoundAndGenerationIdentity() throws {
        let page = try LibraryHeadlineProjectionPage(
            generationID: UUID().uuidString,
            kind: .recent,
            pageIndex: 0,
            stories: [story()])
        XCTAssertEqual(try JSONDecoder().decode(LibraryHeadlineProjectionPage.self, from: JSONEncoder().encode(page)), page)
        XCTAssertThrowsError(try LibraryHeadlineProjectionPage(
            generationID: "bad/name", kind: .recent, pageIndex: 0))
        XCTAssertThrowsError(try LibraryHeadlineProjectionPage(
            generationID: UUID().uuidString, kind: .recent, pageIndex: 0,
            stories: try (0...LibraryHeadlineProjectionPage.maximumStories).map { try story(id: "story-\($0)") }))

        let identity = try LibraryHeadlineStoryIdentity(
            id: "expired-1", publisherID: "feed-1", link: URL(string: "http://example.com/old"), savedRevision: 3)
        let expired = try LibraryHeadlineProjectionPage(
            generationID: UUID().uuidString, kind: .expired, pageIndex: 0, storyIdentities: [identity])
        XCTAssertEqual(try JSONDecoder().decode(LibraryHeadlineProjectionPage.self, from: JSONEncoder().encode(expired)), expired)
    }

    func testProjectionIndexBoundsPagedSectionsAndRetiredGenerations() throws {
        let retired = try (0...8).map {
            try LibraryHeadlineProjectionGeneration(
                id: String(format: "%032x", $0), recentPageCount: 0, savedPageCount: 0, publisherPageCount: 0)
        }
        XCTAssertThrowsError(try LibraryHeadlineProjectionIndex(
            generationID: UUID().uuidString,
            revision: 0,
            updatedAt: now,
            recentPageCount: LibraryHeadlineProjectionIndex.maximumPagesPerSection + 1,
            savedPageCount: 0,
            publisherPageCount: 0))
        XCTAssertThrowsError(try LibraryHeadlineProjectionIndex(
            generationID: UUID().uuidString,
            revision: 0,
            updatedAt: now,
            recentPageCount: 0,
            savedPageCount: 0,
            publisherPageCount: 0,
            retiredGenerations: retired))
        XCTAssertThrowsError(try LibraryHeadlineProjectionIndex(
            generationID: UUID().uuidString,
            revision: 0,
            updatedAt: now,
            recentPageCount: 0,
            savedPageCount: 0,
            publisherPageCount: 0,
            stagedGenerations: [retired[0], retired[1]]))
    }

    func testProjectionCarriesExpiredCompareAndSetStateAndReadsOldShape() throws {
        let identity = try LibraryHeadlineStoryIdentity(
            id: "expired-1", publisherID: "feed-1", link: URL(string: "https://example.com/old"), savedRevision: 4)
        let projection = try LibraryHeadlineProjection(
            revision: 7, updatedAt: now, recent: [], saved: [], publishers: [], expiredIdentities: [identity])
        XCTAssertEqual(try JSONDecoder().decode(LibraryHeadlineProjection.self, from: JSONEncoder().encode(projection)), projection)

        var oldShape = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(projection)) as? [String: Any])
        oldShape.removeValue(forKey: "expiredIdentities")
        let oldProjection = try JSONDecoder().decode(
            LibraryHeadlineProjection.self, from: JSONSerialization.data(withJSONObject: oldShape))
        XCTAssertTrue(oldProjection.expiredIdentities.isEmpty)
    }
}
