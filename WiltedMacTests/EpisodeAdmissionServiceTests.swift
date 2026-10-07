import Foundation
import XCTest
import WiltedDomain
import WiltedProducer
@testable import WiltedMac

/// Drives the real model against a temporary library: refresh, manual Keep and
/// Skip, and the download-completion path. Nothing here reads a real library.
@MainActor
final class EpisodeAdmissionServiceTests: XCTestCase {
    // MARK: Automatic refresh

    func testAutoKeepWithDownloadAndImmediatePreparationIssuesOneOfEachInRequestOrder() async throws {
        let fixture = try await makeFixture(
            policy: FeedAutomationPolicy(autoKeep: .on, autoDownload: .on, autoPrepare: .on),
            feedItems: [.init("c", day: 3), .init("b", day: 2), .init("a", day: 1)]
        )

        let claimed = try await fixture.model.automaticRefresh(fixture.feedURL, claimingNewest: 0)

        let ids = ["a", "b", "c"].map(fixture.id)
        XCTAssertEqual(claimed, ids, "the oldest release is first in line")
        for kind in [WorkTicketKind.podcastDownload, .podcastPreparation] {
            let tickets = try await fixture.tickets(kind).sorted { $0.requestSequence < $1.requestSequence }
            XCTAssertEqual(tickets.map(\.subjectID), ids, "exactly one \(kind) ticket each, in request order")
        }
        let queue = try await fixture.store.podcastQueueState()
        XCTAssertEqual(queue.episodeIDs.map(\.rawValue), ids)
        let decisions = try await fixture.store.decisions(forFeed: fixture.feedID)
        XCTAssertEqual(decisions.count, 3)
        XCTAssertTrue(decisions.allSatisfy { $0.decision == .keep && $0.source == .policy })
    }

    func testAutoKeepWithManualDownloadKeepsButIssuesNoTickets() async throws {
        let fixture = try await makeFixture(
            policy: FeedAutomationPolicy(autoKeep: .on, autoDownload: .off, autoPrepare: .on),
            feedItems: [.init("a", day: 1), .init("b", day: 2)]
        )

        let claimed = try await fixture.model.automaticRefresh(fixture.feedURL, claimingNewest: 0)

        XCTAssertTrue(claimed.isEmpty)
        let tickets = try await fixture.store.workTickets()
        XCTAssertTrue(tickets.isEmpty)
        let queue = try await fixture.store.podcastQueueState()
        XCTAssertEqual(queue.episodeIDs.map(\.rawValue), ["a", "b"].map(fixture.id), "Keep still happened")
    }

    func testDownloadOnWithPrepareOffIssuesNoPreparationTicketEvenAfterDownloadWithPrepareEverythingOn() async throws {
        let fixture = try await makeFixture(
            policy: FeedAutomationPolicy(autoKeep: .on, autoDownload: .on, autoPrepare: .off),
            feedItems: [.init("a", day: 1), .init("b", day: 2)], prepareEverything: true
        )

        let claimed = try await fixture.model.automaticRefresh(fixture.feedURL, claimingNewest: 0)
        let downloads = try await fixture.tickets(.podcastDownload)
        let preparationsAtAdmission = try await fixture.tickets(.podcastPreparation)
        XCTAssertEqual(downloads.count, 2)
        XCTAssertTrue(preparationsAtAdmission.isEmpty)

        for id in claimed { try await fixture.model.startClaimedDownload(id) }
        await fixture.model.waitForPodcastOperations()
        await fixture.model.waitForPodcastPreparationOperationsForTesting()

        XCTAssertEqual(fixture.transport.count, 2, "both downloads really ran")
        XCTAssertTrue(fixture.model.episodes.filter { claimed.contains($0.id) }.allSatisfy { $0.downloadState == .completed })
        let preparationsAfter = try await fixture.tickets(.podcastPreparation)
        XCTAssertTrue(preparationsAfter.isEmpty, "feed Auto prepare Off beats prepare-everything")
        XCTAssertEqual(fixture.runner.count, 0)
    }

