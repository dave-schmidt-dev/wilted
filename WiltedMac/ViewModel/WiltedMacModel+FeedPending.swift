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
