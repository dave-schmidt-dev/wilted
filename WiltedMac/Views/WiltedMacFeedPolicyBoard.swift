import Foundation
import Observation
import WiltedDomain
import WiltedProducer

// MARK: - Board

/// Per-feed automation policies as the Feeds page needs them, read and written
/// through the library store.
///
/// The model keeps no copy of a feed's policy, so this board holds the loaded
/// values for the views. A choice shows at once and is written in order; the
/// board never edits a value it has not loaded, so a failed read cannot be
/// overwritten with defaults. Reload reads into a temporary snapshot and only
/// replaces the last committed values after every read succeeds. `reload()`
/// and `settle()` are awaitable so callers do not race reads or writes.
@MainActor @Observable
final class WiltedMacFeedPolicyBoard {
    let model: WiltedMacModel
    private(set) var policies: [String: FeedAutomationPolicy] = [:]
    private(set) var failedFeedIDs: Set<String> = []
    private(set) var loadState: LoadState = .idle
    /// The feeds that list posts rather than audio, and which of them the reader treats as news.
    private(set) var articleFeedIDs: Set<String> = []
    private(set) var newsFeedIDs: Set<String> = []
    @ObservationIgnored private var rules: [String: EpisodeMatchRules] = [:]
    @ObservationIgnored private var editors: [String: WiltedMacFeedRulesEditor] = [:]
    @ObservationIgnored private var writeChain: Task<Void, Never>?
    @ObservationIgnored private var activeReloadID: UUID?
    @ObservationIgnored private var mutationRevision: UInt64 = 0
    @ObservationIgnored var reloadReadHookForTesting: (@MainActor () async -> Void)?
    @ObservationIgnored var afterFeedPolicyReadHookForTesting: (@MainActor (String) async throws -> Void)?
    @ObservationIgnored var beforeFeedPolicySaveHookForTesting: (@MainActor (String) async throws -> Void)?

    enum LoadState: Equatable {
        case idle, loading, loaded, failed(String)
    }

    var isLoading: Bool {
        if case .loading = loadState { return true }
        return false
    }

    var canRetry: Bool {
        guard !isLoading else { return false }
        if model.store != nil { return true }
        if case let .failed(failure) = model.startupState { return failure.canRetry }
        return true
    }

    init(model: WiltedMacModel) {
        self.model = model
    }

    var loadFailureMessage: String? {
        guard case let .failed(message) = loadState else { return nil }
        return message
    }

    func isLoaded(_ feedID: String) -> Bool { policies[feedID] != nil }

    func policy(for feedID: String) -> FeedAutomationPolicy { policies[feedID] ?? FeedAutomationPolicy() }

    /// The feed's choices resolved against the same global defaults admission uses.
    func resolved(for feedID: String) -> EffectiveFeedAutomationPolicy {
        policy(for: feedID).resolved(using: model.automationSettings.feedAutomationDefaults)
    }

    func summary(for feedID: String) -> [WiltedFeedAutomationSummary.Row] {
        WiltedFeedAutomationSummary.rows(resolved(for: feedID))
    }

