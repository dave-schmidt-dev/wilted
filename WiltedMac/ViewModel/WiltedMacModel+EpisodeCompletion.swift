import Foundation
import WiltedLibrary
import Observation
import AppKit
import os

#if canImport(WiltedProducer)
import WiltedDomain
import WiltedProducer
#endif

#if WILTED_CLOUDKIT_LIVE
import CloudKit
#endif

extension WiltedMacModel {
    static let completionRetryMessage = "Some completions are still being finished. Wilted will retry."

    /// Remove and Mark completed both record the owner's finish, retaining media.
    func skipEpisode(_ episode: WiltedMacEpisode, requireStarted: Bool = false) {
#if canImport(WiltedProducer)
        finishEpisodes([episode])
#endif
    }

#if canImport(WiltedProducer)
    func finishEpisodes(_ requested: [WiltedMacEpisode], at: Timestamp? = nil) {
        guard let store, !isClosingTemporaryState else { return }
        let memberIDs = Set(requested.flatMap { logicalMemberIDs($0.id) })
        let expanded = episodes.filter { memberIDs.contains($0.id) }
        let candidates = expanded.filter { (try? ItemID(rawValue: $0.id)) != nil && !$0.isAudiobook && episodeCompletionProjections[$0.id] == nil && ($0.removalKind == nil || episodeAssociations[$0.id]?.isTerminal == false) }
        guard !candidates.isEmpty else {
            if let invalid = requested.first, (try? ItemID(rawValue: invalid.id)) == nil {
                podcastOperationMessage = "\(invalid.title) could not be marked completed."
            }
            return
        }
        let localNow = manualCompletionNow()
        projectEpisodeCompletions(candidates)
        trackSubscriptionWrite { [weak self] in
            guard let self else { return }
            _ = await self.persistEpisodeCompletions(candidates, store: store, at: at, localNow: localNow)
        }
    }

    func projectEpisodeCompletions(_ candidates: [WiltedMacEpisode]) {
        undoableRemoval = nil
        undoableSkip = nil
        let now = Date()
        for episode in candidates {
            episodeCompletionProjections[episode.id] = WiltedMacEpisodeCompletionProjection(original: episode, projectedRetiredAt: now)
            if let index = episodes.firstIndex(where: { $0.id == episode.id }) {
                episodes[index] = Self.projectedCompletion(episodes[index], retiredAt: now)
            }
        }
        invalidateProjectedLibraryReads()
        podcastOperationMessage = candidates.count == 1 ? "Saving \(candidates[0].title) as completed…" : "Saving \(candidates.count) completions…"
    }

    /// Awaitable pane path keeps automatic advance behind durable success.
    func finishCurrentPodcast(_ episode: WiltedMacEpisode) async -> Bool {
        guard let store, !isClosingTemporaryState, !episode.isAudiobook else { return false }
        if episodeCompletionProjections[episode.id] == nil { projectEpisodeCompletions([episode]) }
        return await persistEpisodeCompletions([episode], store: store, at: nil, localNow: manualCompletionNow())
    }

    /// Store attachment rebuilds the one expiry task from durable receipts.
    /// Re-reading rows before release makes restart admission use current state.
    func recoverManualCompletionWindows() async {
        guard let store, !isClosingTemporaryState else { return }
        do {
            _ = try await store.sealExpiredManualCompletions(at: manualCompletionNow())
            let feeds = try await store.manualCompletionRecoveryFeedIDs()
            if !feeds.isEmpty {
                await reloadLibraryRows()
                await releaseWaitingEpisodes(feedIDs: Set(feeds.map(\.rawValue)))
            }
            await scheduleManualCompletionExpiry(store: store)
        } catch { podcastOperationMessage = WiltedMacModel.completionRetryMessage }
    }

    /// The task is separate from user writes and is cancelled/joined on close.
    /// The injected wall clock and sleeper let tests cross the exact deadline.
    func scheduleManualCompletionExpiry(store: LocalLibraryStore) async {
        guard !isClosingTemporaryState else { return }
        // A wake already owns sealing/release; its tail schedules the next window.
        if let active = manualCompletionExpiryDeadline, active <= manualCompletionNow(), manualCompletionExpiryTask != nil { return }
        guard let windows = try? await store.pendingManualCompletionWindows() else { return }
        let deadline = windows.values.min()
        guard deadline != manualCompletionExpiryDeadline else { return }
        manualCompletionExpiryTask?.cancel()
        manualCompletionExpiryDeadline = deadline
        manualCompletionExpiryTask = nil
        guard let deadline else { return }
        let generation = UUID()
        manualCompletionExpiryGeneration = generation
        manualCompletionExpiryTask = Task { [weak self] in
            guard let self else { return }
            do {
                while self.manualCompletionNow() < deadline {
                    try await self.manualCompletionSleep(max(0, deadline.timeIntervalSince(self.manualCompletionNow())))
                    try Task.checkCancellation()
                }
                guard !self.isClosingTemporaryState, self.manualCompletionExpiryGeneration == generation else { return }
                // A later completion can join the same earliest-deadline task.
                // Read its current receipt deadline rather than the task's old snapshot.
                let currentWindows = try await store.pendingManualCompletionWindows()
                guard self.manualCompletionExpiryGeneration == generation, !Task.isCancelled else { return }
                _ = try await store.sealExpiredManualCompletions(at: self.manualCompletionNow())
                if let operationID = self.undoableSkip?.manualCompletionOperationID,
                   (currentWindows[operationID] ?? .distantPast) <= self.manualCompletionNow() { self.undoableSkip = nil }
                await self.reloadLibraryRows()
                await self.releaseWaitingEpisodes(feedIDs: Set(self.episodes.compactMap(\.feedID)))
                self.manualCompletionExpiryDeadline = nil
                self.manualCompletionExpiryTask = nil
                await self.scheduleManualCompletionExpiry(store: store)
            } catch is CancellationError {} catch {
                self.podcastOperationMessage = WiltedMacModel.completionRetryMessage
                self.manualCompletionExpiryDeadline = nil
                self.manualCompletionExpiryTask = nil
            }
        }
    }

