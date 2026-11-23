import Foundation
import XCTest
import WiltedDomain
@testable import WiltedProducer
@testable import WiltedMac

/// A per-feed Skip rule retires every new matching episode whatever the
/// feed's Auto keep, on automatic and manual refresh alike, and records the
/// rule that did it. The owner's case: a show's "Fight Companion" episodes
/// skipped automatically on a feed whose Auto keep is Off.
@MainActor
final class WiltedMacRuleAdmissionTests: XCTestCase {
    private static let fightTitle = "Fight Companion - October 11, 2026"
    private static let skipFightCompanions = EpisodeMatchRule(
        field: .title, includePattern: "fight companion", action: .skip
    )

    // MARK: Refresh

    func testAutoKeepOffSkipRuleRetiresANewMatchOnAutomaticRefresh() async throws {
        let rig = try await makeRig(feedItems: [
            RuleAdmissionItem(guid: "fight", title: Self.fightTitle, day: 2),
            RuleAdmissionItem(guid: "show", title: "#2400 - Guest", day: 1)
        ])

        let claimed = try await rig.model.automaticRefresh(rig.feedURL, claimingNewest: 0)

        XCTAssertTrue(claimed.isEmpty)
        try await assertRetiredByRule(rig, "fight")
        try await assertLiveAndUndecided(rig, "show")
    }

    func testAutoKeepOffSkipRuleRetiresANewMatchOnManualRefresh() async throws {
        let rig = try await makeRig(feedItems: [
            RuleAdmissionItem(guid: "fight", title: Self.fightTitle, day: 2),
            RuleAdmissionItem(guid: "show", title: "#2400 - Guest", day: 1)
        ])

        let result = try await rig.model.refreshPodcastURLs([rig.feedURL], subscribing: false)
        await rig.drain()

        // "Added 1 new episode" must name the one the listener can find.
        XCTAssertEqual(result.newEpisodeIDs.map(\.rawValue), [rig.id("show")])
        XCTAssertFalse(result.newEpisodeIDs.map(\.rawValue).contains(rig.id("fight")), "a rule-retired episode is not added")
        try await assertRetiredByRule(rig, "fight")
        try await assertLiveAndUndecided(rig, "show")
    }

    func testAnEpisodeRestoredFromHistoryIsNeverSkippedAgain() async throws {
        let rig = try await makeRig(feedItems: [RuleAdmissionItem(guid: "fight", title: Self.fightTitle, day: 1)])
        _ = try await rig.model.automaticRefresh(rig.feedURL, claimingNewest: 0)
        try await assertRetiredByRule(rig, "fight")

        rig.model.restoreSkippedFeedEpisode(try XCTUnwrap(rig.episode("fight")))
        await rig.drain()
        let fightID = try ItemID(rawValue: rig.id("fight"))
        let restored = try await rig.store.episodeDecision(for: fightID)
        XCTAssertEqual(restored?.decision, .keep)
        XCTAssertEqual(restored?.source, .manual)

        // Offer the restored episode to admission as if it were new: only the
        // listener's manual decision stands between it and the Skip rule.
        let admitted = try await rig.model.admitAutomatically(
            feedID: rig.feedID, feedEpisodes: rig.model.episodes, newlySaved: [rig.id("fight")], store: rig.store
        )
        XCTAssertTrue(admitted.ruleSkipped.isEmpty)
        _ = try await rig.model.automaticRefresh(rig.feedURL, claimingNewest: 0)
        _ = try await rig.model.refreshPodcastURLs([rig.feedURL], subscribing: false)
        await rig.drain()

        let removal = try await rig.store.removalKind(for: fightID)
        let after = try await rig.store.episodeDecision(for: fightID)
        XCTAssertNil(removal, "the restored episode stays in the feed")
        XCTAssertNil(rig.episode("fight")?.removalKind)
        XCTAssertEqual(after, restored, "the manual Keep is untouched")
    }

