import Foundation
import XCTest
import WiltedDomain
@testable import WiltedLibrary

final class LibraryUndecidedEpisodeProjectionTests: XCTestCase {
    private func id(_ raw: String) throws -> ItemID { try ItemID(rawValue: raw) }

    private func entry(
        _ raw: String, published: TimeInterval, removal: LibraryRemoval = .none,
        association: LibraryEpisodeAssociation? = nil, kind: LibraryKind = .podcastEpisode
    ) throws -> LibraryEntry {
        try LibraryEntry(
            id: id(raw), kind: kind, sourceID: id("show"), title: raw, summary: "",
            publishedAt: Date(timeIntervalSince1970: published), removal: removal,
            episodeAssociation: association,
            payload: Data(#"{"enclosureURL":"https://example.test/audio.mp3"}"#.utf8)
        )
    }

    func testProjectionMatchesFeedEligibilityAndSortsNewestFirst() throws {
        let newest = try entry("newest", published: 30)
        let older = try entry("older", published: 20)
        let queued = try entry("queued", published: 40)
        let retired = try entry("retired", published: 50, removal: .retired)
        let article = try entry("article", published: 60, kind: .article)
        let snapshot = LibrarySnapshot(
            entries: [newest, older, queued, retired, article],
            slots: [try QueueSlot(entryID: id("queued"), sortKey: 0)]
        )

        let newestID = try id("newest")
        let olderID = try id("older")
        XCTAssertEqual(LibraryUndecidedEpisodeProjection.rows(in: snapshot).map(\.id), [newestID, olderID])
    }

    func testAssociatedEpisodesFoldToMacRepresentativeAndAnyQueuedMemberRemovesGroup() throws {
        let a = try id("episode-a"), b = try id("episode-b")
        let association = LibraryEpisodeAssociation(
            groupID: UUID(), representativeID: a, memberIDs: [a, b], associationVersion: 1,
            isTerminal: false
        )
        let first = try entry(a.rawValue, published: 20, association: association)
        let second = try entry(b.rawValue, published: 30, association: association)
        let available = LibrarySnapshot(entries: [first, second])
        XCTAssertEqual(LibraryUndecidedEpisodeProjection.rows(in: available).map(\.id), [a])
        XCTAssertTrue(LibraryUndecidedEpisodeProjection.contains(b, in: available))

        let queued = LibrarySnapshot(entries: [first, second], slots: [try QueueSlot(entryID: b, sortKey: 0)])
        XCTAssertTrue(LibraryUndecidedEpisodeProjection.rows(in: queued).isEmpty)
    }

    func testSharedCandidatePredicateRejectsOldRemovalQueueAndAudiobookFacts() throws {
        XCTAssertTrue(LibraryUndecidedEpisodeProjection.isNewEpisodeCandidate(
            kind: .podcastEpisode, removal: .none, isQueued: false
        ))
        XCTAssertFalse(LibraryUndecidedEpisodeProjection.isNewEpisodeCandidate(
            kind: .podcastEpisode, removal: .retired, isQueued: false
        ))
        XCTAssertFalse(LibraryUndecidedEpisodeProjection.isNewEpisodeCandidate(
            kind: .podcastEpisode, removal: .none, isQueued: true
        ))
        XCTAssertFalse(LibraryUndecidedEpisodeProjection.isNewEpisodeCandidate(
            kind: .podcastEpisode, removal: .none, isQueued: false, isAudiobook: true
        ))
        XCTAssertFalse(LibraryUndecidedEpisodeProjection.isNewEpisodeCandidate(
            kind: .podcastEpisode, removal: .none, groupIsTerminal: true,
            groupHasActiveMember: true, isQueued: false
        ))
    }
}
