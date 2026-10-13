import Foundation
import XCTest
import WiltedDomain
import WiltedProducer
@testable import WiltedMac

/// Turning a feed's Auto download or Auto prepare on acts on the episodes it
/// already keeps, through the Feeds popover's board, against a temporary
/// library with stub transfers and a counting pipeline. Feed A is the one
/// changed; feed B's kept episode, and A's undecided and skipped ones, are
/// the controls that must get nothing.
@MainActor
final class WiltedMacFeedPolicyWorkTests: XCTestCase {
    // MARK: Auto download

    func testAutoDownloadOnDownloadsOnlyThisFeedsKeptEpisodesThatAreNotDownloaded() async throws {
        let f = try await makeFixture(feedA: .init(autoDownload: .off, autoPrepare: .off))

        XCTAssertTrue(f.board.update(f.feedA, autoDownload: .on))
        await f.drain()

        let downloads = try await f.subjects(.podcastDownload)
        XCTAssertEqual(downloads, Set(["kept1", "kept2"].map(f.id)))
        XCTAssertEqual(f.transport.count, 2, "both downloads really ran")
        for key in ["kept1", "kept2"] { XCTAssertEqual(f.episode(key)?.downloadState, .completed, key) }
        for key in ["undecided", "skipped", "other"] {
            XCTAssertEqual(f.episode(key)?.downloadState, .notDownloaded, "\(key) is not this feed's kept episode")
        }
        let preparations = try await f.subjects(.podcastPreparation)
        XCTAssertTrue(preparations.isEmpty, "Auto prepare is still Off")
    }

    func testUseGlobalWithTheGlobalDefaultOnCountsAsOnAndMovingBetweenOnStatesIssuesNothing() async throws {
        let f = try await makeFixture(feedA: .init(autoDownload: .on, autoPrepare: .off), downloadEverything: true)
        let launched = try await f.subjects(.podcastDownload)
        XCTAssertTrue(launched.isEmpty, "precondition: opening the library downloads nothing")

        XCTAssertTrue(f.board.update(f.feedA, autoDownload: .useGlobal))
        await f.drain()
        let afterOnToOn = try await f.subjects(.podcastDownload)
        XCTAssertTrue(afterOnToOn.isEmpty, "On to Use global while the global default is on is not a change")
        XCTAssertEqual(f.transport.count, 0)

        XCTAssertTrue(f.board.update(f.feedA, autoDownload: .off))
        await f.drain()
        XCTAssertEqual(f.transport.count, 0, "switching off issues nothing")

        XCTAssertTrue(f.board.update(f.feedA, autoDownload: .useGlobal))
        await f.drain()
        let downloads = try await f.subjects(.podcastDownload)
        XCTAssertEqual(downloads, Set(["kept1", "kept2"].map(f.id)), "Use global resolves to the global On")
        XCTAssertEqual(f.transport.count, 2)
        XCTAssertEqual(f.episode("other")?.downloadState, .notDownloaded, "another feed is untouched")
    }

    // MARK: Auto prepare

    func testAutoPrepareOnPreparesOnlyThisFeedsKeptDownloadedEpisodes() async throws {
        let f = try await makeFixture(feedA: .init(autoDownload: .off, autoPrepare: .off))
        try await f.downloadFromTheirRows(["kept1", "other"])

        XCTAssertTrue(f.board.update(f.feedA, autoPrepare: .on))
        await f.drain()

        let preparations = try await f.subjects(.podcastPreparation)
        XCTAssertEqual(preparations, [f.id("kept1")], "only the kept, downloaded episode of this feed")
        XCTAssertEqual(f.runner.count, 1, "and its preparation really started")
        let downloads = try await f.subjects(.podcastDownload)
        XCTAssertEqual(downloads, Set(["kept1", "other"].map(f.id)), "Auto prepare downloads nothing")
        XCTAssertEqual(f.episode("kept2")?.downloadState, .notDownloaded)
    }