    func testOneFeedsSkipRuleNeverRetiresAnotherFeedsEpisode() async throws {
        // A kept limit makes undecided episodes candidates; they must be this feed's own.
        let rig = try await makeRig(
            policy: FeedAutomationPolicy(autoKeep: .on, autoDownload: .off, autoPrepare: .off, keptLimit: .explicit(5)),
            feedItems: [RuleAdmissionItem(guid: "show", title: "#2400 - Guest", day: 1)],
            otherFeedEpisodeTitle: Self.fightTitle
        )
        XCTAssertNotNil(rig.model.episodes.first { $0.id == rig.otherEpisodeID.rawValue }, "the other feed's row is loaded")

        _ = try await rig.model.automaticRefresh(rig.feedURL, claimingNewest: 0)

        let otherDecision = try await rig.store.episodeDecision(for: rig.otherEpisodeID)
        let otherRemoval = try await rig.store.removalKind(for: rig.otherEpisodeID)
        XCTAssertNil(otherDecision)
        XCTAssertNil(otherRemoval)
        let show = try await rig.store.episodeDecision(for: ItemID(rawValue: rig.id("show")))
        XCTAssertEqual(show?.source, .policy, "control: the refreshed feed's own new episode was kept")
    }

    func testAnOlderSkipMatchNotFoundNewIsLeftUndecidedForTheRulesSheetsApply() async throws {
        // Auto keep On with a kept limit offers older undecided episodes on every pass.
        let older = [
            RuleAdmissionItem(guid: "fight", title: Self.fightTitle, day: 1),
            RuleAdmissionItem(guid: "show", title: "#2400 - Guest", day: 2)
        ]
        let rig = try await makeRig(
            policy: FeedAutomationPolicy(autoKeep: .on, autoDownload: .off, autoPrepare: .off, keptLimit: .explicit(5)),
            feedItems: older, storedItems: older
        )
        let fightID = try ItemID(rawValue: rig.id("fight"))
        let seeded = try await rig.store.episodeDecision(for: fightID)
        XCTAssertNil(seeded)

        // A slot release, then a refresh that finds nothing new.
        await rig.model.releaseWaitingEpisodes(feedIDs: [rig.feedID.rawValue])
        let show = try await rig.store.episodeDecision(for: ItemID(rawValue: rig.id("show")))
        XCTAssertEqual(show?.source, .policy, "control: the slot release admitted the older episodes")
        let released = try await rig.store.episodeDecision(for: fightID)
        XCTAssertNil(released, "a skip record alone would leave it in the Feed")
        _ = try await rig.model.automaticRefresh(rig.feedURL, claimingNewest: 0)

        let decision = try await rig.store.episodeDecision(for: fightID)
        let removal = try await rig.store.removalKind(for: fightID)
        XCTAssertNil(decision, "undecided, so the rules sheet's Apply retires it")
        XCTAssertNil(removal)
        XCTAssertNotNil(rig.episode("fight"))
        XCTAssertNil(rig.episode("fight")?.removalKind)
    }

    func testApplyKeepsCandidateAudioWhileItsLinkedSiblingIsLoading() async throws {
        let fixture = try await makeMediaLeaseFixture("apply")
        let result = try await withSuspendedSiblingLoad(fixture) {
            try await fixture.rig.model.applyFeedRules(
                feedID: fixture.rig.feedID.rawValue,
                rules: EpisodeMatchRules(rules: [Self.skipFightCompanions]), progress: { _, _ in }
            )
        }

        try await assertCandidateSurvived(fixture)
        try await assertUnleasedControlWasRetired(fixture)
        XCTAssertTrue(try XCTUnwrap(result.undo).retired.contains(fixture.controlID))
    }

    func testAutomaticAdmissionKeepsCandidateAudioWhileItsLinkedSiblingIsLoading() async throws {
        let fixture = try await makeMediaLeaseFixture("refresh")
        let outcome = try await withSuspendedSiblingLoad(fixture) {
            try await fixture.rig.model.admitAutomatically(
                feedID: fixture.rig.feedID, feedEpisodes: fixture.rig.model.episodes,
                newlySaved: [fixture.fightID.rawValue, fixture.controlID.rawValue], store: fixture.rig.store
            )
        }

        XCTAssertEqual(outcome.ruleSkipped, [fixture.controlID.rawValue], "the unleased match is the positive control")
        try await assertCandidateSurvived(fixture)
        try await assertUnleasedControlWasRetired(fixture)
    }

