import Foundation
import WiltedDomain

extension PlaybackController {
    /// Moves the durable queue on after `completedItemID` finished naturally
    /// and its completion was recorded. `state` is the queue as read after
    /// that completion, with `completedItemID` as its current entry.
    ///
    /// - A successor that turns out unavailable when it loads (removed, or
    ///   its media gone, after the lookup chose it) is skipped for the next
    ///   eligible entry after it. The walk only moves forward and each pass
    ///   consumes one entry, so it never wraps and the queue length bounds it.
    /// - `holdAtEnd` is `explicitHoldSerial` at the end of file. An explicit
    ///   pause or stop issued since then owns the player: before the
    ///   successor loads, the advance is dropped and the finished episode
    ///   stays loaded, paused, and current; once loading has begun, the
    ///   successor loads and becomes current but is not started (`startsIf`).
    ///   A newer selection is fenced by the backend generation instead.
    func advanceQueue(
        after completedItemID: ItemID, in state: PodcastQueueState, generation: UInt64, holdAtEnd: UInt64
    ) async {
        let startsIf = { [unowned self] in self.explicitHoldSerial == holdAtEnd }
        let order = state.episodeIDs
        let completedIndex = order.firstIndex(of: completedItemID)
        var anchor = completedItemID
        var skipped: [ItemID] = []
        for _ in 0...order.count {
            let found = try? await nextEligibleEpisodeID(after: anchor)
            guard generation == loadedBackendGeneration, itemID == completedItemID else { return }
            guard let next = found, next != completedItemID, !skipped.contains(next),
                  !Self.precedes(next, completedIndex, in: order) else { break }
            guard startsIf() else { return }
            switch await loadAdvance(to: next, from: completedItemID, generation: generation, startsIf: startsIf) {
            case .settled: return
            case .unavailable: skipped.append(next); anchor = next
            }
        }
        finishAdvance(completedItemID, skippedTo: skipped.last)
    }

    private enum AdvanceLoad { case settled, unavailable }

    /// Loads one looked-up successor. `.unavailable` means it failed the
    /// load-time eligibility or media check and the finished episode is still
    /// the loaded one, so the caller may look past it.
    private func loadAdvance(
        to next: ItemID, from completedItemID: ItemID, generation: UInt64, startsIf: () -> Bool
    ) async -> AdvanceLoad {
        var activeGeneration = generation
        var activeItemID = completedItemID
        do {
            let nextGeneration = try await loadQueuedEpisode(
                next, playAfterLoad: true, expectedGeneration: generation, startsIf: startsIf
            )
            guard loadedBackendGeneration == nextGeneration, itemID == next else { return .settled }
            activeGeneration = nextGeneration
            activeItemID = next
            try await store.setCurrentPodcastQueueEpisode(next)
            guard loadedBackendGeneration == activeGeneration, itemID == activeItemID else { return .settled }
            podcastStateHandler?(next, nil)
        } catch is CancellationError {
            return .settled
        } catch PlaybackControllerError.podcastMediaUnavailable(let missing)
                    where missing == next && loadedBackendGeneration == generation && itemID == completedItemID {
            return .unavailable
        } catch {
            guard loadedBackendGeneration == activeGeneration, itemID == activeItemID else { return .settled }
            stopAfterFailedAdvance(completedItemID, failed: next)
        }
        return .settled
    }

    /// The queue ran out. If the last candidate was skipped as unavailable,
    /// that fault is reported the way a single failed successor always was.
    private func finishAdvance(_ completedItemID: ItemID, skippedTo lastSkipped: ItemID?) {
        if let lastSkipped {
            stopAfterFailedAdvance(completedItemID, failed: lastSkipped)
            return
        }
        podcastStateHandler?(itemID, nil)
        playbackDidFinishHandler?()
    }

    private func stopAfterFailedAdvance(_ completedItemID: ItemID, failed next: ItemID) {
        backend.pause()
        isPlaying = false
        meterListening()
        if let fault = recoverableFault,
           fault == .podcastMediaUnavailable(next) || fault == .podcastMediaUnreadable(next) {
            podcastStateHandler?(completedItemID, fault)
        }
        playbackDidFinishHandler?()
    }

    /// Whether `candidate` sits at or before the finished entry in the queue
    /// as it was when the episode ended, i.e. reaching it would wrap.
    private static func precedes(_ candidate: ItemID, _ completedIndex: Int?, in order: [ItemID]) -> Bool {
        guard let completedIndex, let index = order.firstIndex(of: candidate) else { return false }
        return index <= completedIndex
    }
}