    func testAutoPrepareOnDefersUnderTheOffPeakPolicy() async throws {
        let f = try await makeFixture(
            feedA: .init(autoDownload: .off, autoPrepare: .off), processing: .offPeak(try windowExcludingNow())
        )
        try await f.downloadFromTheirRows(["kept1", "other"])

        XCTAssertTrue(f.board.update(f.feedA, autoPrepare: .on))
        await f.drain()

        XCTAssertTrue(f.model.isDeferredForOffPeak(f.id("kept1")), "an off-peak policy waits for its window")
        XCTAssertEqual(f.runner.count, 0, "nothing prepares outside the window")
        XCTAssertFalse(f.model.isDeferredForOffPeak(f.id("kept2")), "not downloaded")
        XCTAssertFalse(f.model.isDeferredForOffPeak(f.id("other")), "another feed")
    }

    // MARK: Off and failure

    func testTurningEitherOffIssuesNothingAndCancelsNothing() async throws {
        let f = try await makeFixture(
            feedA: .init(autoDownload: .on, autoPrepare: .on), processing: .offPeak(try windowExcludingNow()),
            holdsDownloads: true
        )
        // Work already issued: one download held in flight, one preparation waiting for off-peak.
        f.model.downloadEpisode(try XCTUnwrap(f.episode("kept1")))
        f.model.admitAutomaticPreparation(for: try XCTUnwrap(f.episode("kept2")), at: Date())
        let download = try XCTUnwrap(f.model.podcastDownloadTasks[f.id("kept1")])
        XCTAssertTrue(f.model.isDeferredForOffPeak(f.id("kept2")))

        XCTAssertTrue(f.board.update(f.feedA, autoDownload: .off))
        XCTAssertTrue(f.board.update(f.feedA, autoPrepare: .off))
        await f.board.settle()

        XCTAssertFalse(download.isCancelled, "the running download goes on")
        XCTAssertNotNil(f.model.podcastDownloadTasks[f.id("kept1")])
        XCTAssertTrue(f.episode("kept1")?.downloadState.isInFlight == true)
        XCTAssertTrue(f.model.isDeferredForOffPeak(f.id("kept2")), "the waiting preparation keeps its place")
        XCTAssertNil(f.model.podcastDownloadTasks[f.id("kept2")], "switching off starts nothing")
        XCTAssertTrue(f.model.podcastPreparationTasks.isEmpty)
        let tickets = try await f.store.workTickets()
        XCTAssertFalse(tickets.contains { $0.state == .cancelled }, "\(tickets)")
    }

    func testAFailedPolicySaveIssuesNothing() async throws {
        let f = try await makeFixture(feedA: .init(autoDownload: .off, autoPrepare: .off))
        f.board.beforeFeedPolicySaveHookForTesting = { _ in throw CocoaError(.fileWriteUnknown) }

        XCTAssertTrue(f.board.update(f.feedA, autoDownload: .on, autoPrepare: .on))
        await f.drain()

        XCTAssertTrue(f.board.failedFeedIDs.contains(f.feedA), "the save really failed")
        XCTAssertEqual(
            f.board.policy(for: f.feedA), FeedAutomationPolicy(autoDownload: .off, autoPrepare: .off),
            "the board shows what is stored"
        )
        let failed = try await f.store.workTickets()
        XCTAssertTrue(failed.isEmpty, "\(failed)")
        XCTAssertEqual(f.transport.count, 0)
        XCTAssertEqual(f.runner.count, 0)

        // The control: the same change, saved, does issue the downloads.
        f.board.beforeFeedPolicySaveHookForTesting = nil
        XCTAssertTrue(f.board.update(f.feedA, autoDownload: .on))
        await f.drain()
        let downloads = try await f.subjects(.podcastDownload)
        XCTAssertEqual(downloads, Set(["kept1", "kept2"].map(f.id)))
    }