    private func makeMediaLeaseFixture(_ name: String) async throws -> RuleAdmissionMediaLeaseFixture {
        let items = [
            RuleAdmissionItem(guid: "fight", title: Self.fightTitle, day: 1),
            RuleAdmissionItem(guid: "control", title: "Fight Companion control", day: 2)
        ]
        let rig = try await makeRig(feedItems: [], storedItems: items)
        let fightID = try ItemID(rawValue: rig.id("fight"))
        let controlID = try ItemID(rawValue: rig.id("control"))
        let fightAudio = try await saveAudio(for: fightID, name: "\(name)-fight", rig: rig)
        let controlAudio = try await saveAudio(for: controlID, name: "\(name)-control", rig: rig)
        let siblingID = try await addLinkedSibling(to: fightID, guid: "\(name)-playing-sibling", rig: rig)
        let siblingAudio = try await saveAudio(for: siblingID, name: "\(name)-sibling", rig: rig)
        let gate = RuleAdmissionMediaOpenGate()
        let backend = WiltedMacScriptedBackend()
        backend.beforeMediaOpenForTesting = { await gate.hold() }
        let controller = PlaybackController(store: rig.store, backend: backend, deviceID: "fixture")
        rig.model.playback = controller
        let revision = try AudioRevision(
            itemID: siblingID, revisionID: try RevisionID(rawValue: "\(name)-sibling-load"),
            durationSeconds: 60, byteCount: 1, contentHash: "sha256:\(String(repeating: "a", count: 64))",
            mediaType: "audio/mpeg", createdAt: Timestamp(Date()), schemaVersion: 1
        )
        let loading = Task { try await controller.load(revision: revision, mediaURL: siblingAudio) }
        guard await gate.waitUntilHeld() else {
            gate.release()
            _ = await loading.result
            throw RuleAdmissionGateTimeout()
        }
        return RuleAdmissionMediaLeaseFixture(
            rig: rig, fightID: fightID, controlID: controlID, fightAudio: fightAudio,
            controlAudio: controlAudio, gate: gate, loading: loading
        )
    }

    private func withSuspendedSiblingLoad<Value>(
        _ fixture: RuleAdmissionMediaLeaseFixture, operation: @MainActor () async throws -> Value
    ) async throws -> Value {
        do {
            let value = try await operation()
            fixture.gate.release()
            try await fixture.loading.value
            return value
        } catch {
            fixture.gate.release()
            _ = await fixture.loading.result
            throw error
        }
    }

