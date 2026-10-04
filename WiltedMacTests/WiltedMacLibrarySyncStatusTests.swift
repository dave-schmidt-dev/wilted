import Foundation
import WiltedCloudKit
import WiltedDomain
import WiltedLibrary
import WiltedProducer
import XCTest
@testable import WiltedMac

/// Counts the server calls that matter for Task 5.2: baseline scans, pushes and the changes in
/// them, rounds, and every media call, so "no audio fetch" is measured rather than assumed.
private final class LedgerCounts: @unchecked Sendable {
    private let lock = NSLock()
    private var counts: [String: Int] = [:]
    private var failing = false
    func bump(_ name: String, by amount: Int = 1) { lock.withLock { counts[name, default: 0] += amount } }
    func count(_ name: String) -> Int { lock.withLock { counts[name] ?? 0 } }
    var media: Int { ["publishMedia", "mediaOffers", "fetchMedia", "removeMedia"].map(count).reduce(0, +) }
    var pushFails: Bool {
        get { lock.withLock { failing } }
        set { lock.withLock { failing = newValue } }
    }
}

private struct LedgerTransport: LibraryTransport {
    struct Offline: Error {}
    let inner: InMemoryLibraryTransport
    let counts: LedgerCounts

    func fetchChanges(since token: LibraryChangeToken?) async throws -> LibraryChangeBatch {
        counts.bump(token == nil ? "baselineScan" : "deltaFetch")
        return try await inner.fetchChanges(since: token)
    }
    func push(changes: [PendingLibraryChange]) async throws -> LibraryPushResult {
        counts.bump("push")
        if counts.pushFails { throw Offline() }
        counts.bump("pushedChanges", by: changes.count)
        return try await inner.push(changes: changes)
    }
    func send(intent: LibraryIntent) async throws { try await inner.send(intent: intent) }
    func listIntents() async throws -> [LibraryIntent] { try await inner.listIntents() }
    func publish(_ record: DevicePlaybackPosition, as channel: PlaybackChannel) async throws {
        try await inner.publish(record, as: channel)
    }
    func fetchDeviceRecords() async throws -> LibraryDeviceRecords { try await inner.fetchDeviceRecords() }
    func poll(_ options: LibraryPollOptions) async throws -> LibraryPollResult {
        counts.bump("poll")
        return try await inner.poll(options)
    }
    func publishMedia(offer: LibraryMediaOffer, fileURL: URL) async throws { counts.bump("publishMedia") }
    func mediaOffers() async throws -> [LibraryMediaOffer] { counts.bump("mediaOffers"); return [] }
    func fetchMedia(_ offer: LibraryMediaOffer, progress: @escaping MediaProgressHandler) async throws -> URL {
        counts.bump("fetchMedia")
        throw Offline()
    }
    func removeMedia(entryID: ItemID) async throws { counts.bump("removeMedia") }
}

private actor ScriptedSource: LibraryStateSource {
    private var state: LibraryStateSnapshot
    init(_ state: LibraryStateSnapshot) { self.state = state }
    func set(_ state: LibraryStateSnapshot) { self.state = state }
    func currentState() async throws -> LibraryStateSnapshot { state }
}

private actor QuietSink: LibraryIntentSink {
    func receive(_ intent: LibraryIntent) async throws {}
}

@MainActor
final class WiltedMacLibrarySyncStatusTests: XCTestCase {
    private typealias Status = WiltedMacLibrarySyncStatus
    private typealias Activity = WiltedMacLibrarySyncActivity
    private let flagOn = ["WILTED_LIBRARY_SYNC": "1"]
    private let feedURL = URL(string: "https://feeds.example.test/status.xml")!
    private let created = Timestamp(Date(timeIntervalSince1970: 1_700_000_000))
    private let noon = Calendar.current.date(bySettingHour: 12, minute: 0, second: 0, of: Date())!

    // MARK: Status projection

