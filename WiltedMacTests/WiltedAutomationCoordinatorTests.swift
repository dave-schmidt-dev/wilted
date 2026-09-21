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
    /// Downloads that fail a bounded number of times before succeeding, so a
    /// test can distinguish "retried and recovered" from "retried forever."
    var transientDownloadFailures: [String: Int] = [:]
    var downloadAttempts: [String: Int] = [:]
    /// Episodes that fail with a `WiltedAutomationNonRetryable` error every
    /// time -- the shape a claim-lost or user-cancel outcome takes once it
    /// reaches `startClaimedDownload`. `withRetries` must never retry these.
    var nonRetryableDownloadFailures: Set<String> = []

    init(claimsByFeed: [String: [String]] = [:], unfinished: [String] = [],
         transientFailures: [String: Int] = [:], downloadFailures: Set<String> = [],
         transientDownloadFailures: [String: Int] = [:], nonRetryableDownloadFailures: Set<String> = []) {
        self.claimsByFeed = claimsByFeed
        self.unfinished = unfinished
        self.transientFailures = transientFailures
        self.downloadFailures = downloadFailures
        self.transientDownloadFailures = transientDownloadFailures
        self.nonRetryableDownloadFailures = nonRetryableDownloadFailures
    }

    struct Transient: Error {}
    /// Stands in for a claim-lost (`PodcastClaimAlreadyHeld`) or user-cancel
    /// (`WiltedAutomationNonRetryableDownloadFailure`) outcome without needing
    /// the real download coordinator to produce one.
    struct NonRetryable: Error, WiltedAutomationNonRetryable {}

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
        downloadAttempts[episodeID, default: 0] += 1
        if nonRetryableDownloadFailures.contains(episodeID) { throw NonRetryable() }
        if downloadFailures.contains(episodeID) { throw Transient() }
        if let remaining = transientDownloadFailures[episodeID], remaining > 0 {
            transientDownloadFailures[episodeID] = remaining - 1
            throw Transient()
        }
        startedDownloads.append(episodeID)
    }

    func unfinishedClaims() -> [String] { unfinished }
    func attempts(for episodeID: String) -> Int { downloadAttempts[episodeID] ?? 0 }
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
                                 removeAds: true)
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

    /// Legacy download policy values remain decodable, but every automatic
    /// refresh is inert until a person keeps an episode in Larder.
    func testDownloadLimitsComeFromTheDownloadPolicy() {
        func plan(_ download: WiltedAutomationDownloadPolicy) -> WiltedAutomationPlan {
            WiltedAutomationCoordinator.plan(settings: settings(refresh: .onLaunch, download: download),
                                             trigger: .launch, lastRefreshSuccess: nil, now: origin)
        }
        XCTAssertEqual(plan(.manual).perFeedDownloadLimit, 0)
        XCTAssertNil(plan(.manual).refreshDownloadBudget)
        for legacy in [WiltedAutomationDownloadPolicy.newestOnePerEnabledFeed,
                       .newestThreePerEnabledFeed, .allNewlyAdmittedUpToTwenty] {
            XCTAssertEqual(plan(legacy).perFeedDownloadLimit, 0)
            XCTAssertNil(plan(legacy).refreshDownloadBudget)
        }

        XCTAssertEqual(WiltedAutomationPlan.idle.perFeedDownloadLimit, 0)
        XCTAssertFalse(WiltedAutomationPlan.idle.shouldRefresh)

        // No persisted legacy budget can claim an undecided episode.
        let capped = plan(.allNewlyAdmittedUpToTwenty)
        XCTAssertEqual(capped.limit(remainingBudget: 5), 0)
        XCTAssertEqual(capped.limit(remainingBudget: 0), 0)
        XCTAssertEqual(capped.limit(remainingBudget: nil), 0)
        XCTAssertEqual(plan(.newestOnePerEnabledFeed).limit(remainingBudget: nil), 0)
    }

    func testPreparationEligibilityUsesTheProcessingPolicyAndInjectedLocalTime() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        func date(hour: Int, minute: Int) -> Date {
            calendar.date(from: DateComponents(year: 2026, month: 9, day: 6, hour: hour, minute: minute))!
        }
        func window(_ startHour: Int, _ endHour: Int) throws -> WiltedAutomationOffPeakWindow {
            let start = try XCTUnwrap(WiltedAutomationLocalTime(hour: startHour, minute: 0))
            let end = try XCTUnwrap(WiltedAutomationLocalTime(hour: endHour, minute: 0))
            return try XCTUnwrap(WiltedAutomationOffPeakWindow(start: start, end: end))
        }
        func plan(_ policy: WiltedAutomationProcessingPolicy, hour: Int, minute: Int = 0) -> WiltedAutomationPreparationPlan {
            WiltedAutomationCoordinator.preparationPlan(processingPolicy: policy, at: date(hour: hour, minute: minute), calendar: calendar)
        }

        XCTAssertEqual(plan(.immediate, hour: 12), .prepareNow)
        XCTAssertEqual(plan(.manual, hour: 12), .skip)

        let sameDay = try window(2, 5)
        XCTAssertEqual(plan(.offPeak(sameDay), hour: 1, minute: 59), .deferUntilOffPeak)
        XCTAssertEqual(plan(.offPeak(sameDay), hour: 2), .prepareNow)
        XCTAssertEqual(plan(.offPeak(sameDay), hour: 4, minute: 59), .prepareNow)
        XCTAssertEqual(plan(.offPeak(sameDay), hour: 5), .deferUntilOffPeak)

        let overnight = try window(22, 6)
        XCTAssertEqual(plan(.offPeak(overnight), hour: 21, minute: 59), .deferUntilOffPeak)
        XCTAssertEqual(plan(.offPeak(overnight), hour: 22), .prepareNow)
        XCTAssertEqual(plan(.offPeak(overnight), hour: 2), .prepareNow)
        XCTAssertEqual(plan(.offPeak(overnight), hour: 6), .deferUntilOffPeak)
    }

    // MARK: - Running

    /// Refresh may admit metadata from every enabled feed but cannot claim it.
    func testAPerFeedPolicyClaimsFromEveryEnabledFeed() async {
        let spy = AutomationSpy(claimsByFeed: [
            "one.example.test": ["a", "b", "c"],
            "two.example.test": ["d"],
            "three.example.test": []
        ])
        let subject = coordinator(spy: spy, settings: settings(refresh: .onLaunch, download: .newestOnePerEnabledFeed))
        await subject.run(trigger: .launch)

        let refreshed = await spy.refreshedFeeds
        XCTAssertEqual(refreshed.map(\.limit), [0, 0, 0])
        let started = await spy.startedDownloads
        XCTAssertTrue(started.isEmpty, "undecided Feeds rows never start downloads")
    }

    /// A stored old twenty-episode policy no longer claims any Feeds rows.
    func testTheRefreshBudgetIsSpentAcrossFeedsNotPerFeed() async {
        let spy = AutomationSpy(claimsByFeed: [
            "one.example.test": (1...18).map { "one-\($0)" },
            "two.example.test": (1...5).map { "two-\($0)" },
            "three.example.test": (1...5).map { "three-\($0)" }
        ])
        let subject = coordinator(spy: spy, settings: settings(refresh: .onLaunch, download: .allNewlyAdmittedUpToTwenty))
        await subject.run(trigger: .launch)

        let refreshed = await spy.refreshedFeeds
        XCTAssertEqual(refreshed.map(\.limit), [0, 0, 0])
        let started = await spy.startedDownloads
        XCTAssertTrue(started.isEmpty)
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

    /// The coordinator resumes the claims the model has already filtered to
    /// kept Larder episodes.
    func testRelaunchResumesClaimsThatOutlivedTheirProcess() async {
        let spy = AutomationSpy(unfinished: ["stranded-one", "stranded-two"])
        let subject = coordinator(spy: spy, settings: settings(refresh: .manual))
        await subject.reconcile()

        let started = await spy.startedDownloads
        XCTAssertEqual(started, ["stranded-one", "stranded-two"])
        let refreshed = await spy.refreshedFeeds
        XCTAssertTrue(refreshed.isEmpty, "reconciliation is not a refresh")
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
        XCTAssertFalse(statuses.contains(.downloading(episode: "a", remaining: 1)))
        XCTAssertEqual(statuses.last, .finished(refreshed: 3, downloaded: 0))
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
        XCTAssertTrue(started.isEmpty)

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

    /// `drain`'s `withRetries` around `startDownload` is the same bounded
    /// exponential backoff as `refreshFeed`'s, exercised here directly rather
    /// than assumed from the feed-refresh coverage above: a download that
    /// recovers retries exactly as many times as it failed, and one that
    /// never recovers stops at the ceiling rather than looping forever.
    func testDownloadFailuresRetryWithBoundedBackoffThenGiveUpAtTheCeiling() async {
        let spy = AutomationSpy(claimsByFeed: ["one.example.test": ["a"]],
                                transientDownloadFailures: ["a": 2])
        let subject = coordinator(spy: spy, settings: settings(refresh: .onLaunch, download: .newestOnePerEnabledFeed))
        await subject.run(trigger: .launch)

        let sleeps = await spy.sleeps
        XCTAssertTrue(sleeps.isEmpty, "there is no automatic download work to retry")
        let started = await spy.startedDownloads
        XCTAssertTrue(started.isEmpty)
        let attempts = await spy.attempts(for: "a")
        XCTAssertEqual(attempts, 0)

        let exhausted = AutomationSpy(claimsByFeed: ["one.example.test": ["a"]],
                                      transientDownloadFailures: ["a": 99])
        let giveUp = coordinator(spy: exhausted, settings: settings(refresh: .onLaunch, download: .newestOnePerEnabledFeed))
        await giveUp.run(trigger: .launch)
        let boundedSleeps = await exhausted.sleeps
        XCTAssertTrue(boundedSleeps.isEmpty)
        let neverStarted = await exhausted.startedDownloads
        XCTAssertTrue(neverStarted.isEmpty)
        let exhaustedAttempts = await exhausted.attempts(for: "a")
        XCTAssertEqual(exhaustedAttempts, 0)
    }

    /// A claim-lost or user-cancel outcome (`WiltedAutomationNonRetryable`)
    /// must not be treated like the whole pass being cancelled: `withRetries`
    /// never retries it, and `drain` moves on to the next claim in the same
    /// pass rather than stopping. This is the regression the Phase 3 bug fix
    /// closes -- previously both outcomes threw `CancellationError`, which
    /// `drain`'s `catch is CancellationError` reads as "the whole automation
    /// pass stopped," abandoning every claim after the one that failed.
    func testNonRetryableDownloadFailureSkipsOnlyItsClaimAndDrainContinues() async {
        let spy = AutomationSpy(claimsByFeed: ["one.example.test": ["a", "b"]],
                                nonRetryableDownloadFailures: ["a"])
        let subject = coordinator(spy: spy, settings: settings(refresh: .onLaunch, download: .newestThreePerEnabledFeed))
        await subject.run(trigger: .launch)

        let started = await spy.startedDownloads
        XCTAssertTrue(started.isEmpty)
        let attemptsForA = await spy.attempts(for: "a")
        XCTAssertEqual(attemptsForA, 0)
        let sleeps = await spy.sleeps
        XCTAssertTrue(sleeps.isEmpty, "no backoff for a non-retryable failure")
        let statuses = await spy.statuses
        XCTAssertEqual(statuses.last, .finished(refreshed: 3, downloaded: 0))
    }

    /// One feed being unreachable is not a reason to abandon the others, and a
    /// refresh where nothing succeeded must stay eligible next time.
    func testOneUnreachableFeedDoesNotAbandonTheRest() async {
        let spy = AutomationSpy(claimsByFeed: ["two.example.test": ["b"], "three.example.test": ["c"]],
                                transientFailures: ["one.example.test": 99])
        let subject = coordinator(spy: spy, settings: settings(refresh: .onLaunch, download: .newestOnePerEnabledFeed))
        await subject.run(trigger: .launch)

        let started = await spy.startedDownloads
        XCTAssertTrue(started.isEmpty)
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
        XCTAssertTrue(started.isEmpty)
        let statuses = await spy.statuses
        XCTAssertEqual(statuses.last, .finished(refreshed: 3, downloaded: 0))
    }
}
