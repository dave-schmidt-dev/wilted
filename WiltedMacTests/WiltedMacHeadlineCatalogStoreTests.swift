import Foundation
import XCTest
import WiltedLibrary
import WiltedProducer
@testable import WiltedMac

@MainActor
final class WiltedMacHeadlineCatalogStoreTests: XCTestCase {
    nonisolated private static let fixedNow = Date(timeIntervalSince1970: 1_800_000_000)

    private func story(
        _ id: String,
        publishedAt: Date? = nil,
        firstSeenAt: Date? = nil,
        lastSeenAt: Date? = nil,
        savedAt: Date? = nil,
        savedRevision: Int64 = 0
    ) throws -> LibraryHeadlineStory {
        try LibraryHeadlineStory(
            id: id, title: "Story \(id)", publisherID: "feed-1", publisherName: "Example News",
            link: URL(string: "https://example.com/\(id)"), publishedAt: publishedAt ?? Self.fixedNow,
            firstSeenAt: firstSeenAt ?? Self.fixedNow, lastSeenAt: lastSeenAt ?? Self.fixedNow,
            savedAt: savedAt, savedRevision: savedRevision)
    }

    func testRecentCardsSurviveFeedRotationUntilStableSevenDayCutoffAndSavedSurvives() throws {
        let store = WiltedMacHeadlineCatalogStore(fileURL: nil, now: { Self.fixedNow })
        let a = try story("a")
        let b = try story("b")
        _ = try store.mergeRecent([a, b], at: Self.fixedNow)
        XCTAssertEqual(try store.setSaved(
            story: a, isSaved: true, basedOnRevision: 0, commandID: "save-a", at: Self.fixedNow), .applied)

        let dayOne = Self.fixedNow.addingTimeInterval(24 * 60 * 60)
        let bPoll = try story("b", firstSeenAt: dayOne, lastSeenAt: dayOne)
        let c = try story("c", firstSeenAt: dayOne, lastSeenAt: dayOne)
        let rotated = try store.mergeRecent([bPoll, c], at: dayOne)
        XCTAssertEqual(Set(rotated.recent.map(\.id)), ["a", "b", "c"])

        let unchangedRevision = rotated.revision
        let unchangedGeneration = rotated.generationID
        let repeated = try store.mergeRecent([bPoll, c], at: dayOne.addingTimeInterval(60))
        XCTAssertEqual(repeated.revision, unchangedRevision)
        XCTAssertEqual(repeated.generationID, unchangedGeneration)

        let emptyPoll = try store.mergeRecent([], at: dayOne.addingTimeInterval(60 * 60))
        XCTAssertEqual(Set(emptyPoll.recent.map(\.id)), ["a", "b", "c"])

        let dayEight = try store.projection(at: Self.fixedNow.addingTimeInterval(8 * 24 * 60 * 60))
        XCTAssertTrue(dayEight.recent.isEmpty)
        XCTAssertEqual(dayEight.saved.map(\.id), ["a"])
        XCTAssertEqual(dayEight.saved.first?.link, a.link)
    }

    func testUnchangedFeedPollDoesNotBumpLastSeenOrProjectionGeneration() throws {
        let store = WiltedMacHeadlineCatalogStore(fileURL: nil, now: { Self.fixedNow })
        let first = try store.mergeRecent([story("a")], at: Self.fixedNow)
        let later = Self.fixedNow.addingTimeInterval(60 * 60)
        let poll = try store.mergeRecent([story("a", firstSeenAt: later, lastSeenAt: later)], at: later)

        XCTAssertEqual(poll, first)
        XCTAssertEqual(poll.recent.first?.lastSeenAt, Self.fixedNow)
    }