    /// The second edit was made while the first looked saved, so it saw Auto
    /// download On already. Its save is what turns it on, and it must act.
    func testAChangeQueuedBehindAFailedSaveActsOnWhatItSaves() async throws {
        let f = try await makeFixture(feedA: .init(autoDownload: .off, autoPrepare: .off))
        let saves = DownloadAttemptCounter()
        f.board.beforeFeedPolicySaveHookForTesting = { _ in
            saves.increment()
            if saves.count == 1 { throw CocoaError(.fileWriteUnknown) }
        }

        XCTAssertTrue(f.board.update(f.feedA, autoDownload: .on))
        XCTAssertTrue(f.board.update(f.feedA, keptLimit: .explicit(5)))
        await f.drain()

        XCTAssertEqual(saves.count, 2, "the first save failed and the second ran")
        let feedID = try ItemID(rawValue: f.feedA)
        let stored = try await f.store.feedAutomationPolicy(for: feedID)
        XCTAssertEqual(stored.autoDownload, .on, "the second save carried Auto download On")
        XCTAssertEqual(stored.keptLimit, .explicit(5))
        XCTAssertEqual(f.board.policy(for: f.feedA), stored, "the board shows what the second save stored")
        XCTAssertFalse(f.board.failedFeedIDs.contains(f.feedA), "the save that decided succeeded")
        let downloads = try await f.subjects(.podcastDownload)
        XCTAssertEqual(downloads, Set(["kept1", "kept2"].map(f.id)), "the kept episodes downloaded")

        // The next edit builds on what the board shows, so it keeps Auto download On.
        XCTAssertTrue(f.board.update(f.feedA, keptLimit: .explicit(6)))
        await f.drain()
        let next = try await f.store.feedAutomationPolicy(for: feedID)
        XCTAssertEqual(next.autoDownload, .on, "a later edit does not revert Auto download")
        XCTAssertEqual(next.keptLimit, .explicit(6))
        XCTAssertEqual(f.board.policy(for: f.feedA), next)
    }

    /// Only an edit to the same feed defers the restore: another feed's queued
    /// edit leaves the failed feed restored and marked.
    func testAFailedSaveWithOnlyAnotherFeedsEditQueuedStillRestoresAndMarksTheFeed() async throws {
        let f = try await makeFixture(feedA: .init(autoDownload: .off, autoPrepare: .off))
        let feedA = f.feedA
        f.board.beforeFeedPolicySaveHookForTesting = { feedID in
            if feedID == feedA { throw CocoaError(.fileWriteUnknown) }
        }

        XCTAssertTrue(f.board.update(f.feedA, autoDownload: .on))
        XCTAssertTrue(f.board.update(f.feedB, keptLimit: .explicit(3)))
        await f.drain()

        XCTAssertTrue(f.board.failedFeedIDs.contains(f.feedA))
        XCTAssertEqual(f.board.policy(for: f.feedA), FeedAutomationPolicy(autoDownload: .off, autoPrepare: .off))
        XCTAssertFalse(f.board.failedFeedIDs.contains(f.feedB))
        XCTAssertEqual(f.board.policy(for: f.feedB).keptLimit, .explicit(3))
    }

    /// Rule edits are saved whole, in order, so the same holds for them: a
    /// failed save behind which another edit waits leaves that edit shown, and
    /// a failed save with nothing behind it restores what is stored.
    func testARulesEditQueuedBehindAFailedRulesSaveKeepsItsRules() async throws {
        let f = try await makeFixture(feedA: .init())
        let feedID = try ItemID(rawValue: f.feedA)
        let saves = DownloadAttemptCounter()
        f.board.beforeRulesSaveHookForTesting = { _ in
            saves.increment()
            if saves.count != 2 { throw CocoaError(.fileWriteUnknown) }
        }
        let first = EpisodeMatchRules(rules: [.init(field: .title, includePattern: "alpha", action: .keep)])
        var second = first
        second.rules.append(.init(field: .title, includePattern: "beta", action: .skip))

        XCTAssertTrue(f.board.replaceRules(first, for: f.feedA))
        XCTAssertTrue(f.board.replaceRules(second, for: f.feedA))
        await f.drain()
        let stored = try await f.store.episodeMatchRules(for: feedID)
        XCTAssertEqual(stored, second, "the second save stored the whole set")
        XCTAssertEqual(f.board.rules(for: f.feedA), second)
        XCTAssertFalse(f.board.failedFeedIDs.contains(f.feedA))

        XCTAssertTrue(f.board.replaceRules(first, for: f.feedA))
        await f.drain()
        XCTAssertEqual(saves.count, 3)
        XCTAssertEqual(f.board.rules(for: f.feedA), second, "the board shows what is stored")
        XCTAssertTrue(f.board.failedFeedIDs.contains(f.feedA))
    }
}