    func testEveryAccountHoldHasPlainCopyAndNeverOffersSyncNow() {
        let expected: [(WiltedMacLibraryAccountStatus, Status.Phase, String)] = [
            (.awaitingAccount, .awaitingAccount, "Checking the iCloud account before sending"),
            (.reviewRequired(.unboundLibrary), .reviewRequired, "Review account before sending this library"),
            (.reviewRequired(.switchAccounts), .reviewRequired, "Account changed. Library changes are held for review"),
            (.approvedAwaitingAccount, .approvedAwaitingAccount,
             "Account reviewed. Sending starts when iCloud reports a signed-in account"),
            (.noAccount, .noAccount, "No iCloud account is signed in. Library changes stay on this Mac"),
            (.accountUnavailable, .accountUnavailable,
             "The iCloud account could not be checked. Library changes stay on this Mac"),
            (.failed, .accountFailed, "This library's account record could not be read. Nothing is sent"),
            (.transportUnavailable, .transportUnavailable, "iCloud library sync could not start. Nothing is sent"),
        ]
        let busy = Activity(unsentChanges: 2, lastSentAt: noon, hasFinishedPass: true)
        for (account, phase, headline) in expected {
            let status = Status.resolve(account: account, throttle: nil, activity: busy, now: noon)
            XCTAssertEqual(status.phase, phase, "\(account)")
            XCTAssertEqual(status.headline, headline, "\(account)")
            XCTAssertFalse(status.canSyncNow, "nothing is sent while \(account) holds the library")
        }
        XCTAssertEqual(Status.resolve(account: .reviewRequired(.unboundLibrary), throttle: nil, activity: busy).reviewContext,
                       "This existing library has no account binding.")
        for reason in [LocalLibraryAccountBinding.Reason.signIn, .signOut, .switchAccounts, .ownerMismatch] {
            XCTAssertEqual(Status.resolve(account: .reviewRequired(reason), throttle: nil, activity: busy).reviewContext,
                           "This library belongs to the previous account. Sending is paused.")
        }
        XCTAssertNil(Status.resolve(account: .approvedAwaitingAccount, throttle: nil, activity: busy).reviewContext,
                     "an approved review has nothing left to approve")
    }

    func testAPublisherThatIsNotRunningReadsUnavailableNeverDisabled() {
        let status = Status.resolve(account: nil, throttle: nil, activity: Activity())
        XCTAssertEqual(status.phase, .unavailable)
        XCTAssertEqual(status.headline, "Library sync is not running on this Mac")
        XCTAssertFalse(status.headline.localizedCaseInsensitiveContains("disabled"))
        XCTAssertFalse(status.canSyncNow)
    }

    func testAThrottleOutranksLocalActivityAndHoldsSyncNow() {
        let throttle = TransportGateState(kind: .rateLimited, retryAt: noon.addingTimeInterval(120), consecutiveFailures: 1)
        let status = Status.resolve(
            account: .active, throttle: throttle, activity: Activity(isSyncing: true, unsentChanges: 2, sendFailed: true))
        XCTAssertEqual(status.phase, .throttled)
        XCTAssertEqual(status.headline, "iCloud paused requests. Sync now is available after the retry time")
        XCTAssertFalse(status.canSyncNow)
        XCTAssertTrue(WiltedMacLibrarySyncController.isPause(TransportThrottled(retryAt: noon)),
                      "a throttled pass is reported by the throttle, never as a send failure")
    }

    func testStatesMoveFromWaitingThroughPendingWorkingFailedAndSent() {
        func status(_ activity: Activity) -> Status {
            .resolve(account: .active, throttle: nil, activity: activity, now: noon)
        }
        var activity = Activity()
        XCTAssertEqual(status(activity).headline, "Waiting for the first sync round")
        activity.recordSendFailure(unsent: 2)
        XCTAssertEqual(status(activity).phase, .sendFailed)
        XCTAssertEqual(status(activity).headline, "Send failed. 2 library changes kept for retry.")
        XCTAssertTrue(status(activity).canSyncNow, "a failure is retried by Sync now")
        activity.isSyncing = true
        XCTAssertEqual(status(activity).headline, "Sending 2 library changes…")
        XCTAssertFalse(status(activity).canSyncNow, "a running sync is not started twice")
        activity.isSyncing = false
        activity.recordSend(acknowledged: 1, unsent: 1, at: noon)
        XCTAssertEqual(status(activity).headline, "1 library change waiting to send")
        activity.recordSend(acknowledged: 1, unsent: 0, at: noon)
        let time = noon.formatted(date: .omitted, time: .shortened)
        XCTAssertEqual(status(activity).headline, "Local changes sent at \(time). Phone fetch is separate.")
        activity.recordSend(acknowledged: 0, unsent: 0, at: noon.addingTimeInterval(30))
        XCTAssertEqual(activity.lastSentAt, noon, "an idle pass is not a send")
        activity.recordCheck(succeeded: false, at: noon)
        XCTAssertEqual(status(activity).headline, "Reading phone changes failed. The next sync round retries.")
        activity.recordCheck(succeeded: true, at: noon)
        XCTAssertEqual(status(activity).phase, .sent)
    }

