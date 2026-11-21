import SwiftUI
import XCTest
import WiltedDomain
import WiltedProducer
@testable import WiltedMac

/// Task 4.2: the per-feed rules editor, its preview, and Apply to existing with Undo. The model runs
/// against a temporary library; nothing here reads a real one.
@MainActor
final class WiltedMacFeedRulesTests: XCTestCase {
    let feedURL = URL(string: "https://feeds.example.test/rules.xml")!
    let skipAds = UUID(uuidString: "00000000-0000-0000-0000-0000000000A1")!
    let keepBonus = UUID(uuidString: "00000000-0000-0000-0000-0000000000B2")!
    let decidedAt = Timestamp(Date(timeIntervalSince1970: 1_672_531_200))

    /// How an episode starts, before Apply.
    enum Seed { case undecided, manualKeep, manualSkip, policyKeep, ruleSkip }

    struct Spec {
        let guid: String
        let title: String
        let day: Int
        var seed: Seed = .undecided
        var enclosureURL: URL { URL(string: "https://media.example.test/\(guid).mp3")! }
        var published: Date { Date(timeIntervalSince1970: 1_704_000_000 + Double(day) * 86_400) }
    }

    @MainActor struct Fixture {
        let model: WiltedMacModel
        let board: WiltedMacFeedPolicyBoard
        let editor: WiltedMacFeedRulesEditor
        let store: LocalLibraryStore
        let feedID: ItemID
        let ids: [String: ItemID]
        let directory: URL
        let preferences: UserDefaults
        var feed: String { feedID.rawValue }

        func decisions() async throws -> [String: EpisodeDecisionRecord] {
            Dictionary(uniqueKeysWithValues: try await store.decisions(forFeed: feedID).map { ($0.episodeID.rawValue, $0) })
        }

        func queue() async throws -> PodcastQueueState { try await store.podcastQueueState() }
        func id(_ guid: String) -> String { ids[guid]!.rawValue }
    }

    /// Skip anything starting "Ad"; keep anything starting "Bonus".
    var rules: EpisodeMatchRules {
        EpisodeMatchRules(rules: [
            .init(id: skipAds, field: .title, includePattern: "^Ad", action: .skip),
            .init(id: keepBonus, field: .title, includePattern: "^Bonus", action: .keep),
        ])
    }

    /// Eight episodes covering every way an episode can meet the rules.
    var mixed: [Spec] {
        [
            Spec(guid: "a", title: "Bonus A", day: 1),
            Spec(guid: "b", title: "Ad B", day: 2),
            Spec(guid: "c", title: "Plain C", day: 3),
            Spec(guid: "d", title: "Ad D", day: 4, seed: .policyKeep),
            Spec(guid: "e", title: "Bonus E", day: 5, seed: .ruleSkip),
            Spec(guid: "f", title: "Ad F", day: 6, seed: .manualKeep),
            Spec(guid: "g", title: "Bonus G", day: 7, seed: .manualSkip),
            Spec(guid: "h", title: "Ad H", day: 8, seed: .policyKeep),
        ]
    }

    let autoKeep = FeedAutomationPolicy(autoKeep: .on, autoDownload: .off, autoPrepare: .off)

    // MARK: Done when 1: preview rows are the rule engine's results