    /// Reads every subscription's policy and match rules from the store.
    /// A failed or unavailable read remains visible so no default can look like saved capacity.
    func reload() async {
        let reloadID = UUID()
        activeReloadID = reloadID
        loadState = .loading
        await settle()
        do {
            guard isActiveReload(reloadID) else { return }
            let store = try await availableStore()
            await settle()
            let readRevision = mutationRevision
            await reloadReadHookForTesting?()
            var loaded: [String: FeedAutomationPolicy] = [:]
            var loadedRules: [String: EpisodeMatchRules] = [:]
            for subscription in model.subscriptions {
                guard isActiveReload(reloadID) else { return }
                let feedID: ItemID
                do {
                    feedID = try ItemID(rawValue: subscription.id)
                } catch {
                    throw LoadError.invalidFeedIdentifier(subscription.title)
                }
                do {
                    loaded[subscription.id] = try await store.feedAutomationPolicy(for: feedID)
                    try await afterFeedPolicyReadHookForTesting?(subscription.id)
                    loadedRules[subscription.id] = try await store.episodeMatchRules(for: feedID)
                } catch let error as CancellationError {
                    throw error
                } catch {
                    if Task.isCancelled { throw CancellationError() }
                    throw LoadError.feedRead(subscription.title, error.localizedDescription)
                }
            }
            let articleFeeds: [ArticleFeed]
            do {
                articleFeeds = try await store.articleFeeds()
            } catch let error as CancellationError {
                throw error
            } catch {
                if Task.isCancelled { throw CancellationError() }
                throw LoadError.articleRead(error.localizedDescription)
            }
            var news: Set<String> = []
            for feed in articleFeeds {
                guard isActiveReload(reloadID) else { return }
                do {
                    if try await store.isNews(feedID: feed.itemID) { news.insert(feed.itemID.rawValue) }
                } catch let error as CancellationError {
                    throw error
                } catch {
                    if Task.isCancelled { throw CancellationError() }
                    throw LoadError.articleRead(error.localizedDescription)
                }
            }
            await settle()
            guard isActiveReload(reloadID) else { return }
            guard mutationRevision == readRevision else {
                // A write landed during this read. Its optimistic value and durable write win;
                // start a fresh read after the write settles instead of publishing stale data.
                await reload()
                return
            }
            policies = loaded
            rules = loadedRules
            articleFeedIDs = Set(articleFeeds.map(\.itemID.rawValue))
            newsFeedIDs = news
            loadState = .loaded
        } catch is CancellationError {
            guard activeReloadID == reloadID else { return }
            activeReloadID = nil
            loadState = .idle
        } catch {
            guard activeReloadID == reloadID else { return }
            loadState = .failed(error.localizedDescription)
        }
    }

    private func isActiveReload(_ reloadID: UUID) -> Bool {
        guard activeReloadID == reloadID else { return false }
        guard !Task.isCancelled else {
            activeReloadID = nil
            loadState = .idle
            return false
        }
        return true
    }

    /// Retries store bootstrap when it failed, then reloads the board.
    func retryReload() async {
        if case .failed = model.startupState {
            model.retryStoreBootstrap()
            await model.waitForStoreBootstrap()
        }
        await reload()
    }

    private func availableStore() async throws -> LocalLibraryStore {
        if model.store == nil {
            switch model.startupState {
            case .loading:
                model.startStoreBootstrap()
                await model.waitForStoreBootstrap()
            case let .failed(failure):
                throw LoadError.startup(failure.message)
            case .ready:
                throw LoadError.storeUnavailable
            }
        }
        guard let store = model.store else {
            if case let .failed(failure) = model.startupState { throw LoadError.startup(failure.message) }
            throw LoadError.storeUnavailable
        }
        return store
    }

    private enum LoadError: LocalizedError {
        case storeUnavailable
        case startup(String)
        case invalidFeedIdentifier(String)
        case feedRead(String, String)
        case articleRead(String)

        var errorDescription: String? {
            switch self {
            case .storeUnavailable:
                "The saved library is not available yet. Retry the capacity check."
            case let .startup(message):
                "\(message) Retry the capacity check when the library is ready."
            case let .invalidFeedIdentifier(title):
                "Could not load capacity for \(title): invalid feed identifier."
            case let .feedRead(title, detail):
                "Could not load saved settings for \(title): \(detail)"
            case let .articleRead(detail):
                "Could not load article feed settings: \(detail)"
            }
        }
    }

    // MARK: News flag

    func isArticleFeed(_ feedID: String) -> Bool { articleFeedIDs.contains(feedID) }

    func isNews(_ feedID: String) -> Bool { newsFeedIDs.contains(feedID) }

