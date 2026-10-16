import AppKit
import Foundation
import SwiftUI
import WiltedDomain
import WiltedLibrary
import WiltedProducer
import XCTest
@testable import WiltedMac

/// Headless tests for the Larder duplicate-review sheet: immediate loading,
/// one authoritative visible pair selection, explicit confirmation, captured
/// consequences shown before Apply, stale refusal, superseded/cancelled reads
/// and commits, parent projection refresh, and explicit reversal. Every store
/// is test-owned and synthetic; no test touches the network.
@MainActor
final class WiltedMacEpisodeIdentityReviewTests: XCTestCase {
    let created = Date(timeIntervalSince1970: 1_700_000_000)
    let feedURL = URL(string: "https://feeds.example.test/identity-review.xml")!

    struct Fixture {
        let model: WiltedMacModel
        let store: LocalLibraryStore
        let first: ItemID
        let second: ItemID
        let third: ItemID
    }

    func episode(guid: String, title: String) throws -> PodcastEpisode {
        let enclosure = URL(string: "https://media.example.test/review-\(guid).mp3")!
        return try PodcastEpisode(
            itemID: ItemID.derivePodcastEpisode(feedURL: feedURL, rssGUID: guid, enclosureURL: enclosure),
            feedID: ItemID.derivePodcastFeed(from: feedURL), feedURL: feedURL, rssGUID: guid,
            title: title, publishedTime: Timestamp(created), enclosureURL: enclosure,
            enclosureMediaType: "audio/mpeg", durationSeconds: 3_600, createdAt: Timestamp(created)
        )
    }

    func makeModel(_ suffix: String) -> WiltedMacModel {
        WiltedMacModel(
            arguments: [], stateDirectoryOverride: wiltedTemporaryDirectory("identity-review-\(suffix)"),
            storeBootstrap: { url in try LocalLibraryStore(url: url) },
            preferences: WiltedMacTestPreferences.ephemeral()
        )
    }

    func makeFixture(_ suffix: String, sameTitle: Bool = false) async throws -> Fixture {
        let model = makeModel(suffix)
        model.startStoreBootstrap()
        await model.waitForStoreBootstrap()
        addTeardownBlock { await model.close() }
        let store = try XCTUnwrap(model.store)
        let first = try episode(guid: "review-first", title: "Review First")
        let second = try episode(guid: "review-second", title: sameTitle ? "Review First" : "Review Second")
        let third = try episode(guid: "review-third", title: "Review Third")
        for value in [first, second, third] { try await store.save(episode: value) }
        try await store.save(subscription: PodcastSubscription(
            feedID: first.feedID, subscribedAt: Timestamp(created)
        ))
        await model.reloadLibraryRows()
        return Fixture(model: model, store: store, first: first.itemID, second: second.itemID, third: third.itemID)
    }

    /// First: manual Keep plus a queued download. Second: a completed listen and
    /// the current queue slot. Both in the durable queue.
    func seedKeptAndCompleted(_ fixture: Fixture) async throws {
        try await fixture.store.save(episodeDecision: EpisodeDecisionRecord(
            episodeID: fixture.first, decision: .keep, source: .manual, decidedAt: Timestamp(created)
        ))
        try await fixture.store.save(download: PodcastDownload(
            episodeID: fixture.first, status: .queued, updatedAt: Timestamp(created)
        ))
        let completedAt = Timestamp(created.addingTimeInterval(30))
        try await fixture.store.saveListening(PodcastListeningState(
            episodeID: fixture.second, completedAt: completedAt, lastRevisionID: nil, updatedAt: completedAt
        ))
        try await fixture.store.addPodcastQueueEpisode(fixture.first)
        try await fixture.store.addPodcastQueueEpisode(fixture.second)
        try await fixture.store.setCurrentPodcastQueueEpisode(fixture.second)
    }

    func associate(
        first: ItemID, second: ItemID, in store: LocalLibraryStore, representative: ItemID? = nil
    ) async throws -> PodcastEpisodeAssociation {
        let confirmation = PodcastEpisodePairConfirmation(
            confirmationID: UUID(), feedID: try ItemID.derivePodcastFeed(from: feedURL),
            first: first, second: second, confirmedAt: Timestamp(created)
        )
        let preview = try await store.previewEpisodeAssociation(
            confirming: confirmation, representativeID: representative ?? first
        )
        return try await store.applyEpisodeAssociation(preview)
    }

    func makeReview(_ fixture: Fixture, anchor: ItemID? = nil) -> WiltedMacEpisodeIdentityReviewModel {
        WiltedMacEpisodeIdentityReviewModel(
            model: fixture.model, anchorID: (anchor ?? fixture.first).rawValue
        )
    }

    func larderRows(_ fixture: Fixture, of members: [ItemID]) -> [WiltedMacEpisode] {
        let ids = Set(members.map(\.rawValue))
        return fixture.model.larderPresentationEpisodes.filter { ids.contains($0.id) }
    }