    func testPrepareOnControlPreparesAfterDownloadUnderTheSameSetup() async throws {
        let fixture = try await makeFixture(
            policy: FeedAutomationPolicy(autoKeep: .on, autoDownload: .on, autoPrepare: .useGlobal),
            feedItems: [.init("a", day: 1)], prepareEverything: true
        )

        let claimed = try await fixture.model.automaticRefresh(fixture.feedURL, claimingNewest: 0)
        for id in claimed { try await fixture.model.startClaimedDownload(id) }
        await fixture.model.waitForPodcastOperations()
        await fixture.model.waitForPodcastPreparationOperationsForTesting()

        let preparations = try await fixture.tickets(.podcastPreparation)
        XCTAssertEqual(preparations.map(\.subjectID), [fixture.id("a")])
        XCTAssertEqual(fixture.runner.count, 1, "without the Off gate the preparation really starts")
    }

    func testAutoKeepOffManualSkipAndSkipRuleEachProduceNoTickets() async throws {
        let allOn = FeedAutomationPolicy(autoKeep: .on, autoDownload: .on, autoPrepare: .on)
        let off = try await makeFixture(
            policy: FeedAutomationPolicy(autoKeep: .off, autoDownload: .on, autoPrepare: .on),
            feedItems: [.init("a", day: 1)]
        )
        _ = try await off.model.automaticRefresh(off.feedURL, claimingNewest: 0)
        XCTAssertEqual(off.model.episodes.count, 1, "the refresh did admit the episode to the library")
        let offTickets = try await off.store.workTickets()
        let offQueue = try await off.store.podcastQueueState()
        XCTAssertTrue(offTickets.isEmpty)
        XCTAssertTrue(offQueue.episodeIDs.isEmpty)

        let manual = try await makeFixture(
            policy: allOn, feedItems: [.init("skipped", day: 1), .init("fresh", day: 2)],
            seededDecisions: [("skipped", .skip, .manual)]
        )
        let claimed = try await manual.model.automaticRefresh(manual.feedURL, claimingNewest: 0)
        XCTAssertEqual(claimed, [manual.id("fresh")], "the control episode is admitted")
        let manualTickets = try await manual.store.workTickets()
        XCTAssertFalse(manualTickets.contains { $0.subjectID == manual.id("skipped") })
        XCTAssertNotNil(manual.model.episodes.first { $0.id == manual.id("skipped") })

        let rules = try EpisodeMatchRules(rules: [
            .init(field: .title, includePattern: "Sponsored", action: .skip)
        ])
        let ruled = try await makeFixture(
            policy: allOn, rules: rules,
            feedItems: [.init("ad", title: "Sponsored special", day: 1), .init("show", day: 2)]
        )
        let ruledClaims = try await ruled.model.automaticRefresh(ruled.feedURL, claimingNewest: 0)
        XCTAssertEqual(ruledClaims, [ruled.id("show")])
        let ruledTickets = try await ruled.store.workTickets()
        XCTAssertFalse(ruledTickets.contains { $0.subjectID == ruled.id("ad") })
        let adDecision = try await ruled.store.episodeDecision(for: ItemID(rawValue: ruled.id("ad")))
        XCTAssertEqual(adDecision?.decision, .skip)
        XCTAssertEqual(adDecision?.source, .rule)
        let ruledQueue = try await ruled.store.podcastQueueState()
        XCTAssertEqual(ruledQueue.episodeIDs.map(\.rawValue), [ruled.id("show")])
    }

    // MARK: Manual decisions

    func testManualKeepOnDownloadOffFeedIssuesNoDownloadTicketDespiteGlobalDownloadEverything() async throws {
        let fixture = try await makeFixture(
            policy: FeedAutomationPolicy(autoDownload: .off), storedEpisodes: [.init("a", day: 1)],
            downloadEverything: true
        )
        let control = try await makeFixture(
            policy: FeedAutomationPolicy(autoDownload: .useGlobal), storedEpisodes: [.init("a", day: 1)],
            downloadEverything: true
        )

        fixture.model.keepEpisode(try XCTUnwrap(fixture.episode("a")))
        await fixture.drain()
        control.model.keepEpisode(try XCTUnwrap(control.episode("a")))
        await control.drain()

        let tickets = try await fixture.store.workTickets()
        XCTAssertTrue(tickets.isEmpty)
        XCTAssertEqual(fixture.transport.count, 0)
        XCTAssertEqual(fixture.model.podcastQueueIDs, [fixture.id("a")], "the Keep itself committed")
        let decision = try await fixture.store.episodeDecision(for: ItemID(rawValue: fixture.id("a")))
        XCTAssertEqual(decision?.decision, .keep)
        XCTAssertEqual(decision?.source, .manual)

        let controlDownloads = try await control.tickets(.podcastDownload)
        XCTAssertEqual(controlDownloads.map(\.subjectID), [control.id("a")], "Use global still follows the override")
        XCTAssertEqual(control.transport.count, 1)
    }

