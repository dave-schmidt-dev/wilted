import XCTest
@testable import WiltedMac

/// Records what automation asked for, so a test can assert the schedule without
/// a network, a store, or real time passing.
private actor AutomationSpy {
    var refreshedFeeds: [(url: URL, limit: Int)] = []
    var startedDownloads: [String] = []
    var statuses: [WiltedAutomationStatus] = []
    var sleeps: [TimeInterval] = []
    var recordedSuccesses: [Date] = []

    /// Claims each feed hands back, keyed by host. A feed absent from this map
    /// claims nothing.
    var claimsByFeed: [String: [String]] = [:]
    var unfinished: [String] = []
    /// Feeds that fail before succeeding, so backoff has something to retry.
    var transientFailures: [String: Int] = [:]
    var downloadFailures: Set<String> = []

    init(claimsByFeed: [String: [String]] = [:], unfinished: [String] = [],
         transientFailures: [String: Int] = [:], downloadFailures: Set<String> = []) {
        self.claimsByFeed = claimsByFeed
        self.unfinished = unfinished
        self.transientFailures = transientFailures
        self.downloadFailures = downloadFailures
    }

    struct Transient: Error {}

    func refreshFeed(_ url: URL, limit: Int) throws -> [String] {
        let host = url.host ?? url.absoluteString
        if let remaining = transientFailures[host], remaining > 0 {
            transientFailures[host] = remaining - 1
            throw Transient()
        }
        refreshedFeeds.append((url, limit))
        return Array((claimsByFeed[host] ?? []).prefix(limit))
    }

    func startDownload(_ episodeID: String) throws {
        if downloadFailures.contains(episodeID) { throw Transient() }
        startedDownloads.append(episodeID)
    }

    func unfinishedClaims() -> [String] { unfinished }
    func record(_ status: WiltedAutomationStatus) { statuses.append(status) }
    func record(sleep seconds: TimeInterval) { sleeps.append(seconds) }
    func record(success date: Date) { recordedSuccesses.append(date) }
}

final class WiltedAutomationCoordinatorTests: XCTestCase {
    private let origin = Date(timeIntervalSince1970: 1_700_000_000)

    private func settings(
        refresh: WiltedAutomationRefreshPolicy, download: WiltedAutomationDownloadPolicy = .manual
    ) -> WiltedAutomationSettings {
        WiltedAutomationSettings(refreshPolicy: refresh, downloadPolicy: download,
                                 processingPolicy: .immediate, transcriptPolicy: .bestAvailable,
                                 removeAds: true, readableTranscriptPass: true)
    }

    private func coordinator(
        spy: AutomationSpy,
        settings: WiltedAutomationSettings,
        lastSuccess: Date? = nil,
        now: Date? = nil
    ) -> WiltedAutomationCoordinator {
        let clock = now ?? origin
        return WiltedAutomationCoordinator(
            operations: .init(
                enabledFeedURLs: {
                    [URL(string: "https://one.example.test/feed.xml")!,
                     URL(string: "https://two.example.test/feed.xml")!,
                     URL(string: "https://three.example.test/feed.xml")!]
                },
                refreshFeed: { url, limit in try await spy.refreshFeed(url, limit: limit) },
                startDownload: { id in try await spy.startDownload(id) },
                unfinishedClaims: { await spy.unfinishedClaims() }
            ),
            settings: { settings },
            lastRefreshSuccess: { lastSuccess },
            recordRefreshSuccess: { await spy.record(success: $0) },
            report: { await spy.record($0) },
            now: { clock },
            sleep: { await spy.record(sleep: $0) }
        )
    }

    // MARK: - Scheduling