    private func assertCandidateSurvived(_ fixture: RuleAdmissionMediaLeaseFixture) async throws {
        let removal = try await fixture.rig.store.removalKind(for: fixture.fightID)
        let decision = try await fixture.rig.store.episodeDecision(for: fixture.fightID)
        let audio = try await fixture.rig.store.download(for: fixture.fightID)
        let episode = fixture.rig.episode("fight")
        XCTAssertNil(removal, "the candidate linked to the in-flight load stays live")
        XCTAssertNil(decision, "no Skip decision is written for the candidate")
        XCTAssertNotNil(audio, "the candidate's download record remains")
        XCTAssertNotNil(episode, "the candidate episode remains in the model")
        XCTAssertNil(episode?.removalKind, "the candidate episode remains live in the model")
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.fightAudio.path), "the candidate audio remains")
    }

    private func assertUnleasedControlWasRetired(_ fixture: RuleAdmissionMediaLeaseFixture) async throws {
        let removal = try await fixture.rig.store.removalKind(for: fixture.controlID)
        let decision = try await fixture.rig.store.episodeDecision(for: fixture.controlID)
        XCTAssertEqual(removal, .retired, "the matching candidate with no active load is retired")
        XCTAssertEqual(decision?.source, .rule)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.controlAudio.path), "its unleased audio is deleted")
    }

    private func saveAudio(for id: ItemID, name: String, rig: RuleAdmissionRig) async throws -> URL {
        let mediaURL = rig.directory.appendingPathComponent("\(name).mp3")
        let bytes = Data("audio".utf8)
        try bytes.write(to: mediaURL)
        try await rig.store.save(download: PodcastDownload(
            episodeID: id, status: .completed, bytesReceived: Int64(bytes.count), localURL: mediaURL,
            contentHash: "sha256:" + String(repeating: "a", count: 64), updatedAt: Timestamp(Date())
        ))
        return mediaURL
    }

    private func addLinkedSibling(to targetID: ItemID, guid: String, rig: RuleAdmissionRig) async throws -> ItemID {
        let enclosure = ruleAdmissionEnclosure(guid)
        let siblingID = try ItemID.derivePodcastEpisode(
            feedURL: rig.feedURL, rssGUID: guid, enclosureURL: enclosure
        )
        let now = Timestamp(Date())
        try await rig.store.savePodcastEpisodes([try PodcastEpisode(
            itemID: siblingID, feedID: rig.feedID, feedURL: rig.feedURL, rssGUID: guid,
            title: "Fight Companion sibling", publishedTime: now, enclosureURL: enclosure,
            enclosureMediaType: "audio/mpeg", createdAt: now
        )], admission: .backfill)
        let preview = try await rig.store.previewEpisodeAssociation(
            confirming: PodcastEpisodePairConfirmation(
                confirmationID: UUID(), feedID: rig.feedID, first: targetID, second: siblingID, confirmedAt: now
            ),
            representativeID: targetID
        )
        _ = try await rig.store.applyEpisodeAssociation(preview, at: now)
        return siblingID
    }

    // MARK: Pure planning

    func testFightCompanionTitleMatchesTheSkipRuleWhileKeepRulesWaitForAutoKeep() {
        let keepBonus = EpisodeMatchRule(field: .title, includePattern: "bonus", action: .keep)
        let rules = EpisodeMatchRules(rules: [Self.skipFightCompanions, keepBonus])
        let released = Date(timeIntervalSince1970: 1_760_140_800)
        let candidates: [EpisodeAdmissionService.Candidate] = [
            .init(id: "fight", title: Self.fightTitle, notes: nil, releasedAt: released),
            .init(id: "bonus", title: "Bonus episode", notes: nil, releasedAt: released),
            .init(id: "restored", title: "Fight Companion - October 4, 2026", notes: nil, releasedAt: released)
        ]

        let planned = EpisodeAdmissionService.plan(
            candidates: candidates, keptEpisodeIDs: [], manualDecisions: ["restored": .keep], rules: rules,
            policy: .init(autoKeep: false, autoDownload: true, autoPrepare: true, keptLimit: nil)
        )

        XCTAssertEqual(planned, [.init(
            episodeID: "fight", decision: .skip, source: .rule, ruleID: Self.skipFightCompanions.id, workTicketKinds: []
        )])
    }

    // MARK: Assertions

    private func assertRetiredByRule(
        _ rig: RuleAdmissionRig, _ guid: String, file: StaticString = #filePath, line: UInt = #line
    ) async throws {
        let id = try ItemID(rawValue: rig.id(guid))
        let decision = try await rig.store.episodeDecision(for: id)
        let removal = try await rig.store.removalKind(for: id)
        let retiredAt = try await rig.store.retiredAt(for: id)
        let queue = try await rig.store.podcastQueueState()
        XCTAssertEqual(decision?.decision, .skip, file: file, line: line)
        XCTAssertEqual(decision?.source, .rule, file: file, line: line)
        XCTAssertEqual(decision?.ruleID, Self.skipFightCompanions.id, "History can name the rule", file: file, line: line)
        XCTAssertEqual(removal, .retired, "the skip takes the episode out of the feed", file: file, line: line)
        XCTAssertNotNil(retiredAt, file: file, line: line)
        XCTAssertFalse(queue.episodeIDs.contains(id), file: file, line: line)
        XCTAssertEqual(rig.episode(guid)?.removalKind, .retired, "the model re-read the retired row", file: file, line: line)
    }

    private func assertLiveAndUndecided(
        _ rig: RuleAdmissionRig, _ guid: String, file: StaticString = #filePath, line: UInt = #line
    ) async throws {
        let id = try ItemID(rawValue: rig.id(guid))
        let decision = try await rig.store.episodeDecision(for: id)
        let removal = try await rig.store.removalKind(for: id)
        XCTAssertNil(decision, "Auto keep Off keeps nothing automatically", file: file, line: line)
        XCTAssertNil(removal, file: file, line: line)
        XCTAssertNotNil(rig.episode(guid), file: file, line: line)
        XCTAssertNil(rig.episode(guid)?.removalKind, file: file, line: line)
    }
}

