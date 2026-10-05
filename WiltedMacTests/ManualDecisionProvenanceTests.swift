import Foundation
import XCTest
import WiltedDomain
import WiltedLibrary
import WiltedProducer
@testable import WiltedMac

/// Every owner decision, on the Mac or the phone, must leave a manual decision
/// record, and the automatic paths must then leave that episode alone.
///
/// Episode titles are chosen so the feed's rules contradict the owner: a
/// "Bonus" episode matches a Keep rule and is the one the owner skips, a
/// "Sponsored" episode matches a Skip rule and is the one the owner keeps or
/// restores. Without a manual record the automatic paths would reverse the
/// owner. Nothing here reads a real library.
///
/// Task 4.2's Apply to existing does not exist yet. Two paths stand in for it:
/// a real automatic refresh through the admission service, and the service's
/// re-evaluation of the feed's undecided episodes (`releaseWaitingEpisodes`,
/// plus the pure planner fed the stored decisions and the feed's rules).
@MainActor
final class ManualDecisionProvenanceTests: XCTestCase {
    // MARK: Mac entry points

    func testKeepEpisodeWritesManualKeep() async throws {
        let rig = try await makeRig(.live, title: Self.sponsored)
        rig.model.keepEpisode(try rig.episode())
        await rig.drain()
        try await assertManual(.keep, rig)
        try await assertAutomationLeavesUnchanged(rig)
    }

    func testSkipFeedEpisodeWritesManualSkip() async throws {
        let rig = try await makeRig(.live, title: Self.bonus)
        rig.model.skipFeedEpisode(try rig.episode())
        await rig.drain()
        try await assertManual(.skip, rig)
        try await assertAutomationLeavesUnchanged(rig)
    }

    func testRestoreSkippedFeedEpisodeWritesManualKeep() async throws {
        let rig = try await makeRig(.retired, title: Self.sponsored)
        try await assertNoRecord(rig)
        rig.model.restoreSkippedFeedEpisode(try rig.episode())
        await rig.drain()
        try await assertManual(.keep, rig)
        try await assertAutomationLeavesUnchanged(rig)
    }

    func testSkipEpisodeWritesManualSkip() async throws {
        let rig = try await makeRig(.kept, title: Self.bonus)
        rig.model.skipEpisode(try rig.episode(), requireStarted: false)
        await rig.drain()
        try await assertManual(.skip, rig)
        try await assertAutomationLeavesUnchanged(rig)
    }

    func testUndoSkipEpisodeWritesManualKeep() async throws {
        let rig = try await makeRig(.completedRetired, title: Self.sponsored)
        try await assertNoRecord(rig)
        rig.model.undoSkipEpisode(try rig.episode())
        await rig.drain()
        try await assertManual(.keep, rig)
        try await assertAutomationLeavesUnchanged(rig)
    }

    func testRestoreEpisodeFromDismissalWritesManualKeep() async throws {
        let rig = try await makeRig(.dismissed, title: Self.sponsored)
        try await assertNoRecord(rig)
        rig.model.restoreEpisode(try rig.dismissal())
        await rig.drain()
        try await assertManual(.keep, rig)
        try await assertAutomationLeavesUnchanged(rig)
    }

    func testStoreLevelRestoreEpisodeWritesManualKeep() async throws {
        let rig = try await makeRig(.dismissed, title: Self.sponsored)
        await rig.model.restoreEpisode(try rig.dismissal(), episodeID: rig.itemID, store: rig.store)
        try await assertManual(.keep, rig)
        try await assertAutomationLeavesUnchanged(rig)
    }

    // MARK: Phone intents

    func testPhoneKeepOfANewEpisodeWritesManualKeep() async throws {
        let rig = try await makeRig(.live, title: Self.sponsored)
        try await rig.phone(.keep(entryID: rig.itemID, deviceID: Self.phone))
        try await assertManual(.keep, rig)
        try await assertAutomationLeavesUnchanged(rig)
    }