    func testPreviewRowsEqualTheRuleEngineResultsAndListChangesSeparately() async throws {
        let fixture = try await makeFixture(mixed)
        fixture.editor.preview()
        await fixture.editor.task?.value
        let plan = try XCTUnwrap(fixture.editor.plan)

        let engine = try rules.preview(fixture.model.episodes.filter { $0.feedID == fixture.feed }.map {
            EpisodeMatchEpisode(id: $0.id, title: $0.title, notes: $0.notes ?? "")
        })
        XCTAssertEqual(Set(plan.rows.map(\.episodeID)), Set(engine.map(\.episodeID)))
        for row in plan.rows {
            XCTAssertEqual(row.result, engine.first { $0.episodeID == row.episodeID }?.result, row.title)
        }
        let byTitle = Dictionary(uniqueKeysWithValues: plan.rows.map { ($0.title, $0) })
        XCTAssertEqual(byTitle["Bonus A"]?.result, .keep(ruleID: keepBonus))
        XCTAssertEqual(byTitle["Bonus A"]?.ruleNumber, 2)
        XCTAssertEqual(byTitle["Ad B"]?.result, .skip(ruleID: skipAds))
        XCTAssertEqual(byTitle["Ad B"]?.ruleNumber, 1)
        XCTAssertEqual(byTitle["Plain C"]?.result, .noMatch)
        XCTAssertNil(byTitle["Plain C"]?.ruleNumber)

        let outcomes = byTitle.mapValues(\.outcome)
        XCTAssertEqual(outcomes, [
            "Bonus A": .keep, "Ad B": .skip, "Plain C": .keep, "Ad D": .keepToSkip, "Bonus E": .skipToKeep,
            "Ad F": .protectedManual, "Bonus G": .protectedManual, "Ad H": .heldStarted,
        ])
        let counts = plan.counts
        XCTAssertEqual(counts.keeps, 2)
        XCTAssertEqual(counts.skips, 1)
        XCTAssertEqual(counts.undecidedChanges, 3)
        XCTAssertEqual(counts.keepToSkip, 1)
        XCTAssertEqual(counts.skipToKeep, 1)
        XCTAssertEqual(counts.automaticChanges, 2)
        XCTAssertEqual(counts.protectedManual, 2)
        XCTAssertEqual(counts.heldStarted, 1)
        XCTAssertEqual(counts.totalChanges, 5)
        let hoisted1 = try await fixture.queue()
        XCTAssertEqual(hoisted1.episodeIDs.count, 3, "a preview writes nothing")
    }

    func testPreviewWithAutoKeepOffPlansSkipRuleSkipsAndLeavesKeepRulesInactive() async throws {
        let fixture = try await makeFixture(mixed, policy: FeedAutomationPolicy(autoKeep: .off))
        fixture.editor.preview()
        await fixture.editor.task?.value
        let outcomes = Dictionary(uniqueKeysWithValues: try XCTUnwrap(fixture.editor.plan).rows.map { ($0.title, $0.outcome) })
        XCTAssertEqual(outcomes, ["Bonus A": .inactive, "Ad B": .skip, "Plain C": .inactive, "Ad D": .keepToSkip, "Bonus E": .inactive,
                                  "Ad F": .protectedManual, "Bonus G": .protectedManual, "Ad H": .heldStarted])
        XCTAssertEqual(fixture.editor.plan?.admissions.map(\.episodeID), ["b", "d"].map(fixture.id), "Skip rules still skip")
        XCTAssertEqual(fixture.editor.plan?.rows.first { $0.title == "Bonus A" }?.result, .keep(ruleID: keepBonus))
        XCTAssertTrue(fixture.editor.canApply)
    }

    // MARK: Fixture

