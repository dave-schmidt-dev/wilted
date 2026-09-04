import Foundation

/// What prompted an automation evaluation.
///
/// Wilted automates only while it is open, so these are the two moments it can
/// notice: the window opening, and a timer inside a window that is already
/// open. A closed app and a sleeping Mac do no work, and a missed interval
/// becomes eligible at the next one of these rather than being made up.
enum WiltedAutomationTrigger: Equatable, Sendable {
    case launch
    case openWindowTick
}

/// One evaluation's decision, as data.
///
/// Separating the decision from the work is what makes the schedule testable
/// without a store, a network, or a clock that moves on its own.
struct WiltedAutomationPlan: Equatable, Sendable {
    let shouldRefresh: Bool
    /// How many of one feed's newly admitted episodes this refresh may claim.
    let perFeedDownloadLimit: Int
    /// The ceiling across the whole refresh. `nil` means the per-feed limit is
    /// the only bound, which is what the per-feed policies ask for.
    let refreshDownloadBudget: Int?

    static let idle = WiltedAutomationPlan(shouldRefresh: false, perFeedDownloadLimit: 0,
                                           refreshDownloadBudget: nil)

    /// What one feed may claim given what earlier feeds in the same refresh took.
    func limit(remainingBudget: Int?) -> Int {
        guard let remainingBudget else { return perFeedDownloadLimit }
        return max(0, min(perFeedDownloadLimit, remainingBudget))
    }
}

/// What automation is doing, for a surface to show and a listener to stop.
enum WiltedAutomationStatus: Equatable, Sendable {
    case idle
    case refreshing(feedsRemaining: Int)
    case downloading(episode: String, remaining: Int)
    case retrying(afterSeconds: TimeInterval, attempt: Int)
    case failed(String)
    case cancelled
    case finished(refreshed: Int, downloaded: Int)
}

