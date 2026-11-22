import Foundation
import SwiftData
import XCTest
import WiltedDomain
@testable import WiltedProducer

final class LocalLibraryEpisodeIngestIdentityTests: XCTestCase {
    let origin = Date(timeIntervalSince1970: 1_700_000_000)
    private let feedURL = URL(string: "https://podcasts.example.test/twit/feed.xml")!

    func makeStore(_ name: String = #function) throws -> LocalLibraryStore {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("wilted-episode-identity-\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return try LocalLibraryStore(url: directory.appendingPathComponent("library.sqlite"))
    }

    func episode(
        feedURL: URL? = nil,
        guid: String,
        enclosure: String,
        title: String = "Security Now! 1635: Example Episode",
        publishedAt: Date? = Date(timeIntervalSince1970: 1_700_000_000),
        duration: Double? = 3_600,
        byteCount: Int64? = 1_234_567,
        createdAt: Date = Date(timeIntervalSince1970: 1_700_000_000)
    ) throws -> PodcastEpisode {
        let feedURL = feedURL ?? self.feedURL
        let enclosureURL = URL(string: enclosure)!
        let feedID = try ItemID.derivePodcastFeed(from: feedURL)
        return try PodcastEpisode(
            itemID: ItemID.derivePodcastEpisode(feedURL: feedURL, rssGUID: guid, enclosureURL: enclosureURL),
            feedID: feedID,
            feedURL: feedURL,
            rssGUID: guid,
            title: title,
            publishedTime: publishedAt.map(Timestamp.init),
            enclosureURL: enclosureURL,
            enclosureMediaType: "audio/mpeg",
            enclosureByteCount: byteCount,
            durationSeconds: duration,
            createdAt: Timestamp(createdAt)
        )
    }

    func seedLegacyEpisodes(
        _ episodes: [PodcastEpisode],
        removalKinds: [ItemID: PodcastEpisodeRemovalKind] = [:],
        in store: LocalLibraryStore
    ) throws {
        let context = ModelContext(store.container)
        for episode in episodes {
            let record = try LocalLibrarySchemaV13Models.PodcastEpisodeRecord(episode)
            if let removalKind = removalKinds[episode.itemID] {
                record.retiredAt = origin
                record.removalKind = removalKind.rawValue
            }
            context.insert(record)
        }
        try context.save()
    }

    func testTwitShortGUIDLookalikeOfARetiredEpisodeIsSavedHeldAndLeavesTheOriginalUntouched() async throws {
        let store = try makeStore()
        let old = try episode(
            guid: "https://captivate.fm/show/audio/twit-1635.mp3",
            enclosure: "https://captivate.fm/show/audio/twit-1635.mp3"
        )
        let refreshed = try episode(
            guid: "TWiT-1635-1110-863758",
            enclosure: "https://cdn.twit.tv/audio/twit-1635.mp3",
            title: " security   now! 1635: example episode ",
            publishedAt: origin.addingTimeInterval(45),
            duration: 3_604, createdAt: origin.addingTimeInterval(100)
        )

        try await store.save(episode: old)
        try await store.retireEpisode(old.itemID, at: Timestamp(origin))
        let result = try await store.admitPodcastEpisodes(
            [refreshed], admission: .incremental, claimingNewest: 5,
            claimedAt: Timestamp(origin.addingTimeInterval(100))
        )

        // The newcomer is its own row, held, and never downloaded.
        let stored = try await store.podcastEpisodes(for: old.feedID)
        XCTAssertEqual(Set(stored.map(\.itemID)), [old.itemID, refreshed.itemID])
        XCTAssertEqual(stored.first(where: { $0.itemID == old.itemID })?.rssGUID, old.rssGUID)
        XCTAssertEqual(stored.first(where: { $0.itemID == old.itemID })?.createdAt, Timestamp(origin))
        XCTAssertEqual(result.claimed, [])
        let held = try await store.podcastEpisodeIdentityReviewHeldIDs(in: old.feedID)
        XCTAssertEqual(held, [refreshed.itemID])
        let removal = try await store.removalKind(for: old.itemID)
        XCTAssertEqual(removal, .retired)
        let associations = try await store.episodeAssociations()
        XCTAssertTrue(associations.isEmpty, "nothing is linked without the owner's Same episode choice")

        // A later refresh of the same feed keeps it held and adds nothing.
        let repeated = try await store.admitPodcastEpisodes(
            [refreshed], admission: .incremental, claimingNewest: 5
        )
        let afterRepeat = try await store.podcastEpisodes(for: old.feedID)
        XCTAssertEqual(afterRepeat.count, 2)
        XCTAssertTrue(repeated.claimed.isEmpty)
        XCTAssertTrue(repeated.admission.newlyAdmitted.isEmpty)
    }

