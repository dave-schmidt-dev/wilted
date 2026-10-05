import SwiftUI
import XCTest
import WiltedDomain
import WiltedProducer
@testable import WiltedMac

/// Task 4.2: the per-feed rules editor, its preview, and Apply to existing with Undo. The model runs
/// against a temporary library; nothing here reads a real one.
@MainActor
final class WiltedMacFeedRulesTests: XCTestCase {
    private let feedURL = URL(string: "https://feeds.example.test/rules.xml")!
    private let skipAds = UUID(uuidString: "00000000-0000-0000-0000-0000000000A1")!
    private let keepBonus = UUID(uuidString: "00000000-0000-0000-0000-0000000000B2")!
    private let decidedAt = Timestamp(Date(timeIntervalSince1970: 1_672_531_200))

    /// How an episode starts, before Apply.
    private enum Seed { case undecided, manualKeep, manualSkip, policyKeep, ruleSkip }

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
    private var rules: EpisodeMatchRules {
        EpisodeMatchRules(rules: [
            .init(id: skipAds, field: .title, includePattern: "^Ad", action: .skip),
            .init(id: keepBonus, field: .title, includePattern: "^Bonus", action: .keep),
        ])
    }

    /// Eight episodes covering every way an episode can meet the rules.
    private var mixed: [Spec] {
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

    private let autoKeep = FeedAutomationPolicy(autoKeep: .on, autoDownload: .off, autoPrepare: .off)

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

    func testPreviewWithAutoKeepOffStillShowsVerdictsButChangesNothing() async throws {
        let fixture = try await makeFixture(mixed, policy: FeedAutomationPolicy(autoKeep: .off))
        fixture.editor.preview()
        await fixture.editor.task?.value
        let plan = try XCTUnwrap(fixture.editor.plan)
        XCTAssertEqual(plan.counts.totalChanges, 0)
        XCTAssertTrue(plan.admissions.isEmpty)
        XCTAssertEqual(plan.rows.first { $0.title == "Bonus A" }?.outcome, .inactive)
        XCTAssertEqual(plan.rows.first { $0.title == "Bonus A" }?.result, .keep(ruleID: keepBonus))
        XCTAssertFalse(fixture.editor.canApply)
    }

    // MARK: Done when 2: Apply, then Undo

    func testApplyChangesUndecidedAndAutomaticEpisodesAndLeavesManualAndStartedAlone() async throws {
        let fixture = try await makeFixture(mixed)
        let before = try await fixture.decisions()
        let queueBefore = try await fixture.queue()
        let ticketsBefore = try await fixture.store.workTickets()
        XCTAssertEqual(queueBefore.episodeIDs.map(\.rawValue), [fixture.id("d"), fixture.id("f"), fixture.id("h")])

        fixture.editor.preview()
        await fixture.editor.task?.value
        XCTAssertTrue(fixture.editor.canApply)
        fixture.editor.apply()
        await fixture.editor.task?.value
        XCTAssertNotNil(fixture.editor.undo)

        let after = try await fixture.decisions()
        func check(_ guid: String, _ decision: EpisodeDecision, _ source: EpisodeDecisionSource, _ rule: UUID?,
                   line: UInt = #line) {
            XCTAssertEqual(after[fixture.id(guid)]?.decision, decision, guid, line: line)
            XCTAssertEqual(after[fixture.id(guid)]?.source, source, guid, line: line)
            XCTAssertEqual(after[fixture.id(guid)]?.ruleID, rule, guid, line: line)
        }
        check("a", .keep, .rule, keepBonus)
        check("b", .skip, .rule, skipAds)
        check("c", .keep, .policy, nil)
        check("d", .skip, .rule, skipAds)
        check("e", .keep, .rule, keepBonus)
        for untouched in ["f", "g", "h"] {
            XCTAssertEqual(after[fixture.id(untouched)], before[fixture.id(untouched)], "\(untouched) is unchanged")
        }
        // d left the Larder; f and h stayed where they were; the new keeps follow in release order.
        let queueAfter = try await fixture.queue().episodeIDs.map(\.rawValue)
        XCTAssertEqual(queueAfter, ["f", "h", "a", "c", "e"].map(fixture.id))
        XCTAssertEqual(fixture.model.podcastQueueIDs, queueAfter)
        let ticketsAfter = try await fixture.store.workTickets()
        let added = ticketsAfter.filter { ticket in !ticketsBefore.contains { $0.kind == ticket.kind && $0.subjectID == ticket.subjectID } }
        XCTAssertEqual(
            added.map { "\($0.kind.rawValue) \($0.subjectID) \($0.state.rawValue)" },
            ["podcastPreparation \(fixture.id("d")) cancelled"],
            "Apply starts no download or preparation; skipping the kept Ad D only withdraws its place in the line"
        )
    }

    // MARK: Apply's Keeps are automatic Keeps (4.2b)

    private var downloadAndPrepare: FeedAutomationPolicy {
        FeedAutomationPolicy(autoKeep: .on, autoDownload: .on, autoPrepare: .on)
    }

    /// No transfer can start, so every download an Apply issues stays not yet started.
    private func applyRules(_ fixture: Fixture) async {
        fixture.model.podcastDownloadCoordinator = nil
        fixture.editor.preview()
        await fixture.editor.task?.value
        fixture.editor.apply()
        await fixture.editor.task?.value
    }

    private func tickets(_ fixture: Fixture, _ kind: WorkTicketKind) async throws -> [WorkTicket] {
        try await fixture.store.workTickets().filter { $0.kind == kind }.sorted { $0.subjectID < $1.subjectID }
    }

    /// Ticket writes the model makes in the background settle shortly after the call.
    private func eventually(_ what: String, line: UInt = #line, _ condition: () async throws -> Bool) async throws {
        for _ in 0..<300 {
            if try await condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail(what, line: line)
    }

    func testApplyKeepsIssueOneDownloadAndOnePreparationEachWhenTheFeedPolicyCallsForThemAndNoneWhenOff() async throws {
        let on = try await makeFixture(mixed, policy: downloadAndPrepare)
        await applyRules(on)
        let newlyKept = ["a", "c", "e"].map(on.id).sorted()
        let downloads = try await tickets(on, .podcastDownload)
        XCTAssertEqual(downloads.map(\.subjectID), newlyKept, "one download ticket per newly kept episode")
        XCTAssertTrue(downloads.allSatisfy { $0.state == .pending })
        let preparations = try await tickets(on, .podcastPreparation).filter { $0.state == .pending }
        XCTAssertEqual(preparations.map(\.subjectID), newlyKept, "one preparation ticket per newly kept episode")
        let claimed = try await on.store.downloads()
        XCTAssertEqual(claimed.map(\.episodeID.rawValue).sorted(), newlyKept, "the store claim 3.1 takes")
        for ticket in preparations {
            XCTAssertEqual(on.model.preparationRequestSequences[ticket.subjectID], ticket.requestSequence, "adopted, as 3.1 does")
        }

        let off = try await makeFixture(mixed, policy: FeedAutomationPolicy(autoKeep: .on, autoDownload: .off, autoPrepare: .on))
        await applyRules(off)
        let offDownloads = try await tickets(off, .podcastDownload)
        let offPreparations = try await tickets(off, .podcastPreparation).filter { $0.state == .pending }
        let offClaims = try await off.store.downloads()
        XCTAssertTrue(offDownloads.isEmpty)
        XCTAssertTrue(offPreparations.isEmpty)
        XCTAssertTrue(offClaims.isEmpty)
        let offQueue = try await off.queue().episodeIDs.map(\.rawValue)
        XCTAssertEqual(offQueue, ["f", "h", "a", "c", "e"].map(off.id), "the Keeps still happened")
    }

    func testUndoWithdrawsTheNotYetStartedTicketsAndLeavesAStartedDownloadAlone() async throws {
        let fixture = try await makeFixture(mixed, policy: downloadAndPrepare)
        await applyRules(fixture)
        // Episode c's transfer has begun; a and e are still waiting.
        await fixture.model.recordWorkTicketTransition(kind: .podcastDownload, subjectID: fixture.id("c"), state: .running)

        fixture.editor.undoLastApply()
        await fixture.editor.task?.value

        let downloads = try await tickets(fixture, .podcastDownload)
        XCTAssertEqual(downloads.map { "\($0.subjectID) \($0.state.rawValue)" }.sorted(),
                       [("a", "cancelled"), ("c", "running"), ("e", "cancelled")].map { "\(fixture.id($0.0)) \($0.1)" }.sorted())
        try await eventually("the preparation requests are withdrawn") {
            let open = try await self.tickets(fixture, .podcastPreparation).filter { !$0.state.isTerminal }
            return open.isEmpty
        }
        for guid in ["a", "c", "e"] {
            XCTAssertNil(fixture.model.preparationRequestSequences[fixture.id(guid)], guid)
        }
        let claims = try await fixture.store.downloads()
        XCTAssertEqual(claims.first { $0.episodeID == fixture.ids["a"] }?.status, .cancelled, "the waiting claim is released")
    }

    func testUndoOfAnApplySkipRequestsThePreparationApplyWithdrew() async throws {
        let fixture = try await makeFixture(mixed, policy: downloadAndPrepare)
        let d = fixture.id("d")
        fixture.model.registerPreparationRequest(for: d)
        try await eventually("d holds a pending preparation ticket") {
            try await self.tickets(fixture, .podcastPreparation).contains { $0.subjectID == d && $0.state == .pending }
        }
        let before = try XCTUnwrap(fixture.model.preparationRequestSequences[d])
        await applyRules(fixture)
        try await eventually("Apply withdrew d's request") {
            try await self.tickets(fixture, .podcastPreparation).contains { $0.subjectID == d && $0.state == .cancelled }
        }
        XCTAssertNil(fixture.model.preparationRequestSequences[d])

        fixture.editor.undoLastApply()
        await fixture.editor.task?.value

        try await eventually("Undo asked for d's preparation again") {
            try await self.tickets(fixture, .podcastPreparation).contains { $0.subjectID == d && $0.state == .pending }
        }
        let again = try XCTUnwrap(fixture.model.preparationRequestSequences[d])
        XCTAssertGreaterThan(again, before)
        let record = try await fixture.decisions()[d]
        XCTAssertEqual(record?.decision, .keep)
        let bTickets = try await tickets(fixture, .podcastPreparation).filter { $0.subjectID == fixture.id("b") }
        XCTAssertTrue(bTickets.isEmpty, "an episode that held no request is not given one")
    }

    func testAnAutomaticKeepThatIsPlayingIsNeverSkipped() async throws {
        let fixture = try await makeFixture(mixed)
        fixture.model.currentPodcastEpisodeID = fixture.id("d")
        fixture.editor.preview()
        await fixture.editor.task?.value
        XCTAssertEqual(fixture.editor.plan?.rows.first { $0.title == "Ad D" }?.outcome, .heldStarted)
        fixture.editor.apply()
        await fixture.editor.task?.value
        let record = try await fixture.decisions()[fixture.id("d")]
        XCTAssertEqual(record?.decision, .keep)
        XCTAssertEqual(record?.source, .policy)
        let hoisted3 = try await fixture.queue()
        XCTAssertTrue(hoisted3.episodeIDs.contains(fixture.ids["d"]!))
    }

    func testUndoRestoresTheDecisionRecordsAndTheQueueExactly() async throws {
        let fixture = try await makeFixture(mixed)
        let decisionsBefore = try await fixture.decisions()
        let queueBefore = try await fixture.queue()

        fixture.editor.preview()
        await fixture.editor.task?.value
        fixture.editor.apply()
        await fixture.editor.task?.value
        let applied = try await fixture.decisions()
        XCTAssertNotEqual(applied, decisionsBefore, "the control: Apply did change the records")
        let hoisted4 = try await fixture.queue()
        XCTAssertNotEqual(hoisted4, queueBefore)

        fixture.editor.undoLastApply()
        await fixture.editor.task?.value

        let hoisted5 = try await fixture.decisions()
        XCTAssertEqual(hoisted5, decisionsBefore)
        let hoisted6 = try await fixture.queue()
        XCTAssertEqual(hoisted6, queueBefore, "ids, order and the current episode")
        for guid in ["a", "b", "c"] {
            let record = try await fixture.store.episodeDecision(for: fixture.ids[guid]!)
            XCTAssertNil(record, "\(guid) was undecided and is undecided again")
        }
        XCTAssertEqual(fixture.model.podcastQueueIDs, queueBefore.episodeIDs.map(\.rawValue))
        XCTAssertNil(fixture.editor.undo)
    }

    func testUndoLeavesAnEpisodeTheListenerDecidedAboutSinceApply() async throws {
        let fixture = try await makeFixture(mixed)
        fixture.editor.preview()
        await fixture.editor.task?.value
        fixture.editor.apply()
        await fixture.editor.task?.value
        let manual = EpisodeDecisionRecord(
            episodeID: fixture.ids["b"]!, decision: .keep, source: .manual, decidedAt: Timestamp(Date())
        )
        try await fixture.store.save(episodeDecision: manual)

        fixture.editor.undoLastApply()
        await fixture.editor.task?.value

        let after = try await fixture.decisions()
        XCTAssertEqual(after[fixture.id("b")], manual, "the listener's choice outlives Undo")
        XCTAssertNil(after[fixture.id("a")], "the rest is restored")
    }

    func testApplyRespectsTheKeptLimit() async throws {
        let specs = [
            Spec(guid: "k", title: "Kept K", day: 0, seed: .manualKeep),
            Spec(guid: "x1", title: "Plain 1", day: 1), Spec(guid: "x2", title: "Plain 2", day: 2),
            Spec(guid: "x3", title: "Plain 3", day: 3), Spec(guid: "x4", title: "Plain 4", day: 4),
        ]
        let fixture = try await makeFixture(
            specs, rules: EpisodeMatchRules(),
            policy: FeedAutomationPolicy(autoKeep: .on, autoDownload: .off, autoPrepare: .off, keptLimit: .explicit(3))
        )
        fixture.editor.preview()
        await fixture.editor.task?.value
        XCTAssertEqual(fixture.editor.plan?.counts.keeps, 2)
        XCTAssertEqual(fixture.editor.plan?.counts.waiting, 2)
        fixture.editor.apply()
        await fixture.editor.task?.value

        let hoisted7 = try await fixture.queue()
        XCTAssertEqual(hoisted7.episodeIDs.map(\.rawValue), ["k", "x1", "x2"].map(fixture.id))
        for waiting in ["x3", "x4"] {
            let record = try await fixture.store.episodeDecision(for: fixture.ids[waiting]!)
            XCTAssertNil(record, "\(waiting) waits for a place; the limit never removes")
        }
    }

    func testADecisionMadeWhileApplyIsEvaluatingIsNotOverwritten() async throws {
        let fixture = try await makeFixture(mixed)
        let store = fixture.store
        let target = try XCTUnwrap(fixture.ids["b"])
        let manual = EpisodeDecisionRecord(episodeID: target, decision: .keep, source: .manual, decidedAt: Timestamp(Date()))
        fixture.editor.stepHookForTesting = { done in
            if done == 8 { try? await store.save(episodeDecision: manual) }
        }
        fixture.editor.preview()
        await fixture.editor.task?.value
        fixture.editor.apply()
        await fixture.editor.task?.value
        let record = try await fixture.store.episodeDecision(for: target)
        XCTAssertEqual(record, manual, "Ad B would have been skipped by a rule, but the listener kept it")
    }

    // MARK: Off the main actor, counted progress, cancellation

    func testEvaluationRunsOffTheMainActorWithCountedProgress() async throws {
        let fixture = try await makeFixture(mixed)
        let recorder = StepRecorder()
        var reported: [[Int]] = []
        let plan = try await fixture.model.previewFeedRules(
            feedID: fixture.feed, rules: rules,
            progress: { done, total in reported.append([done, total]) },
            stepHook: { done in recorder.record(done: done, onMain: Self.isMainThread()) }
        )
        XCTAssertEqual(plan.rows.count, 8)
        XCTAssertEqual(reported, (1...8).map { [$0, 8] }, "one count per episode, against a fixed total")
        XCTAssertEqual(recorder.done, Array(1...8))
        XCTAssertEqual(recorder.onMain, Array(repeating: false, count: 8), "no step ran on the main thread")
    }

    func testCancellingAPreviewLeavesEverythingUnchanged() async throws {
        let fixture = try await makeFixture(mixed)
        let (decisions, queue) = (try await fixture.decisions(), try await fixture.queue())
        let editor = fixture.editor
        editor.stepHookForTesting = { done in
            if done == 3 { await MainActor.run { editor.cancel() } }
        }
        editor.preview()
        XCTAssertTrue(editor.isBusy)
        await editor.task?.value

        XCTAssertNil(editor.plan, "a cancelled evaluation yields no preview")
        XCTAssertFalse(editor.isBusy)
        XCTAssertNil(editor.progress)
        XCTAssertEqual(editor.message, "Cancelled. Nothing was changed.")
        let hoisted8 = try await fixture.decisions()
        XCTAssertEqual(hoisted8, decisions)
        let hoisted9 = try await fixture.queue()
        XCTAssertEqual(hoisted9, queue)
    }

    func testCancellingAnApplyDuringEvaluationWritesNothing() async throws {
        let fixture = try await makeFixture(mixed)
        let (decisions, queue) = (try await fixture.decisions(), try await fixture.queue())
        let box = TaskBox()
        let task = Task { [model = fixture.model, feed = fixture.feed, rules] in
            try await model.applyFeedRules(
                feedID: feed, rules: rules, progress: { _, _ in },
                stepHook: { done in if done == 4 { box.cancel() } }
            )
        }
        box.task = task
        let result = await task.result
        XCTAssertThrowsError(try result.get()) { XCTAssertTrue($0 is CancellationError, "\($0)") }

        let hoisted10 = try await fixture.decisions()
        XCTAssertEqual(hoisted10, decisions)
        let hoisted11 = try await fixture.queue()
        XCTAssertEqual(hoisted11, queue)
        XCTAssertEqual(fixture.model.podcastQueueIDs, queue.episodeIDs.map(\.rawValue))
    }

    // MARK: Editing and validation

    func testAddReorderEnableAndDeleteRulesSurviveARelaunch() async throws {
        let fixture = try await makeFixture([Spec(guid: "a", title: "Bonus A", day: 1)], rules: EpisodeMatchRules())
        let editor = fixture.editor
        let first = editor.addRule()
        editor.update(first) { $0.include = "alpha"; $0.action = .skip; $0.field = .notes }
        let second = editor.addRule()
        editor.update(second) { $0.include = "beta"; $0.exclude = "beta two" }
        let third = editor.addRule()
        editor.update(third) { $0.include = "gamma" }
        editor.move(third, by: -2)
        editor.update(second) { $0.isEnabled = false }
        editor.delete(first)
        await fixture.board.settle()

        let saved = try await fixture.store.episodeMatchRules(for: fixture.feedID)
        XCTAssertEqual(saved.rules.map(\.includePattern), ["gamma", "beta"])
        XCTAssertEqual(saved.rules.map(\.isEnabled), [true, false])
        XCTAssertEqual(saved.rules.map(\.excludePattern), [nil, "beta two"], "a blank exception is stored as none")
        XCTAssertEqual(saved.rules.map(\.id), [third, second])

        await fixture.model.close()
        let relaunched = try await relaunch(fixture)
        let board = WiltedMacFeedPolicyBoard(model: relaunched)
        await board.reload()
        let reloaded = board.rulesEditor(for: fixture.feed)
        reloaded.loadIfNeeded()
        XCTAssertEqual(reloaded.drafts.map(\.include), ["gamma", "beta"])
        XCTAssertEqual(reloaded.drafts.map(\.isEnabled), [true, false])
        XCTAssertEqual(reloaded.ruleCount, 2)
    }

    func testInvalidRulesShowInlineErrorsKeepTheirTextAndAreNotSaved() async throws {
        let fixture = try await makeFixture([Spec(guid: "a", title: "Bonus A", day: 1)], rules: rules)
        let editor = fixture.editor
        let id = editor.addRule()
        let empty = try XCTUnwrap(editor.drafts.last)
        XCTAssertNotNil(editor.problems(for: empty).include, "an empty pattern would match everything")

        editor.update(id) { $0.include = "(" }
        var draft = try XCTUnwrap(editor.drafts.last)
        XCTAssertEqual(draft.include, "(", "the text stays on screen")
        XCTAssertEqual(editor.problems(for: draft).include, "This is not a valid pattern. Check brackets and escapes.")
        XCTAssertNil(editor.problems(for: draft).exclude)
        XCTAssertTrue(editor.hasProblems)
        XCTAssertFalse(editor.canRun)
        XCTAssertFalse(editor.canApply)
        editor.preview()
        XCTAssertNil(editor.task, "a preview is refused while a rule has an error")

        editor.update(id) { $0.include = "fine"; $0.exclude = "[" }
        draft = try XCTUnwrap(editor.drafts.last)
        XCTAssertNil(editor.problems(for: draft).include)
        XCTAssertNotNil(editor.problems(for: draft).exclude)
        editor.update(id) { $0.include = String(repeating: "a", count: EpisodeMatchRules.maximumPatternLength + 1); $0.exclude = "" }
        draft = try XCTUnwrap(editor.drafts.last)
        XCTAssertEqual(editor.problems(for: draft).include, "Use at most \(EpisodeMatchRules.maximumPatternLength) characters.")

        await fixture.board.settle()
        let stored = try await fixture.store.episodeMatchRules(for: fixture.feedID)
        XCTAssertEqual(stored, rules, "nothing invalid reached the store")

        editor.update(id) { $0.include = "fixed" }
        XCTAssertFalse(editor.hasProblems)
        await fixture.board.settle()
        let fixed = try await fixture.store.episodeMatchRules(for: fixture.feedID)
        XCTAssertEqual(fixed.rules.map(\.includePattern), ["^Ad", "^Bonus", "fixed"])
    }

    // MARK: Hosted views, accessibility, narrow and wide

    func testRulesPageShowsEditorErrorsPreviewAndSeparateCountsAtNarrowAndWideWidths() async throws {
        let fixture = try await makeFixture(mixed)
        fixture.editor.loadIfNeeded()
        fixture.editor.preview()
        await fixture.editor.task?.value
        let subscription = try XCTUnwrap(fixture.model.subscriptions.first)
        let resolved = fixture.board.resolved(for: fixture.feed)
        for width in [WiltedMacFeedRulesView.width + 48, 700] {
            let shown = try WiltedMacHeadless.recognizedText(
                WiltedMacFeedRulesView(editor: fixture.editor, subscription: subscription, resolved: resolved, back: {}, maximumHeight: nil)
                    .frame(width: WiltedMacFeedRulesView.width),
                size: CGSize(width: width, height: 2_400)
            ).joined(separator: "\n")
            for text in ["Match rules", "Add rule", "Apply to existing", "Undecided episodes", "Automatic decisions"] {
                XCTAssertTrue(shown.contains(text), "\(text) at \(width): \(shown)")
            }
            XCTAssertTrue(shown.contains("2 to keep, 1 to skip"), "\(width): \(shown)")
            XCTAssertTrue(shown.contains("1 Keep to Skip, 1 Skip to Keep"), "\(width): \(shown)")
            XCTAssertTrue(shown.contains("2 yours, 1 started"), "\(width): \(shown)")
        }

        let bad = fixture.editor.addRule()
        fixture.editor.update(bad) { $0.include = "(" }
        let shown = try WiltedMacHeadless.recognizedText(
            WiltedMacFeedRulesView(editor: fixture.editor, subscription: subscription, resolved: resolved, back: {}, maximumHeight: nil)
                .frame(width: WiltedMacFeedRulesView.width),
            size: CGSize(width: 700, height: 2_400)
        ).joined(separator: " ")
        XCTAssertTrue(shown.contains("not a valid pattern"), shown)
        XCTAssertTrue(shown.contains("Fix the rules marked below"), shown)
    }

    func testRulesPageSaysSoWhenAutoKeepIsOffAndTheSettingsPageLinksToIt() async throws {
        let fixture = try await makeFixture(mixed, policy: FeedAutomationPolicy(autoKeep: .off))
        fixture.editor.loadIfNeeded()
        let subscription = try XCTUnwrap(fixture.model.subscriptions.first)
        let rulesPage = try WiltedMacHeadless.recognizedText(
            WiltedMacFeedRulesView(
                editor: fixture.editor, subscription: subscription,
                resolved: fixture.board.resolved(for: fixture.feed), back: {}, maximumHeight: nil
            ),
            size: CGSize(width: 600, height: 1_400)
        ).joined(separator: " ")
        XCTAssertTrue(rulesPage.contains("Auto keep is Off"), rulesPage)

        let settings = try WiltedMacHeadless.recognizedText(
            WiltedMacFeedPolicyContent(board: fixture.board, subscription: subscription).frame(width: 380).padding(16),
            size: CGSize(width: 412, height: 800)
        ).joined(separator: " ")
        XCTAssertTrue(settings.contains("Match rules"), settings)
        XCTAssertTrue(settings.contains("2 rules"), settings)
    }

    func testEveryNewControlCarriesAnAccessibilityLabel() throws {
        let source = try WiltedMacHeadless.viewSource("WiltedMacFeedRulesView.swift")
        let controls = ["Picker(", "TextField(", "Stepper(", "Button(", "Toggle(", "Menu("].reduce(0) {
            $0 + WiltedMacHeadless.occurrences(of: $1, in: source)
        } - WiltedMacHeadless.occurrences(of: "iconButton(", in: source)  // the three icon buttons share one labelled helper
        XCTAssertGreaterThan(controls, 8)
        XCTAssertGreaterThanOrEqual(WiltedMacHeadless.occurrences(of: ".accessibilityLabel(", in: source), controls)
        for label in [
            "Add a match rule for", "Preview match rules for", "Apply match rules to existing episodes of",
            "Cancel checking rules for", "Undo applied match rules for", "Back to feed settings for",
            "Rule \\(number) enabled for", "Rule \\(number) action for", "Rule \\(number) pattern to match for",
            "Rule \\(number) exception pattern for",
        ] {
            XCTAssertTrue(source.contains(label), label)
        }
        XCTAssertTrue(source.contains("\"Edit match rules for \\(subscription.title)\""))
        let policy = try WiltedMacHeadless.viewSource("WiltedMacFeedPolicyView.swift")
        XCTAssertTrue(policy.contains("WiltedMacFeedRulesEntry("), "the settings page opens the rules page")
    }

    // MARK: Fixture

    private func makeFixture(
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

    private func relaunch(_ fixture: Fixture) async throws -> WiltedMacModel {
        let model = WiltedMacModel(
            arguments: [], stateDirectoryOverride: fixture.directory, preferences: fixture.preferences
        )
        model.startStoreBootstrap()
        await model.waitForStoreBootstrap()
        addTeardownBlock { await model.close() }
        return model
    }

    nonisolated private static func isMainThread() -> Bool { Thread.isMainThread }
}

/// Records each evaluation step from off the main actor.
private final class StepRecorder: @unchecked Sendable {
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
private final class TaskBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Task<FeedRulesApplyResult, Error>?

    var task: Task<FeedRulesApplyResult, Error>? {
        get { lock.lock(); defer { lock.unlock() }; return stored }
        set { lock.lock(); defer { lock.unlock() }; stored = newValue }
    }

    func cancel() { task?.cancel() }
}