    func testManualKeepOnDownloadOnFeedDownloadsWithGlobalOverrideOff() async throws {
        let fixture = try await makeFixture(
            policy: FeedAutomationPolicy(autoDownload: .on), storedEpisodes: [.init("a", day: 1)]
        )

        fixture.model.keepEpisode(try XCTUnwrap(fixture.episode("a")))
        await fixture.drain()

        let tickets = try await fixture.tickets(.podcastDownload)
        XCTAssertEqual(tickets.map(\.subjectID), [fixture.id("a")])
        XCTAssertEqual(fixture.transport.count, 1)
    }

    func testManualSkipAndRestoreWriteManualDecisionRecords() async throws {
        let fixture = try await makeFixture(policy: FeedAutomationPolicy(), storedEpisodes: [.init("a", day: 1)])
        let itemID = try ItemID(rawValue: fixture.id("a"))

        fixture.model.skipFeedEpisode(try XCTUnwrap(fixture.episode("a")))
        await fixture.drain()
        let skipped = try await fixture.store.episodeDecision(for: itemID)
        XCTAssertEqual(skipped?.decision, .skip)
        XCTAssertEqual(skipped?.source, .manual)

        fixture.model.restoreSkippedFeedEpisode(try XCTUnwrap(fixture.episode("a")))
        await fixture.drain()
        let restored = try await fixture.store.episodeDecision(for: itemID)
        XCTAssertEqual(restored?.decision, .keep)
        XCTAssertEqual(restored?.source, .manual)
    }

    func testManualPrepareOnAnAutoPrepareOffFeedStillIssuesExactlyOneTicketWhileTheAutomaticPathIssuesNone() async throws {
        let fixture = try await makeFixture(
            policy: FeedAutomationPolicy(autoKeep: .on, autoDownload: .on, autoPrepare: .off),
            feedItems: [.init("a", day: 1)], prepareEverything: true
        )

        let claimed = try await fixture.model.automaticRefresh(fixture.feedURL, claimingNewest: 0)
        for id in claimed { try await fixture.model.startClaimedDownload(id) }
        await fixture.model.waitForPodcastOperations()
        await fixture.model.waitForPodcastPreparationOperationsForTesting()

        XCTAssertEqual(fixture.episode("a")?.downloadState, .completed, "the kept episode is downloaded")
        let automatic = try await fixture.tickets(.podcastPreparation)
        XCTAssertTrue(automatic.isEmpty, "control: the automatic path issues none under feed Auto prepare Off")
        XCTAssertEqual(fixture.runner.count, 0)

        fixture.model.prepareEpisode(try XCTUnwrap(fixture.episode("a")))
        await fixture.model.waitForPodcastPreparationOperationsForTesting()

        let manual = try await fixture.tickets(.podcastPreparation)
        XCTAssertEqual(manual.map(\.subjectID), [fixture.id("a")], "an explicit Prepare issues exactly one ticket")
        XCTAssertEqual(fixture.runner.count, 1, "and the preparation really starts")
    }

    // MARK: Release

    func testRetiringAKeptEpisodeReleasesTheOldestWaitingEpisode() async throws {
        let fixture = try await makeFixture(
            policy: FeedAutomationPolicy(autoKeep: .on, autoDownload: .on, autoPrepare: .off, keptLimit: .explicit(1)),
            storedEpisodes: [.init("a", day: 1), .init("b", day: 2), .init("c", day: 3)],
            keptStored: ["a"]
        )

        fixture.model.skipFeedEpisode(try XCTUnwrap(fixture.episode("a")))
        await fixture.drain()
        XCTAssertEqual(fixture.model.podcastQueueIDs, ["a", "b"].map(fixture.id), "b is the oldest waiting episode")
        let released = try await fixture.store.episodeDecision(for: ItemID(rawValue: fixture.id("b")))
        XCTAssertEqual(released?.source, .policy)
        let waiting = try await fixture.store.episodeDecision(for: ItemID(rawValue: fixture.id("c")))
        XCTAssertNil(waiting, "c still waits")
        let downloads = try await fixture.tickets(.podcastDownload)
        XCTAssertEqual(downloads.map(\.subjectID), [fixture.id("b")])

        fixture.model.skipFeedEpisode(try XCTUnwrap(fixture.episode("b")))
        await fixture.drain()
        XCTAssertEqual(fixture.model.podcastQueueIDs, ["a", "b", "c"].map(fixture.id), "retiring b releases c")
    }