    func testDifferentFeedsWithMatchingMetadataRemainSeparate() async throws {
        let otherFeed = URL(string: "https://podcasts.example.test/twit-mirror/feed.xml")!
        let first = try episode(guid: "TWiT-1635-1110-863758", enclosure: "https://cdn.example.test/one.mp3")
        let second = try episode(
            feedURL: otherFeed, guid: "TWiT-1635-1110-863758",
            enclosure: "https://cdn.example.test/one.mp3"
        )
        let store = try makeStore()

        try await store.admitPodcastEpisodes([first, second], admission: .incremental, claimingNewest: 5)

        let stored = try await store.podcastEpisodes()
        XCTAssertEqual(stored.count, 2)
        XCTAssertNotEqual(first.feedID, second.feedID)
    }

    func testPureMatcherUsesNormalizedTitleAndTheSpecifiedTolerances() throws {
        let old = try episode(
            guid: "https://captivate.fm/show/audio/twit-1635.mp3",
            enclosure: "https://captivate.fm/show/audio/twit-1635.mp3"
        )
        let sameMetadata = try episode(
            guid: "legacy-url-guid",
            enclosure: "https://cdn.twit.tv/audio/twit-1635-old-host.mp3"
        )
        let incoming = try episode(
            guid: "TWiT-1635-1110-863758",
            enclosure: "https://cdn.twit.tv/audio/twit-1635.mp3",
            title: " SECURITY   NOW! 1635:   EXAMPLE EPISODE ",
            publishedAt: origin.addingTimeInterval(60), duration: 3_605
        )

        XCTAssertEqual(
            PodcastEpisodeIdentityMatcher.match(incoming: incoming, candidates: [old, sameMetadata]),
            .ambiguous(
                candidateIDs: [old.itemID, sameMetadata.itemID].sorted { $0.rawValue < $1.rawValue },
                reasons: [.multipleMatches]
            )
        )
        XCTAssertEqual(
            PodcastEpisodeIdentityMatcher.match(incoming: incoming, candidates: [old]),
            .matched(old.itemID)
        )
    }

    func testPureMatcherIgnoresDifferentLengthsAndDoesNotUseURLAlone() throws {
        let old = try episode(guid: "old-guid", enclosure: "https://cdn.example.test/shared.mp3")
        let durationConflict = try episode(
            guid: "new-guid", enclosure: "https://cdn.example.test/shared.mp3",
            title: "security now! 1635: example episode", publishedAt: origin, duration: 3_606
        )
        let urlOnly = try episode(
            guid: "newer-guid", enclosure: "https://cdn.example.test/shared.mp3",
            title: "A different episode", publishedAt: origin, duration: old.durationSeconds
        )

        // Same title and publish minute but a different length is a different
        // episode, not a lookalike.
        XCTAssertEqual(
            PodcastEpisodeIdentityMatcher.match(incoming: durationConflict, candidates: [old]),
            .none
        )
        XCTAssertEqual(PodcastEpisodeIdentityMatcher.match(incoming: urlOnly, candidates: [old]), .none)
    }