@MainActor
private struct RuleAdmissionMediaLeaseFixture {
    let rig: RuleAdmissionRig
    let fightID: ItemID
    let controlID: ItemID
    let fightAudio: URL
    let controlAudio: URL
    let gate: RuleAdmissionMediaOpenGate
    let loading: Task<Void, Error>
}

@MainActor
private final class RuleAdmissionMediaOpenGate {
    private var isHeld = false
    private var isReleased = false
    private var loadContinuation: CheckedContinuation<Void, Never>?
    private var heldContinuation: CheckedContinuation<Bool, Never>?

    func hold() async {
        isHeld = true
        heldContinuation?.resume(returning: true)
        heldContinuation = nil
        await withCheckedContinuation { continuation in
            if isReleased {
                continuation.resume()
            } else {
                loadContinuation = continuation
            }
        }
    }

    func waitUntilHeld() async -> Bool {
        if isHeld { return true }
        return await withCheckedContinuation { continuation in
            heldContinuation = continuation
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(5))
                guard let self, let heldContinuation = self.heldContinuation else { return }
                self.heldContinuation = nil
                heldContinuation.resume(returning: false)
            }
        }
    }

    func release() {
        isReleased = true
        loadContinuation?.resume()
        loadContinuation = nil
    }
}

private struct RuleAdmissionGateTimeout: Error {}

// MARK: - Fixture

private struct RuleAdmissionItem {
    let guid: String
    let title: String
    let day: Int
}

private func ruleAdmissionEnclosure(_ guid: String) -> URL {
    URL(string: "https://media.example.test/rule-admission/\(guid).mp3")!
}

/// Publication dates in January 2024, after the fixture's 2023 subscription,
/// so an incremental refresh admits every item as new.
private func ruleAdmissionPublished(_ day: Int) -> Date {
    Date(timeIntervalSince1970: 1_704_000_000 + Double(day) * 86_400)
}

@MainActor
private struct RuleAdmissionRig {
    let model: WiltedMacModel
    let store: LocalLibraryStore
    let feedURL: URL
    let feedID: ItemID
    let otherEpisodeID: ItemID
    let directory: URL

    func id(_ guid: String) -> String {
        (try? ItemID.derivePodcastEpisode(
            feedURL: feedURL, rssGUID: guid, enclosureURL: ruleAdmissionEnclosure(guid)
        ).rawValue) ?? guid
    }

    func episode(_ guid: String) -> WiltedMacEpisode? { model.episodes.first { $0.id == id(guid) } }

    func drain() async {
        for writer in Array(model.subscriptionWriteTasks.values) { await writer.value }
        await model.waitForPodcastOperations()
    }
}