// MARK: - Fixture

private final class CountingPreparationRunner: PodcastPipelineRunning, @unchecked Sendable {
    private let counter = DownloadAttemptCounter()
    var count: Int { counter.count }
    func run(request: Data, onProgress: @escaping @Sendable (PodcastPreparationProgress) -> Void) async throws -> Data {
        counter.increment()
        throw CancellationError()
    }
}

@MainActor
private struct PolicyWorkFixture {
    let model: WiltedMacModel
    let board: WiltedMacFeedPolicyBoard
    let store: LocalLibraryStore
    let feedA: String
    let feedB: String
    let ids: [String: String]
    let transport: DownloadAttemptCounter
    let runner: CountingPreparationRunner

    func id(_ key: String) -> String { ids[key] ?? key }

    func episode(_ key: String) -> WiltedMacEpisode? { model.episodes.first { $0.id == id(key) } }

    func subjects(_ kind: WorkTicketKind) async throws -> Set<String> {
        Set(try await store.workTickets().filter { $0.kind == kind }.map(\.subjectID))
    }

    func drain() async {
        await board.settle()
        await model.waitForPodcastOperations()
        await model.waitForPodcastPreparationOperationsForTesting()
    }

    /// Downloads episodes the way their Larder row does. Every fixture feed
    /// starts on Auto prepare Off, so the downloads issue no preparation.
    func downloadFromTheirRows(_ keys: [String]) async throws {
        for key in keys { model.downloadEpisode(try XCTUnwrap(episode(key), key)) }
        await drain()
        for key in keys { XCTAssertEqual(episode(key)?.downloadState, .completed, key) }
        let preparations = try await subjects(.podcastPreparation)
        XCTAssertTrue(preparations.isEmpty, "precondition: no preparation before Auto prepare turns on")
    }
}

extension WiltedMacFeedPolicyWorkTests {
    private struct Spec {
        let feed: Int
        let guid: String
        let kept: Bool
        var skipped = false
        var enclosureURL: URL { URL(string: "https://media.example.test/work-\(guid).mp3")! }
    }