    func testPhoneKeepOfAnEpisodeThePolicyKeptConvertsItToManual() async throws {
        let rig = try await makeRig(.policyKept, title: Self.sponsored)
        let before = try await rig.record()
        XCTAssertEqual(before?.source, .policy, "the control: the record starts as the policy's")
        try await rig.phone(.keep(entryID: rig.itemID, deviceID: Self.phone))
        try await assertManual(.keep, rig)
        try await assertAutomationLeavesUnchanged(rig)
    }

    func testPhoneSkipWritesManualSkip() async throws {
        let rig = try await makeRig(.live, title: Self.bonus)
        try await rig.phone(.skip(entryID: rig.itemID, deviceID: Self.phone))
        try await assertManual(.skip, rig)
        try await assertAutomationLeavesUnchanged(rig)
    }

    func testPhoneMarkDoneWritesManualSkip() async throws {
        let rig = try await makeRig(.kept, title: Self.bonus)
        try await rig.phone(.markDone(entryID: rig.itemID, deviceID: Self.phone))
        try await assertManual(.skip, rig)
        try await assertAutomationLeavesUnchanged(rig)
    }

    func testPhoneRestoreOfASkippedEpisodeWritesManualKeep() async throws {
        let rig = try await makeRig(.retired, title: Self.sponsored)
        try await assertNoRecord(rig)
        try await rig.phone(.restore(entryID: rig.itemID, deviceID: Self.phone))
        try await assertManual(.keep, rig)
        try await assertAutomationLeavesUnchanged(rig)
    }

    func testPhoneRestoreOfARemovedEpisodeWritesManualKeep() async throws {
        let rig = try await makeRig(.dismissed, title: Self.sponsored)
        try await assertNoRecord(rig)
        try await rig.phone(.restore(entryID: rig.itemID, deviceID: Self.phone))
        try await assertManual(.keep, rig)
        try await assertAutomationLeavesUnchanged(rig)
    }

    // MARK: Assertions

    private func assertNoRecord(_ rig: Rig, file: StaticString = #filePath, line: UInt = #line) async throws {
        let record = try await rig.record()
        XCTAssertNil(record, "the control: nothing but the entry point may write the record", file: file, line: line)
    }

    private func assertManual(
        _ decision: EpisodeDecision, _ rig: Rig, file: StaticString = #filePath, line: UInt = #line
    ) async throws {
        let record = try await rig.record()
        XCTAssertEqual(record?.decision, decision, file: file, line: line)
        XCTAssertEqual(record?.source, .manual, file: file, line: line)
        XCTAssertNil(record?.ruleID, file: file, line: line)
    }

    /// Stands in for Apply to existing: an automatic refresh and the service's
    /// re-evaluation must leave the episode's record, removal state and Larder
    /// place exactly as the owner left them, while still admitting a fresh one.
    private func assertAutomationLeavesUnchanged(
        _ rig: Rig, file: StaticString = #filePath, line: UInt = #line
    ) async throws {
        let before = try await rig.snapshot()
        let claimed = try await rig.model.automaticRefresh(rig.feedURL, claimingNewest: 0)
        XCTAssertTrue(claimed.isEmpty, "Auto download is off, so no claim", file: file, line: line)
        await rig.model.releaseWaitingEpisodes(feedIDs: [rig.feedID.rawValue])
        await rig.drain()

        let decisions = try await rig.store.decisions(forFeed: rig.feedID)
        let manual = Dictionary(uniqueKeysWithValues: decisions.filter { $0.source == .manual }.map {
            ($0.episodeID.rawValue, $0.decision == .keep ? FeedManualDecision.keep : .skip)
        })
        let target = Self.candidate(title: rig.title, id: rig.itemID.rawValue)
        let planned = EpisodeAdmissionService.plan(
            candidates: [target], keptEpisodeIDs: [], manualDecisions: manual, rules: Self.rules,
            policy: .init(autoKeep: true, autoDownload: false, autoPrepare: false, keptLimit: nil)
        )
        XCTAssertTrue(planned.isEmpty, "the planner and rules must not re-decide a manual one", file: file, line: line)
        // The control: the same planner does reverse an episode with no manual record.
        let uncontrolled = EpisodeAdmissionService.plan(
            candidates: [target], keptEpisodeIDs: [], manualDecisions: [:], rules: Self.rules,
            policy: .init(autoKeep: true, autoDownload: false, autoPrepare: false, keptLimit: nil)
        )
        XCTAssertEqual(uncontrolled.count, 1, "rules do contradict this episode", file: file, line: line)

        let after = try await rig.snapshot()
        XCTAssertEqual(after, before, file: file, line: line)
        let fresh = try await rig.store.episodeDecision(for: rig.freshID)
        XCTAssertEqual(fresh?.source, .policy, "the refresh did run and admit the fresh episode", file: file, line: line)
    }