    func makeFixture(
        _ specs: [Spec], rules rulesOverride: EpisodeMatchRules? = nil, policy: FeedAutomationPolicy? = nil
    ) async throws -> Fixture {
        let directory = wiltedTemporaryDirectory("feed-rules")
        let feedURL = self.feedURL
        let feedID = try ItemID.derivePodcastFeed(from: feedURL)
        let at = Timestamp(Date(timeIntervalSince1970: 1_672_531_200))
        let policy = policy ?? autoKeep
        let rules = rulesOverride ?? self.rules
        let preferences = WiltedMacTestPreferences.ephemeral()
        let ids = Dictionary(uniqueKeysWithValues: try specs.map { spec in
            (spec.guid, try ItemID.derivePodcastEpisode(feedURL: feedURL, rssGUID: spec.guid, enclosureURL: spec.enclosureURL))
        })
        let model = WiltedMacModel(
            arguments: [], stateDirectoryOverride: directory,
            storeBootstrap: { url in
                let store = try LocalLibraryStore(url: url)
                try await store.save(feed: try PodcastFeed(
                    itemID: feedID, canonicalURL: feedURL, title: "Rules Feed", createdAt: at
                ))
                try await store.save(subscription: PodcastSubscription(feedID: feedID, subscribedAt: at))
                var queued: [ItemID] = []
                for spec in specs {
                    let id = ids[spec.guid]!
                    try await store.save(episode: try PodcastEpisode(
                        itemID: id, feedID: feedID, feedURL: feedURL, rssGUID: spec.guid, title: spec.title,
                        publishedTime: Timestamp(spec.published), enclosureURL: spec.enclosureURL,
                        enclosureMediaType: "audio/mpeg", createdAt: at
                    ))
                    switch spec.seed {
                    case .undecided: break
                    case .manualKeep, .policyKeep: queued.append(id)
                    case .manualSkip, .ruleSkip: break
                    }
                    let record: (EpisodeDecision, EpisodeDecisionSource, UUID?)? = switch spec.seed {
                    case .undecided: nil
                    case .manualKeep: (.keep, .manual, nil)
                    case .manualSkip: (.skip, .manual, nil)
                    case .policyKeep: (.keep, .policy, nil)
                    case .ruleSkip: (.skip, .rule, UUID(uuidString: "00000000-0000-0000-0000-0000000000A1"))
                    }
                    if let record {
                        try await store.save(episodeDecision: .init(
                            episodeID: id, decision: record.0, source: record.1, ruleID: record.2, decidedAt: at
                        ))
                    }
                }
                if !queued.isEmpty {
                    try await store.replacePodcastQueue(try PodcastQueueState(episodeIDs: queued, currentEpisodeID: nil))
                }
                try await store.save(feedAutomationPolicy: policy, for: feedID)
                try await store.replaceEpisodeMatchRules(rules, for: feedID)
                return store
            },
            preferences: preferences
        )
        model.startStoreBootstrap()
        await model.waitForStoreBootstrap()
        addTeardownBlock { await model.close() }
        // "Ad H" is part-heard: the durable position the model loads for it.
        if let heard = specs.first(where: { $0.guid == "h" }), let index = model.episodes.firstIndex(where: { $0.id == ids[heard.guid]!.rawValue }) {
            model.episodes[index].playbackSeconds = 30
        }
        let board = WiltedMacFeedPolicyBoard(model: model)
        await board.reload()
        let editor = board.rulesEditor(for: feedID.rawValue)
        editor.loadIfNeeded()
        return Fixture(
            model: model, board: board, editor: editor, store: try XCTUnwrap(model.store), feedID: feedID, ids: ids,
            directory: directory, preferences: preferences
        )
    }

    func relaunch(_ fixture: Fixture) async throws -> WiltedMacModel {
        let model = WiltedMacModel(
            arguments: [], stateDirectoryOverride: fixture.directory, preferences: fixture.preferences
        )
        model.startStoreBootstrap()
        await model.waitForStoreBootstrap()
        addTeardownBlock { await model.close() }
        return model
    }

    nonisolated static func isMainThread() -> Bool { Thread.isMainThread }
}

/// Records each evaluation step from off the main actor.
final class StepRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var steps: [(Int, Bool)] = []

    func record(done: Int, onMain: Bool) {
        lock.lock(); defer { lock.unlock() }
        steps.append((done, onMain))
    }

    var done: [Int] { lock.lock(); defer { lock.unlock() }; return steps.map(\.0) }
    var onMain: [Bool] { lock.lock(); defer { lock.unlock() }; return steps.map(\.1) }
}

/// Lets a step hook cancel the task it runs under.
final class TaskBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Task<FeedRulesApplyResult, Error>?

    var task: Task<FeedRulesApplyResult, Error>? {
        get { lock.lock(); defer { lock.unlock() }; return stored }
        set { lock.lock(); defer { lock.unlock() }; stored = newValue }
    }

    func cancel() { task?.cancel() }
}