    /// The schedule is a function of the policy, the trigger, and the persisted
    /// last success. Nothing here touches a network or a real clock.
    func testRefreshEligibilityComesFromThePolicyAndTheLastSuccess() {
        func plan(_ policy: WiltedAutomationRefreshPolicy, _ trigger: WiltedAutomationTrigger,
                  last: Date?, at offset: TimeInterval = 0) -> WiltedAutomationPlan {
            WiltedAutomationCoordinator.plan(settings: settings(refresh: policy), trigger: trigger,
                                             lastRefreshSuccess: last, now: origin.addingTimeInterval(offset))
        }

        XCTAssertFalse(plan(.manual, .launch, last: nil).shouldRefresh)
        XCTAssertFalse(plan(.manual, .openWindowTick, last: nil).shouldRefresh)

        XCTAssertTrue(plan(.onLaunch, .launch, last: nil).shouldRefresh)
        XCTAssertFalse(plan(.onLaunch, .openWindowTick, last: nil).shouldRefresh,
                       "a tick inside an open window is not a launch")

        // A first run has nothing to space itself from.
        XCTAssertTrue(plan(.whileOpen(everyHours: 6), .launch, last: nil).shouldRefresh)
        // One second short of the interval is not the interval.
        XCTAssertFalse(plan(.whileOpen(everyHours: 6), .openWindowTick,
                            last: origin, at: 6 * 3_600 - 1).shouldRefresh)
        XCTAssertTrue(plan(.whileOpen(everyHours: 6), .openWindowTick,
                           last: origin, at: 6 * 3_600).shouldRefresh)
        // A Mac that was closed for a week is eligible at the next open, once.
        XCTAssertTrue(plan(.whileOpen(everyHours: 24), .launch,
                           last: origin, at: 7 * 24 * 3_600).shouldRefresh)
        XCTAssertFalse(plan(.whileOpen(everyHours: 24), .launch,
                            last: origin, at: 23 * 3_600).shouldRefresh)
    }

    /// Every download policy maps to one bounded pair of limits, and a refresh
    /// that is not happening cannot download anything.
    func testDownloadLimitsComeFromTheDownloadPolicy() {
        func plan(_ download: WiltedAutomationDownloadPolicy) -> WiltedAutomationPlan {
            WiltedAutomationCoordinator.plan(settings: settings(refresh: .onLaunch, download: download),
                                             trigger: .launch, lastRefreshSuccess: nil, now: origin)
        }
        XCTAssertEqual(plan(.manual).perFeedDownloadLimit, 0)
        XCTAssertNil(plan(.manual).refreshDownloadBudget)
        XCTAssertEqual(plan(.newestOnePerEnabledFeed).perFeedDownloadLimit, 1)
        XCTAssertNil(plan(.newestOnePerEnabledFeed).refreshDownloadBudget)
        XCTAssertEqual(plan(.newestThreePerEnabledFeed).perFeedDownloadLimit, 3)
        XCTAssertEqual(plan(.allNewlyAdmittedUpToTwenty).perFeedDownloadLimit, 20)
        XCTAssertEqual(plan(.allNewlyAdmittedUpToTwenty).refreshDownloadBudget, 20)

        XCTAssertEqual(WiltedAutomationPlan.idle.perFeedDownloadLimit, 0)
        XCTAssertFalse(WiltedAutomationPlan.idle.shouldRefresh)

        // The budget is spent across feeds, never per feed.
        let capped = plan(.allNewlyAdmittedUpToTwenty)
        XCTAssertEqual(capped.limit(remainingBudget: 5), 5)
        XCTAssertEqual(capped.limit(remainingBudget: 0), 0)
        XCTAssertEqual(capped.limit(remainingBudget: nil), 20)
        XCTAssertEqual(plan(.newestOnePerEnabledFeed).limit(remainingBudget: nil), 1)
    }

    // MARK: - Running

    /// A per-feed policy asks each feed for its own newest episodes and never
    /// reaches past the ones that refresh admitted.
    func testAPerFeedPolicyClaimsFromEveryEnabledFeed() async {
        let spy = AutomationSpy(claimsByFeed: [
            "one.example.test": ["a", "b", "c"],
            "two.example.test": ["d"],
            "three.example.test": []
        ])
        let subject = coordinator(spy: spy, settings: settings(refresh: .onLaunch, download: .newestOnePerEnabledFeed))
        await subject.run(trigger: .launch)

        let refreshed = await spy.refreshedFeeds
        XCTAssertEqual(refreshed.map(\.limit), [1, 1, 1])
        let started = await spy.startedDownloads
        XCTAssertEqual(started, ["a", "d"], "one newest per feed, and nothing from the feed with none")
    }

