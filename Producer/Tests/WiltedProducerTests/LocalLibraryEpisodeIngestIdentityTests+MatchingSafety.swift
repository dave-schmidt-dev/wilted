import XCTest
import WiltedDomain
@testable import WiltedProducer

extension LocalLibraryEpisodeIngestIdentityTests {
    func testTwoNewEntriesMatchingOneUnlistedEpisodeAreBothHeld() async throws {
        let store = try makeStore()
        let old = try episode(guid: "stored", enclosure: "https://cdn.example.test/stored.mp3")
        let first = try episode(guid: "new-one", enclosure: "https://cdn.example.test/new-one.mp3")
        let second = try episode(guid: "new-two", enclosure: "https://cdn.example.test/new-two.mp3")
        try await store.save(episode: old)
        let result = try await store.admitPodcastEpisodes(
            [first, second], admission: .incremental, claimingNewest: 5
        )
        let holds = try await store.pendingPodcastEpisodeIdentityReviews(in: old.feedID)
        XCTAssertEqual(Set(holds.map(\.incomingID)), [first.itemID, second.itemID])
        XCTAssertTrue(holds.allSatisfy { $0.candidateIDs.contains(old.itemID) })
        XCTAssertTrue(result.claimed.isEmpty)
        let original = try await store.podcastEpisode(for: old.itemID)
        XCTAssertEqual(original?.rssGUID, old.rssGUID)
    }

    func testStaleMetadataCannotRedirectAnItemWhoseCurrentSourceIDIsInTheRefresh() async throws {
        let original = try episode(
            guid: "stable-guid-a", enclosure: "https://cdn.example.test/a.mp3",
            title: "Previous title", publishedAt: origin, duration: 3_600
        )
        let correctedA = try episode(
            guid: "stable-guid-a", enclosure: "https://cdn.example.test/a.mp3",
            title: "Corrected title for A", publishedAt: origin.addingTimeInterval(86_400),
            duration: 3_900
        )
        let distinctB = try episode(
            guid: "stable-guid-b", enclosure: "https://cdn.example.test/b.mp3",
            title: "Previous title", publishedAt: origin, duration: 3_600
        )
        let store = try makeStore()
        try await store.save(episode: original)
        try await store.save(download: PodcastDownload(
            episodeID: original.itemID, status: .failed, updatedAt: Timestamp(origin)
        ))
        let revisionID = try RevisionID(rawValue: "stale-metadata-progress")
        _ = try await store.save(playback: PlaybackState(
            itemID: original.itemID, revisionID: revisionID, sessionID: "identity-test",
            sequence: 1, positionSeconds: 420, durationSeconds: 3_600, completed: false,
            intent: .progress, deviceID: "identity-test", updatedAt: Timestamp(origin)
        ))

        let result = try await store.admitPodcastEpisodes(
            [correctedA, distinctB], admission: .incremental, claimingNewest: 0
        )

        let stored = try await store.podcastEpisodes(for: original.feedID)
        XCTAssertEqual(Set(stored.map(\.itemID)), [original.itemID, distinctB.itemID])
        XCTAssertEqual(stored.first(where: { $0.itemID == original.itemID })?.title, correctedA.title)
        XCTAssertEqual(stored.first(where: { $0.itemID == distinctB.itemID })?.title, distinctB.title)
        XCTAssertEqual(result.admission.newlyAdmitted, [distinctB.itemID])
        let holds = try await store.pendingPodcastEpisodeIdentityReviews(in: original.feedID)
        XCTAssertEqual(holds.map(\.incomingID), [distinctB.itemID])
        let snapshot = try await store.podcastLibrarySnapshot()
        XCTAssertNotNil(snapshot.downloads[original.itemID])
        XCTAssertEqual(
            snapshot.playbackStates.values.first(where: { $0.itemID == original.itemID })?.positionSeconds,
            420
        )
    }

