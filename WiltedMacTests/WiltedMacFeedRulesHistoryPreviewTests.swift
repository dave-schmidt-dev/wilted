import CryptoKit
import XCTest
import WiltedDomain
import WiltedProducer
@testable import WiltedMac

/// B7c-2.3: the rules preview covers every stored episode, previews again as
/// the rules are edited, and a rule Skip that Apply writes retires the episode
/// until Undo returns it. The model runs against a temporary library.
@MainActor
final class WiltedMacFeedRulesHistoryPreviewTests: XCTestCase {
    private let feedURL = URL(string: "https://feeds.example.test/fight-companions.xml")!
    private let skipFights = UUID(uuidString: "00000000-0000-0000-0000-0000000000F1")!
    private let keepGuests = UUID(uuidString: "00000000-0000-0000-0000-0000000000F2")!
    /// The rule a `.ruleSkip` seed names, so a rewritten record shows.
    private let staleRule = UUID(uuidString: "00000000-0000-0000-0000-0000000000F9")!
    private let seededAt = Timestamp(Date(timeIntervalSince1970: 1_672_531_200))

    /// Skip fight companions; keep numbered guest episodes.
    private var rules: EpisodeMatchRules {
        EpisodeMatchRules(rules: [
            .init(id: skipFights, field: .title, includePattern: "Fight Companion", action: .skip),
            .init(id: keepGuests, field: .title, includePattern: "^#", action: .keep),
        ])
    }

    /// How an episode starts. A downloaded Keep has a completed download whose
    /// file sits in the library directory. A rule Skip is a live episode
    /// holding a skip record, as a rule wrote before its Skip retired episodes.
    private enum Seed { case undecided, policyKeep, retired, downloadedKeep, ruleSkip }

    private struct Spec {
        let guid: String
        let title: String
        let day: Int
        var seed: Seed = .undecided
        var enclosureURL: URL { URL(string: "https://media.example.test/\(guid).mp3")! }
        var published: Date { Date(timeIntervalSince1970: 1_704_000_000 + Double(day) * 86_400) }
    }

    @MainActor private struct Fixture {
        let model: WiltedMacModel
        let board: WiltedMacFeedPolicyBoard
        let editor: WiltedMacFeedRulesEditor
        let store: LocalLibraryStore
        let ids: [String: ItemID]

        func id(_ guid: String) -> String { ids[guid]!.rawValue }
        func row(_ guid: String) -> FeedRulesPreviewRow? { editor.plan?.rows.first { $0.episodeID == id(guid) } }
        func isRetiredOnScreen(_ guid: String) -> Bool? {
            model.episodes.first { $0.id == id(guid) }.map { $0.removalKind == .retired }
        }

        func previewed() async throws -> FeedRulesPlan {
            editor.preview()
            await editor.task?.value
            return try XCTUnwrap(editor.plan)
        }

        func applied() async {
            editor.apply()
            await editor.task?.value
        }
    }

    // MARK: Every stored episode

    func testARetiredMatchShowsItsVerdictAsHistoryAndIsNeverAdmitted() async throws {
        let fixture = try await makeFixture([
            Spec(guid: "old", title: "Fight Companion - March 1", day: 1, seed: .retired),
            Spec(guid: "guest", title: "#2101 - Guest", day: 2, seed: .retired),
            Spec(guid: "new", title: "Fight Companion - March 8", day: 3),
        ])
        let plan = try await fixture.previewed()

        XCTAssertEqual(fixture.row("old")?.result, .skip(ruleID: skipFights))
        XCTAssertEqual(fixture.row("old")?.ruleNumber, 1)
        XCTAssertEqual(fixture.row("old")?.outcome, .history)
        XCTAssertEqual(fixture.row("guest")?.result, .keep(ruleID: keepGuests))
        XCTAssertEqual(fixture.row("guest")?.outcome, .history, "a Keep rule never brings a retired episode back")
        XCTAssertEqual(plan.admissions.map(\.episodeID), [fixture.id("new")])
        XCTAssertEqual(plan.counts.totalChanges, 1)
    }