    func testPureMatcherRequiresBothMissingDurationsToHaveEqualByteCount() throws {
        let old = try episode(
            guid: "old-guid", enclosure: "https://cdn.example.test/old.mp3",
            duration: nil, byteCount: 1_234_567
        )
        let sameBytes = try episode(
            guid: "new-guid", enclosure: "https://cdn.example.test/new.mp3",
            duration: nil, byteCount: 1_234_567
        )
        let differentBytes = try episode(
            guid: "other-guid", enclosure: "https://cdn.example.test/other.mp3",
            duration: nil, byteCount: 1_234_568
        )

        XCTAssertEqual(
            PodcastEpisodeIdentityMatcher.match(incoming: sameBytes, candidates: [old]),
            .matched(old.itemID)
        )
        XCTAssertEqual(
            PodcastEpisodeIdentityMatcher.match(incoming: differentBytes, candidates: [old]),
            .none
        )
    }

    func testPureMatcherKeepsPunctuationInTitleIdentity() throws {
        let old = try episode(
            guid: "old-guid", enclosure: "https://cdn.example.test/old.mp3", title: "!!!"
        )
        let incoming = try episode(
            guid: "new-guid", enclosure: "https://cdn.example.test/new.mp3", title: "---"
        )

        XCTAssertEqual(PodcastEpisodeIdentityMatcher.match(incoming: incoming, candidates: [old]), .none)
    }

    func testPureMatcherDoesNotMatchAnUndatedCandidate() throws {
        let undated = try episode(
            guid: "undated-guid", enclosure: "https://cdn.example.test/undated.mp3",
            publishedAt: nil
        )
        let incoming = try episode(
            guid: "dated-guid", enclosure: "https://cdn.example.test/dated.mp3"
        )

        XCTAssertEqual(PodcastEpisodeIdentityMatcher.match(incoming: incoming, candidates: [undated]), .none)
    }

    func testDifferentLengthSameTitleIsNotFlaggedAndStaysDownloadable() async throws {
        let first = try episode(guid: "radio-old", enclosure: "https://cdn.example.test/old.mp3")
        let other = try episode(
            guid: "radio-new", enclosure: "https://cdn.example.test/new.mp3",
            publishedAt: origin.addingTimeInterval(20), duration: 1_200
        )
        let store = try makeStore()
        try await store.save(episode: first)

        let result = try await store.admitPodcastEpisodes(
            [other], admission: .incremental, claimingNewest: 5
        )
        let held = try await store.podcastEpisodeIdentityReviewHeldIDs(in: first.feedID)

        XCTAssertTrue(held.isEmpty, "a much shorter episode with the same title is not a lookalike")
        XCTAssertEqual(result.claimed, [other.itemID])
    }

    func testLookalikeDoesNotClaimAutomaticDownload() async throws {
        let first = try episode(guid: "TWiT-1635-old", enclosure: "https://cdn.example.test/old.mp3")
        let conflict = try episode(
            guid: "TWiT-1635-new", enclosure: "https://cdn.example.test/new.mp3",
            title: "security now! 1635: example episode",
            publishedAt: origin.addingTimeInterval(20), duration: 3_603
        )
        let store = try makeStore()

        try await store.save(episode: first)
        let result = try await store.admitPodcastEpisodes(
            [conflict], admission: .incremental, claimingNewest: 5
        )
        let pendingReviews = try await store.pendingPodcastEpisodeIdentityReviews(in: first.feedID)
        let heldIDs = try await store.podcastEpisodeIdentityReviewHeldIDs(in: first.feedID)
        let automaticClaim = try await store.claimPodcastDownload(
            episodeID: conflict.itemID, scope: .untouched
        )
        let manualClaim = try await store.claimPodcastDownload(
            episodeID: conflict.itemID, scope: .notInFlight
        )

        XCTAssertTrue(result.claimed.isEmpty, "a lookalike must be held from automatic download")
        XCTAssertEqual(pendingReviews.map(\.incomingID), [conflict.itemID])
        XCTAssertEqual(heldIDs, [conflict.itemID])
        XCTAssertFalse(automaticClaim, "a possible duplicate is kept out of automatic download")
        XCTAssertTrue(manualClaim, "a manual download is never blocked by the flag")
    }