    func testPunctuationKeepsDistinctItemsReleasedTogetherSeparate() async throws {
        let numbered = try episode(
            guid: "episode-one-point-two", enclosure: "https://cdn.example.test/1.2.mp3",
            title: "Episode 1.2"
        )
        let unpunctuated = try episode(
            guid: "episode-twelve", enclosure: "https://cdn.example.test/12.mp3",
            title: "Episode 12"
        )
        let store = try makeStore()

        let result = try await store.admitPodcastEpisodes(
            [numbered, unpunctuated], admission: .incremental, claimingNewest: 0
        )

        let stored = try await store.podcastEpisodes(for: numbered.feedID)
        XCTAssertEqual(Set(stored.map(\.itemID)), [numbered.itemID, unpunctuated.itemID])
        XCTAssertEqual(Set(result.admission.newlyAdmitted), [numbered.itemID, unpunctuated.itemID])
        let associations = try await store.episodeAssociations()
        let reviews = try await store.pendingPodcastEpisodeIdentityReviews(in: numbered.feedID)
        XCTAssertTrue(associations.isEmpty)
        XCTAssertTrue(reviews.isEmpty)

        let repeated = try await store.admitPodcastEpisodes(
            [numbered, unpunctuated], admission: .incremental, claimingNewest: 5
        )
        let afterRepeat = try await store.podcastEpisodes(for: numbered.feedID)
        XCTAssertEqual(Set(afterRepeat.map(\.itemID)), [numbered.itemID, unpunctuated.itemID])
        XCTAssertTrue(repeated.admission.newlyAdmitted.isEmpty)
        XCTAssertTrue(repeated.claimed.isEmpty)
    }

    func testListedSingleLookalikeIsHeldAndNeverClaimedAcrossRefreshes() async throws {
        let originalA = try episode(
            guid: "stable-guid-a-overlap", enclosure: "https://cdn.example.test/a-overlap.mp3",
            title: "Shared title", publishedAt: origin, duration: 3_600
        )
        let correctedA = originalA
        let distinctB = try episode(
            guid: "stable-guid-b-overlap", enclosure: "https://cdn.example.test/b-overlap.mp3",
            title: "Shared title", publishedAt: origin, duration: 3_600
        )
        let store = try makeStore()
        try await store.save(episode: originalA)

        let firstRefresh = try await store.admitPodcastEpisodes(
            [correctedA, distinctB], admission: .incremental, claimingNewest: 5
        )
        let firstReview = try await store.pendingPodcastEpisodeIdentityReviews(in: originalA.feedID)
        let firstAssociations = try await store.episodeAssociations()

        XCTAssertEqual(firstRefresh.admission.newlyAdmitted, [distinctB.itemID])
        XCTAssertTrue(firstRefresh.claimed.isEmpty)
        XCTAssertEqual(firstReview.map(\.incomingID), [distinctB.itemID])
        XCTAssertEqual(firstReview.first?.candidateIDs, [originalA.itemID])
        XCTAssertTrue(firstAssociations.isEmpty)

        let secondRefresh = try await store.admitPodcastEpisodes(
            [correctedA, distinctB], admission: .incremental, claimingNewest: 5
        )
        let stored = try await store.podcastEpisodes(for: originalA.feedID)
        let heldIDs = try await store.podcastEpisodeIdentityReviewHeldIDs(in: originalA.feedID)
        let secondAssociations = try await store.episodeAssociations()

        XCTAssertEqual(Set(stored.map(\.itemID)), [originalA.itemID, distinctB.itemID])
        XCTAssertTrue(secondRefresh.admission.newlyAdmitted.isEmpty)
        XCTAssertTrue(secondRefresh.claimed.isEmpty)
        XCTAssertEqual(heldIDs, [distinctB.itemID])
        XCTAssertTrue(secondAssociations.isEmpty)
    }