    func testCompletingAKeptEpisodeReleasesTheOldestWaitingEpisode() async throws {
        let fixture = try await makeFixture(
            policy: FeedAutomationPolicy(autoKeep: .on, autoDownload: .on, autoPrepare: .off, keptLimit: .explicit(1)),
            storedEpisodes: [.init("a", day: 1), .init("b", day: 2), .init("c", day: 3)],
            keptStored: ["a"]
        )

        await fixture.model.completeAndRetire(try ItemID(rawValue: fixture.id("a")))
        await fixture.drain()

        XCTAssertEqual(fixture.model.podcastQueueIDs, ["a", "b"].map(fixture.id), "b is the oldest waiting episode")
        let released = try await fixture.store.episodeDecision(for: ItemID(rawValue: fixture.id("b")))
        XCTAssertEqual(released?.source, .policy)
        let waiting = try await fixture.store.episodeDecision(for: ItemID(rawValue: fixture.id("c")))
        XCTAssertNil(waiting, "c still waits")
        let downloads = try await fixture.tickets(.podcastDownload)
        XCTAssertEqual(downloads.map(\.subjectID), [fixture.id("b")])
    }

    func testMarkingAKeptEpisodeCompletedReleasesTheOldestWaitingEpisode() async throws {
        let fixture = try await makeFixture(
            policy: FeedAutomationPolicy(autoKeep: .on, autoDownload: .on, autoPrepare: .off, keptLimit: .explicit(1)),
            storedEpisodes: [.init("a", day: 1), .init("b", day: 2), .init("c", day: 3)],
            keptStored: ["a"]
        )

        fixture.model.skipEpisode(try XCTUnwrap(fixture.episode("a")), requireStarted: false)
        await fixture.drain()

        XCTAssertEqual(fixture.model.podcastQueueIDs.last, fixture.id("b"), "b is the oldest waiting episode")
        let waiting = try await fixture.store.episodeDecision(for: ItemID(rawValue: fixture.id("c")))
        XCTAssertNil(waiting, "c still waits")
    }

    func testRemovingAKeptEpisodeReleasesTheOldestWaitingEpisode() async throws {
        let fixture = try await makeFixture(
            policy: FeedAutomationPolicy(autoKeep: .on, autoDownload: .on, autoPrepare: .off, keptLimit: .explicit(1)),
            storedEpisodes: [.init("a", day: 1), .init("b", day: 2), .init("c", day: 3)],
            keptStored: ["a"]
        )

        fixture.model.removeEpisode(try XCTUnwrap(fixture.episode("a")))
        await fixture.drain()

        XCTAssertEqual(fixture.model.podcastQueueIDs, [fixture.id("b")], "removing a frees the slot for b")
        let waiting = try await fixture.store.episodeDecision(for: ItemID(rawValue: fixture.id("c")))
        XCTAssertNil(waiting, "c still waits")
    }

    func testNoKeptLimitMeansSkipReleasesNothing() async throws {
        let fixture = try await makeFixture(
            policy: FeedAutomationPolicy(autoKeep: .on, autoDownload: .off),
            storedEpisodes: [.init("a", day: 1), .init("b", day: 2)], keptStored: ["a"]
        )

        fixture.model.skipFeedEpisode(try XCTUnwrap(fixture.episode("a")))
        await fixture.drain()

        XCTAssertEqual(fixture.model.podcastQueueIDs, [fixture.id("a")])
    }

    // MARK: Pure planning