    func testUnknownCountsAndTimesStayUnknown() {
        func headline(_ activity: Activity) -> String {
            Status.resolve(account: .unmanaged, throttle: nil, activity: activity, now: noon).headline
        }
        XCTAssertEqual(headline(Activity(isSyncing: true)), "Syncing this Mac's library…")
        XCTAssertEqual(headline(Activity(sendFailed: true)), "Send failed. Library changes are kept for retry.")
        XCTAssertEqual(headline(Activity(hasFinishedPass: true)), "Nothing waiting to send from this Mac")
        XCTAssertEqual(Status.timeLabel(nil), "Not yet this launch")
        XCTAssertEqual(headline(Activity(accountReviewed: true)), "Account reviewed. Waiting for the first sync round")
        XCTAssertTrue(Status.scopeNote.contains("this Mac's own"), "the times are labelled as the Mac's")
    }

    func testFixtureScenariosParseFromTheirLaunchArgument() {
        for scenario in WiltedMacLibrarySyncFixtureScenario.allCases {
            XCTAssertEqual(
                WiltedMacLibrarySyncFixtureScenario.scenario(in: ["--wilted-ui-fixture-ready", "--wilted-ui-fixture-library-sync", scenario.rawValue]),
                scenario)
        }
        XCTAssertNil(WiltedMacLibrarySyncFixtureScenario.scenario(in: ["--wilted-ui-fixture-library-sync"]))
        XCTAssertNil(WiltedMacLibrarySyncFixtureScenario.scenario(in: ["--wilted-ui-fixture-library-sync", "bogus"]))
    }

    // MARK: Model wiring

    private func launch(_ name: String) async throws -> (WiltedMacModel, LocalLibraryStore) {
        let model = WiltedMacModel(
            arguments: [], stateDirectoryOverride: wiltedTemporaryDirectory(name),
            storeBootstrap: { try LocalLibraryStore(url: $0) }, preferences: WiltedMacTestPreferences.ephemeral())
        model.startStoreBootstrap()
        await model.waitForStoreBootstrap()
        return (model, try XCTUnwrap(model.store))
    }

    private func shut(_ model: WiltedMacModel) async {
        model.stopLibrarySync()
        await model.waitForLibrarySyncShutdown()
    }

    private func seed(_ store: LocalLibraryStore) async throws {
        let feedID = try ItemID.derivePodcastFeed(from: feedURL)
        try await store.save(feed: try PodcastFeed(itemID: feedID, canonicalURL: feedURL, title: "Show", createdAt: created))
        let enclosure = URL(string: "https://media.example.test/status-a.mp3")!
        try await store.save(episode: try PodcastEpisode(
            itemID: try ItemID.derivePodcastEpisode(feedURL: feedURL, rssGUID: "a", enclosureURL: enclosure),
            feedID: feedID, feedURL: feedURL, rssGUID: "a", title: "Episode a", publishedTime: created,
            enclosureURL: enclosure, enclosureMediaType: "audio/mpeg", createdAt: created))
    }