    private static func candidate(title: String, id: String) -> EpisodeAdmissionService.Candidate {
        .init(id: id, title: title, notes: nil, releasedAt: Date(timeIntervalSince1970: 1_704_086_400))
    }
}

// MARK: - Fixture

private extension ManualDecisionProvenanceTests {
    static let phone = "iphone"
    static let sponsored = "Sponsored special"
    static let bonus = "Bonus episode"
    static let guid = "target"
    static let freshGUID = "fresh"

    /// Where the target episode starts, before the entry point under test.
    enum Seed { case live, kept, policyKept, retired, completedRetired, dismissed }

    /// Skip anything "Sponsored"; keep anything "Bonus".
    static let rules: EpisodeMatchRules = {
        // The patterns are constants that pass validation.
        EpisodeMatchRules(rules: [
            .init(field: .title, includePattern: "Sponsored", action: .skip),
            .init(field: .title, includePattern: "Bonus", action: .keep)
        ])
    }()

    struct Snapshot: Equatable {
        var record: EpisodeDecisionRecord?
        var removal: PodcastEpisodeRemovalKind?
        var queue: [ItemID]
    }

    @MainActor
    struct Rig {
        let model: WiltedMacModel
        let store: LocalLibraryStore
        let feedURL: URL
        let feedID: ItemID
        let itemID: ItemID
        let freshID: ItemID
        let title: String
        let applier: WiltedMacIntentApplier

        func episode() throws -> WiltedMacEpisode {
            try XCTUnwrap(model.episodes.first { $0.id == itemID.rawValue })
        }

        func dismissal() throws -> WiltedMacDismissedEpisode {
            try XCTUnwrap(model.dismissedEpisodes.first { $0.id == itemID.rawValue })
        }

        func record() async throws -> EpisodeDecisionRecord? { try await store.episodeDecision(for: itemID) }

        func snapshot() async throws -> Snapshot {
            Snapshot(
                record: try await record(), removal: try await store.removalKind(for: itemID),
                queue: try await store.podcastQueueState().episodeIDs.filter { $0 == itemID }
            )
        }

        func drain() async {
            for writer in Array(model.subscriptionWriteTasks.values) { await writer.value }
            await model.waitForPodcastOperations()
            await model.waitForPodcastPreparationOperationsForTesting()
        }

        /// Applies one phone intent through the real applier and the real model.
        func phone(_ intent: @autoclosure () throws -> LibraryIntent) async throws {
            try await applier.apply(try intent())
            await drain()
        }
    }

