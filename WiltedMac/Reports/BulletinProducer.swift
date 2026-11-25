import Foundation
import os
import WiltedLibrary
import WiltedProducer

/// The Reports settings the producer reads on every poll.
struct BulletinProducerSettings: Equatable, Sendable {
    var interruptionsEnabled: Bool
    var alertsEnabled: Bool
    var headlinesEnabled: Bool
    var publishedActive = false
    /// Headlines about these topics are never read.
    var topics = HeadlineTopicFilter()
}

/// One post of a news feed, as the producer needs it.
struct NewsHeadlineCandidate: Equatable, Sendable {
    /// Stable across polls: the post's identity inside its feed.
    let id: String
    let feedTitle: String
    /// Stable identity of the feed, used for publisher actions across devices.
    var feedID: String? = nil
    let title: String
    let publishedAt: Date?
    var link: URL?
    var categories: [String] = []
}

/// Why a poll could not do its work, without being a failure to back off from: the library
/// server is not reachable yet (sync not running, account not confirmed). No network was used.
struct BulletinProducerUnavailable: Error, Equatable, Sendable {
    let reason: String
}

/// What Settings shows about the producer.
struct BulletinProducerStatus: Equatable, Sendable {
    /// A poll is running now (news feeds are being read or the channel is being written).
    var isPolling = false
    var lastPollAt: Date?
    var lastError: String?
    var consecutiveFailures = 0
    /// The library server was not reachable at the last poll; set instead of an error.
    var waitingFor: String?
    var nextPollAt: Date?
    /// Whether the channel last published, or read back at the start, has any switch on.
    /// Nil until the channel has been read once.
    var publishedActive: Bool?
    /// How many of the posts the news feeds list now are skipped by the topic list.
    var skippedHeadlineCount = 0
}