    func testOwnerConfirmedPairClearsPossibleDuplicateHold() async throws {
        let first = try episode(guid: "old-guid", enclosure: "https://cdn.example.test/old.mp3")
        let incoming = try episode(
            guid: "TWiT-1635-1110-863758", enclosure: "https://cdn.twit.tv/new.mp3",
            publishedAt: origin.addingTimeInterval(20), duration: 3_610
        )
        let store = try makeStore()
        try await store.save(episode: first)
        _ = try await store.admitPodcastEpisodes(
            [incoming], admission: .incremental, claimingNewest: 0
        )

        let confirmation = PodcastEpisodePairConfirmation(
            confirmationID: UUID(), feedID: first.feedID,
            first: first.itemID, second: incoming.itemID, confirmedAt: Timestamp(origin)
        )
        let preview = try await store.previewEpisodeAssociation(
            confirming: confirmation, representativeID: first.itemID
        )
        let association = try await store.applyEpisodeAssociation(preview)
        let heldIDs = try await store.podcastEpisodeIdentityReviewHeldIDs(in: first.feedID)

        XCTAssertEqual(Set(association.memberIDs), [first.itemID, incoming.itemID])
        XCTAssertTrue(heldIDs.isEmpty)
    }

    func testOwnerConfirmationOfAnUnrelatedPairKeepsPossibleDuplicateHeld() async throws {
        let firstCandidate = try episode(
            guid: "candidate-a", enclosure: "https://cdn.example.test/a.mp3", duration: 3_600
        )
        let secondCandidate = try episode(
            guid: "candidate-b", enclosure: "https://cdn.example.test/b.mp3", duration: 3_608
        )
        let unrelated = try episode(
            guid: "unrelated", enclosure: "https://cdn.example.test/unrelated.mp3",
            title: "A different item", publishedAt: origin.addingTimeInterval(-86_400)
        )
        let incoming = try episode(
            guid: "TWiT-1635-1110-863758", enclosure: "https://cdn.twit.tv/incoming.mp3",
            duration: 3_604
        )
        let store = try makeStore()
        try seedLegacyEpisodes([firstCandidate, secondCandidate, unrelated], in: store)
        _ = try await store.admitPodcastEpisodes(
            [incoming], admission: .incremental, claimingNewest: 0
        )

        let confirmation = PodcastEpisodePairConfirmation(
            confirmationID: UUID(), feedID: incoming.feedID,
            first: incoming.itemID, second: unrelated.itemID, confirmedAt: Timestamp(origin)
        )
        let preview = try await store.previewEpisodeAssociation(
            confirming: confirmation, representativeID: incoming.itemID
        )
        _ = try await store.applyEpisodeAssociation(preview)

        let pending = try await store.pendingPodcastEpisodeIdentityReviews(in: incoming.feedID)
        let heldIDs = try await store.podcastEpisodeIdentityReviewHeldIDs(in: incoming.feedID)
        XCTAssertEqual(pending.map(\.incomingID), [incoming.itemID])
        XCTAssertEqual(Set(pending.first?.candidateIDs ?? []), [firstCandidate.itemID, secondCandidate.itemID])
        XCTAssertEqual(heldIDs, [incoming.itemID])
    }