    private func persistEpisodeCompletions(_ candidates: [WiltedMacEpisode], store: LocalLibraryStore, at: Timestamp?, localNow: Date) async -> Bool {
        do {
            try await subscriptionWriteHookForTesting?()
            let result = try await store.manuallyCompleteEpisodes(candidates.compactMap { try? ItemID(rawValue: $0.id) }, at: at, localNow: localNow)
            let committed = Set(result.committed.map(\.rawValue))
            for episode in candidates {
                if committed.contains(episode.id) {
                    episodeCompletionProjections[episode.id] = nil
                    // Existing transfer/preparation work belongs to its own request.
                    // Completion creates no new work and must not cancel that owner.
                } else { rollbackEpisodeCompletionProjection(episode.id, title: episode.title) }
            }
            guard let committedEpisode = candidates.first(where: { committed.contains($0.id) }) else { return false }
            do {
                var undo = committedEpisode
                undo.manualCompletionOperationID = result.operationID
                undoableSkip = undo
            }
            await scheduleManualCompletionExpiry(store: store)
            // Pause checkpoints real audio position; manual finish never seeks to EOF.
            if let current = currentPodcastEpisodeID, committed.contains(current) { await stopPlaybackForRemovedEpisode() }
            await refreshPodcastQueueState()
            await reloadLibraryRows()
            podcastOperationMessage = committed.count == 1
                ? "Marked \(committedEpisode.title) completed. Undo completion is available for 10 seconds."
                : "Marked \(committed.count) episodes completed. Undo completion is available for 10 seconds."
            return committed.count == candidates.count
        } catch {
            for episode in candidates { rollbackEpisodeCompletionProjection(episode.id, title: episode.title) }
            return false
        }
    }
#endif

    /// The row the Larder draws while a completion is being written.
    nonisolated static func projectedCompletion(
        _ row: WiltedMacEpisode, retiredAt: Date
    ) -> WiltedMacEpisode {
        var value = row
        value.isPlayed = true
        value.retiredAt = retiredAt
        value.removalKind = .retired
        return value
    }

    /// Reapplies in-flight completion projections to freshly loaded rows, so a
    /// reload cannot resurrect an episode whose completion is still writing.
    nonisolated static func applyingPendingEpisodeCompletions(
        _ loaded: [WiltedMacEpisode],
        projections: [String: WiltedMacEpisodeCompletionProjection]
    ) -> [WiltedMacEpisode] {
        guard !projections.isEmpty else { return loaded }
        return loaded.map { row in
            guard let projection = projections[row.id] else { return row }
            return Self.projectedCompletion(row, retiredAt: projection.projectedRetiredAt)
        }
    }

    /// Puts a failed completion back exactly as this operation found it. Only
    /// the completion fields are unprojected, so a download or preparation
    /// that advanced while the write ran keeps its progress, and no unrelated
    /// hidden episode or playback command is touched.
    func rollbackEpisodeCompletionProjection(_ episodeID: String, title: String) {
        if let projection = episodeCompletionProjections[episodeID],
           let index = episodes.firstIndex(where: { $0.id == episodeID }) {
            episodes[index].isPlayed = projection.original.isPlayed
            episodes[index].retiredAt = projection.original.retiredAt
            episodes[index].removalKind = projection.original.removalKind
        }
        episodeCompletionProjections[episodeID] = nil
        undoableSkip = nil
        podcastOperationMessage = "\(title) could not be marked completed."
    }

    /// Receipt Undo restores prior state and placement without starting audio.
    func undoSkipEpisode(_ episode: WiltedMacEpisode) {
#if canImport(WiltedProducer)
        guard episodeCompletionProjections[episode.id] == nil else { return }
        undoableSkip = nil
        podcastOperationMessage = "Restoring completion…"
        trackSubscriptionWrite { [weak self] in
            guard let self, let store = self.store, let id = try? ItemID(rawValue: episode.id) else { return }
            do {
                let restored: Bool
                var hadConflicts = false
                if let operationID = episode.manualCompletionOperationID {
                    let result = try await store.undoManualCompletion(operationID, at: self.manualCompletionNow())
                    restored = !result.committed.isEmpty
                    hadConflicts = !result.unresolved.isEmpty
                } else { restored = try await store.restoreManualCompletion(id, asOwnerChoice: false, at: self.manualCompletionNow()) ?? false }
                await self.scheduleManualCompletionExpiry(store: store)
                await self.refreshPodcastQueueState()
                await self.reloadLibraryRows()
                self.podcastOperationMessage = hadConflicts
                    ? "Some episodes changed since completion and could not be restored."
                    : restored ? "Restored retained episodes." : "Completion changed or Undo expired. Use Restore in Feeds."
            } catch { self.podcastOperationMessage = "Completion could not be restored." }
        }
#endif
    }
}