    func testNineRetiredAndOneUndecidedPreviewTenRowsNewestFirst() async throws {
        let retired = (1...9).map { day in
            Spec(guid: "r\(day)", title: day.isMultiple(of: 2) ? "Episode \(day)" : "Fight Companion \(day)",
                 day: day, seed: .retired)
        }
        let fixture = try await makeFixture(retired + [Spec(guid: "u", title: "Fight Companion 10", day: 10)])
        let plan = try await fixture.previewed()

        XCTAssertEqual(plan.rows.map(\.episodeID), (["u"] + (1...9).reversed().map { "r\($0)" }).map(fixture.id))
        XCTAssertEqual(plan.rows.filter { $0.outcome == .history }.count, 9)
        XCTAssertEqual(plan.admissions.map(\.episodeID), [fixture.id("u")])
    }

    func testRowsShowAtMostTwentyFiveMatchesAndPadFewerThanTenWithTheNewestNonMatches() async throws {
        let policy = EffectiveFeedAutomationPolicy(autoKeep: true, autoDownload: false, autoPrepare: false, keptLimit: nil)
        func rows(_ titles: [String]) async throws -> [String] {
            let episodes = titles.enumerated().map { day, title in
                FeedRulesEpisode(id: "e\(day)", title: title, notes: "",
                                 releasedAt: Date(timeIntervalSince1970: Double(day) * 86_400), isStarted: false, isHistory: true)
            }
            let input = FeedRulesInput(rules: rules, policy: policy, episodes: episodes, records: [:], keptIDs: [])
            return try await FeedRulesPlan.make(input).rows.map(\.episodeID)
        }
        // Thirty matches, then five newer episodes no rule matches.
        let many = try await rows(Array(repeating: "Fight Companion", count: 30) + Array(repeating: "Episode", count: 5))
        XCTAssertEqual(many, (5..<30).reversed().map { "e\($0)" }, "the newest 25 matches, and no padding")
        // Three matches among fifteen: they show with the seven newest non-matches.
        let few = try await rows((0..<15).map { [2, 6, 13].contains($0) ? "Fight Companion" : "Episode" })
        XCTAssertEqual(few, [14, 13, 12, 11, 10, 9, 8, 7, 6, 2].map { "e\($0)" })
    }

    func testCalculatedSortsRankAllCandidatesBeforeCapAndLeaveRuleResultsAlone() async throws {
        let rules = EpisodeMatchRules(rules: [
            .init(field: .title, includePattern: "Episode", action: .skip)
        ])
        let published = (0..<34).map { Date(timeIntervalSince1970: 1_700_000_000 + Double($0)) }
        let episodes = (0..<35).map { index in
            let title = String(format: "Episode %02d", index)
            let presentation = WiltedMacEpisodePresentation(
                title: title, showTitle: "Order Test",
                publishedAt: index == 34 ? nil : published[index],
                sourceDurationSeconds: Double(10_000 - index * 100), playableDurationSeconds: nil)
            return FeedRulesEpisode(
                id: "sorted-\(index)", title: title, notes: "Episode notes",
                releasedAt: Date(timeIntervalSince1970: Double(index)), presentation: presentation,
                isStarted: false)
        }
        let input = FeedRulesInput(
            rules: rules,
            policy: EffectiveFeedAutomationPolicy(
                autoKeep: true, autoDownload: false, autoPrepare: false, keptLimit: nil),
            episodes: episodes, records: [:], keptIDs: [])
        let plan = try await FeedRulesPlan.make(input)
        let originalAdmissions = plan.admissions
        let originalCounts = plan.counts

        XCTAssertEqual(plan.rows.map(\.id), (10..<35).reversed().map { "sorted-\($0)" })
        XCTAssertEqual(
            plan.presentationRows(sort: .alphabetical, direction: .ascending).map(\.id),
            (0..<25).map { "sorted-\($0)" },
            "Alphabetical selects the first 25 across all matches, including rows beyond the newest cap")
        XCTAssertEqual(
            plan.presentationRows(sort: .length, direction: .ascending).map(\.id),
            (10..<35).reversed().map { "sorted-\($0)" })
        XCTAssertEqual(
            plan.presentationRows(sort: .length, direction: .descending).map(\.id),
            (0..<25).map { "sorted-\($0)" })
        let ageRows = plan.presentationRows(sort: .age, direction: .ascending)
        XCTAssertEqual(ageRows.map(\.id), (9..<34).reversed().map { "sorted-\($0)" })
        XCTAssertFalse(ageRows.contains { $0.id == "sorted-34" },
                       "an unknown publication date stays last even though intake time is newest")
        XCTAssertEqual(plan.presentationRows(sort: .custom, direction: .ascending), plan.rows)

        let metadata = try XCTUnwrap(plan.presentationRows(sort: .alphabetical, direction: .ascending).first)
        XCTAssertEqual(metadata.presentation?.showTitle, "Order Test")
        XCTAssertEqual(metadata.presentation?.sourceDurationSeconds, 10_000)
        XCTAssertEqual(metadata.presentation?.publishedAt, published[0])
        XCTAssertEqual(plan.admissions, originalAdmissions)
        XCTAssertEqual(plan.counts, originalCounts)
        XCTAssertEqual(plan.counts.skips, 35)
    }

