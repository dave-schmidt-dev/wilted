import Foundation
import SwiftData
import XCTest
import WiltedDomain
@testable import WiltedProducer

extension LocalLibraryStoreTests {
    private func precisionEpisode(_ guid: String, at date: Date) throws -> PodcastEpisode {
        let (_, base) = try podcastValues()
        let enclosure = URL(string: "https://podcasts.example.test/precision/\(guid).mp3")!
        return try PodcastEpisode(itemID: ItemID.derivePodcastEpisode(feedURL: base.feedURL,
            rssGUID: guid, enclosureURL: enclosure), feedID: base.feedID, feedURL: base.feedURL,
            rssGUID: guid, title: "Precision \(guid)", enclosureURL: enclosure,
            enclosureMediaType: "audio/mpeg", createdAt: Timestamp(date))
    }

    private static func precisionAssociation(
        _ first: PodcastEpisode, _ second: PodcastEpisode, in store: LocalLibraryStore
    ) async throws -> PodcastEpisodeAssociation {
        for episode in [first, second] { try await store.save(episode: episode) }
        let confirmation = PodcastEpisodePairConfirmation(confirmationID: UUID(), feedID: first.feedID,
            first: first.itemID, second: second.itemID, confirmedAt: first.createdAt)
        let preview = try await store.previewEpisodeAssociation(confirming: confirmation, representativeID: first.itemID)
        return try await store.applyEpisodeAssociation(preview, at: first.createdAt)
    }

    func testFractionalAssociationSurvivesApplyReadReopenAndReversalWithoutChangingRawCreationDates() async throws {
        let url = makeURL(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        var store = try LocalLibraryStore(url: url)
        let date = Date(timeIntervalSince1970: 1_700_000_000.123456)
        let first = try precisionEpisode("first", at: date)
        let second = try precisionEpisode("second", at: date.addingTimeInterval(1.000123))
        let association = try await Self.precisionAssociation(first, second, in: store)
        let initial = try await store.episodeAssociations()
        XCTAssertEqual(initial, [association])
        store = try LocalLibraryStore(url: url)
        let reopened = try await store.episodeAssociations()
        XCTAssertEqual(reopened, [association])
        let source = try await store.podcastEpisode(for: first.itemID)
        XCTAssertEqual(source?.createdAt.date, date, "The raw source scalar retains its original precision")
        let identity = try await store.podcastLibraryIdentitySnapshot(profile: .publication)
        XCTAssertEqual(identity.associations, [association])
        XCTAssertEqual(identity.states[first.itemID]?.memberIDs.sorted { $0.rawValue < $1.rawValue },
                       [first.itemID, second.itemID].sorted { $0.rawValue < $1.rawValue })
        let preview = try await store.previewEpisodeAssociationReversal(association.associationID, expectedVersion: 1)
        let reversed = try await store.reverseEpisodeAssociation(preview)
        XCTAssertFalse(reversed.isActive)
        let active = try await store.episodeAssociations()
        XCTAssertTrue(active.isEmpty)
        let finalSource = try await store.podcastEpisode(for: first.itemID)
        XCTAssertEqual(finalSource?.createdAt.date, date)
    }

    func testRecordedMillisecondComparisonNormalizesWholeSecondFormsAndRejectsDifferentRecordedInstants() throws {
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        let first = base.addingTimeInterval(0.1231)
        let sameMillisecond = base.addingTimeInterval(0.1232)
        XCTAssertNotEqual(first, sameMillisecond)
        XCTAssertTrue(EpisodeAssociationReadLookup.sameRecordedCreationInstant(first, sameMillisecond))
        XCTAssertFalse(EpisodeAssociationReadLookup.sameRecordedCreationInstant(first, base.addingTimeInterval(0.1241)))
        let fractionalWhole = try Timestamp(iso8601: "2023-11-14T22:13:20.000Z")
        let whole = try Timestamp(iso8601: "2023-11-14T22:13:20Z")
        XCTAssertTrue(EpisodeAssociationReadLookup.sameRecordedCreationInstant(fractionalWhole.date, whole.date))
        let nearWhole = base.addingTimeInterval(0.0001)
        XCTAssertNotEqual(Timestamp(nearWhole).description, Timestamp(base).description)
        XCTAssertTrue(EpisodeAssociationReadLookup.sameRecordedCreationInstant(nearWhole, base))
        let nearEnd = base.addingTimeInterval(0.9999)
        let recordedEnd = try Timestamp(iso8601: Timestamp(nearEnd).description)
        XCTAssertTrue(EpisodeAssociationReadLookup.sameRecordedCreationInstant(nearEnd, recordedEnd.date))
        XCTAssertFalse(EpisodeAssociationReadLookup.sameRecordedCreationInstant(base.addingTimeInterval(0.998),
                                                                              base.addingTimeInterval(1)))
    }

    @MainActor
    func testAssociationStillRefusesChangedCanonicalCreationDateFeedMembershipAndRawID() async throws {
        for mutation in ["date", "feed", "membership", "rawID"] {
            let url = makeURL(mutation)
            defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
            let store = try LocalLibraryStore(url: url)
            let date = Date(timeIntervalSince1970: 1_700_000_000.123456)
            let first = try precisionEpisode("first", at: date)
            let second = try precisionEpisode("second", at: date)
            _ = try await Self.precisionAssociation(first, second, in: store)
            let before = try await store.episodeAssociations()
            XCTAssertEqual(before.count, 1)
            let context = ModelContext(store.container)
            let episodes = try context.fetch(FetchDescriptor<LocalLibrarySchemaV13Models.PodcastEpisodeRecord>())
            let raw = try XCTUnwrap(episodes.first { $0.id == first.itemID.rawValue })
            switch mutation {
            case "date": raw.createdAt = raw.createdAt.addingTimeInterval(0.01)
            case "feed": raw.feedID = "different-feed"
            case "rawID": raw.id = "different-raw-episode"
            default:
                let rows = try context.fetch(FetchDescriptor<LocalLibrarySchemaV20Models.EpisodeAssociationRecord>())
                let association = try XCTUnwrap(rows.first)
                association.members = try JSONEncoder().encode([first.itemID, ItemID(rawValue: "foreign-member")])
            }
            try context.save()
            let refused = try await store.episodeAssociations()
            XCTAssertTrue(refused.isEmpty, mutation)
            let rawAfter = try context.fetch(FetchDescriptor<LocalLibrarySchemaV13Models.PodcastEpisodeRecord>())
            XCTAssertEqual(rawAfter.count, 2, "Refusal retains raw source rows")
        }
    }

    @MainActor
    func testAppliedAssociationAcceptsOnlySubmillisecondSourceChangesWithinTheRecordedInstant() async throws {
        let url = makeURL(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = try LocalLibraryStore(url: url)
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        let first = try precisionEpisode("first", at: base.addingTimeInterval(0.1231))
        let second = try precisionEpisode("second", at: base.addingTimeInterval(0.0001))
        let association = try await Self.precisionAssociation(first, second, in: store)
        let context = ModelContext(store.container)
        let episodes = try context.fetch(FetchDescriptor<LocalLibrarySchemaV13Models.PodcastEpisodeRecord>())
        try XCTUnwrap(episodes.first { $0.id == first.itemID.rawValue }).createdAt = base.addingTimeInterval(0.1232)
        try XCTUnwrap(episodes.first { $0.id == second.itemID.rawValue }).createdAt = base
        try context.save()
        let accepted = try await store.episodeAssociations()
        XCTAssertEqual(accepted, [association])
    }
}
