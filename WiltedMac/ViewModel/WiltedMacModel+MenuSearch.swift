import Foundation
import Observation
import AppKit
import os

#if canImport(WiltedProducer)
import WiltedDomain
import WiltedProducer
import WiltedSync
#endif

#if WILTED_CLOUDKIT_LIVE
import CloudKit
#endif

extension WiltedMacModel {
    /// The articles a search admits. Articles are the Menu's second list, so
    /// they narrow with the same rule rather than disappearing under a query.
    var menuSearchArticleResults: [WiltedMacArticle] {
        guard isSearchingMenu else { return articles }
        return articles.filter { article in
            Self.matches(.article(article), query: trimmedSearchQuery,
                         transcriptMatches: transcriptSearchMatches)
        }
    }

    func matchesMenuSearch(_ episode: WiltedMacEpisode) -> Bool {
        Self.matches(.episode(episode), query: trimmedSearchQuery,
                     transcriptMatches: transcriptSearchMatches)
    }

    /// What the Menu's search field matches.
    ///
    /// Separated from the list so the rule can be read and tested on its own:
    /// the field sits above rows that each show a line of show notes, and
    /// matching only the title made those visible words unfindable.
    nonisolated static func matches(
        _ item: WiltedMacLibraryItem,
        query: String,
        transcriptMatches: Set<String> = []
    ) -> Bool {
        guard !query.isEmpty else { return true }
        return item.title.localizedCaseInsensitiveContains(query)
            || item.source.localizedCaseInsensitiveContains(query)
            || item.searchableDetail.localizedCaseInsensitiveContains(query)
            || transcriptMatches.contains(item.id)
    }

    /// Asks the store which transcripts match, once the field goes quiet.
    ///
    /// Debounced because every call reads transcript text from disk, and
    /// checked against the live query on the way back because a slow answer
    /// must not repopulate the list for a search the reader has moved off.
    /// Cancellation alone would not settle it: a task can finish its read just
    /// before the cancel lands.
    func scheduleTranscriptSearch() {
        transcriptSearchTask?.cancel()
        let query = trimmedSearchQuery
        guard query.count >= Self.transcriptSearchMinimumLength, let store else {
            transcriptSearchTask = nil
            isSearchingTranscripts = false
            transcriptSearchMatches = []
            return
        }
        isSearchingTranscripts = true
        transcriptSearchTask = Task { [weak self] in
            try? await Task.sleep(for: Self.transcriptSearchDebounce)
            guard !Task.isCancelled else { return }
            let found = (try? await store.itemIDsWithTranscript(matching: query)) ?? []
            guard !Task.isCancelled, let self else { return }
            guard self.trimmedSearchQuery == query else { return }
            self.transcriptSearchMatches = Set(found.map(\.rawValue))
            self.isSearchingTranscripts = false
        }
    }

    /// Feeds asks one question, and this is its data: the episodes that
    /// arrived and are not waiting on the Menu yet. An episode already on the
    /// Menu is not in Feeds.
    var feedsEpisodes: [WiltedMacEpisode] {
        let waiting = Set(podcastQueueIDs)
        return Self.sortedLarderEpisodes(
            larderVisibleEpisodes.filter { !waiting.contains($0.id) },
            by: larderSort
        )
    }

    func sortedMenuEpisodeIDs(
        _ ids: [String],
        by sort: WiltedMacMenuSort
    ) -> [String] {
        guard sort != .custom else { return ids }
        // The episode playing now keeps its place, because the reader is in
        // the middle of it. Every other row sorts around it: the old code
        // pinned the prefix before the current row and sorted only the rows
        // after it, so entries before the current index never moved.
        guard let currentID = currentPodcastEpisodeID,
              let currentIndex = ids.firstIndex(of: currentID) else {
            return ids.sorted { menuSortPrecedes($0, $1, by: sort) }
        }
        var rest = ids
        rest.remove(at: currentIndex)
        let sorted = rest.sorted { menuSortPrecedes($0, $1, by: sort) }
        var result = sorted
        result.insert(currentID, at: min(currentIndex, result.count))
        return result
    }