    /// The twenty-episode ceiling is spent across the whole refresh, so a noisy
    /// first feed leaves less for the next one rather than every feed taking
    /// twenty.
    func testTheRefreshBudgetIsSpentAcrossFeedsNotPerFeed() async {
        let spy = AutomationSpy(claimsByFeed: [
            "one.example.test": (1...18).map { "one-\($0)" },
            "two.example.test": (1...5).map { "two-\($0)" },
            "three.example.test": (1...5).map { "three-\($0)" }
        ])
        let subject = coordinator(spy: spy, settings: settings(refresh: .onLaunch, download: .allNewlyAdmittedUpToTwenty))
        await subject.run(trigger: .launch)

        let refreshed = await spy.refreshedFeeds
        XCTAssertEqual(refreshed.map(\.limit), [20, 2, 0],
                       "eighteen taken leaves two, and then none")
        let started = await spy.startedDownloads
        XCTAssertEqual(started.count, 20)
    }

    /// A manual download policy refreshes and claims nothing, so turning
    /// automatic downloads off cannot start a transfer.
    func testAManualDownloadPolicyRefreshesWithoutDownloading() async {
        let spy = AutomationSpy(claimsByFeed: ["one.example.test": ["a"]])
        let subject = coordinator(spy: spy, settings: settings(refresh: .onLaunch, download: .manual))
        await subject.run(trigger: .launch)

        let refreshed = await spy.refreshedFeeds
        XCTAssertEqual(refreshed.map(\.limit), [0, 0, 0])
        let started = await spy.startedDownloads
        XCTAssertTrue(started.isEmpty)
    }

    /// A policy that is not due does no work and says so.
    func testAPolicyThatIsNotDueDoesNothing() async {
        let spy = AutomationSpy(claimsByFeed: ["one.example.test": ["a"]])
        let subject = coordinator(spy: spy, settings: settings(refresh: .manual, download: .newestOnePerEnabledFeed))
        await subject.run(trigger: .launch)

        let refreshed = await spy.refreshedFeeds
        let statuses = await spy.statuses
        let successes = await spy.recordedSuccesses
        XCTAssertTrue(refreshed.isEmpty)
        XCTAssertEqual(statuses, [.idle])
        XCTAssertTrue(successes.isEmpty, "a refresh that did not happen must not move the timestamp")
    }

    // MARK: - Recovery, admission, and observability

    /// A claim outlives the process that made it. The relaunch resumes it from
    /// the store rather than from anything automation persisted itself.
    func testRelaunchResumesClaimsThatOutlivedTheirProcess() async {
        let spy = AutomationSpy(unfinished: ["stranded-one", "stranded-two"])
        let subject = coordinator(spy: spy, settings: settings(refresh: .manual))
        await subject.reconcile()

        let started = await spy.startedDownloads
        XCTAssertEqual(started, ["stranded-one", "stranded-two"])
        let refreshed = await spy.refreshedFeeds
        XCTAssertTrue(refreshed.isEmpty, "reconciliation resumes work; it does not start a refresh")
    }

    /// Nothing to resume is the ordinary case and must stay silent.
    func testRelaunchWithNoClaimsSaysNothing() async {
        let spy = AutomationSpy()
        let subject = coordinator(spy: spy, settings: settings(refresh: .manual))
        await subject.reconcile()

        let statuses = await spy.statuses
        XCTAssertTrue(statuses.isEmpty)
    }