    // MARK: Live preview

    func testThreeEditsWithinTheDelayRunOneEvaluationOfTheLastRules() async throws {
        let fixture = try await makeFixture([
            Spec(guid: "fight", title: "Fight Companion - March 1", day: 1),
            Spec(guid: "guest", title: "#2101 - Guest", day: 2),
        ])
        let editor = fixture.editor
        let counter = EvaluationCounter()
        editor.stepHookForTesting = { done in _ = counter.step(done) }

        // Only the last pattern matches, so the verdict shows which rules ran.
        editor.update(skipFights) { $0.include = "Fight Night" }
        try await Task.sleep(for: .milliseconds(30))
        editor.update(skipFights) { $0.include = "Fight Night Live" }
        try await Task.sleep(for: .milliseconds(30))
        editor.update(skipFights) { $0.include = "Fight Companion - March" }
        XCTAssertNil(editor.plan, "nothing is evaluated while editing continues")
        XCTAssertEqual(counter.evaluations, 0)

        await editor.task?.value
        XCTAssertEqual(counter.evaluations, 1)
        XCTAssertEqual(fixture.row("fight")?.result, .skip(ruleID: skipFights))
        XCTAssertFalse(editor.isBusy)
        XCTAssertTrue(editor.canApply, "Apply still waits for a click")
        let decision = try await fixture.store.episodeDecision(for: fixture.ids["fight"]!)
        XCTAssertNil(decision, "a live preview writes nothing")
    }

    func testAnEditWhileAPreviewRunsCancelsItAndPreviewsTheNewRules() async throws {
        let fixture = try await makeFixture([
            Spec(guid: "fight", title: "Fight Companion - March 1", day: 1),
            Spec(guid: "guest", title: "#2101 - Guest", day: 2),
        ])
        let editor = fixture.editor
        let counter = EvaluationCounter()
        editor.stepHookForTesting = { done in
            // The first evaluation stalls on its first episode until it is cancelled.
            guard counter.step(done) == 1, done == 1 else { return }
            try? await Task.sleep(for: .seconds(10))
            counter.noteCancelled(Task.isCancelled)
        }

        editor.preview()
        try await eventually("the first preview is running") { counter.evaluations == 1 }
        XCTAssertFalse(editor.canRun, "an explicit Preview waits for the running one")
        editor.update(skipFights) { $0.include = "Fight Night" }
        XCTAssertFalse(editor.isBusy, "an edit is never blocked by the running preview")

        await editor.task?.value
        try await eventually("the replaced evaluation was cancelled") { counter.cancelled }
        XCTAssertEqual(counter.evaluations, 2)
        XCTAssertNil(editor.message, "a replaced preview says nothing")
        XCTAssertEqual(fixture.row("fight")?.result, .noMatch, "the edited rule no longer matches it")
        XCTAssertEqual(fixture.row("fight")?.outcome, .keep)
        XCTAssertEqual(editor.plan?.admissions.map(\.source), [.policy, .rule])
    }

    // MARK: Apply and Undo

    /// A new fight companion, a kept one, and a kept guest the rules leave alone.
    private var fightsAndAGuest: [Spec] {
        [
            Spec(guid: "kept", title: "Fight Companion - March 1", day: 1, seed: .policyKeep),
            Spec(guid: "new", title: "Fight Companion - March 8", day: 2),
            Spec(guid: "guest", title: "#2101 - Guest", day: 3, seed: .policyKeep),
        ]
    }