    func testPlanKeepsInReleaseOrderAndSkipsManualDecisions() throws {
        let candidates = [candidate("new", 2), candidate("old", 1), candidate("manual", 0)]
        let result = EpisodeAdmissionService.plan(
            candidates: candidates, keptEpisodeIDs: [], manualDecisions: ["manual": .skip], rules: .init(),
            policy: .init(autoKeep: true, autoDownload: true, autoPrepare: true, keptLimit: nil)
        )

        XCTAssertEqual(result.map(\.episodeID), ["old", "new"])
        XCTAssertEqual(result.first?.workTicketKinds, [.podcastDownload, .podcastPreparation])
    }

    func testFeedOffAndGlobalDefaultsResolveIndependently() {
        XCTAssertTrue(EpisodeAdmissionService.suppressesAutomaticPreparation(FeedAutomationPolicy(autoPrepare: .off)))
        XCTAssertFalse(EpisodeAdmissionService.suppressesAutomaticPreparation(FeedAutomationPolicy()))
        XCTAssertFalse(EpisodeAdmissionService.shouldDownloadAfterManualKeep(
            feedPolicy: FeedAutomationPolicy(autoDownload: .off), globalDownloadEverything: true
        ))
        XCTAssertTrue(EpisodeAdmissionService.shouldDownloadAfterManualKeep(
            feedPolicy: FeedAutomationPolicy(autoDownload: .on), globalDownloadEverything: false
        ))
    }

    private func candidate(_ id: String, _ seconds: TimeInterval) -> EpisodeAdmissionService.Candidate {
        .init(id: id, title: "Episode", notes: nil, releasedAt: Date(timeIntervalSince1970: seconds))
    }
}

// MARK: - Fixture

/// A feed with a guid, title and publication day (January 2024).
private struct EpisodeSpec: Sendable {
    let guid: String
    let title: String
    let day: Int
    init(_ guid: String, title: String? = nil, day: Int) {
        (self.guid, self.title, self.day) = (guid, title ?? "Episode \(guid)", day)
    }
    var enclosureURL: URL { URL(string: "https://media.example.test/\(guid).mp3")! }
    func itemID(feedURL: URL) throws -> ItemID {
        try ItemID.derivePodcastEpisode(feedURL: feedURL, rssGUID: guid, enclosureURL: enclosureURL)
    }
    var published: Date { Date(timeIntervalSince1970: 1_704_000_000 + Double(day) * 86_400) }
}

private final class CountingPipelineRunner: PodcastPipelineRunning, @unchecked Sendable {
    private let counter = DownloadAttemptCounter()
    var count: Int { counter.count }
    func run(request: Data, onProgress: @escaping @Sendable (PodcastPreparationProgress) -> Void) async throws -> Data {
        counter.increment()
        throw CancellationError()
    }
}

@MainActor
private struct AdmissionFixture {
    let model: WiltedMacModel
    let store: LocalLibraryStore
    let feedURL: URL
    let feedID: ItemID
    let transport: DownloadAttemptCounter
    let runner: CountingPipelineRunner

    /// The episode ID the library derives for a spec guid.
    func id(_ guid: String) -> String {
        (try? ItemID.derivePodcastEpisode(
            feedURL: feedURL, rssGUID: guid, enclosureURL: EpisodeSpec(guid, day: 1).enclosureURL
        ).rawValue) ?? guid
    }

    func episode(_ guid: String) -> WiltedMacEpisode? { model.episodes.first { $0.id == id(guid) } }

    func tickets(_ kind: WorkTicketKind) async throws -> [WorkTicket] {
        try await store.workTickets().filter { $0.kind == kind }
    }

    func drain() async {
        for writer in Array(model.subscriptionWriteTasks.values) { await writer.value }
        await model.waitForPodcastOperations()
        await model.waitForPodcastPreparationOperationsForTesting()
    }
}