    /// Every stall-prone stage announces itself, and the run ends with a
    /// countable outcome rather than silence.
    func testEveryStageIsObservable() async {
        let spy = AutomationSpy(claimsByFeed: ["one.example.test": ["a"]])
        let subject = coordinator(spy: spy, settings: settings(refresh: .onLaunch, download: .newestOnePerEnabledFeed))
        await subject.run(trigger: .launch)

        let statuses = await spy.statuses
        XCTAssertEqual(statuses.first, .refreshing(feedsRemaining: 3))
        XCTAssertTrue(statuses.contains(.downloading(episode: "a", remaining: 1)))
        XCTAssertEqual(statuses.last, .finished(refreshed: 3, downloaded: 1))
    }

    /// A transient failure is retried with growing waits and a hard ceiling. An
    /// automatic loop that never gives up hammers a feed host from a machine
    /// nobody is watching.
    func testTransientFailuresRetryWithBoundedBackoff() async {
        let spy = AutomationSpy(claimsByFeed: ["one.example.test": ["a"]],
                                transientFailures: ["one.example.test": 2])
        let subject = coordinator(spy: spy, settings: settings(refresh: .onLaunch, download: .newestOnePerEnabledFeed))
        await subject.run(trigger: .launch)

        let sleeps = await spy.sleeps
        XCTAssertEqual(sleeps, [2, 4], "two failures, two growing waits, then success")
        let started = await spy.startedDownloads
        XCTAssertEqual(started, ["a"])

        let exhausted = AutomationSpy(claimsByFeed: ["one.example.test": ["a"]],
                                      transientFailures: ["one.example.test": 99])
        let giveUp = coordinator(spy: exhausted, settings: settings(refresh: .onLaunch, download: .newestOnePerEnabledFeed))
        await giveUp.run(trigger: .launch)
        let boundedSleeps = await exhausted.sleeps
        XCTAssertEqual(boundedSleeps.count, WiltedAutomationCoordinator.maximumRetries,
                       "the ceiling holds; the feed is left alone until the next trigger")
        let neverStarted = await exhausted.startedDownloads
        XCTAssertTrue(neverStarted.isEmpty)
    }

    /// One feed being unreachable is not a reason to abandon the others, and a
    /// refresh where nothing succeeded must stay eligible next time.
    func testOneUnreachableFeedDoesNotAbandonTheRest() async {
        let spy = AutomationSpy(claimsByFeed: ["two.example.test": ["b"], "three.example.test": ["c"]],
                                transientFailures: ["one.example.test": 99])
        let subject = coordinator(spy: spy, settings: settings(refresh: .onLaunch, download: .newestOnePerEnabledFeed))
        await subject.run(trigger: .launch)

        let started = await spy.startedDownloads
        XCTAssertEqual(started, ["b", "c"])
        let successes = await spy.recordedSuccesses
        XCTAssertEqual(successes, [origin], "two feeds succeeded, so the timestamp moves")

        let allDown = AutomationSpy(transientFailures: [
            "one.example.test": 99, "two.example.test": 99, "three.example.test": 99
        ])
        let outage = coordinator(spy: allDown, settings: settings(refresh: .onLaunch, download: .newestOnePerEnabledFeed))
        await outage.run(trigger: .launch)
        let noSuccess = await allDown.recordedSuccesses
        XCTAssertTrue(noSuccess.isEmpty, "a total outage must not look like a successful refresh")
    }

    /// A download that will not start leaves its claim behind rather than
    /// blocking the rest of the pass. The next launch reconciles it.
    func testAFailedDownloadLeavesItsClaimForTheNextLaunch() async {
        let spy = AutomationSpy(claimsByFeed: ["one.example.test": ["a"], "two.example.test": ["b"]],
                                downloadFailures: ["a"])
        let subject = coordinator(spy: spy, settings: settings(refresh: .onLaunch, download: .newestOnePerEnabledFeed))
        await subject.run(trigger: .launch)

        let started = await spy.startedDownloads
        XCTAssertEqual(started, ["b"], "the pass continues past the episode that would not start")
        let statuses = await spy.statuses
        XCTAssertEqual(statuses.last, .finished(refreshed: 3, downloaded: 1))
    }
}