    func testSavedAndMutedFieldsUseIndependentRevisionsAndCommandReceiptsSurviveRestart() throws {
        let directory = wiltedTemporaryDirectory("headline-catalog-receipt")
        let file = directory.appendingPathComponent("catalog.json")
        let store = WiltedMacHeadlineCatalogStore(fileURL: file, now: { Self.fixedNow })
        let a = try story("a")
        _ = try store.mergeRecent([a], at: Self.fixedNow)

        XCTAssertEqual(try store.setSaved(
            story: a, isSaved: true, basedOnRevision: 0, commandID: "save-a", at: Self.fixedNow), .applied)
        XCTAssertEqual(try store.setPublisherMuted(
            id: "feed-1", name: "Example News", isMuted: true, basedOnRevision: 0,
            commandID: "mute-feed", at: Self.fixedNow), .applied)

        let restarted = WiltedMacHeadlineCatalogStore(fileURL: file, now: { Self.fixedNow })
        XCTAssertEqual(try restarted.setSaved(
            story: a, isSaved: true, basedOnRevision: 0, commandID: "save-a", at: Self.fixedNow), .applied,
            "replayed IDs return the durable receipt")
        XCTAssertEqual(try restarted.projection(at: Self.fixedNow).saved.first?.savedRevision, 1)
        XCTAssertEqual(try restarted.projection(at: Self.fixedNow).publishers.first?.revision, 1)

        XCTAssertEqual(try restarted.setSaved(
            story: a, isSaved: false, basedOnRevision: 0, commandID: "stale-unsave", at: Self.fixedNow), .staleRevision)
        XCTAssertEqual(try restarted.projection(at: Self.fixedNow).saved.map(\.id), ["a"])
        XCTAssertEqual(try restarted.setSaved(
            story: a, isSaved: false, basedOnRevision: 0, commandID: "stale-unsave", at: Self.fixedNow), .staleRevision)
    }

    func testPhoneSaveQueuedOnDaySixCanRestoreAnExpiredCardOnDayNine() throws {
        let store = WiltedMacHeadlineCatalogStore(fileURL: nil, now: { Self.fixedNow })
        let a = try story("a")
        _ = try store.mergeRecent([a], at: Self.fixedNow)
        let daySixSnapshot = a
        let dayNine = Self.fixedNow.addingTimeInterval(9 * 24 * 60 * 60)

        XCTAssertEqual(try store.setSaved(
            story: daySixSnapshot, isSaved: true, basedOnRevision: 0,
            commandID: "offline-save-a", at: dayNine), .applied)

        let projection = try store.projection(at: dayNine)
        XCTAssertTrue(projection.recent.isEmpty)
        XCTAssertTrue(projection.expiredIdentities.isEmpty)
        XCTAssertEqual(projection.saved.count, 1)
        XCTAssertEqual(projection.saved.first?.title, a.title)
        XCTAssertEqual(projection.saved.first?.link, a.link)
        XCTAssertEqual(projection.saved.first?.savedRevision, 1)
    }

    func testPersistedUnsaveRevisionRejectsAndReplaysStaleOfflineCommands() throws {
        let directory = wiltedTemporaryDirectory("headline-catalog-expired-revision")
        let file = directory.appendingPathComponent("catalog.json")
        let store = WiltedMacHeadlineCatalogStore(fileURL: file, now: { Self.fixedNow })
        let a = try story("a")
        _ = try store.mergeRecent([a], at: Self.fixedNow)
        XCTAssertEqual(try store.setSaved(
            story: a, isSaved: true, basedOnRevision: 0, commandID: "mac-save-a", at: Self.fixedNow), .applied)

        let dayNine = Self.fixedNow.addingTimeInterval(9 * 24 * 60 * 60)
        XCTAssertEqual(try store.setSaved(
            story: a, isSaved: false, basedOnRevision: 1, commandID: "mac-unsave-a", at: dayNine), .applied)
        XCTAssertEqual(try store.projection(at: dayNine).expiredIdentities.first?.savedRevision, 2)

        let restarted = WiltedMacHeadlineCatalogStore(fileURL: file, now: { Self.fixedNow })
        let staleUnsave = try restarted.setSaved(
            story: a, isSaved: false, basedOnRevision: 1, commandID: "phone-stale-unsave", at: dayNine)
        XCTAssertEqual(staleUnsave, .staleRevision)
        XCTAssertEqual(try restarted.setSaved(
            story: a, isSaved: false, basedOnRevision: 1, commandID: "phone-stale-unsave", at: dayNine), .staleRevision)
        XCTAssertEqual(try restarted.setSaved(
            story: a, isSaved: true, basedOnRevision: 1, commandID: "phone-stale-revival", at: dayNine), .staleRevision)
        XCTAssertTrue(try restarted.projection(at: dayNine).saved.isEmpty)
        XCTAssertEqual(try restarted.projection(at: dayNine).expiredIdentities.first?.savedRevision, 2)
    }