    func testIncomingEpisodeWithTwoCompetingExistingMatchesIsNotMergedOrClaimed() async throws {
        let first = try episode(
            guid: "legacy-a", enclosure: "https://cdn.example.test/a.mp3", duration: 3_600
        )
        let second = try episode(
            guid: "legacy-b", enclosure: "https://cdn.example.test/b.mp3", duration: 3_608
        )
        let incoming = try episode(
            guid: "TWiT-1635-1110-863758", enclosure: "https://cdn.twit.tv/audio/twit-1635.mp3",
            duration: 3_604
        )
        let store = try makeStore()
        try seedLegacyEpisodes([first, second], in: store)

        let result = try await store.admitPodcastEpisodes(
            [incoming], admission: .incremental, claimingNewest: 5
        )

        let stored = try await store.podcastEpisodes(for: first.feedID)
        XCTAssertEqual(stored.count, 3)
        XCTAssertTrue(result.claimed.isEmpty)
    }

    func testFinishedEpisodeLookalikeIsHeldAndNeverClaimedAfterGUIDChange() async throws {
        let old = try episode(guid: "https://captivate.fm/finished.mp3", enclosure: "https://captivate.fm/finished.mp3")
        let refreshed = try episode(
            guid: "TWiT-1635-1110-863758", enclosure: "https://cdn.twit.tv/finished.mp3",
            publishedAt: origin.addingTimeInterval(15)
        )
        let store = try makeStore()
        let revisionID = try RevisionID(rawValue: "finished-revision")
        try await store.save(episode: old)
        _ = try await store.save(
            playback: PlaybackState(
                itemID: old.itemID, revisionID: revisionID, sessionID: "identity-test",
                sequence: 1, positionSeconds: 3_600, durationSeconds: 3_600, completed: true,
                intent: .progress, deviceID: "identity-test", updatedAt: Timestamp(origin)
            ),
            listening: PodcastListeningState(
                episodeID: old.itemID, completedAt: Timestamp(origin), lastRevisionID: revisionID,
                updatedAt: Timestamp(origin)
            )
        )

        let result = try await store.admitPodcastEpisodes(
            [refreshed], admission: .incremental, claimingNewest: 5
        )

        let stored = try await store.podcastEpisodes(for: old.feedID)
        let snapshot = try await store.podcastLibrarySnapshot()
        let held = try await store.podcastEpisodeIdentityReviewHeldIDs(in: old.feedID)
        XCTAssertEqual(Set(stored.map(\.itemID)), [old.itemID, refreshed.itemID])
        XCTAssertEqual(held, [refreshed.itemID])
        XCTAssertNotNil(snapshot.listeningStates[old.itemID]?.completedAt)
        XCTAssertNil(snapshot.listeningStates[refreshed.itemID])
        XCTAssertTrue(result.claimed.isEmpty)
    }

    func testFeedBatchLookalikePairIsHeldAndNeverClaimed() async throws {
        let old = try episode(
            guid: "https://captivate.fm/show/audio/twit-1635.mp3",
            enclosure: "https://captivate.fm/show/audio/twit-1635.mp3"
        )
        let new = try episode(
            guid: "TWiT-1635-1110-863758",
            enclosure: "https://cdn.twit.tv/audio/twit-1635.mp3",
            title: "Security Now! 1635: Example Episode",
            publishedAt: origin.addingTimeInterval(30), duration: 3_602
        )
        let store = try makeStore()

        let result = try await store.admitPodcastEpisodes(
            [old, new], admission: .incremental, claimingNewest: 5,
            claimedAt: Timestamp(origin.addingTimeInterval(100))
        )

        // Two lookalikes first seen together are never collapsed: both keep
        // their own publisher details. The one listed second is flagged against
        // the first; the first is the earlier episode and downloads normally.
        XCTAssertEqual(Set(result.admission.saved), [old.itemID, new.itemID])
        XCTAssertEqual(result.claimed, [old.itemID])
        let stored = try await store.podcastEpisodes(for: old.feedID)
        XCTAssertEqual(Set(stored.map(\.itemID)), [old.itemID, new.itemID])
        XCTAssertEqual(stored.first(where: { $0.itemID == old.itemID })?.rssGUID, old.rssGUID)
        XCTAssertEqual(stored.first(where: { $0.itemID == new.itemID })?.rssGUID, new.rssGUID)
        let held = try await store.podcastEpisodeIdentityReviewHeldIDs(in: old.feedID)
        XCTAssertEqual(held, [new.itemID])

        let repeated = try await store.admitPodcastEpisodes(
            [new, old], admission: .incremental, claimingNewest: 5
        )
        let afterRepeat = try await store.podcastEpisodes(for: old.feedID)
        XCTAssertEqual(Set(afterRepeat.map(\.itemID)), [old.itemID, new.itemID])
        XCTAssertTrue(repeated.admission.newlyAdmitted.isEmpty)
        XCTAssertTrue(repeated.claimed.isEmpty)
        let heldAfterRepeat = try await store.podcastEpisodeIdentityReviewHeldIDs(in: old.feedID)
        XCTAssertEqual(heldAfterRepeat, [new.itemID])
    }

