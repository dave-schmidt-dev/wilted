import Foundation
import Observation
import WiltedDomain
import WiltedProducer

/// Lifetime statistics as observed state: loaded and rebuilt in the
/// background, never a prerequisite to opening the larder.
extension WiltedMacModel {
    /// Re-reads the durable summary (one O(1) read) without touching sync or
    /// mutable library rows. A failed re-read keeps the totals on screen, like
    /// `reloadLibraryRows`; only the first load or a rebuild can make them
    /// unavailable, and an unavailable state is cleared by `retry`, not here.
    func refreshLifetimeStatistics() async {
        guard let store else { return }
        switch statisticsState {
        case .loading:
            // Fixtures never bootstrap; production already has a task here.
            if statisticsTask == nil { beginLifetimeStatisticsLoad() }
        case .rebuilding, .unavailable:
            return
        case .ready:
            guard let summary = try? await statisticsOperations.summary(store),
                  summary.state == .ready, case .ready = statisticsState else { return }
            statisticsState = .ready(summary)
        }
    }

    /// Loads the summary in the background, rebuilding it first when the store
    /// says it must be (right after the V14 migration). Never awaited by
    /// bootstrap and never throws into it: every outcome is `statisticsState`.
    func beginLifetimeStatisticsLoad() {
        statisticsTask?.cancel()
        guard let store else { return }
        statisticsState = .loading
        let operations = statisticsOperations
        let onProgress: @Sendable (WiltedMacStatisticsProgress) -> Void = { [weak self] progress in
            Task { @MainActor [weak self] in self?.noteStatisticsRebuild(progress) }
        }
        statisticsTask = Task { [weak self] in
            do {
                var summary = try await operations.summary(store)
                if summary.state == .rebuildRequired {
                    self?.statisticsState = .rebuilding(nil)
                    summary = try await operations.rebuild(store, onProgress)
                }
                try Task.checkCancellation()
                self?.statisticsState = .ready(summary)
            } catch is CancellationError {
                return
            } catch {
                self?.statisticsState = .unavailable(detail: String(describing: error))
            }
        }
    }

    /// The Settings "Try again" action after an unavailable summary.
    func retryLifetimeStatistics() {
        guard case .unavailable = statisticsState else { return }
        beginLifetimeStatisticsLoad()
    }

    private func noteStatisticsRebuild(_ progress: WiltedMacStatisticsProgress) {
        // A progress hop that lands after the publish must not undo `.ready`.
        guard case .rebuilding = statisticsState else { return }
        statisticsState = .rebuilding(progress)
    }

    /// Deterministic test seam; production does not wait on this task.
    func waitForLifetimeStatisticsForTesting() async {
        await statisticsTask?.value
    }
}