    func makeRig(_ seed: Seed, title: String) async throws -> Rig {
        let feedURL = URL(string: "https://feeds.example.test/provenance.xml")!
        let feedID = try ItemID.derivePodcastFeed(from: feedURL)
        let itemID = try ItemID.derivePodcastEpisode(
            feedURL: feedURL, rssGUID: Self.guid, enclosureURL: Self.enclosure(Self.guid)
        )
        let freshID = try ItemID.derivePodcastEpisode(
            feedURL: feedURL, rssGUID: Self.freshGUID, enclosureURL: Self.enclosure(Self.freshGUID)
        )
        let at = Timestamp(Date(timeIntervalSince1970: 1_704_000_000))
        let item: (String, String, Int) -> String = { guid, title, day in
            """
            <item><guid>\(guid)</guid><title>\(title)</title>
            <pubDate>\(Self.rfc822(Date(timeIntervalSince1970: 1_704_000_000 + Double(day) * 86_400)))</pubDate>
            <enclosure url="\(Self.enclosure(guid).absoluteString)" type="audio/mpeg" /></item>
            """
        }
        let xml = "<rss version=\"2.0\"><channel><title>Provenance</title>"
            + item(Self.guid, title, 1) + item(Self.freshGUID, "Neutral fresh", 2) + "</channel></rss>"
        let model = WiltedMacModel(
            arguments: [], stateDirectoryOverride: wiltedTemporaryDirectory("manual-provenance"),
            storeBootstrap: { url in
                let store = try LocalLibraryStore(url: url)
                try await store.save(feed: try PodcastFeed(
                    itemID: feedID, canonicalURL: feedURL, title: "Provenance", createdAt: at
                ))
                try await store.save(subscription: PodcastSubscription(feedID: feedID, subscribedAt: at))
                try await store.save(episode: try PodcastEpisode(
                    itemID: itemID, feedID: feedID, feedURL: feedURL, rssGUID: Self.guid, title: title,
                    publishedTime: Timestamp(Date(timeIntervalSince1970: 1_704_086_400)),
                    enclosureURL: Self.enclosure(Self.guid), enclosureMediaType: "audio/mpeg", createdAt: at
                ))
                switch seed {
                case .live: break
                case .kept, .policyKept:
                    try await store.replacePodcastQueue(try PodcastQueueState(episodeIDs: [itemID], currentEpisodeID: nil))
                    if seed == .policyKept {
                        try await store.save(episodeDecision: .init(
                            episodeID: itemID, decision: .keep, source: .policy, decidedAt: at
                        ))
                    }
                case .retired: _ = try await store.retireEpisodes([itemID], at: at)
                case .completedRetired:
                    _ = try await store.completeAndRetireEpisode(listening: PodcastListeningState(
                        episodeID: itemID, completedAt: at, lastRevisionID: nil, updatedAt: at
                    ))
                case .dismissed: try await store.dismissPodcastEpisode(itemID)
                }
                try await store.save(feedAutomationPolicy: FeedAutomationPolicy(
                    autoKeep: .on, autoDownload: .off, autoPrepare: .off, keptLimit: .explicit(5)
                ), for: feedID)
                try await store.replaceEpisodeMatchRules(Self.rules, for: feedID)
                return store
            },
            podcastFeedClient: PodcastFeedClient(loader: FixedBodyLoader(body: Data(xml.utf8))),
            preferences: WiltedMacTestPreferences.ephemeral()
        )
        model.startStoreBootstrap()
        await model.waitForStoreBootstrap()
        addTeardownBlock { await MainActor.run { model.stopLibrarySync() }; await model.close() }
        let applier = WiltedMacIntentApplier(
            host: model, ledger: WiltedMacIntentLedger(fileURL: nil), book: WiltedMacIntentOutcomeBook(fileURL: nil),
            transport: InMemoryLibraryTransport(
                deviceID: "mac-test", server: InMemoryLibraryServer(writerDeviceID: "mac-test")
            )
        )
        return Rig(
            model: model, store: try XCTUnwrap(model.store), feedURL: feedURL, feedID: feedID, itemID: itemID,
            freshID: freshID, title: title, applier: applier
        )
    }

    static func enclosure(_ guid: String) -> URL { URL(string: "https://media.example.test/\(guid).mp3")! }

    static func rfc822(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss 'GMT'"
        return formatter.string(from: date)
    }
}