/// Policy evaluation, scheduling metadata, serialised admission, retry, and
/// cancellation for app-open automation.
///
/// It deliberately owns none of the truth it acts on. Whether an episode is
/// downloaded, preparing, or failed is `LocalLibraryStore`'s answer and the
/// preparation journal's; duplicating it here would create a second version of
/// the same fact that can disagree after a crash. What this owns is the
/// decision to start work and the claim that stops two callers starting it
/// twice.
actor WiltedAutomationCoordinator {
    /// The work automation performs, injected so scheduling can be tested
    /// without a network, a store, or real time passing.
    struct Operations: Sendable {
        /// Feeds eligible for automatic refresh, in a stable order.
        var enabledFeedURLs: @Sendable () async throws -> [URL]
        /// Refreshes one feed and claims up to `limit` of the episodes that
        /// exact refresh admitted, in the same store save. Returns the claimed
        /// episode IDs.
        var refreshFeed: @Sendable (URL, Int) async throws -> [String]
        /// Starts one claimed episode's download. Idempotent per episode.
        var startDownload: @Sendable (String) async throws -> Void
        /// Claims that outlived the process that made them.
        var unfinishedClaims: @Sendable () async throws -> [String]
    }

    /// How many times a transient failure is retried, and how long the waits
    /// grow. Bounded because an automatic loop that never gives up is a way to
    /// hammer a feed host from a machine nobody is watching.
    static let maximumRetries = 3
    static let baseRetryDelay: TimeInterval = 2

    private let operations: Operations
    private let now: @Sendable () -> Date
    private let settings: @Sendable () async -> WiltedAutomationSettings
    private let lastRefreshSuccess: @Sendable () async -> Date?
    private let recordRefreshSuccess: @Sendable (Date) async -> Void
    private let report: @Sendable (WiltedAutomationStatus) async -> Void
    private let sleep: @Sendable (TimeInterval) async throws -> Void

    private var running: Task<Void, Never>?

    init(
        operations: Operations,
        settings: @escaping @Sendable () async -> WiltedAutomationSettings,
        lastRefreshSuccess: @escaping @Sendable () async -> Date?,
        recordRefreshSuccess: @escaping @Sendable (Date) async -> Void,
        report: @escaping @Sendable (WiltedAutomationStatus) async -> Void,
        now: @escaping @Sendable () -> Date = Date.init,
        sleep: @escaping @Sendable (TimeInterval) async throws -> Void = { seconds in
            try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
        }
    ) {
        self.operations = operations
        self.settings = settings
        self.lastRefreshSuccess = lastRefreshSuccess
        self.recordRefreshSuccess = recordRefreshSuccess
        self.report = report
        self.now = now
        self.sleep = sleep
    }

    // MARK: - Decision

    /// Whether this trigger should refresh, and how much it may download.
    ///
    /// `onLaunch` refreshes on each launch, which is what the setting says. The
    /// persisted timestamp is what stops an interval tick repeating work the
    /// launch already did, and what makes a missed interval eligible at the next
    /// open rather than immediately overdue forever.
    static func plan(
        settings: WiltedAutomationSettings,
        trigger: WiltedAutomationTrigger,
        lastRefreshSuccess: Date?,
        now: Date
    ) -> WiltedAutomationPlan {
        let shouldRefresh: Bool
        switch settings.refreshPolicy {
        case .manual:
            shouldRefresh = false
        case .onLaunch:
            shouldRefresh = trigger == .launch
        case let .whileOpen(everyHours: hours):
            guard let last = lastRefreshSuccess else {
                shouldRefresh = true
                break
            }
            shouldRefresh = now.timeIntervalSince(last) >= Double(hours) * 3_600
        }
        guard shouldRefresh else { return .idle }
        let perFeed: Int
        switch settings.downloadPolicy {
        case .manual: perFeed = 0
        case .newestOnePerEnabledFeed: perFeed = 1
        case .newestThreePerEnabledFeed: perFeed = 3
        case .allNewlyAdmittedUpToTwenty: perFeed = 20
        }
        return WiltedAutomationPlan(
            shouldRefresh: true,
            perFeedDownloadLimit: perFeed,
            refreshDownloadBudget: settings.downloadPolicy.maximumEpisodesPerRefresh
        )
    }

    // MARK: - Running

    /// Evaluates and, if the policy allows, runs one refresh-and-download pass.
    ///
    /// At most one pass runs at a time. A second call while a pass is in flight
    /// is a no-op rather than a queue, because the pass it would duplicate is
    /// already claiming the episodes it would claim.
    func run(trigger: WiltedAutomationTrigger) async {
        guard running == nil else { return }
        let task = Task { await self.performPass(trigger: trigger) }
        running = task
        await task.value
        running = nil
    }

    /// Stops the pass in flight. The claims it already made stay durable, and
    /// the next launch reconciles them.
    func cancel() {
        running?.cancel()
    }

    /// Resumes claims that outlived the process that made them.
    ///
    /// A claim is durable and a running download is not, so a crash mid-transfer
    /// leaves a `queued` or `downloading` record with nothing behind it. The
    /// store is the only thing that knows which episodes those are.
    func reconcile() async {
        let claims: [String]
        do {
            claims = try await operations.unfinishedClaims()
        } catch {
            await report(.failed(Self.failureLabel))
            return
        }
        guard !claims.isEmpty else { return }
        await drain(claims)
    }

    private func performPass(trigger: WiltedAutomationTrigger) async {
        let plan = Self.plan(settings: await settings(), trigger: trigger,
                             lastRefreshSuccess: await lastRefreshSuccess(), now: now())
        guard plan.shouldRefresh else {
            await report(.idle)
            return
        }
        let feeds: [URL]
        do {
            feeds = try await withRetries { try await self.operations.enabledFeedURLs() }
        } catch is CancellationError {
            await report(.cancelled)
            return
        } catch {
            await report(.failed(Self.failureLabel))
            return
        }

        var remaining = plan.refreshDownloadBudget
        var claimed: [String] = []
        var refreshed = 0
        for (index, feed) in feeds.enumerated() {
            if Task.isCancelled {
                await report(.cancelled)
                return
            }
            await report(.refreshing(feedsRemaining: feeds.count - index))
            let limit = plan.limit(remainingBudget: remaining)
            do {
                let feedClaims = try await withRetries { try await self.operations.refreshFeed(feed, limit) }
                refreshed += 1
                claimed.append(contentsOf: feedClaims)
                if let budget = remaining { remaining = max(0, budget - feedClaims.count) }
            } catch is CancellationError {
                await report(.cancelled)
                return
            } catch {
                // One unreachable feed is not a reason to abandon the others.
                // The refresh timestamp below still moves only if something
                // succeeded, so a total outage stays eligible next time.
                continue
            }
        }
        if refreshed > 0 { await recordRefreshSuccess(now()) }
        let downloaded = await drain(claimed)
        if Task.isCancelled {
            await report(.cancelled)
        } else {
            await report(.finished(refreshed: refreshed, downloaded: downloaded))
        }
    }

    /// Starts each claimed episode in turn.
    ///
    /// Serial on purpose. The claims are already durable, so nothing is lost by
    /// taking them one at a time, and a listener on a domestic connection would
    /// rather have one episode finish than six crawl.
    @discardableResult
    private func drain(_ claims: [String]) async -> Int {
        var completed = 0
        for (index, episodeID) in claims.enumerated() {
            if Task.isCancelled { return completed }
            await report(.downloading(episode: episodeID, remaining: claims.count - index))
            do {
                try await withRetries { try await self.operations.startDownload(episodeID) }
                completed += 1
            } catch is CancellationError {
                return completed
            } catch {
                // The claim stays. A later launch reconciles it rather than
                // this pass blocking on one episode.
                continue
            }
        }
        return completed
    }

    /// Bounded exponential backoff.
    ///
    /// Cancellation is not a transient failure and is rethrown immediately, so a
    /// stop request does not wait out a backoff first.
    private func withRetries<T>(_ work: @Sendable () async throws -> T) async throws -> T {
        var attempt = 0
        while true {
            do {
                return try await work()
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                attempt += 1
                guard attempt <= Self.maximumRetries, !Task.isCancelled else { throw error }
                let delay = Self.baseRetryDelay * pow(2, Double(attempt - 1))
                await report(.retrying(afterSeconds: delay, attempt: attempt))
                try await sleep(delay)
            }
        }
    }

    /// What a surface says when automation could not finish. The cause belongs
    /// in the log and on Prep, not in a banner the listener cannot act on.
    static let failureLabel = "Automatic updates could not finish. They will try again."
}