    func testRetiredEpisodeStaysRetiredAndItsLookalikeIsHeld() async throws {
        let old = try episode(guid: "https://captivate.fm/old.mp3", enclosure: "https://captivate.fm/old.mp3")
        let refreshed = try episode(
            guid: "TWiT-1635-1110-863758", enclosure: "https://cdn.twit.tv/new.mp3",
            publishedAt: origin.addingTimeInterval(15)
        )
        let store = try makeStore()

        try await store.save(episode: old)
        let retired = try await store.retireEpisode(old.itemID, at: Timestamp(origin))
        XCTAssertTrue(retired)
        let result = try await store.admitPodcastEpisodes(
            [refreshed], admission: .incremental, claimingNewest: 5
        )

        let stored = try await store.podcastEpisodes(for: old.feedID)
        let removalKind = try await store.removalKind(for: old.itemID)
        let held = try await store.podcastEpisodeIdentityReviewHeldIDs(in: old.feedID)
        XCTAssertEqual(Set(stored.map(\.itemID)), [old.itemID, refreshed.itemID])
        XCTAssertEqual(removalKind, .retired)
        XCTAssertEqual(held, [refreshed.itemID])
        XCTAssertTrue(result.claimed.isEmpty)
    }

    func testLiveStoredLookalikeIsHeldAndItsDetailsAreUntouched() async throws {
        let live = try episode(
            guid: "https://captivate.fm/live.mp3", enclosure: "https://captivate.fm/live.mp3"
        )
        let lookalike = try episode(
            guid: "TWiT-live-1110", enclosure: "https://cdn.twit.tv/live.mp3",
            publishedAt: origin.addingTimeInterval(20)
        )
        let store = try makeStore()
        try await store.save(episode: live)

        let result = try await store.admitPodcastEpisodes(
            [lookalike], admission: .incremental, claimingNewest: 5
        )

        let stored = try await store.podcastEpisodes(for: live.feedID)
        XCTAssertEqual(Set(stored.map(\.itemID)), [live.itemID, lookalike.itemID])
        XCTAssertEqual(stored.first(where: { $0.itemID == live.itemID })?.rssGUID, live.rssGUID)
        XCTAssertTrue(result.claimed.isEmpty)
        let associations = try await store.episodeAssociations()
        XCTAssertTrue(associations.isEmpty, "nothing is linked automatically")
        let reviews = try await store.pendingPodcastEpisodeIdentityReviews(in: live.feedID)
        XCTAssertEqual(reviews.map(\.incomingID), [lookalike.itemID])
        XCTAssertEqual(reviews.first?.candidateIDs, [live.itemID])
    }