extension WiltedMacRuleAdmissionTests {
    /// One subscribed feed carrying the Fight Companion Skip rule, serving
    /// `feedItems` on every load. `otherFeedEpisodeTitle` adds a second
    /// subscribed feed with one stored, undecided episode of that title.
    /// `storedItems` are stored undecided before the model loads, so no
    /// refresh finds them new.
    fileprivate func makeRig(
        policy: FeedAutomationPolicy = FeedAutomationPolicy(autoKeep: .off, autoDownload: .off, autoPrepare: .off),
        feedItems: [RuleAdmissionItem],
        storedItems: [RuleAdmissionItem] = [],
        otherFeedEpisodeTitle: String? = nil
    ) async throws -> RuleAdmissionRig {
        let feedURL = URL(string: "https://feeds.example.test/rule-admission.xml")!
        let feedID = try ItemID.derivePodcastFeed(from: feedURL)
        let otherFeedURL = URL(string: "https://feeds.example.test/other-show.xml")!
        let otherFeedID = try ItemID.derivePodcastFeed(from: otherFeedURL)
        let otherEpisodeID = try ItemID.derivePodcastEpisode(
            feedURL: otherFeedURL, rssGUID: "other", enclosureURL: ruleAdmissionEnclosure("other")
        )
        let subscribedAt = Timestamp(Date(timeIntervalSince1970: 1_672_531_200))
        let rules = EpisodeMatchRules(rules: [Self.skipFightCompanions])
        let items = feedItems.map { item in
            """
            <item><guid>\(item.guid)</guid><title>\(item.title)</title>
            <pubDate>\(Self.rfc822(ruleAdmissionPublished(item.day)))</pubDate>
            <enclosure url="\(ruleAdmissionEnclosure(item.guid).absoluteString)" type="audio/mpeg" /></item>
            """
        }.joined()
        let xml = "<rss version=\"2.0\"><channel><title>Rule Admission</title>\(items)</channel></rss>"
        let directory = wiltedTemporaryDirectory("rule-admission")
        let model = WiltedMacModel(
            arguments: [], stateDirectoryOverride: directory,
            storeBootstrap: { url in
                let store = try LocalLibraryStore(url: url)
                try await store.save(feed: try PodcastFeed(
                    itemID: feedID, canonicalURL: feedURL, title: "Rule Admission", createdAt: subscribedAt
                ))
                try await store.save(subscription: PodcastSubscription(feedID: feedID, subscribedAt: subscribedAt))
                try await store.save(feedAutomationPolicy: policy, for: feedID)
                try await store.replaceEpisodeMatchRules(rules, for: feedID)
                for item in storedItems {
                    let enclosure = ruleAdmissionEnclosure(item.guid)
                    try await store.save(episode: try PodcastEpisode(
                        itemID: try ItemID.derivePodcastEpisode(feedURL: feedURL, rssGUID: item.guid, enclosureURL: enclosure),
                        feedID: feedID, feedURL: feedURL, rssGUID: item.guid, title: item.title,
                        publishedTime: Timestamp(ruleAdmissionPublished(item.day)), enclosureURL: enclosure,
                        enclosureMediaType: "audio/mpeg", createdAt: subscribedAt
                    ))
                }
                if let otherFeedEpisodeTitle {
                    try await store.save(feed: try PodcastFeed(
                        itemID: otherFeedID, canonicalURL: otherFeedURL, title: "Other Show", createdAt: subscribedAt
                    ))
                    try await store.save(subscription: PodcastSubscription(feedID: otherFeedID, subscribedAt: subscribedAt))
                    try await store.save(episode: try PodcastEpisode(
                        itemID: otherEpisodeID, feedID: otherFeedID, feedURL: otherFeedURL, rssGUID: "other",
                        title: otherFeedEpisodeTitle, publishedTime: Timestamp(ruleAdmissionPublished(0)),
                        enclosureURL: ruleAdmissionEnclosure("other"), enclosureMediaType: "audio/mpeg",
                        createdAt: subscribedAt
                    ))
                }
                return store
            },
            podcastFeedClient: PodcastFeedClient(loader: FixedBodyLoader(body: Data(xml.utf8))),
            preferences: WiltedMacTestPreferences.ephemeral()
        )
        model.startStoreBootstrap()
        await model.waitForStoreBootstrap()
        addTeardownBlock { await model.close() }
        return RuleAdmissionRig(
            model: model, store: try XCTUnwrap(model.store), feedURL: feedURL, feedID: feedID,
            otherEpisodeID: otherEpisodeID, directory: directory
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