    private func menuSortPrecedes(_ lhsID: String, _ rhsID: String, by sort: WiltedMacMenuSort) -> Bool {
        let lhs = episodes.first(where: { $0.id == lhsID })
        let rhs = episodes.first(where: { $0.id == rhsID })
        switch sort {
        case .custom:
            return false
        case .newest:
            if let lhs, let rhs, lhs.releasedAt != rhs.releasedAt {
                return lhs.releasedAt > rhs.releasedAt
            }
        case .oldest:
            if let lhs, let rhs, lhs.releasedAt != rhs.releasedAt {
                return lhs.releasedAt < rhs.releasedAt
            }
        case .shortest:
            switch (lhs?.durationSeconds, rhs?.durationSeconds) {
            case let (left?, right?) where left != right:
                return left < right
            case (nil, .some): return false
            case (.some, nil): return true
            default: break
            }
        case .show:
            let comparison = (lhs?.feedTitle ?? "").localizedStandardCompare(rhs?.feedTitle ?? "")
            if comparison != .orderedSame { return comparison == .orderedAscending }
        case .title:
            let comparison = (lhs?.title ?? "").localizedStandardCompare(rhs?.title ?? "")
            if comparison != .orderedSame { return comparison == .orderedAscending }
        }
        return lhsID < rhsID
    }

    /// Applies a non-custom Menu sort to the durable queue without moving the
    /// current item. The local snapshot changes first so the picker never
    /// appears to do nothing while SwiftData catches up.
    func applyMenuSortIfNeeded() {
        guard !isApplyingMenuSort, menuSort != .custom else { return }
        let sorted = sortedMenuEpisodeIDs(podcastQueueIDs, by: menuSort)
        guard sorted != podcastQueueIDs else { return }
        podcastQueueIDs = sorted
#if canImport(WiltedProducer)
        guard let playback,
              let episodeIDs = try? sorted.map({ try ItemID(rawValue: $0) }),
              let state = try? PodcastQueueState(
                episodeIDs: episodeIDs,
                currentEpisodeID: currentPodcastEpisodeID.flatMap { try? ItemID(rawValue: $0) }
              ) else {
            return
        }
        isApplyingMenuSort = true
        Task { [weak self] in
            do {
                try await playback.replacePodcastQueue(state)
            } catch {
                // Reported rather than swallowed: the old code retried forever
                // and said nothing, so a queue that would not accept the sort
                // looked like a Menu that simply ignored the picker.
                self?.podcastOperationMessage = "The Larder order could not be saved."
            }
            await self?.refreshPodcastQueueState()
            self?.isApplyingMenuSort = false
        }
#endif
    }

    func canPlayEpisode(_ episode: WiltedMacEpisode) -> Bool {
        !hiddenEpisodeIDs.contains(episode.id) &&
            episode.retiredAt == nil &&
            episode.removalKind == nil &&
            episode.downloadState == .completed &&
            episode.preparationState.isPrepared &&
            episode.isReadyMediaAvailable
    }

    func canAddEpisodeToMenu(_ episode: WiltedMacEpisode) -> Bool {
        canPlayEpisode(episode) && currentPodcastEpisodeID != episode.id && !podcastQueueIDs.contains(episode.id)
    }

    /// Prepared podcast rows in the same newest/oldest order the Larder uses.
    /// This is intentionally independent of the current search or scope: the
    /// bulk Menu action is a queue operation over the whole Larder, not just
    /// the rows currently visible through a filter.
    var readyToPlayEpisodes: [WiltedMacEpisode] {
        Self.sortedLarderEpisodes(
            larderVisibleEpisodes.filter { canPlayEpisode($0) },
            by: larderSort
        )
    }

    /// The exact set the Menu bulk action may append: prepared, not current,
    /// and absent from the durable queue already. Keeping this predicate in
    /// the model makes the disabled state and the mutation share one answer.
    var preparedEpisodesReadyForMenu: [WiltedMacEpisode] {
        readyToPlayEpisodes.filter(canAddEpisodeToMenu)
    }

    static func isEligibleForPreparation(_ episode: WiltedMacEpisode) -> Bool {
        guard episode.downloadState == .completed else { return false }
        switch episode.preparationState {
        case .notPrepared, .failed: return true
        case .preparing, .prepared: return false
        }
    }

    var hasCurrentPlayback: Bool { currentArticle != nil || currentEpisode != nil }

    /// Whether the finished-with-it press has nothing left to do.
    ///
    /// The written record is only half of what the press does: it also retires
    /// the episode from the Larder, and the two come apart in ways the record
    /// alone cannot see. A completion written before retirement existed, a
    /// dismissal that failed after the completion stuck, and a completion
    /// synced from iPhone all leave an episode marked finished and still on
    /// the shelf. Disabling on the record alone turned the only control that
    /// could finish the job into a dead end, so it takes both.
    ///
    /// Articles settle on the record: they have no Larder retirement to wait
    /// for. An episode already gone from `episodes` has no `currentEpisode`
    /// either, so the retired case reads as settled through the same guard.
    var playbackCompletionIsSettled: Bool {
        guard playbackCompleted else { return false }
        guard isPodcastPlayback, let episode = currentEpisode else { return true }
        return hiddenEpisodeIDs.contains(episode.id) || episode.retiredAt != nil
    }