    func testApplySkipRetiresTheEpisodeWithTheRuleAsItsSource() async throws {
        let fixture = try await makeFixture(fightsAndAGuest)
        _ = try await fixture.previewed()
        await fixture.applied()

        for guid in ["new", "kept"] {
            let removal = try await fixture.store.removalKind(for: fixture.ids[guid]!)
            let decision = try await fixture.store.episodeDecision(for: fixture.ids[guid]!)
            XCTAssertEqual(removal, .retired, guid)
            XCTAssertEqual(decision?.decision, .skip, guid)
            XCTAssertEqual(decision?.source, .rule, guid)
            XCTAssertEqual(decision?.ruleID, skipFights, guid)
            XCTAssertEqual(fixture.isRetiredOnScreen(guid), true, guid)
        }
        let queue = try await fixture.store.podcastQueueState()
        XCTAssertEqual(queue.episodeIDs.map(\.rawValue), [fixture.id("guest")])
        XCTAssertEqual(fixture.editor.undo?.retired, Set(["new", "kept"].map { fixture.ids[$0]! }))
        XCTAssertEqual(fixture.editor.message, "Applied 2 changes.")

        let again = try await fixture.previewed()
        XCTAssertEqual(fixture.row("new")?.outcome, .history)
        XCTAssertEqual(fixture.row("kept")?.outcome, .history)
        XCTAssertTrue(again.admissions.isEmpty, "a retired episode is never applied twice")
    }

    func testUndoReturnsTheRetiredEpisodesWithTheirPriorDecisions() async throws {
        let fixture = try await makeFixture(fightsAndAGuest)
        let keptBefore = try await fixture.store.episodeDecision(for: fixture.ids["kept"]!)
        let queueBefore = try await fixture.store.podcastQueueState()
        _ = try await fixture.previewed()
        await fixture.applied()

        fixture.editor.undoLastApply()
        await fixture.editor.task?.value

        XCTAssertEqual(fixture.editor.message, "Undone. 2 episodes restored.")
        XCTAssertNil(fixture.editor.undo)
        for guid in ["new", "kept"] {
            let removal = try await fixture.store.removalKind(for: fixture.ids[guid]!)
            XCTAssertNil(removal, guid)
            XCTAssertEqual(fixture.isRetiredOnScreen(guid), false, guid)
        }
        let newDecision = try await fixture.store.episodeDecision(for: fixture.ids["new"]!)
        let keptDecision = try await fixture.store.episodeDecision(for: fixture.ids["kept"]!)
        XCTAssertNil(newDecision, "undecided again")
        XCTAssertEqual(keptDecision, keptBefore, "the policy Keep is back")
        let queue = try await fixture.store.podcastQueueState()
        XCTAssertEqual(queue, queueBefore, "in its old place in the Larder")
    }

    func testWithAutoKeepOffASkipRulePlansItsSkipAndAKeepRuleStaysInactive() async throws {
        let fixture = try await makeFixture([
            Spec(guid: "fight", title: "Fight Companion - March 1", day: 1),
            Spec(guid: "guest", title: "#2101 - Guest", day: 2),
            Spec(guid: "plain", title: "Bonus Episode", day: 3),
        ], policy: FeedAutomationPolicy(autoKeep: .off))
        let plan = try await fixture.previewed()

        XCTAssertEqual(fixture.row("fight")?.outcome, .skip)
        XCTAssertEqual(fixture.row("guest")?.result, .keep(ruleID: keepGuests))
        XCTAssertEqual(fixture.row("guest")?.outcome, .inactive)
        XCTAssertEqual(fixture.row("plain")?.outcome, .inactive)
        XCTAssertEqual(plan.admissions.map(\.episodeID), [fixture.id("fight")])

        await fixture.applied()
        let fight = try await fixture.store.removalKind(for: fixture.ids["fight"]!)
        let guest = try await fixture.store.episodeDecision(for: fixture.ids["guest"]!)
        let plain = try await fixture.store.episodeDecision(for: fixture.ids["plain"]!)
        XCTAssertEqual(fight, .retired)
        XCTAssertNil(guest, "Auto keep On is the only automatic authority to Keep (W-INV-023)")
        XCTAssertNil(plain)
    }

    func testSkippingADownloadedKeptEpisodeIsFlaggedAndDeletesItsAudio() async throws {
        let fixture = try await makeFixture([
            Spec(guid: "downloaded", title: "Fight Companion - March 1", day: 1, seed: .downloadedKeep),
            Spec(guid: "streamed", title: "Fight Companion - March 8", day: 2),
        ])
        let stored = try await fixture.store.download(for: fixture.ids["downloaded"]!)
        let mediaURL = try XCTUnwrap(stored?.localURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: mediaURL.path))
        _ = try await fixture.previewed()