    /// Polls a condition that needs an actor hop (the in-memory server).
    func waitFor(
        _ what: String, timeout: Duration = .seconds(10),
        _ condition: @MainActor () async -> Bool
    ) async throws {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(25))
        }
        if await condition() { return }
        XCTFail("Timed out waiting for \(what)")
    }

    // MARK: - Loading, fencing, retry

    func testLoadStartsImmediatelyAndSupersededOrCancelledReadsNeverPublish() async throws {
        let fixture = try await makeFixture("loading")
        let review = makeReview(fixture)
        XCTAssertEqual(review.stage, .loading, "the sheet reads as loading before any await")

        let gate = ReviewGate()
        defer { Task { await gate.release() } }
        review.readHookForTesting = { await gate.pause() }
        let superseded = Task { await review.load() }
        try await waitFor("review hook entered") { await gate.hasEntered }
        XCTAssertEqual(review.stage, .loading)

        // A newer load owns the sheet while the first read is still parked.
        review.readHookForTesting = nil
        let current = Task { await review.load() }
        await current.value
        XCTAssertEqual(review.stage, .ready)
        XCTAssertEqual(
            Set(review.candidates.map(\.id)),
            Set([fixture.second.rawValue, fixture.third.rawValue])
        )
        XCTAssertEqual(review.visibleRepresentativeID, fixture.first.rawValue,
                       "loading resets the representative to this episode")
        let published = review.candidates.count

        // State changes after the superseded read started; releasing it must
        // publish nothing.
        try await fixture.store.save(episode: try episode(guid: "review-fourth", title: "Review Fourth"))
        await gate.release()
        await superseded.value
        XCTAssertEqual(review.candidates.count, published, "a superseded read never publishes")

        // A cancelled read publishes nothing either.
        let cancelled = Task { await review.load() }
        cancelled.cancel()
        await cancelled.value
        XCTAssertEqual(review.candidates.count, published)
    }

    func testLoadFailureOffersRetryAndSucceedsOnceTheStoreOpens() async throws {
        let model = makeModel("retry")
        addTeardownBlock { await model.close() }
        let first = try episode(guid: "retry-first", title: "Retry First")
        let review = WiltedMacEpisodeIdentityReviewModel(model: model, anchorID: first.itemID.rawValue)
        await review.load()
        guard case .failed = review.stage else {
            XCTFail("an unopened store reads as a failure with Retry")
            return
        }
        model.startStoreBootstrap()
        await model.waitForStoreBootstrap()
        let store = try XCTUnwrap(model.store)
        try await store.save(episode: first)
        await review.load()
        XCTAssertEqual(review.stage, .ready)
        XCTAssertEqual(review.anchorTitle, "Retry First")
    }

    // MARK: - One authoritative visible selection

    func testVisibleSelectionChangeAfterPreviewVoidsComparisonAndApprovalBeforeApply() async throws {
        let fixture = try await makeFixture("selection-void")
        try await seedKeptAndCompleted(fixture)
        let review = makeReview(fixture)
        await review.load()
        await review.selectPair(
            first: fixture.first.rawValue, second: fixture.second.rawValue,
            representative: fixture.first.rawValue
        )
        await review.reviewPair()
        XCTAssertNotNil(review.approvalPreview)

        // Changing the candidate voids the old comparison and typed approval.
        review.setVisibleCandidate(fixture.third.rawValue)
        XCTAssertNil(review.comparison)
        XCTAssertNil(review.approvalPreview)
        XCTAssertNil(review.selection)
        XCTAssertEqual(review.visibleCandidateID, fixture.third.rawValue)
        XCTAssertEqual(review.visibleRepresentativeID, fixture.first.rawValue)

        // The old A+B pair can no longer be applied.
        await review.applyAssociation()
        XCTAssertEqual(review.errorMessage, WiltedMacEpisodeIdentityReviewModel.confirmationRequiredMessage)
        let associations = try await fixture.store.episodeAssociations()
        XCTAssertTrue(associations.isEmpty, "a changed selection can never apply the old pair")

        // The new selection must be compared and confirmed for itself.
        await review.selectPair(
            first: fixture.first.rawValue, second: fixture.third.rawValue,
            representative: fixture.first.rawValue
        )
        XCTAssertNotNil(review.comparison)
        XCTAssertNil(review.approvalPreview)
        await review.reviewPair()
        XCTAssertNotNil(review.approvalPreview)
    }

    func testRepresentativeChangeAfterPreviewVoidsTheTypedApproval() async throws {
        let fixture = try await makeFixture("representative-void")
        let review = makeReview(fixture)
        await review.load()
        await review.selectPair(
            first: fixture.first.rawValue, second: fixture.second.rawValue,
            representative: fixture.first.rawValue
        )
        await review.reviewPair()
        XCTAssertNotNil(review.approvalPreview)

        review.setVisibleRepresentative(fixture.second.rawValue)
        XCTAssertNil(review.approvalPreview)
        XCTAssertNil(review.comparison)
        XCTAssertNil(review.selection)
        XCTAssertEqual(review.visibleRepresentativeID, fixture.second.rawValue)

        await review.applyAssociation()
        XCTAssertEqual(review.errorMessage, WiltedMacEpisodeIdentityReviewModel.confirmationRequiredMessage)
        let associations = try await fixture.store.episodeAssociations()
        XCTAssertTrue(associations.isEmpty)
    }

    func testDelayedComparisonSupersededBySelectionChangePublishesNothingAndOwnsNoSpinner() async throws {
        let fixture = try await makeFixture("delayed-comparison")
        let review = makeReview(fixture)
        await review.load()

        let firstGate = ReviewGate()
        defer { Task { await firstGate.release() } }
        review.readHookForTesting = { await firstGate.pause() }
        let superseded = Task { await review.selectPair(
            first: fixture.first.rawValue, second: fixture.second.rawValue,
            representative: fixture.first.rawValue) }
        try await waitFor("review hook entered") { await firstGate.hasEntered }
        XCTAssertEqual(review.activity, .comparingPair)

        // The owner changes the candidate while the comparison is parked: the
        // old read is superseded and its busy ownership released.
        review.setVisibleCandidate(fixture.third.rawValue)
        XCTAssertNil(review.activity)
        XCTAssertNil(review.comparison)

        // A newer comparison starts while the old read is still parked.
        let secondGate = ReviewGate()
        defer { Task { await secondGate.release() } }
        review.readHookForTesting = { await secondGate.pause() }
        let current = Task { await review.selectPair(
            first: fixture.first.rawValue, second: fixture.third.rawValue,
            representative: fixture.first.rawValue) }
        try await waitFor("review hook entered") { await secondGate.hasEntered }
        XCTAssertEqual(review.activity, .comparingPair)

        // Releasing the old read may not publish or clear the newer spinner.
        review.readHookForTesting = nil
        await firstGate.release()
        await superseded.value
        XCTAssertNil(review.comparison, "the superseded read never restores its comparison")
        XCTAssertEqual(review.activity, .comparingPair, "an old completion cannot clear a newer spinner")

        await secondGate.release()
        await current.value
        XCTAssertNil(review.activity)
        let compared = try XCTUnwrap(review.comparison)
        XCTAssertEqual(Set([compared.first.episodeID, compared.second.episodeID]),
                       Set([fixture.first, fixture.third]))
    }

    func testDelayedPreviewSupersededByCandidateChangePublishesNothing() async throws {
        let fixture = try await makeFixture("delayed-preview")
        let review = makeReview(fixture)
        await review.load()
        await review.selectPair(
            first: fixture.first.rawValue, second: fixture.second.rawValue, representative: fixture.first.rawValue)
        XCTAssertNotNil(review.comparison)

        let gate = ReviewGate()
        defer { Task { await gate.release() } }
        review.readHookForTesting = { await gate.pause() }
        let preview = Task { await review.reviewPair() }
        try await waitFor("review hook entered") { await gate.hasEntered }

        review.setVisibleCandidate(fixture.third.rawValue)
        await gate.release()
        await preview.value
        XCTAssertNil(review.approvalPreview, "a superseded preview never publishes an approval")
        XCTAssertNil(review.comparison)
        XCTAssertNil(review.selection)
    }

    /// Dismissal (the sheet's own invalidation) must void a parked read even
    /// though the underlying store call keeps running.
    func testDismissalInvalidatesParkedReads() async throws {
        let fixture = try await makeFixture("dismissal")
        let review = makeReview(fixture)
        await review.load()
        let gate = ReviewGate()
        defer { Task { await gate.release() } }
        review.readHookForTesting = { await gate.pause() }
        let comparison = Task { await review.selectPair(
            first: fixture.first.rawValue, second: fixture.second.rawValue,
            representative: fixture.first.rawValue) }
        try await waitFor("review hook entered") { await gate.hasEntered }
        let mountedSheet = WiltedMacEpisodeIdentityReview(
            model: fixture.model, anchorID: fixture.first.rawValue, review: review
        )
        _ = try WiltedMacHeadless.recognizedText(mountedSheet, size: CGSize(width: 700, height: 900))
        try await waitFor("sheet disappearance cancels the owned read") { review.activity == nil }
        await gate.release()
        await comparison.value
        XCTAssertNil(review.comparison)
        XCTAssertNil(review.activity)
    }
}

/// Holds a review read, preview, or parked commit until the test lets it go.
actor ReviewGate {
    private(set) var hasEntered = false
    private var isReleased = false
    private var releases: [CheckedContinuation<Void, Never>] = []

    func pause() async {
        hasEntered = true
        guard !isReleased else { return }
        await withCheckedContinuation { releases.append($0) }
    }

    func release() {
        isReleased = true
        releases.forEach { $0.resume() }
        releases = []
    }
}