    /// Marks an article feed as news (or not). Returns false, changing nothing, for a feed that is
    /// not loaded or does not list articles.
    @discardableResult
    func setNews(_ value: Bool, for feedID: String) -> Bool {
        guard isLoaded(feedID), isArticleFeed(feedID) else { return false }
        mutationRevision &+= 1
        if value { newsFeedIDs.insert(feedID) } else { newsFeedIDs.remove(feedID) }
        failedFeedIDs.remove(feedID)
        let previous = writeChain
        writeChain = Task { [weak self] in
            await previous?.value
            await self?.persist(isNews: value, feedID)
        }
        return true
    }

    private func persist(isNews value: Bool, _ feedID: String) async {
        guard let store = model.store, !model.isClosingTemporaryState,
              let id = try? ItemID(rawValue: feedID) else { return }
        do {
            try await store.save(isNews: value, feedID: id)
        } catch {
            failedFeedIDs.insert(feedID)
            if (try? await store.isNews(feedID: id)) == true { newsFeedIDs.insert(feedID) } else { newsFeedIDs.remove(feedID) }
        }
    }

    /// Fills the board without a store, so a preview or snapshot can render a given state.
    func loadForPreview(feedID: String, policy: FeedAutomationPolicy = FeedAutomationPolicy(),
                        isArticleFeed: Bool, isNews: Bool) {
        policies[feedID] = policy
        loadState = .loaded
        if isArticleFeed { articleFeedIDs.insert(feedID) }
        if isNews { newsFeedIDs.insert(feedID) }
    }

    // MARK: Match rules

    /// The feed's saved rules, in order.
    func rules(for feedID: String) -> EpisodeMatchRules { rules[feedID] ?? EpisodeMatchRules() }

    /// The feed's rules editor, kept so a draft survives closing the popover.
    func rulesEditor(for feedID: String) -> WiltedMacFeedRulesEditor {
        if let editor = editors[feedID] { return editor }
        let editor = WiltedMacFeedRulesEditor(board: self, feedID: feedID)
        editors[feedID] = editor
        return editor
    }

    /// Saves a feed's whole ordered rule set. Returns false, changing nothing,
    /// when the feed is not loaded or a pattern is invalid.
    @discardableResult
    func replaceRules(_ next: EpisodeMatchRules, for feedID: String) -> Bool {
        guard isLoaded(feedID), (try? next.validate()) != nil else { return false }
        mutationRevision &+= 1
        rules[feedID] = next
        failedFeedIDs.remove(feedID)
        let previous = writeChain
        writeChain = Task { [weak self] in
            await previous?.value
            await self?.persist(rules: next, feedID)
        }
        return true
    }

    private func persist(rules next: EpisodeMatchRules, _ feedID: String) async {
        guard let store = model.store, !model.isClosingTemporaryState,
              let id = try? ItemID(rawValue: feedID) else { return }
        do {
            try await store.replaceEpisodeMatchRules(next, for: id)
        } catch {
            failedFeedIDs.insert(feedID)
            if let stored = try? await store.episodeMatchRules(for: id) { rules[feedID] = stored }
        }
    }

    /// Waits for every accepted choice to reach the store.
    func settle() async {
        while let pending = writeChain {
            await pending.value
            if writeChain == pending { writeChain = nil }
        }
    }

    /// Applies one or more choices to a feed. Returns false, changing nothing,
    /// when the feed is not loaded or a kept limit is below one.
    @discardableResult
    func update(
        _ feedID: String,
        autoKeep: FeedAutomationOverride? = nil,
        autoDownload: FeedAutomationOverride? = nil,
        autoPrepare: FeedAutomationOverride? = nil,
        keptLimit: FeedKeptLimitOverride? = nil
    ) -> Bool {
        guard let current = policies[feedID] else { return false }
        if case let .explicit(count)? = keptLimit, count < 1 { return false }
        let next = FeedAutomationPolicy(
            autoKeep: autoKeep ?? current.autoKeep, autoDownload: autoDownload ?? current.autoDownload,
            autoPrepare: autoPrepare ?? current.autoPrepare, keptLimit: keptLimit ?? current.keptLimit
        )
        guard next != current else { return true }
        mutationRevision &+= 1
        policies[feedID] = next
        failedFeedIDs.remove(feedID)
        // Only a change to what may be kept can open or close places.
        let changesCapacity = next.autoKeep != current.autoKeep || next.keptLimit != current.keptLimit
        let previous = writeChain
        writeChain = Task { [weak self] in
            await previous?.value
            await self?.persist(feedID, from: current, to: next, releasing: changesCapacity)
        }
        return true
    }