    /// Feed A holds two kept episodes, one undecided and one manually skipped;
    /// feed B, on Auto download and Auto prepare Off, holds one kept episode.
    /// Settings are in place before the library opens, so no global switch
    /// acts on the Larder while the test sets up.
    fileprivate func makeFixture(
        feedA policy: FeedAutomationPolicy, processing: WiltedAutomationProcessingPolicy = .immediate,
        downloadEverything: Bool = false, holdsDownloads: Bool = false
    ) async throws -> PolicyWorkFixture {
        let directory = wiltedTemporaryDirectory("feed-policy-work")
        let feedURLs = [0, 1].map { URL(string: "https://feeds.example.test/work-\($0).xml")! }
        let feedIDs = try feedURLs.map { try ItemID.derivePodcastFeed(from: $0) }
        let subscribedAt = Timestamp(Date(timeIntervalSince1970: 1_672_531_200))
        let specs = [
            Spec(feed: 0, guid: "kept1", kept: true), Spec(feed: 0, guid: "kept2", kept: true),
            Spec(feed: 0, guid: "undecided", kept: false), Spec(feed: 0, guid: "skipped", kept: false, skipped: true),
            Spec(feed: 1, guid: "other", kept: true),
        ]
        let episodeIDs = try specs.map {
            try ItemID.derivePodcastEpisode(feedURL: feedURLs[$0.feed], rssGUID: $0.guid, enclosureURL: $0.enclosureURL)
        }
        let policies = [policy, FeedAutomationPolicy(autoDownload: .off, autoPrepare: .off)]
        let counter = DownloadAttemptCounter()
        let runner = CountingPreparationRunner()
        let model = WiltedMacModel(
            arguments: [], stateDirectoryOverride: directory,
            storeBootstrap: { url in
                let store = try LocalLibraryStore(url: url)
                for (index, feedID) in feedIDs.enumerated() {
                    try await store.save(feed: try PodcastFeed(
                        itemID: feedID, canonicalURL: feedURLs[index], title: "Work Feed \(index)", createdAt: subscribedAt
                    ))
                    try await store.save(subscription: PodcastSubscription(feedID: feedID, subscribedAt: subscribedAt))
                    try await store.save(feedAutomationPolicy: policies[index], for: feedID)
                }
                for (index, spec) in specs.enumerated() {
                    try await store.save(episode: try PodcastEpisode(
                        itemID: episodeIDs[index], feedID: feedIDs[spec.feed], feedURL: feedURLs[spec.feed],
                        rssGUID: spec.guid, title: "Episode \(spec.guid)",
                        publishedTime: Timestamp(Date(timeIntervalSince1970: 1_704_000_000 + Double(index) * 86_400)),
                        enclosureURL: spec.enclosureURL, enclosureMediaType: "audio/mpeg", createdAt: subscribedAt
                    ))
                    guard spec.kept || spec.skipped else { continue }
                    try await store.save(episodeDecision: .init(
                        episodeID: episodeIDs[index], decision: spec.kept ? .keep : .skip, source: .manual,
                        decidedAt: subscribedAt
                    ))
                }
                let kept = zip(specs, episodeIDs).filter { $0.0.kept }.map(\.1)
                try await store.replacePodcastQueue(try PodcastQueueState(episodeIDs: kept, currentEpisodeID: nil))
                return store
            },
            podcastDownloadTransportFactory: {
                if holdsDownloads { return HeldPodcastDownloadTransport(chunk: 4) }
                return CountingPodcastDownloadTransport(counter: counter, events: [
                    .response(.init(url: feedURLs[0], statusCode: 200, mediaType: "audio/mpeg", expectedByteCount: 4)),
                    .data(Data("body".utf8)),
                ])
            },
            podcastMediaValidatorFactory: { StubPodcastMediaValidator(duration: 12) },
            podcastPipelineRunnerFactory: { runner },
            preferences: WiltedMacTestPreferences.ephemeral()
        )
        addTeardownBlock { await model.close() }
        model.setAutomationSettings(WiltedAutomationSettings(
            refreshPolicy: .manual, downloadPolicy: .manual, processingPolicy: processing,
            transcriptPolicy: .alwaysTranscribe, removeAds: false,
            downloadEverythingOnLarder: downloadEverything, prepareEverythingDownloaded: false
        ))
        model.startStoreBootstrap()
        await model.waitForStoreBootstrap()
        let board = WiltedMacFeedPolicyBoard(model: model)
        await board.reload()
        XCTAssertTrue(board.isLoaded(feedIDs[0].rawValue))
        XCTAssertEqual(Set(model.podcastQueueIDs), Set(zip(specs, episodeIDs).filter { $0.0.kept }.map(\.1.rawValue)))
        return PolicyWorkFixture(
            model: model, board: board, store: try XCTUnwrap(model.store),
            feedA: feedIDs[0].rawValue, feedB: feedIDs[1].rawValue,
            ids: Dictionary(uniqueKeysWithValues: zip(specs.map(\.guid), episodeIDs.map(\.rawValue))),
            transport: counter, runner: runner
        )
    }

    /// An off-peak window that starts two hours from now, so the current time
    /// is outside it whenever the suite runs.
    private func windowExcludingNow() throws -> WiltedAutomationOffPeakWindow {
        let hour = Calendar.current.component(.hour, from: Date())
        let start = try XCTUnwrap(WiltedAutomationLocalTime(hour: (hour + 2) % 24, minute: 0))
        let end = try XCTUnwrap(WiltedAutomationLocalTime(hour: (hour + 3) % 24, minute: 0))
        return try XCTUnwrap(WiltedAutomationOffPeakWindow(start: start, end: end))
    }
}