extension EpisodeAdmissionServiceTests {
    fileprivate func makeFixture(
        policy: FeedAutomationPolicy,
        rules: EpisodeMatchRules = .init(),
        storedEpisodes: [EpisodeSpec] = [],
        keptStored: [String] = [],
        feedItems: [EpisodeSpec] = [],
        seededDecisions: [(String, EpisodeDecision, EpisodeDecisionSource)] = [],
        downloadEverything: Bool = false,
        prepareEverything: Bool = false
    ) async throws -> AdmissionFixture {
        let directory = wiltedTemporaryDirectory("episode-admission")
        let feedURL = URL(string: "https://feeds.example.test/admission.xml")!
        let feedID = try ItemID.derivePodcastFeed(from: feedURL)
        let subscribedAt = Timestamp(Date(timeIntervalSince1970: 1_672_531_200))
        let counter = DownloadAttemptCounter()
        let runner = CountingPipelineRunner()
        let itemsXML = feedItems.map { spec in
            """
            <item><guid>\(spec.guid)</guid><title>\(spec.title)</title>
            <pubDate>\(Self.rfc822(spec.published))</pubDate>
            <enclosure url="\(spec.enclosureURL.absoluteString)" type="audio/mpeg" /></item>
            """
        }.joined()
        let xml = "<rss version=\"2.0\"><channel><title>Admission</title>\(itemsXML)</channel></rss>"
        let model = WiltedMacModel(
            arguments: [], stateDirectoryOverride: directory,
            storeBootstrap: { url in
                let store = try LocalLibraryStore(url: url)
                try await store.save(feed: try PodcastFeed(
                    itemID: feedID, canonicalURL: feedURL, title: "Admission", createdAt: subscribedAt
                ))
                try await store.save(subscription: PodcastSubscription(feedID: feedID, subscribedAt: subscribedAt))
                for spec in storedEpisodes {
                    try await store.save(episode: try PodcastEpisode(
                        itemID: try spec.itemID(feedURL: feedURL), feedID: feedID, feedURL: feedURL, rssGUID: spec.guid,
                        title: spec.title, publishedTime: Timestamp(spec.published),
                        enclosureURL: spec.enclosureURL, enclosureMediaType: "audio/mpeg", createdAt: subscribedAt
                    ))
                }
                let kept = try keptStored.map { guid in
                    try storedEpisodes.first { $0.guid == guid }!.itemID(feedURL: feedURL)
                }
                if !kept.isEmpty {
                    try await store.replacePodcastQueue(try PodcastQueueState(episodeIDs: kept, currentEpisodeID: kept.first))
                    for id in kept {
                        try await store.save(episodeDecision: .init(
                            episodeID: id, decision: .keep, source: .manual, decidedAt: subscribedAt
                        ))
                    }
                }
                for (guid, decision, source) in seededDecisions {
                    let spec = (storedEpisodes + feedItems).first { $0.guid == guid } ?? EpisodeSpec(guid, day: 1)
                    try await store.save(episodeDecision: .init(
                        episodeID: try spec.itemID(feedURL: feedURL), decision: decision, source: source, decidedAt: subscribedAt
                    ))
                }
                try await store.save(feedAutomationPolicy: policy, for: feedID)
                try await store.replaceEpisodeMatchRules(rules, for: feedID)
                return store
            },
            podcastDownloadTransportFactory: {
                CountingPodcastDownloadTransport(counter: counter, events: [
                    .response(.init(url: feedURL, statusCode: 200, mediaType: "audio/mpeg", expectedByteCount: 4)),
                    .data(Data("body".utf8))
                ])
            },
            podcastMediaValidatorFactory: { StubPodcastMediaValidator(duration: 12) },
            podcastPipelineRunnerFactory: { runner },
            podcastFeedClient: PodcastFeedClient(loader: FixedBodyLoader(body: Data(xml.utf8))),
            preferences: WiltedMacTestPreferences.ephemeral()
        )
        model.startStoreBootstrap()
        await model.waitForStoreBootstrap()
        model.updateAutomationSettings { settings in
            WiltedAutomationSettings(
                refreshPolicy: settings.refreshPolicy, downloadPolicy: settings.downloadPolicy,
                processingPolicy: .immediate, transcriptPolicy: settings.transcriptPolicy,
                removeAds: settings.removeAds, autoAddPreparedToLarder: settings.autoAddPreparedToLarder,
                downloadEverythingOnLarder: downloadEverything, prepareEverythingDownloaded: prepareEverything
            )
        }
        addTeardownBlock { await model.close() }
        let store = try LocalLibraryStore(url: directory.appendingPathComponent("library.sqlite"))
        return AdmissionFixture(
            model: model, store: store, feedURL: feedURL, feedID: feedID, transport: counter, runner: runner
        )
    }

    private static func rfc822(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss 'GMT'"
        return formatter.string(from: date)
    }
}