    private func persist(
        _ feedID: String, from prior: FeedAutomationPolicy, to policy: FeedAutomationPolicy, releasing: Bool
    ) async {
        guard let store = model.store, !model.isClosingTemporaryState,
              let id = try? ItemID(rawValue: feedID) else { return }
        // What this save changes is measured from the last saved policy, not the
        // optimistic value the edit saw: an earlier queued save may have failed.
        // Writes are serialized, so this read is the last saved state.
        let saved = (try? await store.feedAutomationPolicy(for: id)) ?? prior
        do {
            try await beforeFeedPolicySaveHookForTesting?(feedID)
            try await store.save(feedAutomationPolicy: policy, for: id)
        } catch {
            failedFeedIDs.insert(feedID)
            if let stored = try? await store.feedAutomationPolicy(for: id) { policies[feedID] = stored }
            return
        }
        // A raised limit, or Auto keep switched on, fills open places now,
        // through the same admission a refresh uses. Nothing is ever removed.
        if releasing { await model.releaseWaitingEpisodes(feedIDs: [feedID]) }
        // Auto download or Auto prepare switched on acts on the episodes the
        // feed already keeps, after any release so newly kept ones are not
        // started twice. Switching either off leaves issued work alone.
        model.startKeptEpisodeWork(feedID: feedID, from: saved, to: policy)
    }

    // MARK: Waiting for space

    /// Episodes the admission planner holds back because the feed is full,
    /// oldest first. Empty unless the feed resolves to Auto keep with a limit.
    func waitingEpisodes(forFeed feedID: String) -> [WiltedMacEpisode] {
        guard isLoaded(feedID) else { return [] }
        let policy = resolved(for: feedID)
        guard policy.autoKeep, policy.keptLimit != nil else { return [] }
        let live = model.episodes.filter { $0.feedID == feedID && $0.removalKind == nil }
        let kept = Set(model.podcastQueueIDs).intersection(live.map(\.id))
        let feedRules = rules[feedID] ?? EpisodeMatchRules()
        let candidates = model.feedsEpisodes.filter { episode in
            guard episode.feedID == feedID, episode.removalKind == nil, !episode.isPlayed else { return false }
            // A rule decides its own episodes; only the rest reach the planner.
            guard case .noMatch? = try? feedRules.evaluate(
                .init(id: episode.id, title: episode.title, notes: episode.notes ?? "")
            ) else { return false }
            return true
        }
        let byID = Dictionary(candidates.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return FeedAdmissionPlanner.plan(
            candidates: candidates.map { .init(id: $0.id, releaseDate: $0.releasedAt) },
            keptEpisodeIDs: kept, playingEpisodeID: nil, partHeardEpisodeIDs: [],
            manualDecisions: [:], policy: policy
        ).filter { $0.outcome == .wait }.compactMap { byID[$0.candidate.id] }
    }

    /// The IDs waiting for space across every loaded feed.
    var waitingEpisodeIDs: Set<String> {
        Set(policies.keys.flatMap { waitingEpisodes(forFeed: $0).map(\.id) })
    }
}

extension WiltedMacFeedPolicyBoard {
    /// How many of the feed's episodes are kept in Larder right now.
    func keptCount(forFeed feedID: String) -> Int {
        let queued = Set(model.podcastQueueIDs)
        return model.episodes.filter { $0.feedID == feedID && $0.removalKind == nil && queued.contains($0.id) }.count
    }
}