    /// The previous queued episode before the current one that satisfies `canPlayEpisode`.
    /// Walks backward through `podcastQueueIDs` and selects the nearest earlier episode
    /// that can actually be played.
    func previousEligiblePodcastQueueEpisode() -> WiltedMacEpisode? {
        guard isPodcastPlayback, let currentPodcastEpisodeID,
              let index = podcastQueueIDs.firstIndex(of: currentPodcastEpisodeID),
              index > podcastQueueIDs.startIndex else { return nil }
        for id in podcastQueueIDs[..<index].reversed() {
            guard let candidate = episodes.first(where: { $0.id == id }),
                  canPlayEpisode(candidate) else { continue }
            return candidate
        }
        return nil
    }

    var canSelectPreviousEpisode: Bool {
        previousEligiblePodcastQueueEpisode() != nil
    }

    /// The next queued episode after the current one that satisfies `canPlayEpisode`.
    /// Walks forward through `podcastQueueIDs` and selects the first later episode
    /// that can actually be played.
    func nextEligiblePodcastQueueEpisode() -> WiltedMacEpisode? {
        guard isPodcastPlayback, let currentPodcastEpisodeID,
              let index = podcastQueueIDs.firstIndex(of: currentPodcastEpisodeID) else { return nil }
        let nextIndex = podcastQueueIDs.index(after: index)
        guard nextIndex < podcastQueueIDs.endIndex else { return nil }
        for id in podcastQueueIDs[nextIndex...] {
            guard let candidate = episodes.first(where: { $0.id == id }),
                  canPlayEpisode(candidate) else { continue }
            return candidate
        }
        return nil
    }

    var canSelectNextEpisode: Bool {
        nextEligiblePodcastQueueEpisode() != nil
    }

    var canCancelPreparation: Bool { preparation?.cancellable == true }

    /// The player's one-line status, matching the listener's status channel so
    /// the same condition reads the same way on both platforms. Never color
    /// alone: the tone accompanies this text rather than replacing it.
    var playbackStatusMessage: String {
        if !hasCurrentPlayback { return "Nothing is playing" }
        if let playbackError { return playbackError }
        if isPlaying { return "Playing" }
        if isNowPlaying { return "Paused" }
        return "Ready"
    }

    var playbackStatusTone: WiltedStatusTone {
        if playbackError != nil { return .failure }
        if isPlaying { return .active }
        return .neutral
    }

    /// Elapsed and total, in the listener's wording.
    var playbackProgressLabel: String {
        WiltedDuration.progress(position: playbackPositionSeconds, duration: playbackDurationSeconds)
    }

    /// The spoken form of the same readout.
    var playbackProgressSpokenLabel: String {
        WiltedDuration.spokenProgress(position: playbackPositionSeconds, duration: playbackDurationSeconds)
    }

    /// Adds whatever was pasted, working out for itself which kind it is.
    ///
    /// Two boxes made the reader classify an address before pasting it, and a
    /// podcast address dropped in the article box produced a parse error rather
    /// than a subscription. The document decides instead: an unmistakable feed
    /// extension short-circuits, anything else is fetched once and sniffed.
    func addPastedLink() {
        let trimmed = urlDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), url.scheme?.lowercased() == "https", url.host != nil else {
            linkDraftStatus = "Enter a complete HTTPS address."
            return
        }
        advertisedFeed = nil
        linkDraftStatus = nil
        guard !fixtureMode else { addArticle(); return }

#if canImport(WiltedProducer)
        guard linkClassificationTask == nil else { return }
        linkDraftStatus = "Checking that address\u{2026}"
        linkClassificationTask = Task { [weak self] in
            guard let self else { return }
            defer { self.linkClassificationTask = nil }
            do {
                let kind = try await self.pastedLinkClassifier.classify(url)
                guard !Task.isCancelled else { self.linkDraftStatus = nil; return }
                self.linkDraftStatus = nil
                switch kind {
                case .podcastFeed:
                    self.handPodcastFeedToSubscriptions(url)
                case .article:
                    self.addArticle()
                case .articleAdvertisingFeed(let feedURL):
                    self.advertisedFeed = feedURL
                    self.addArticle()
                }
            } catch is CancellationError {
                self.linkDraftStatus = nil
            } catch {
                self.linkDraftStatus = "Wilted could not reach that address. Check it, or retry when online."
            }
        }
#else
        addArticle()
#endif
    }

}