    func testLegacyCatalogWithoutExpiredIdentityAnchorsStillAcceptsOfflineSave() throws {
        let file = wiltedTemporaryDirectory("headline-catalog-legacy-expired").appendingPathComponent("catalog.json")
        let identity = try LibraryHeadlineStoryIdentity(
            id: "legacy-expired", publisherID: "feed-1", link: URL(string: "https://example.com/legacy-expired"),
            savedRevision: 3)
        let publisher = try LibraryHeadlinePublisher(id: "feed-1", name: "Example News", isMuted: false, revision: 0)
        let projection = try LibraryHeadlineProjection(
            revision: 1, updatedAt: Self.fixedNow, recent: [], saved: [], publishers: [publisher],
            expiredIdentities: [identity])
        let envelope: [String: Any] = [
            "version": 1,
            "projection": try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(projection)) as? [String: Any]),
            "receipts": [:]
        ]
        try JSONSerialization.data(withJSONObject: envelope).write(to: file)

        let store = WiltedMacHeadlineCatalogStore(fileURL: file, now: { Self.fixedNow })
        let offlineStory = try story("legacy-expired")
        XCTAssertEqual(try store.setSaved(
            story: offlineStory, isSaved: true, basedOnRevision: 3,
            commandID: "legacy-offline-save", at: Self.fixedNow), .applied)

        let restarted = WiltedMacHeadlineCatalogStore(fileURL: file, now: { Self.fixedNow })
        XCTAssertEqual(try restarted.projection(at: Self.fixedNow).saved.first?.savedRevision, 4)
    }

    func testStoryIdentityMismatchCannotChangeSavedState() throws {
        let store = WiltedMacHeadlineCatalogStore(fileURL: nil, now: { Self.fixedNow })
        let canonical = try story("a")
        _ = try store.mergeRecent([canonical], at: Self.fixedNow)
        let forged = try LibraryHeadlineStory(
            id: canonical.id, title: canonical.title, publisherID: canonical.publisherID,
            publisherName: canonical.publisherName, link: URL(string: "https://attacker.example/story"),
            publishedAt: canonical.publishedAt, firstSeenAt: canonical.firstSeenAt, lastSeenAt: canonical.lastSeenAt)

        XCTAssertEqual(try store.setSaved(
            story: forged, isSaved: true, basedOnRevision: 0, commandID: "forged-save", at: Self.fixedNow),
            .rejected(WiltedMacHeadlineCatalogStore.reasonStoryIdentityMismatch))
        XCTAssertTrue(try store.projection(at: Self.fixedNow).saved.isEmpty)
    }

    func testCatalogAllowsMoreThanOneCloudPageOfRecentStories() throws {
        let store = WiltedMacHeadlineCatalogStore(fileURL: nil, now: { Self.fixedNow })
        let stories = try (0..<(LibraryHeadlineProjectionPage.maximumStories + 1)).map { try story("story-\($0)") }
        let projection = try store.mergeRecent(stories, at: Self.fixedNow)

        XCTAssertEqual(projection.recent.count, LibraryHeadlineProjectionPage.maximumStories + 1)
    }

    func testRecentOverflowMovesOldestCardsIntoTheSaveableIdentityLedger() throws {
        let store = WiltedMacHeadlineCatalogStore(fileURL: nil, now: { Self.fixedNow })
        let capacity = LibraryHeadlineProjectionPage.maximumStories
            * LibraryHeadlineProjectionIndex.maximumPagesPerSection
        let initialStories = try (0..<capacity).map { try story("capacity-\($0)") }
        let initial = try store.mergeRecent(initialStories, at: Self.fixedNow)
        let firstDisplaced = try XCTUnwrap(initial.recent.last)

        let firstPoll = try store.mergeRecent(
            [story("newer-a", publishedAt: Self.fixedNow.addingTimeInterval(1))],
            at: Self.fixedNow.addingTimeInterval(1))
        XCTAssertEqual(firstPoll.recent.count, capacity)
        XCTAssertTrue(firstPoll.expiredIdentities.contains { $0.id == firstDisplaced.id })
        let secondDisplaced = try XCTUnwrap(firstPoll.recent.last)

        let secondPoll = try store.mergeRecent(
            [story("newer-b", publishedAt: Self.fixedNow.addingTimeInterval(2))],
            at: Self.fixedNow.addingTimeInterval(2))
        XCTAssertEqual(secondPoll.recent.count, capacity)
        XCTAssertTrue(secondPoll.expiredIdentities.contains { $0.id == firstDisplaced.id })
        XCTAssertTrue(secondPoll.expiredIdentities.contains { $0.id == secondDisplaced.id })
        XCTAssertEqual(try store.setSaved(
            story: firstDisplaced, isSaved: true, basedOnRevision: firstDisplaced.savedRevision,
            commandID: "save-displaced-recent", at: Self.fixedNow.addingTimeInterval(2)), .applied)
        XCTAssertEqual(try store.projection(at: Self.fixedNow.addingTimeInterval(2)).saved.first?.id, firstDisplaced.id)
    }

    func testExpiredIdentityCapacityRetainsNewestEntriesAndTheirOfflineSaveRevision() throws {
        let directory = wiltedTemporaryDirectory("headline-catalog-expired-capacity")
        let file = directory.appendingPathComponent("catalog.json")
        let count = WiltedMacHeadlineCatalogStore.maximumExpiredIdentityCount
        let oldestAnchor = Self.fixedNow.addingTimeInterval(-LibraryHeadlineProjection.recentRetention - 1_000)
        let identities = try (0..<count).map { index in
            try LibraryHeadlineStoryIdentity(
                id: String(format: "expired-%05d", index), publisherID: "feed-1",
                link: URL(string: "https://example.com/expired-\(index)"), savedRevision: index == count - 1 ? 5 : 0)
        }
        let anchors = Dictionary(uniqueKeysWithValues: identities.enumerated().map { index, identity in
            (identity.id, oldestAnchor.addingTimeInterval(TimeInterval(index)))
        })
        let publisher = try LibraryHeadlinePublisher(id: "feed-1", name: "Example News", isMuted: false, revision: 0)
        let initial = try LibraryHeadlineProjection(
            revision: 1, updatedAt: Self.fixedNow, recent: [], saved: [], publishers: [publisher],
            expiredIdentities: identities)
        let encodedProjection = try JSONEncoder().encode(initial)
        let encodedAnchors = try JSONEncoder().encode(anchors)
        let envelope: [String: Any] = [
            "version": 1,
            "projection": try XCTUnwrap(JSONSerialization.jsonObject(with: encodedProjection) as? [String: Any]),
            "receipts": [:],
            "expiredIdentityAnchors": try XCTUnwrap(JSONSerialization.jsonObject(with: encodedAnchors) as? [String: Any])
        ]
        try JSONSerialization.data(withJSONObject: envelope).write(to: file)

        let store = WiltedMacHeadlineCatalogStore(fileURL: file, now: { Self.fixedNow })
        let incomingAnchor = oldestAnchor.addingTimeInterval(0.5)
        let incoming = try story("expired-new", publishedAt: incomingAnchor)
        let capped = try store.mergeRecent([incoming], at: Self.fixedNow)

        XCTAssertEqual(capped.expiredIdentities.count, count)
        XCTAssertFalse(capped.expiredIdentities.contains { $0.id == "expired-00000" })
        XCTAssertTrue(capped.expiredIdentities.contains { $0.id == "expired-new" })

        let retained = try story(String(format: "expired-%05d", count - 1))
        XCTAssertEqual(try store.setSaved(
            story: retained, isSaved: true, basedOnRevision: 5,
            commandID: "offline-save-retained-expired", at: Self.fixedNow), .applied)
        XCTAssertEqual(try store.setSaved(
            story: retained, isSaved: false, basedOnRevision: 5,
            commandID: "stale-unsave-retained-expired", at: Self.fixedNow), .staleRevision)
        XCTAssertEqual(try store.projection(at: Self.fixedNow).saved.first?.savedRevision, 6)

        let evicted = try story("expired-00000")
        XCTAssertEqual(try store.setSaved(
            story: evicted, isSaved: true, basedOnRevision: 0,
            commandID: "offline-save-evicted-expired", at: Self.fixedNow), .rejected("unknownStory"))
    }

    func testFailedAtomicWriteLeavesCommandUnappliedForRetry() throws {
        let file = wiltedTemporaryDirectory("headline-catalog-failed-write").appendingPathComponent("catalog.json")
        let seed = WiltedMacHeadlineCatalogStore(fileURL: file, now: { Self.fixedNow })
        let a = try story("a")
        _ = try seed.mergeRecent([a], at: Self.fixedNow)
        let failingWriter: WiltedMacHeadlineCatalogStore.Writer = { _, _ in throw POSIXError(.ENOSPC) }
        let failing = WiltedMacHeadlineCatalogStore(fileURL: file, now: { Self.fixedNow }, write: failingWriter)

        XCTAssertThrowsError(try failing.setSaved(
            story: a, isSaved: true, basedOnRevision: 0, commandID: "save-retry", at: Self.fixedNow))
        XCTAssertTrue(try WiltedMacHeadlineCatalogStore(fileURL: file, now: { Self.fixedNow })
            .projection(at: Self.fixedNow).saved.isEmpty)

        let recovered = WiltedMacHeadlineCatalogStore(fileURL: file, now: { Self.fixedNow })
        XCTAssertEqual(try recovered.setSaved(
            story: a, isSaved: true, basedOnRevision: 0, commandID: "save-retry", at: Self.fixedNow), .applied)
        XCTAssertEqual(try recovered.projection(at: Self.fixedNow).saved.map(\.id), ["a"])
    }
}
