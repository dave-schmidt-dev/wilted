import Foundation
import os

#if canImport(WiltedProducer)
import WiltedProducer
#endif

extension WiltedMacModel {
    /// Carries a download state this process owns onto the loaded row.
    ///
    /// `downloadState` comes only from the durable download row, and a click
    /// writes that row several store hops after it paints the row `Queued`. A
    /// reload landing in between -- another episode's download finishing, say
    /// -- used to put the row back to `Download` while its task was still
    /// running, and a second click then did nothing because the task existed.
    /// So a live task's queued or downloading row keeps its state over a loaded
    /// not-downloaded, failed, or cancelled one (a retry's old record). A
    /// loaded in-flight or completed record wins, which is how the task's own
    /// reload publishes `.completed`.
    ///
    /// A real failure is never hidden: every terminal exit of the task writes
    /// its terminal state to the row before the task entry is cleared, so a
    /// settled row no longer counts as in flight.
    nonisolated static func applyingInFlightDownloads(
        to loaded: [WiltedMacEpisode], from current: [WiltedMacEpisode], inFlight: Set<String>
    ) -> [WiltedMacEpisode] {
        guard !inFlight.isEmpty else { return loaded }
        var owned: [String: WiltedMacEpisodeDownloadState] = [:]
        for episode in current where inFlight.contains(episode.id) && owned[episode.id] == nil {
            switch episode.downloadState {
            case .queued, .downloading: owned[episode.id] = episode.downloadState
            case .notDownloaded, .completed, .failed, .cancelled: continue
            }
        }
        guard !owned.isEmpty else { return loaded }
        return loaded.map { episode in
            guard let state = owned[episode.id] else { return episode }
            switch episode.downloadState {
            case .notDownloaded, .failed, .cancelled:
                var value = episode
                value.downloadState = state
                return value
            case .queued, .downloading, .completed:
                return episode
            }
        }
    }
}

#if canImport(WiltedProducer)
/// Admits one download's progress reports at a rate the main actor can render.
///
/// The coordinator reports every network chunk, and each report used to queue
/// its own main-actor task that rewrote `episodes` -- re-sorting the Larder
/// every time -- so a few transfers together stalled the window. A report is
/// admitted when its stage changes, when it is the completed stage or the
/// last byte, or when `interval` has passed since the last admitted one.
final class WiltedMacDownloadProgressThrottle: Sendable {
    static let interval: TimeInterval = 0.25

    private struct Admitted {
        let stage: PodcastDownloadStage
        let at: Date
    }

    private let last = OSAllocatedUnfairLock<Admitted?>(initialState: nil)

    func admits(_ progress: PodcastDownloadProgress, at moment: Date = Date()) -> Bool {
        let isFinal = progress.stage == .completed
            || progress.expectedByteCount.map { progress.bytesReceived >= $0 } == true
        return last.withLock { last in
            if !isFinal, let previous = last, previous.stage == progress.stage,
               moment.timeIntervalSince(previous.at) < Self.interval {
                return false
            }
            last = Admitted(stage: progress.stage, at: moment)
            return true
        }
    }
}
#endif
