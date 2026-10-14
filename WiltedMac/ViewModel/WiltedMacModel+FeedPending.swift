import Foundation

/// Where one feed stands in the refresh in flight. A row that is not in the table is idle.
enum WiltedMacFeedRefreshState: Equatable, Sendable {
    case queued, refreshing, done, failed
}

/// A durable write the feed's row is waiting on. `updating` carries the value being saved.
enum WiltedMacFeedWrite: Equatable, Sendable {
    case updating(enabled: Bool)
    case removing
}

extension WiltedMacModel {
    /// What the feed's row says it is doing, or nil when it is idle. A pending write outranks a
    /// refresh state because it is the one the listener's last tap started.
    func feedRowStatus(_ feedID: String) -> String? {
        switch pendingFeedWrites[feedID] {
        case .updating: return "Saving…"
        case .removing: return "Removing…"
        case nil: break
        }
        switch feedRefreshStates[feedID] {
        case .queued: return "Waiting to refresh"
        case .refreshing: return "Refreshing…"
        case .done: return "Refreshed"
        case .failed: return "Could not refresh. Retry Refresh."
        case nil: return nil
        }
    }

    func isFeedWritePending(_ feedID: String) -> Bool { pendingFeedWrites[feedID] != nil }

    // MARK: - Optimistic Show episodes

    /// The enabled value this feed projects right now: a queued tap outranks
    /// the write in flight, and both outrank the loaded row. Nil when idle.
    func projectedFeedEnabled(_ feedID: String) -> Bool? {
        if let queued = queuedFeedEnabled[feedID] { return queued }
        if let projection = feedEnabledProjections[feedID] { return projection.projected }
        if case let .updating(enabled)? = pendingFeedWrites[feedID] { return enabled }
        return nil
    }

    /// Applies the pending projection to a loaded subscription row, preserving
    /// every other field the snapshot carries.
    func applyingPendingFeedEnabled(_ row: WiltedMacSubscription) -> WiltedMacSubscription {
        guard let enabled = projectedFeedEnabled(row.id), enabled != row.enabled else { return row }
        var value = row
        value.enabled = enabled
        return value
    }

    /// Projects the toggle's value on the loaded row and on the feed's rows in
    /// the Larder, both before the durable write starts and for every coalesced
    /// tap that arrives while it runs. Only this feed's row and episodes move.
    func projectFeedEnabled(_ feedID: String, enabled: Bool) {
        if let index = subscriptions.firstIndex(where: { $0.id == feedID }) {
            subscriptions[index].enabled = enabled
        }
        guard var projection = feedEnabledProjections[feedID] else { return }
        projection.projected = enabled
        if enabled {
            if !projection.withheldEpisodes.isEmpty {
                let present = Set(episodes.map(\.id))
                episodes.append(contentsOf: projection.withheldEpisodes.filter { !present.contains($0.id) })
                projection.withheldEpisodes = []
            }
        } else {
            let withheld = episodes.filter { $0.feedID == feedID }
            if !withheld.isEmpty {
                projection.withheldEpisodes = withheld
                let ids = Set(withheld.map(\.id))
                episodes.removeAll { ids.contains($0.id) }
            }
        }
        feedEnabledProjections[feedID] = projection
    }

#if canImport(WiltedProducer)
    /// Rejects library snapshots that began before this projection, the same
    /// way a feed rename does, so a load already in flight cannot republish the
    /// pre-toggle row or its episodes.
    func invalidateProjectedLibraryReads() {
        libraryReadEpoch &+= 1
        lastAppliedLibraryReadEpoch = libraryReadEpoch
    }
#endif

    /// Ends a refresh for every row: queued and refreshing rows stop, finished rows go back to idle,
    /// and a failed row stays so the listener can see which feed to retry.
    func settleFeedRefreshStates() {
        feedRefreshStates = feedRefreshStates.filter { $0.value == .failed }
    }

    /// Marks a feed in the refresh in flight. A row the refresh never queued, or one a cancel already
    /// settled, is left alone, so a late answer cannot repaint it.
    func markFeedRefresh(forURL url: URL, _ state: WiltedMacFeedRefreshState) {
        guard let id = subscriptions.first(where: { $0.feedURL == url })?.id,
              feedRefreshStates[id] != nil else { return }
        feedRefreshStates[id] = state
    }

    /// Queues every subscribed feed in `urls`, before the first request is made.
    func queueFeedRefresh(for urls: [URL]) {
        feedRefreshStates = [:]
        for url in urls {
            if let id = subscriptions.first(where: { $0.feedURL == url })?.id { feedRefreshStates[id] = .queued }
        }
    }

    // MARK: - Last refreshed

    /// "2 hours ago", or "Never" before the first successful refresh.
    func lastPodcastRefreshRelativeText(now: Date = Date()) -> String {
        guard let lastPodcastRefreshAt else { return "Never" }
        let formatter = RelativeDateTimeFormatter()
        formatter.dateTimeStyle = .named
        formatter.unitsStyle = .full
        return formatter.localizedString(for: lastPodcastRefreshAt, relativeTo: now)
    }

    /// The exact date the relative text stands for, for VoiceOver and the hover help.
    var lastPodcastRefreshExactText: String {
        guard let lastPodcastRefreshAt else { return "Podcasts have not been refreshed yet." }
        return "Last refreshed " + lastPodcastRefreshAt.formatted(date: .complete, time: .standard)
    }
}