    private func eventually(_ what: String, _ condition: () async -> Bool) async throws {
        for _ in 0..<250 {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTFail("Timed out waiting for \(what)")
    }

    private func ledger(_ device: String = "mac-status") -> (InMemoryLibraryServer, LedgerTransport, LedgerCounts) {
        let server = InMemoryLibraryServer(writerDeviceID: device)
        let counts = LedgerCounts()
        return (server, LedgerTransport(inner: InMemoryLibraryTransport(deviceID: device, server: server), counts: counts), counts)
    }

    func testASelectedPublisherShowsItsOwnCardAndATestHostKeepsTheLegacyOne() async throws {
        let (model, _) = try await launch("library-status-selected")
        XCTAssertFalse(model.showsLibraryPublisherSync, "a test host selects the legacy engine")
        model.librarySyncBuildFacts = WiltedMacLibraryBuildFacts(compiledLive: true, hostsTests: false)
        XCTAssertTrue(model.showsLibraryPublisherSync, "a live launch selects the publisher")
        XCTAssertEqual(model.librarySyncStatus.phase, .unavailable, "not running reads Unavailable, never Disabled")
        XCTAssertNil(model.syncLibraryNow(), "nothing to sync while the publisher is not running")
    }

    func testSyncNowCoalescesABurstIntoOneRoundAndReportsTheMacsOwnSend() async throws {
        let (model, store) = try await launch("library-status-sync-now")
        try await seed(store)
        let (server, transport, counts) = ledger()
        XCTAssertTrue(model.startLibrarySyncIfEnabled(environment: flagOn, transport: transport, debounce: .milliseconds(20)))
        let controller = try XCTUnwrap(model.librarySyncController)
        try await eventually("the first round and pass") {
            let running = await controller.inbound?.poller?.isRunning ?? false
            return running && counts.count("poll") >= 1 && controller.passCount >= 2 && model.librarySyncActivity.lastCheckedAt != nil
        }
        XCTAssertEqual(model.librarySyncStatus.phase, .sent)
        XCTAssertNotNil(model.librarySyncActivity.lastSentAt, "the seeded library was acknowledged")
        XCTAssertFalse(model.librarySyncActivity.sendFailed)
        let entries = await server.currentSnapshot.entries.count
        XCTAssertEqual(entries, 1)
        let polls = counts.count("poll")
        let pushes = counts.count("push")

        let first = try XCTUnwrap(model.syncLibraryNow())
        XCTAssertTrue(model.librarySyncActivity.isSyncing)
        XCTAssertEqual(model.librarySyncStatus.phase, .working)
        XCTAssertNil(model.syncLibraryNow(), "a press while a sync runs is refused by the card state")
        let joined = try XCTUnwrap(controller.syncNow() as Task<Void, Never>?)
        XCTAssertEqual(first, joined, "a second request joins the running sync")
        await first.value

        XCTAssertEqual(controller.syncNowRuns, 1)
        XCTAssertEqual(counts.count("poll"), polls + 1, "one round for the whole burst")
        XCTAssertEqual(counts.count("push"), pushes, "nothing changed, so nothing is sent again")
        XCTAssertFalse(model.librarySyncActivity.isSyncing)
        XCTAssertEqual(counts.count("fetchMedia"), 0, "no audio is fetched")
        await shut(model)
        XCTAssertEqual(model.librarySyncActivity, Activity(), "stopping clears the publisher's activity")
    }

    func testAFailedSendKeepsItsCountAndSyncNowRecovers() async throws {
        let (model, store) = try await launch("library-status-failure")
        try await seed(store)
        let (server, transport, counts) = ledger()
        counts.pushFails = true
        XCTAssertTrue(model.startLibrarySyncIfEnabled(environment: flagOn, transport: transport, debounce: .milliseconds(20)))
        try await eventually("a failed send") { model.librarySyncActivity.sendFailed }
        XCTAssertNil(model.librarySyncActivity.unsentChanges, "a thrown pass reports no count it cannot know")
        XCTAssertEqual(model.librarySyncStatus.headline, "Send failed. Library changes are kept for retry.")
        XCTAssertNil(model.librarySyncActivity.lastSentAt, "nothing was acknowledged, so nothing is reported sent")

        counts.pushFails = false
        try await eventually("the round that recovers") {
            if let task = model.syncLibraryNow() { await task.value }
            return model.librarySyncStatus.phase == .sent
        }
        XCTAssertEqual(model.librarySyncActivity.unsentChanges, 0)
        let entries = await server.currentSnapshot.entries.count
        XCTAssertEqual(entries, 1)
        await shut(model)
    }

    func testAccountReviewCopyAndApprovalThroughTheRealOwner() async throws {
        let (model, store) = try await launch("library-status-review")
        try await seed(store)
        let fixture = WiltedMacLibraryAccountFixture()
        let (_, transport, counts) = ledger("mac-review")
        XCTAssertTrue(model.startLibrarySyncIfEnabled(
            environment: flagOn, transport: transport, debounce: .milliseconds(10), account: fixture.source))
        XCTAssertEqual(model.librarySyncStatus.phase, .awaitingAccount)
        fixture.signIn(recordName: "_status-owner-record")
        try await eventually("the unbound review") { model.libraryAccountStatus == .reviewRequired(.unboundLibrary) }
        XCTAssertEqual(model.librarySyncStatus.headline, "Review account before sending this library")
        XCTAssertNil(model.syncLibraryNow(), "a held library has no Sync now")
        XCTAssertEqual(counts.count("push"), 0, "nothing is sent before review")

        await model.reviewLibraryAccount().value
        XCTAssertEqual(model.libraryAccountStatus, .active)
        try await eventually("the reviewed library's first send") { model.librarySyncStatus.phase == .sent }
        XCTAssertFalse(model.librarySyncActivity.accountReviewed, "the acknowledged send replaces the review note")
        await shut(model)
    }

    func testApprovingWithoutACurrentAccountSaysSoPlainly() async throws {
        let (model, store) = try await launch("library-status-approved-waiting")
        try await seed(store)
        let fixture = WiltedMacLibraryAccountFixture()
        let (_, transport, counts) = ledger("mac-approved")
        XCTAssertTrue(model.startLibrarySyncIfEnabled(
            environment: flagOn, transport: transport, debounce: .milliseconds(10), account: fixture.source))
        fixture.emit(.quarantineRequired(.signOut))
        try await eventually("the held library") { model.libraryAccountStatus?.needsReview == true }
        XCTAssertEqual(model.librarySyncStatus.headline, "Account changed. Library changes are held for review")

        await model.reviewLibraryAccount().value
        XCTAssertEqual(model.libraryAccountStatus, .approvedAwaitingAccount)
        XCTAssertEqual(model.librarySyncStatus.headline,
                       "Account reviewed. Sending starts when iCloud reports a signed-in account")
        XCTAssertFalse(model.librarySyncStatus.canSyncNow)
        XCTAssertEqual(counts.count("push"), 0)
        await shut(model)
    }

    // MARK: Restart and baseline volume

    func testAnUnchangedEpisodeEncodesToTheSameBytesEveryPass() async throws {
        let (model, store) = try await launch("library-status-stable-payload")
        try await seed(store)
        let source = WiltedMacLocalLibraryStateSource(store: store, deviceID: "mac-status") { nil }
        let first = try await source.currentState().episodes.map(\.payload)
        for _ in 0..<50 {
            let again = try await source.currentState().episodes.map(\.payload)
            XCTAssertEqual(again, first, "the differ compares payload bytes; unstable bytes re-send every episode")
        }
        let (_, transport, counts) = ledger("mac-stable")
        let publisher = WiltedMacLibraryPublisher(source: source, transport: transport, sink: QuietSink(), relaysIntents: false)
        for _ in 0..<20 { _ = try await publisher.sync(includesStats: false) }
        XCTAssertEqual(counts.count("push"), 1, "twenty passes over an unchanged library send it once")
        await shut(model)
    }

    private func id(_ name: String) -> ItemID { try! ItemID(rawValue: "item-\(name)") }

    private func state(titles: [String: String]) -> LibraryStateSnapshot {
        let episodes = titles.keys.sorted().map { name in
            try! LibraryEntry(id: id(name), kind: .podcastEpisode, sourceID: id("feed"), title: titles[name]!,
                              summary: "", publishedAt: Date(timeIntervalSince1970: 1_000))
        }
        return LibraryStateSnapshot(
            feeds: [LibrarySource(id: id("feed"), kind: .podcastFeed, title: "Feed")],
            episodes: episodes, queue: titles.keys.sorted().map(id))
    }

    func testARestartSendsOnlyTheOfflineDeltaWithOneBaselineScanPerProcessAndNoAudio() async throws {
        let server = InMemoryLibraryServer(writerDeviceID: "mac")
        let source = ScriptedSource(state(titles: ["a": "A", "b": "B"]))
        let firstCounts = LedgerCounts()
        let first = WiltedMacLibraryPublisher(
            source: source, transport: LedgerTransport(inner: InMemoryLibraryTransport(deviceID: "mac", server: server), counts: firstCounts),
            sink: QuietSink(), relaysIntents: false)
        _ = try await first.sync()
        _ = try await first.sync()
        XCTAssertEqual(firstCounts.count("baselineScan"), 1, "one baseline scan for the first process")

        // Quit, then edit offline: one renamed episode.
        await source.set(state(titles: ["a": "A renamed", "b": "B"]))
        let counts = LedgerCounts()
        let restarted = WiltedMacLibraryPublisher(
            source: source, transport: LedgerTransport(inner: InMemoryLibraryTransport(deviceID: "mac", server: server), counts: counts),
            sink: QuietSink(), relaysIntents: false)
        let delta = try await restarted.sync()
        XCTAssertEqual(delta.pushed, 1, "exactly the offline edit")
        XCTAssertEqual(delta.acknowledged, 1)
        XCTAssertEqual(delta.conflicts, 0)
        XCTAssertEqual(counts.count("pushedChanges"), 1, "no unchanged record is sent again")
        let unchanged = try await restarted.sync()
        XCTAssertEqual(unchanged.pushed, 0, "nothing is sent twice")
        XCTAssertEqual(counts.count("push"), 1)
        XCTAssertEqual(counts.count("baselineScan"), 1, "at most one baseline metadata scan per process")
        XCTAssertEqual(counts.count("deltaFetch"), 0)
        XCTAssertEqual(counts.media + firstCounts.media, 0, "the baseline is metadata only; no audio is fetched")
        let renamed = await server.currentSnapshot.entries[id("a")]?.title
        XCTAssertEqual(renamed, "A renamed")
    }

    func testIdleRoundsAfterARestartAreBoundedAndScanTheBaselineOnce() async throws {
        let server = InMemoryLibraryServer(writerDeviceID: "mac")
        let source = ScriptedSource(state(titles: ["a": "A"]))
        _ = try await WiltedMacLibraryPublisher(
            source: source, transport: InMemoryLibraryTransport(deviceID: "mac", server: server),
            sink: QuietSink(), relaysIntents: false).sync()

        let time = VirtualTime()
        let counts = LedgerCounts()
        let transport = LedgerTransport(inner: InMemoryLibraryTransport(deviceID: "mac", server: server), counts: counts)
        let restarted = WiltedMacLibraryPublisher(source: source, transport: transport, sink: QuietSink(), relaysIntents: false)
        let poller = WiltedMacInboundPoller(
            transport: transport, sink: QuietSink(), deviceID: "mac",
            publishRound: { _ = try? await restarted.sync(includesStats: false) },
            clock: { time.now }, sleep: { try await time.sleep(Double($0.components.seconds)) })
        await poller.start()
        await time.advance(by: 600)
        await poller.stop()

        XCTAssertEqual(counts.count("poll"), 21, "one round at start, then one per 30 s")
        XCTAssertEqual(counts.count("baselineScan"), 1, "the restart's one baseline scan, never one per round")
        XCTAssertEqual(counts.count("push"), 0, "an unchanged library sends nothing")
        XCTAssertEqual(counts.count("deltaFetch"), 0)
        XCTAssertEqual(counts.media, 0)
    }

    func testRepeatedAccountSignalsInOneProcessSeedTheBaselineOnce() async throws {
        let (model, _) = try await launch("library-status-one-baseline")
        let fixture = WiltedMacLibraryAccountFixture()
        let (_, transport, counts) = ledger("mac-baseline")
        XCTAssertTrue(model.startLibrarySyncIfEnabled(
            environment: flagOn, transport: transport, debounce: .milliseconds(10), account: fixture.source))
        fixture.signIn(recordName: "_baseline-owner-record")
        try await eventually("the bound owner's first pass") {
            model.libraryAccountStatus == .active && model.librarySyncActivity.hasFinishedPass
        }
        // The same owner reported again (a duplicate sign-in, then a confirmation) is not a new
        // account, so the publisher keeps its baseline. A real account switch reseeds by design.
        fixture.signIn(recordName: "_baseline-owner-record")
        fixture.emit(.ownershipConfirmed)
        if let task = model.syncLibraryNow() { await task.value }
        if let task = model.syncLibraryNow() { await task.value }
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(model.libraryAccountStatus, .active)
        XCTAssertEqual(counts.count("baselineScan"), 1, "one baseline metadata scan for this process")
        XCTAssertEqual(counts.count("fetchMedia"), 0)
        await shut(model)
    }
}