        XCTAssertEqual(fixture.row("downloaded")?.outcome, .keepToSkip)
        XCTAssertEqual(fixture.row("downloaded")?.deletesDownloadedAudio, true)
        XCTAssertEqual(fixture.row("streamed")?.outcome, .skip)
        XCTAssertEqual(fixture.row("streamed")?.deletesDownloadedAudio, false)

        await fixture.applied()
        let download = try await fixture.store.download(for: fixture.ids["downloaded"]!)
        XCTAssertNil(download, "a rule Skip deletes the audio, as a manual Skip does")
        XCTAssertFalse(FileManager.default.fileExists(atPath: mediaURL.path))
    }

    func testApplyConfirmationCountsDownloadedAudioOnMatchesThePreviewDoesNotShow() async throws {
        // Twenty-seven fight companions; the oldest and the newest hold downloaded audio.
        let fixture = try await makeFixture((0...26).map { day in
            Spec(guid: "f\(day)", title: "Fight Companion \(day)", day: day,
                 seed: day == 0 || day == 26 ? .downloadedKeep : .undecided)
        })
        let plan = try await fixture.previewed()

        XCTAssertEqual(plan.rows.count, FeedRulesPlan.shownMatchLimit)
        XCTAssertNil(fixture.row("f0"), "the oldest match is not shown")
        XCTAssertEqual(fixture.row("f26")?.deletesDownloadedAudio, true)
        XCTAssertEqual(plan.rows.filter(\.deletesDownloadedAudio).count, 1, "the row flag marks shown rows only")
        XCTAssertEqual(plan.admissions.count, 27, "Apply commits every match, shown or not")
        XCTAssertEqual(plan.audioDeletions, 2)
        XCTAssertEqual(WiltedMacFeedRulesPreview.audioDeletions(in: plan), 2, "the confirmation counts the unshown one")
    }

    func testApplyRetiresALiveEpisodeHoldingARuleSkipAndUndoReturnsItsPriorRecord() async throws {
        let fixture = try await makeFixture([Spec(guid: "held", title: "Fight Companion - March 1", day: 1, seed: .ruleSkip)])
        let held = fixture.ids["held"]!
        let before = try await fixture.store.episodeDecision(for: held)
        XCTAssertEqual(before?.ruleID, staleRule)
        XCTAssertEqual(fixture.isRetiredOnScreen("held"), false, "a skip record alone left it in the Feed")
        let plan = try await fixture.previewed()

        XCTAssertEqual(fixture.row("held")?.current, .decided(.skip, .rule))
        XCTAssertEqual(fixture.row("held")?.outcome, .skip)
        XCTAssertEqual(plan.admissions.map(\.expected), [before], "Apply replaces that record and only that one")

        await fixture.applied()
        let removal = try await fixture.store.removalKind(for: held)
        let applied = try await fixture.store.episodeDecision(for: held)
        XCTAssertEqual(removal, .retired, "Apply takes it out of the Feed")
        XCTAssertEqual(fixture.isRetiredOnScreen("held"), true)
        XCTAssertEqual(applied?.decision, .skip)
        XCTAssertEqual(applied?.source, .rule)
        XCTAssertEqual(applied?.ruleID, skipFights, "the record names the rule that retired it")

        fixture.editor.undoLastApply()
        await fixture.editor.task?.value
        let restored = try await fixture.store.removalKind(for: held)
        let after = try await fixture.store.episodeDecision(for: held)
        XCTAssertNil(restored)
        XCTAssertEqual(fixture.isRetiredOnScreen("held"), false)
        XCTAssertEqual(after, before, "its prior record is back")
    }

    func testALiveEpisodeHoldingARuleSkipPlansTheSameSkipAsAnUndecidedOne() async throws {
        // A Skip rule acts whatever the feed's Auto keep (W-INV-023).
        for policy in [FeedAutomationPolicy(autoKeep: .on, autoDownload: .off, autoPrepare: .off),
                       FeedAutomationPolicy(autoKeep: .off)] {
            let fixture = try await makeFixture([
                Spec(guid: "held", title: "Fight Companion - March 1", day: 1, seed: .ruleSkip),
                Spec(guid: "fresh", title: "Fight Companion - March 8", day: 2),
            ], policy: policy)
            let held = try await fixture.store.episodeDecision(for: fixture.ids["held"]!)
            XCTAssertNotNil(held)
            let plan = try await fixture.previewed()

            XCTAssertEqual(fixture.row("held")?.outcome, .skip, "\(policy)")
            XCTAssertEqual(fixture.row("fresh")?.outcome, .skip, "\(policy)")
            XCTAssertEqual(plan.counts.skips, 2, "\(policy)")
            XCTAssertEqual(plan.admissions.map(\.episodeID), ["held", "fresh"].map(fixture.id), "\(policy)")
            XCTAssertEqual(plan.admissions.map(\.expected), [held, nil], "\(policy)")
        }
    }

    // MARK: Fixture

    /// Background writes settle shortly after the call.
    private func eventually(_ what: String, line: UInt = #line, _ condition: () async throws -> Bool) async throws {
        for _ in 0..<300 {
            if try await condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail(what, line: line)
    }

    private func makeFixture(
        _ specs: [Spec], policy: FeedAutomationPolicy = FeedAutomationPolicy(autoKeep: .on, autoDownload: .off, autoPrepare: .off)
    ) async throws -> Fixture {
        let directory = wiltedTemporaryDirectory("feed-rules-history")
        let (feedURL, rules, at, staleRule) = (feedURL, rules, seededAt, staleRule)
        let feedID = try ItemID.derivePodcastFeed(from: feedURL)
        let ids = Dictionary(uniqueKeysWithValues: try specs.map { spec in
            (spec.guid, try ItemID.derivePodcastEpisode(feedURL: feedURL, rssGUID: spec.guid, enclosureURL: spec.enclosureURL))
        })
        let model = WiltedMacModel(
            arguments: [], stateDirectoryOverride: directory,
            storeBootstrap: { url in
                let store = try LocalLibraryStore(url: url)
                try await store.save(feed: try PodcastFeed(
                    itemID: feedID, canonicalURL: feedURL, title: "Fight Feed", createdAt: at
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
                    case .retired: _ = try await store.retireEpisode(id, at: at)
                    case .ruleSkip:
                        try await store.save(episodeDecision: .init(
                            episodeID: id, decision: .skip, source: .rule, ruleID: staleRule, decidedAt: at
                        ))
                    case .policyKeep, .downloadedKeep:
                        try await store.save(episodeDecision: .init(episodeID: id, decision: .keep, source: .policy, decidedAt: at))
                        queued.append(id)
                    }
                    guard spec.seed == .downloadedKeep else { continue }
                    // Inside the library directory, where a Skip may delete it.
                    let audio = Data("fight-companion-audio".utf8)
                    let mediaURL = url.deletingLastPathComponent().appendingPathComponent("\(spec.guid).mp3")
                    try audio.write(to: mediaURL)
                    try await store.save(download: PodcastDownload(
                        episodeID: id, status: .completed, bytesReceived: Int64(audio.count),
                        expectedByteCount: Int64(audio.count), localURL: mediaURL,
                        contentHash: "sha256:" + SHA256.hash(data: audio).map { String(format: "%02x", $0) }.joined(),
                        updatedAt: at
                    ))
                }
                if !queued.isEmpty {
                    try await store.replacePodcastQueue(try PodcastQueueState(episodeIDs: queued, currentEpisodeID: nil))
                }
                try await store.save(feedAutomationPolicy: policy, for: feedID)
                try await store.replaceEpisodeMatchRules(rules, for: feedID)
                return store
            },
            preferences: WiltedMacTestPreferences.ephemeral()
        )
        model.startStoreBootstrap()
        await model.waitForStoreBootstrap()
        addTeardownBlock { await model.close() }
        let board = WiltedMacFeedPolicyBoard(model: model)
        await board.reload()
        let editor = board.rulesEditor(for: feedID.rawValue)
        editor.loadIfNeeded()
        return Fixture(model: model, board: board, editor: editor, store: try XCTUnwrap(model.store), ids: ids)
    }
}

/// Counts rules evaluations from off the main actor: each one starts at step 1.
private final class EvaluationCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var started = 0
    private var sawCancellation = false

    /// Records one step and returns how many evaluations have started.
    func step(_ done: Int) -> Int {
        lock.lock(); defer { lock.unlock() }
        if done == 1 { started += 1 }
        return started
    }

    func noteCancelled(_ cancelled: Bool) {
        lock.lock(); defer { lock.unlock() }
        sawCancellation = sawCancellation || cancelled
    }

    var evaluations: Int { lock.lock(); defer { lock.unlock() }; return started }
    var cancelled: Bool { lock.lock(); defer { lock.unlock() }; return sawCancellation }
}