    func testListedAAndStoredCLookalikesAreComparedBeforeBCanRebind() async throws {
        let listedA = try episode(
            guid: "unchanged-listed-a", enclosure: "https://cdn.example.test/unchanged-a.mp3",
            title: "Same episode metadata", duration: 3_600
        )
        let storedC = try episode(
            guid: "unrelated-stored-c", enclosure: "https://cdn.example.test/unrelated-c.mp3",
            title: "Same episode metadata", duration: 3_600
        )
        let incomingB = try episode(
            guid: "distinct-incoming-b", enclosure: "https://cdn.example.test/incoming-b.mp3",
            title: "Same episode metadata", duration: 3_600
        )
        let store = try makeStore()
        try seedLegacyEpisodes([listedA, storedC], in: store)

        let result = try await store.admitPodcastEpisodes(
            [listedA, incomingB], admission: .incremental, claimingNewest: 5
        )
        let stored = try await store.podcastEpisodes(for: listedA.feedID)
        let reviews = try await store.pendingPodcastEpisodeIdentityReviews(in: listedA.feedID)

        XCTAssertEqual(Set(stored.map(\.itemID)), [listedA.itemID, storedC.itemID, incomingB.itemID])
        XCTAssertEqual(stored.first(where: { $0.itemID == storedC.itemID })?.rssGUID, storedC.rssGUID)
        XCTAssertEqual(result.admission.newlyAdmitted, [incomingB.itemID])
        XCTAssertTrue(result.claimed.isEmpty)
        XCTAssertEqual(reviews.map(\.incomingID), [incomingB.itemID])
        XCTAssertEqual(Set(reviews.first?.candidateIDs ?? []), [listedA.itemID, storedC.itemID])
    }

    func testListedLookalikeJoinsEveryEarlierMatchingItem() async throws {
        let listedA = try episode(
            guid: "duration-listed-a", enclosure: "https://cdn.example.test/duration-a.mp3",
            title: "Same title", duration: 3_600
        )
        let storedC = try episode(
            guid: "duration-stored-c", enclosure: "https://cdn.example.test/duration-c.mp3",
            title: "Same title", duration: 3_603
        )
        let incomingB = try episode(
            guid: "duration-new-b", enclosure: "https://cdn.example.test/duration-b.mp3",
            title: "Same title", duration: 3_600
        )
        let store = try makeStore()
        try seedLegacyEpisodes([listedA, storedC], in: store)

        let result = try await store.admitPodcastEpisodes(
            [listedA, incomingB], admission: .incremental, claimingNewest: 5
        )
        let review = try await store.pendingPodcastEpisodeIdentityReviews(in: listedA.feedID)

        XCTAssertTrue(result.claimed.isEmpty)
        XCTAssertEqual(review.map(\.incomingID), [incomingB.itemID])
        XCTAssertEqual(Set(review.first?.candidateIDs ?? []), [listedA.itemID, storedC.itemID])
        XCTAssertEqual(Set(review.first?.reasons ?? []), [.multipleMatches])
    }

    func testStaleAndCurrentMetadataForOneStorageIDStillHoldTheNewcomer() async throws {
        let originalA = try episode(
            guid: "duration-stable-a", enclosure: "https://cdn.example.test/stable-a.mp3",
            title: "Same title", duration: 3_600
        )
        let refreshedA = try episode(
            guid: "duration-stable-a", enclosure: "https://cdn.example.test/stable-a.mp3",
            title: "Same title", duration: 3_620
        )
        let incomingB = try episode(
            guid: "duration-stable-b", enclosure: "https://cdn.example.test/stable-b.mp3",
            title: "Same title", duration: 3_600
        )
        let store = try makeStore()
        try await store.save(episode: originalA)

        let result = try await store.admitPodcastEpisodes(
            [refreshedA, incomingB], admission: .incremental, claimingNewest: 5
        )
        let reviews = try await store.pendingPodcastEpisodeIdentityReviews(in: originalA.feedID)

        XCTAssertEqual(result.admission.newlyAdmitted, [incomingB.itemID])
        XCTAssertTrue(result.claimed.isEmpty)
        XCTAssertEqual(reviews.map(\.incomingID), [incomingB.itemID])
        XCTAssertEqual(reviews.first?.candidateIDs, [originalA.itemID])
    }

    func testNormalizedTitlesUseUnicodeCanonicalCaseAndWhitespaceRules() {
        XCTAssertEqual(
            PodcastEpisodeIdentityMatcher.normalizedTitle("  Café\t  Épisode  "),
            PodcastEpisodeIdentityMatcher.normalizedTitle("cafe\u{301}   e\u{301}pisode")
        )
    }
}