/// Publishes `LibraryBulletins` for the Mac: the switches from Settings and the headlines of
/// news feeds. Weather alerts are not published; each playing device runs its own monitor.
///
/// A poll refreshes story cards regardless of speech settings, admits fresh eligible posts in a
/// bounded pending queue, rotates published headlines through the transport limit, and writes the
/// channel only when its switches or list changed. A failed poll backs off without losing pending work.
actor BulletinProducer {
    private static let log = Logger(subsystem: "com.zerodelta.wilted.mac", category: "Bulletins")
    static let pollInterval: TimeInterval = 900
    static let maximumBackoff: TimeInterval = 3600
    /// How long the server and receiving devices keep a headline.
    static let headlineLifetime: TimeInterval = 3600
    /// When the library server is not reachable yet there is nothing to back off from; look again soon.
    static let unavailableRetry: TimeInterval = 30
    static let seenLimit = 2000

    private let heardHeadlines: @Sendable () async -> HeardHeadlineHistory.Snapshot
    private let settings: @Sendable () async -> BulletinProducerSettings
    private let newsItems: @Sendable () async throws -> [NewsHeadlineCandidate]
    private let onCandidates: @Sendable ([NewsHeadlineCandidate]) async throws -> Void
    private let fetchPublished: @Sendable () async throws -> LibraryBulletins?
    private let publish: @Sendable (LibraryBulletins) async throws -> Void
    private let onStatus: @Sendable (BulletinProducerStatus) -> Void
    private let sleep: @Sendable (TimeInterval) async throws -> Void
    private let now: @Sendable () -> Date
    private let pollInterval: TimeInterval

    private(set) var status = BulletinProducerStatus()
    private var baselineLoaded = false
    private var published: LibraryBulletins?
    private var headlines: [Bulletin] = []
    private var pendingHeadlines: [Bulletin] = []
    private var seen: Set<String> = []
    private var seenOrder: [String] = []
    private var stories = HeadlineStoryMemory()
    private var newsBaselined = false
    private var observedSettings: BulletinProducerSettings?
    private var loop: Task<Void, Never>?
    private var loopGeneration = 0

    init(settings: @escaping @Sendable () async -> BulletinProducerSettings,
         newsItems: @escaping @Sendable () async throws -> [NewsHeadlineCandidate],
         onCandidates: @escaping @Sendable ([NewsHeadlineCandidate]) async throws -> Void = { _ in },
         fetchPublished: @escaping @Sendable () async throws -> LibraryBulletins?,
         publish: @escaping @Sendable (LibraryBulletins) async throws -> Void,
         onStatus: @escaping @Sendable (BulletinProducerStatus) -> Void = { _ in },
         sleep: @escaping @Sendable (TimeInterval) async throws -> Void = { try await Task.sleep(for: .seconds($0)) },
         now: @escaping @Sendable () -> Date = { Date() },
         pollInterval: TimeInterval = BulletinProducer.pollInterval,
         heardHeadlines: @escaping @Sendable () async -> HeardHeadlineHistory.Snapshot = { .init() }) {
        self.heardHeadlines = heardHeadlines
        self.settings = settings
        self.newsItems = newsItems
        self.onCandidates = onCandidates
        self.fetchPublished = fetchPublished
        self.publish = publish
        self.onStatus = onStatus
        self.sleep = sleep
        self.now = now
        self.pollInterval = pollInterval
    }

    // MARK: - Loop

    /// Polls now, then after each delay, until stopped. Safe to call twice.
    func start() {
        guard loop == nil else { return }
        launchLoop()
    }

    func stop() {
        loop?.cancel()
        loop = nil
        loopGeneration &+= 1
    }

    /// Settings changed. Polls at once when a switch moved, unless the last poll failed:
    /// a failing poll waits out its backoff.
    func settingsChanged() async {
        let current = await settings()
        let moved = observedSettings.map {
            $0.interruptionsEnabled != current.interruptionsEnabled || $0.alertsEnabled != current.alertsEnabled
                || $0.headlinesEnabled != current.headlinesEnabled || $0.publishedActive != current.publishedActive
                || $0.topics != current.topics
        } ?? false
        observedSettings = current
        guard moved, loop != nil, status.consecutiveFailures == 0 else { return }
        loop?.cancel()
        launchLoop()
    }

    /// Reads a changed set of news feeds without altering the user's speech settings.
    func sourcesChanged() {
        guard loop != nil, status.consecutiveFailures == 0 else { return }
        loop?.cancel()
        launchLoop()
    }

    /// Withdraws unstarted headlines from a muted publisher and refreshes the channel.
    func publisherMuted(_ publisherID: String) {
        headlines.removeAll { $0.publisherID == publisherID }
        pendingHeadlines.removeAll { $0.publisherID == publisherID }
        sourcesChanged()
    }

    private func launchLoop() {
        loopGeneration &+= 1
        let generation = loopGeneration
        loop = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let delay = await self.pollThenDelay(generation: generation)
                guard let delay else { return }
                let sleeper = await self.sleepClosure()
                do { try await sleeper(delay) } catch { return }
            }
        }
    }

    private func sleepClosure() -> @Sendable (TimeInterval) async throws -> Void { sleep }

    private func pollThenDelay(generation: Int) async -> TimeInterval? {
        guard generation == loopGeneration else { return nil }
        await poll()
        guard generation == loopGeneration, !Task.isCancelled else { return nil }
        return delayUntilNextPoll()
    }

    private func delayUntilNextPoll() -> TimeInterval {
        if status.waitingFor != nil { return Self.unavailableRetry }
        guard status.consecutiveFailures > 0 else { return pollInterval }
        let factor = pow(2.0, Double(min(status.consecutiveFailures, 8)))
        return min(Self.maximumBackoff, pollInterval * factor)
    }

    // MARK: - Poll

    /// One poll. Errors never escape: they land in `status`.
    func poll() async {
        status.isPolling = true
        report()
        do {
            try await run()
            status.lastError = nil
            status.waitingFor = nil
            status.consecutiveFailures = 0
            status.lastPollAt = now()
        } catch is CancellationError {
            // Stopped or restarted mid-poll; nothing to record.
        } catch let unavailable as BulletinProducerUnavailable {
            status.waitingFor = unavailable.reason
        } catch let error as WiltedMacLibraryAccountError {
            status.waitingFor = error.description
        } catch {
            Self.log.error("bulletin check failed: \(LogSafeError.describe(error), privacy: .public)")
            status.lastError = Self.describe(error)
            status.waitingFor = nil
            status.consecutiveFailures += 1
            status.lastPollAt = now()
        }
        status.isPolling = false
        status.nextPollAt = loop == nil ? nil : now().addingTimeInterval(delayUntilNextPoll())
        report()
    }

    private func report() { onStatus(status) }

    /// The one sentence Settings shows for a failed check. The raw error is for the log only.
    static func describe(_ error: Error) -> String {
        switch ReportFailureCause.of(error) {
        case .offline: "Could not check headline feeds while this Mac is offline."
        case .timedOut: "The connection timed out while checking headline feeds."
        case .speechUnavailable, .other: "Could not check headline feeds."
        }
    }

    private func run() async throws {
        let current = await settings()
        observedSettings = current
        if !baselineLoaded, current.interruptionsEnabled {
            published = try await fetchPublished()
            baselineLoaded = true
            if let published {
                headlines = published.headlines
                for bulletin in published.headlines {
                    remember(bulletin.id)
                    stories.remember(Self.storyTitle(of: bulletin), at: bulletin.issuedAt)
                }
            }
            status.publishedActive = published.map { $0.alertsEnabled || $0.headlinesEnabled } ?? false
        }

        // Publish setting changes before waiting on RSS. Turning off interruptions must reach
        // devices even when every feed is down; the next section still refreshes quiet story cards.
        let time = now()
        headlines.removeAll { $0.isExpired(at: time) }
        pendingHeadlines.removeAll { $0.isExpired(at: time) }
        if !current.interruptionsEnabled || !current.headlinesEnabled {
            headlines = []
            pendingHeadlines = []
        }
        let settingsOnly = try LibraryBulletins(
            alertsEnabled: current.interruptionsEnabled && current.alertsEnabled,
            headlinesEnabled: current.interruptionsEnabled && current.headlinesEnabled,
            headlines: headlines,
            updatedAt: time)
        let mustClearPreviouslyActive = current.publishedActive
            && !settingsOnly.alertsEnabled && !settingsOnly.headlinesEnabled
        if Self.differs(settingsOnly, from: published) || mustClearPreviouslyActive {
            try await publish(settingsOnly)
            published = settingsOnly
            status.publishedActive = settingsOnly.alertsEnabled || settingsOnly.headlinesEnabled
        }

        // Candidate collection is independent of speech and weather switches, so Recent stays
        // current while the listener has speech turned off.
        let candidates = try await newsItems()
        try await onCandidates(candidates)

        let desired: LibraryBulletins
        if current.interruptionsEnabled {
            if current.headlinesEnabled {
                await collectHeadlines(candidates, topics: current.topics)
            }
            desired = try LibraryBulletins(alertsEnabled: current.alertsEnabled,
                                           headlinesEnabled: current.headlinesEnabled,
                                           headlines: headlines, updatedAt: time)
        } else {
            headlines = []
            desired = try LibraryBulletins(alertsEnabled: false, headlinesEnabled: false, headlines: [], updatedAt: now())
        }
        guard Self.differs(desired, from: published) else { return }
        try await publish(desired)
        published = desired
        status.publishedActive = desired.alertsEnabled || desired.headlinesEnabled
    }

    /// Whether the channel needs a write. A channel never published and wanted all-off is not written:
    /// devices read a missing channel as off.
    private static func differs(_ desired: LibraryBulletins, from published: LibraryBulletins?) -> Bool {
        guard let published else {
            return desired.alertsEnabled || desired.headlinesEnabled || !desired.headlines.isEmpty
        }
        return desired.alertsEnabled != published.alertsEnabled
            || desired.headlinesEnabled != published.headlinesEnabled
            || desired.headlines != published.headlines
    }

    // MARK: - Headlines

    private func collectHeadlines(
        _ candidates: [NewsHeadlineCandidate], topics: HeadlineTopicFilter
    ) async {
        let heard = await heardHeadlines()
        let skipped = Set(candidates.filter {
            topics.skips(title: $0.title, link: $0.link, categories: $0.categories)
        }.map(\.id))
        status.skippedHeadlineCount = skipped.count
        let time = now()
        let isBaseline = !newsBaselined
        let pendingIDs = Set(pendingHeadlines.compactMap(\.headlineStoryID))
        let activeIDs = Set(headlines.compactMap(\.headlineStoryID))
        let fresh = candidates
            .filter { !seen.contains($0.id) && !pendingIDs.contains($0.id) && !activeIDs.contains($0.id) }
            .sorted {
                let left = $0.publishedAt ?? time
                let right = $1.publishedAt ?? time
                return left == right ? $0.id < $1.id : left < right
            }
        newsBaselined = true

        var pendingStories = stories
        for bulletin in pendingHeadlines {
            pendingStories.remember(Self.storyTitle(of: bulletin), at: bulletin.issuedAt)
        }
        for candidate in fresh {
            guard !seen.contains(candidate.id) else { continue }
            guard !skipped.contains(candidate.id) else { remember(candidate.id); continue }
            if let date = candidate.publishedAt {
                guard time.timeIntervalSince(date) <= Self.headlineLifetime,
                      date.timeIntervalSince(time) < 300 else {
                    remember(candidate.id)
                    continue
                }
            } else if isBaseline {
                remember(candidate.id)
                continue
            }
            guard heard.allows(id: "headline:\(candidate.id)", title: candidate.title, at: time),
                  pendingStories.verdict(for: candidate.title, at: time) != .duplicate else {
                remember(candidate.id)
                continue
            }
            guard pendingHeadlines.count < Self.seenLimit else { continue }
            guard let bulletin = Self.bulletin(for: candidate, at: time) else {
                remember(candidate.id)
                continue
            }
            queue(bulletin, candidate: candidate, into: &pendingStories)
        }
        pendingHeadlines.sort(by: Self.pendingBefore)
        publishPendingHeadlines()
    }

    private func queue(
        _ bulletin: Bulletin,
        candidate: NewsHeadlineCandidate,
        into pendingStories: inout HeadlineStoryMemory
    ) {
        pendingHeadlines.append(bulletin)
        pendingStories.remember(candidate.title, at: bulletin.issuedAt)
        remember(candidate.id)
    }

    /// Advances the bounded channel window without evicting a headline until a successful
    /// previous publish proves that its ID reached the channel.
    private func publishPendingHeadlines() {
        guard !pendingHeadlines.isEmpty else { return }
        let capacity = LibraryBulletins.maximumHeadlines
        let freeSlots = capacity - headlines.count
        let mustRotate = max(0, pendingHeadlines.count - freeSlots)
        if mustRotate > 0 {
            let deliveredIDs = Set(published?.headlines.map(\.id) ?? [])
            let removable = headlines
                .filter { deliveredIDs.contains($0.id) }
                .sorted { Self.older($0, than: $1) }
                .prefix(mustRotate)
                .map(\.id)
            let removal = Set(removable)
            headlines.removeAll { removal.contains($0.id) }
        }
        let slots = max(0, capacity - headlines.count)
        let count = min(slots, pendingHeadlines.count)
        guard count > 0 else { return }
        let admitted = Array(pendingHeadlines.prefix(count))
        pendingHeadlines.removeFirst(count)
        for bulletin in admitted {
            headlines.append(bulletin)
            stories.remember(Self.storyTitle(of: bulletin), at: bulletin.issuedAt)
        }
        headlines.sort(by: Self.newer)
    }

    private static func newer(_ lhs: Bulletin, _ rhs: Bulletin) -> Bool {
        let left = lhs.publishedAt ?? lhs.issuedAt
        let right = rhs.publishedAt ?? rhs.issuedAt
        if left != right { return left > right }
        if lhs.issuedAt != rhs.issuedAt { return lhs.issuedAt > rhs.issuedAt }
        return lhs.id < rhs.id
    }

    private static func pendingBefore(_ lhs: Bulletin, _ rhs: Bulletin) -> Bool {
        let left = lhs.publishedAt ?? lhs.issuedAt
        let right = rhs.publishedAt ?? rhs.issuedAt
        return left == right ? lhs.id < rhs.id : left < right
    }

    private static func older(_ lhs: Bulletin, than rhs: Bulletin) -> Bool {
        let left = lhs.publishedAt ?? lhs.issuedAt
        let right = rhs.publishedAt ?? rhs.issuedAt
        if left != right { return left < right }
        if lhs.issuedAt != rhs.issuedAt { return lhs.issuedAt < rhs.issuedAt }
        return lhs.id > rhs.id
    }

    private static func storyTitle(of bulletin: Bulletin) -> String {
        bulletin.headline ?? headlineTitle(of: bulletin.text)
    }

    private static func bulletin(for candidate: NewsHeadlineCandidate, at time: Date) -> Bulletin? {
        let title = candidate.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return nil }
        let source = candidate.feedTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        let text = source.isEmpty ? title : "\(source). \(title)"
        return try? Bulletin(id: "headline:\(candidate.id)", kind: .headline,
                             text: String(text.prefix(Bulletin.maximumTextCharacters)),
                             severity: .unknown, issuedAt: time,
                             expiresAt: time.addingTimeInterval(headlineLifetime),
                             storyID: candidate.id, publisherID: candidate.feedID,
                             publisherName: source.isEmpty ? nil : String(source.prefix(200)),
                             headline: String(title.prefix(Bulletin.maximumTextCharacters)),
                             link: candidate.link, publishedAt: candidate.publishedAt)
    }

    /// The headline part of a published bulletin text, which reads "Source. Headline".
    static func headlineTitle(of text: String) -> String {
        guard let range = text.range(of: ". ") else { return text }
        return String(text[range.upperBound...])
    }

    private func remember(_ id: String) {
        guard seen.insert(id).inserted else { return }
        seenOrder.append(id)
        if seenOrder.count > Self.seenLimit {
            let overflow = seenOrder.count - Self.seenLimit
            for old in seenOrder.prefix(overflow) { seen.remove(old) }
            seenOrder.removeFirst(overflow)
        }
    }
}
