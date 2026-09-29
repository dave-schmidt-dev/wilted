import Foundation
import XCTest
import WiltedDomain
import WiltedProducer
@testable import WiltedMac

@MainActor
final class WiltedMacFeedDecisionRaceTests: XCTestCase {
    func testDecisionCommitsWhileAnUnrelatedLedgerWriterIsHeld() async throws {
        let gate = BootstrapGate()
        let fixture = try await makeRaceFixture(count: 1)
        addTeardownBlock { await fixture.model.close() }
        addTeardownBlock { await gate.release() }
        let unrelatedToken = UUID()
        fixture.model.subscriptionWriteTasks[unrelatedToken] = Task { await gate.hold() }
        await gate.waitUntilHeld()

        let episodeID = fixture.episodes[0].id
        let decision = Task { @MainActor in
            fixture.model.keepEpisode(fixture.episodes[0])
            while true {
                guard let durable = try? await fixture.store.podcastQueueState() else { return false }
                if durable.episodeIDs.map(\.rawValue) == [episodeID] { return true }
                try? await Task.sleep(nanoseconds: 10_000_000)
            }
        }
        let completedBeforeUnrelatedRelease = await withTaskGroup(of: Bool.self) { group in
            group.addTask { await decision.value }
            group.addTask {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                return false
            }
            let result = await group.next() ?? false
            await gate.release()
            group.cancelAll()
            return result
        }
        XCTAssertTrue(completedBeforeUnrelatedRelease)
        await waitForFeedDecisionWriters(fixture.model)
    }

    func testDisjointDecisionsRemainDurablyOrderedAfterFirstPostCommitPause() async throws {
        let gate = RaceFirstDurableGate()
        let fixture = try await makeRaceFixture(count: 2)
        addTeardownBlock { await fixture.model.close() }
        addTeardownBlock { await gate.release() }
        fixture.model.feedDecisionAfterDurableCommitForTesting = { await gate.holdFirstOnly() }

        fixture.model.keepEpisode(fixture.episodes[0])
        fixture.model.keepEpisode(fixture.episodes[1])
        await gate.waitUntilHeld()
        let beforeRelease = try await fixture.store.podcastQueueState()
        XCTAssertEqual(beforeRelease.episodeIDs.map(\.rawValue), [fixture.episodes[0].id])

        await gate.release()
        await waitForFeedDecisionWriters(fixture.model)
        let durable = try await fixture.store.podcastQueueState()
        XCTAssertEqual(durable.episodeIDs.map(\.rawValue), fixture.episodes.map(\.id))
        XCTAssertEqual(fixture.model.podcastQueueIDs, fixture.episodes.map(\.id))
    }

    func testBulkSkipWithdrawsOnlyItsCapturedPreparationRequests() async throws {
        let gate = BootstrapGate()
        let fixture = try await makeRaceFixture(count: 3)
        addTeardownBlock { await fixture.model.close() }
        addTeardownBlock { await gate.release() }
        let selected = Array(fixture.episodes.prefix(2))
        let retained = fixture.episodes[2]
        fixture.model.preparationRequestSequences = [selected[0].id: 1, selected[1].id: 2, retained.id: 3]
        fixture.model.feedDecisionBeforeCommitForTesting = { await gate.hold() }

        fixture.model.decideFeedEpisodes(.skip, episodes: selected)
        await gate.waitUntilHeld()
        XCTAssertNil(fixture.model.preparationRequestSequences[selected[0].id])
        XCTAssertNil(fixture.model.preparationRequestSequences[selected[1].id])
        XCTAssertEqual(fixture.model.preparationRequestSequences[retained.id], 3)

        await gate.release()
        await waitForFeedDecisionWriters(fixture.model)
        for index in 0..<2 {
            let removal = try await fixture.store.removalKind(for: fixture.itemIDs[index])
            XCTAssertEqual(removal, .retired)
        }
    }

    private func makeRaceFixture(count: Int) async throws -> RaceFixture {
        let directory = wiltedTemporaryDirectory("feed-decision-race")
        let createdAt = Timestamp(Date(timeIntervalSince1970: 1_700_000_000))
        let feedURL = URL(string: "https://feeds.example.test/feed-decision-race.xml")!
        let feedID = try ItemID.derivePodcastFeed(from: feedURL)
        let itemIDs = try (0..<count).map { index in
            try ItemID.derivePodcastEpisode(
                feedURL: feedURL, rssGUID: "race-\(index)",
                enclosureURL: URL(string: "https://media.example.test/race-\(index).mp3")!
            )
        }
        let model = WiltedMacModel(
            arguments: [], stateDirectoryOverride: directory,
            storeBootstrap: { url in
                let store = try LocalLibraryStore(url: url)
                try await store.save(feed: try PodcastFeed(
                    itemID: feedID, canonicalURL: feedURL, title: "Race feed", createdAt: createdAt
                ))
                try await store.save(subscription: PodcastSubscription(feedID: feedID, subscribedAt: createdAt))
                for (index, itemID) in itemIDs.enumerated() {
                    try await store.save(episode: try PodcastEpisode(
                        itemID: itemID, feedID: feedID, feedURL: feedURL, rssGUID: "race-\(index)",
                        title: "Race \(index)", publishedTime: createdAt,
                        enclosureURL: URL(string: "https://media.example.test/race-\(index).mp3")!,
                        enclosureMediaType: "audio/mpeg", createdAt: createdAt
                    ))
                }
                return store
            },
            preferences: WiltedMacTestPreferences.ephemeral()
        )
        model.startStoreBootstrap()
        await model.waitForStoreBootstrap()
        let store = try LocalLibraryStore(url: directory.appendingPathComponent("library.sqlite"))
        let episodes = itemIDs.compactMap { itemID in model.episodes.first { $0.id == itemID.rawValue } }
        XCTAssertEqual(episodes.count, count)
        return RaceFixture(model: model, store: store, episodes: episodes, itemIDs: itemIDs)
    }
}

private struct RaceFixture {
    let model: WiltedMacModel
    let store: LocalLibraryStore
    let episodes: [WiltedMacEpisode]
    let itemIDs: [ItemID]
}

private actor RaceFirstDurableGate {
    private var held = false
    private var continuation: CheckedContinuation<Void, Never>?
    private var observers: [CheckedContinuation<Void, Never>] = []

    func holdFirstOnly() async {
        guard !held else { return }
        held = true
        observers.forEach { $0.resume() }
        observers.removeAll()
        await withCheckedContinuation { continuation = $0 }
    }

    func waitUntilHeld() async {
        if held { return }
        await withCheckedContinuation { observers.append($0) }
    }

    func release() {
        continuation?.resume()
        continuation = nil
    }
}
