import Foundation

#if canImport(WiltedProducer)
import WiltedProducer

extension WiltedMacModel {
    /// Runs one durable Processor refresh at a time, folding overlapping calls
    /// into a single follow-up for the latest request and current store.
    func drainProcessorRunsRefreshes() async {
        defer { processorRunsRefreshTask = nil }

        while !Task.isCancelled {
            guard !isClosingTemporaryState, let store else { return }
            let generation = processorRunsRefreshGeneration
            processorRunsRefreshReadCountForTesting += 1

            let runs = try? await store.preparationRuns()
            guard isCurrentProcessorRunsRefresh(store: store, generation: generation) else {
                if Task.isCancelled || isClosingTemporaryState { return }
                continue
            }
            await processorRunsRefreshAfterRunsReadForTesting?(store, generation)
            guard isCurrentProcessorRunsRefresh(store: store, generation: generation) else {
                if Task.isCancelled || isClosingTemporaryState { return }
                continue
            }
            guard let runs else { return }

            // Episodes prepare through the same journal as articles, so the
            // history has to be able to name both kinds of item.
            let articles = (try? await store.articles()) ?? []
            guard isCurrentProcessorRunsRefresh(store: store, generation: generation) else {
                if Task.isCancelled || isClosingTemporaryState { return }
                continue
            }
            var titles = Dictionary(
                uniqueKeysWithValues: articles.map { ($0.itemID.rawValue, ($0.title, $0.source)) }
            )

            let feeds = (try? await store.podcastFeeds()) ?? []
            guard isCurrentProcessorRunsRefresh(store: store, generation: generation) else {
                if Task.isCancelled || isClosingTemporaryState { return }
                continue
            }
            let feedTitles = Dictionary(
                uniqueKeysWithValues: feeds.map { ($0.itemID, $0.title) }
            )

            let episodes = (try? await store.podcastEpisodes()) ?? []
            guard isCurrentProcessorRunsRefresh(store: store, generation: generation) else {
                if Task.isCancelled || isClosingTemporaryState { return }
                continue
            }
            for episode in episodes {
                titles[episode.itemID.rawValue] = (episode.title, feedTitles[episode.feedID] ?? "Podcast")
            }

            let dismissals = (try? await store.dismissedPodcastEpisodes()) ?? []
            guard isCurrentProcessorRunsRefresh(store: store, generation: generation) else {
                if Task.isCancelled || isClosingTemporaryState { return }
                continue
            }
            for dismissal in dismissals {
                titles[dismissal.episodeID.rawValue] = (
                    dismissal.title ?? "Removed podcast episode",
                    dismissal.feedID.flatMap { feedTitles[$0] } ?? "Removed podcast"
                )
            }

            let durableRuns = runs.map { run in
                let known = titles[run.itemID.rawValue]
                let outcome: WiltedMacProcessorRun.Outcome = if !run.isTerminal {
                    .running
                } else {
                    switch run.outcome {
                    case .succeeded: .succeeded
                    case .cancelled: .cancelled
                    default: .failed
                    }
                }
                let isPodcast = run.requestID.hasPrefix(Self.podcastRequestPrefix)
                let events = Self.processorEvents(for: run)
                let detail = run.failure?.message ?? run.detail
                let timeline = run.entries.last(where: { $0.status.terminal })?.status.timeline
                return WiltedMacProcessorRun(
                    id: run.id,
                    itemID: run.itemID.rawValue,
                    isPodcast: isPodcast,
                    title: known?.0 ?? "Unknown item",
                    source: known?.1 ?? run.itemID.rawValue,
                    stage: run.stage.rawValue,
                    detail: detail,
                    narrative: Self.processorNarrative(isPodcast: isPodcast, outcome: outcome, detail: detail,
                                                       events: events),
                    fraction: run.fraction,
                    outcome: outcome,
                    updatedAt: run.updatedAt.date,
                    events: events,
                    timeline: timeline
                )
            }

            let trackedItemIDs = Set(podcastPreparationTasks.keys)
            projectedProcessorRuns = projectedProcessorRuns.filter { trackedItemIDs.contains($0.key) }
            var mergedRuns = durableRuns.filter { run in
                guard run.isPodcast, trackedItemIDs.contains(run.itemID) else { return true }
                guard let projected = projectedProcessorRuns[run.itemID] else {
                    // A queued task has not reached the journal yet. Do not
                    // redraw the failed row from its previous attempt.
                    return false
                }
                // The durable row wins once it is at least as new as the
                // projection, including a terminal row written at completion.
                return run.updatedAt >= projected.updatedAt
            }
            for projected in projectedProcessorRuns.values
                where trackedItemIDs.contains(projected.itemID)
                    && !mergedRuns.contains(where: {
                        $0.isPodcast == projected.isPodcast && $0.itemID == projected.itemID
                            && $0.updatedAt >= projected.updatedAt
                    }) {
                mergedRuns.insert(projected, at: 0)
            }
            processorRuns = mergedRuns
            return
        }
    }

    private func isCurrentProcessorRunsRefresh(store: LocalLibraryStore, generation: UInt64) -> Bool {
        !Task.isCancelled && !isClosingTemporaryState
            && processorRunsRefreshGeneration == generation && self.store === store
    }
}
#endif