    func testTwoRemovedLookalikesHoldTheNewcomerInsteadOfPickingOne() async throws {
        let first = try episode(guid: "removed-a", enclosure: "https://cdn.example.test/removed-a.mp3")
        let second = try episode(guid: "removed-b", enclosure: "https://cdn.example.test/removed-b.mp3")
        let incoming = try episode(
            guid: "TWiT-removed-new", enclosure: "https://cdn.twit.tv/removed-new.mp3"
        )
        let store = try makeStore()
        try seedLegacyEpisodes(
            [first, second], removalKinds: [first.itemID: .retired, second.itemID: .dismissed], in: store
        )

        let result = try await store.admitPodcastEpisodes(
            [incoming], admission: .incremental, claimingNewest: 5
        )

        XCTAssertTrue(result.claimed.isEmpty)
        let reviews = try await store.pendingPodcastEpisodeIdentityReviews(in: first.feedID)
        XCTAssertEqual(reviews.map(\.incomingID), [incoming.itemID])
        XCTAssertEqual(Set(reviews.first?.candidateIDs ?? []), [first.itemID, second.itemID])
        let stored = try await store.podcastEpisodes(for: first.feedID)
        XCTAssertEqual(stored.count, 3)
    }

    func testRemovedLookalikeThatTheFeedStillListsIsNotRelinked() async throws {
        let listedRetired = try episode(
            guid: "listed-retired", enclosure: "https://cdn.example.test/listed-retired.mp3",
            title: "Old title", publishedAt: origin, duration: 3_600
        )
        let correctedListing = try episode(
            guid: "listed-retired", enclosure: "https://cdn.example.test/listed-retired.mp3",
            title: "Corrected title", publishedAt: origin.addingTimeInterval(86_400), duration: 3_900
        )
        let newcomer = try episode(
            guid: "distinct-newcomer", enclosure: "https://cdn.example.test/newcomer.mp3",
            title: "Old title", publishedAt: origin, duration: 3_600
        )
        let store = try makeStore()
        try await store.save(episode: listedRetired)
        try await store.retireEpisode(listedRetired.itemID, at: Timestamp(origin))

        let result = try await store.admitPodcastEpisodes(
            [correctedListing, newcomer], admission: .incremental, claimingNewest: 5
        )

        XCTAssertTrue(result.claimed.isEmpty)
        let stored = try await store.podcastEpisodes(for: listedRetired.feedID)
        XCTAssertEqual(Set(stored.map(\.itemID)), [listedRetired.itemID, newcomer.itemID])
        let reviews = try await store.pendingPodcastEpisodeIdentityReviews(in: listedRetired.feedID)
        XCTAssertEqual(reviews.map(\.incomingID), [newcomer.itemID])
    }

    func testRelistingStoredLegacyTwinsCreatesNoHoldsAndNoAssociations() async throws {
        let first = try episode(guid: "legacy-url-one", enclosure: "https://cdn.example.test/one.mp3")
        let second = try episode(guid: "legacy-url-two", enclosure: "https://cdn.example.test/two.mp3")
        let store = try makeStore()
        try seedLegacyEpisodes([first, second], in: store)
        let before = try await store.podcastEpisodes(for: first.feedID)

        let result = try await store.admitPodcastEpisodes(
            [first, second], admission: .incremental, claimingNewest: 5
        )

        // Both are already stored, so neither is a newcomer: nothing is
        // held, linked, claimed or changed.
        let after = try await store.podcastEpisodes(for: first.feedID)
        let held = try await store.podcastEpisodeIdentityReviewHeldIDs(in: first.feedID)
        let associations = try await store.episodeAssociations(includingReversed: true)
        XCTAssertEqual(after, before)
        XCTAssertTrue(held.isEmpty)
        XCTAssertTrue(associations.isEmpty)
        XCTAssertTrue(result.admission.newlyAdmitted.isEmpty)
        XCTAssertTrue(result.claimed.isEmpty)
    }

    func testThreeChainedLookalikesAreAllHeldEvenWhenTheEndsDoNotMatchEachOther() async throws {
        // A is stored. B is within a minute of A, and C is within a minute of
        // B but not of A. C must not slip through as "new".
        let stored = try episode(
            guid: "chain-a", enclosure: "https://cdn.example.test/chain-a.mp3",
            title: "Chained title", publishedAt: origin
        )
        let middle = try episode(
            guid: "chain-b", enclosure: "https://cdn.example.test/chain-b.mp3",
            title: "Chained title", publishedAt: origin.addingTimeInterval(50)
        )
        let last = try episode(
            guid: "chain-c", enclosure: "https://cdn.example.test/chain-c.mp3",
            title: "Chained title", publishedAt: origin.addingTimeInterval(100)
        )
        let store = try makeStore()
        try await store.save(episode: stored)

        let result = try await store.admitPodcastEpisodes(
            [middle, last], admission: .incremental, claimingNewest: 5
        )

        let held = try await store.podcastEpisodeIdentityReviewHeldIDs(in: stored.feedID)
        let rows = try await store.podcastEpisodes(for: stored.feedID)
        XCTAssertEqual(held, [middle.itemID, last.itemID])
        XCTAssertEqual(Set(rows.map(\.itemID)), [stored.itemID, middle.itemID, last.itemID])
        XCTAssertTrue(result.claimed.isEmpty)
    }

    func testSayingDifferentRemovesOnlyTheFlag() async throws {
        let original = try episode(guid: "diff-old", enclosure: "https://cdn.example.test/diff-old.mp3")
        let newcomer = try episode(
            guid: "diff-new", enclosure: "https://cdn.example.test/diff-new.mp3",
            publishedAt: origin.addingTimeInterval(20)
        )
        let store = try makeStore()
        try await store.save(episode: original)
        _ = try await store.admitPodcastEpisodes([newcomer], admission: .incremental, claimingNewest: 5)
        let flaggedBefore = try await store.podcastEpisodeIdentityReviewHeldIDs(in: original.feedID)
        XCTAssertEqual(flaggedBefore, [newcomer.itemID])

        let cleared = try await store.clearPodcastEpisodePossibleDuplicate(newcomer.itemID)
        let relisted = try await store.admitPodcastEpisodes(
            [original, newcomer], admission: .incremental, claimingNewest: 5
        )

        XCTAssertTrue(cleared)
        let flaggedAfter = try await store.podcastEpisodeIdentityReviewHeldIDs(in: original.feedID)
        XCTAssertTrue(flaggedAfter.isEmpty)
        XCTAssertTrue(relisted.admission.newlyAdmitted.isEmpty, "a refresh never flags a stored episode again")
        let rows = try await store.podcastEpisodes(for: original.feedID)
        XCTAssertEqual(Set(rows.map(\.itemID)), [original.itemID, newcomer.itemID])
        let automaticClaim = try await store.claimPodcastDownload(episodeID: newcomer.itemID, scope: .untouched)
        XCTAssertTrue(automaticClaim, "once cleared it downloads like any other episode")
        let clearedAgain = try await store.clearPodcastEpisodePossibleDuplicate(newcomer.itemID)
        XCTAssertFalse(clearedAgain)
    }

    func testTwoLookalikesFirstSeenTogetherFlagOnlyTheSecond() async throws {
        let first = try episode(guid: "pair-one", enclosure: "https://cdn.example.test/pair-one.mp3")
        let second = try episode(
            guid: "pair-two", enclosure: "https://cdn.example.test/pair-two.mp3",
            publishedAt: origin.addingTimeInterval(10)
        )
        let store = try makeStore()

        let result = try await store.admitPodcastEpisodes(
            [first, second], admission: .incremental, claimingNewest: 5
        )

        let flagged = try await store.pendingPodcastEpisodeIdentityReviews(in: first.feedID)
        XCTAssertEqual(flagged.map(\.incomingID), [second.itemID])
        XCTAssertEqual(flagged.first?.candidateIDs, [first.itemID])
        XCTAssertEqual(result.claimed, [first.itemID])
    }
}
