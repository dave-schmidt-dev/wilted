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
/// Passes one download's progress reports on at a rate the main actor can render.
///
/// The coordinator reports every network chunk, and each report used to queue
/// its own main-actor task that rewrote `episodes` -- re-sorting the Larder
/// every time -- so a few transfers together stalled the window. A report goes
/// out at once when its stage changes, when it is the completed stage, or when
/// `interval` has passed since the last one went out. Anything sooner is held,
/// and the newest held report goes out when the interval ends, so a transfer
/// that stalls after a burst still shows the bytes it reached. The byte count
/// is no test of the end: a feed's declared size can undercount the file.
final class WiltedMacDownloadProgressThrottle: Sendable {
    static let interval: TimeInterval = 0.25

    enum Decision: Equatable {
        /// Deliver this report now.
        case now
        /// Hold it, and deliver the newest held report after this many seconds.
        case later(TimeInterval)
        /// Hold it in place of the one a pending delivery will send.
        case coalesced
    }

    private struct State {
        var stage: PodcastDownloadStage?
        var deliveredAt: Date?
        var held: PodcastDownloadProgress?
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    /// Delivers `progress` now, later as the newest held report, or not at all
    /// when a newer report replaces it first.
    func submit(_ progress: PodcastDownloadProgress,
                deliver: @escaping @Sendable (PodcastDownloadProgress) -> Void) {
        switch admit(progress) {
        case .now:
            deliver(progress)
        case .later(let delay):
            Task { [self] in
                try? await Task.sleep(for: .seconds(delay))
                if let held = takeHeld() { deliver(held) }
            }
        case .coalesced:
            break
        }
    }

    func admit(_ progress: PodcastDownloadProgress, at moment: Date = Date()) -> Decision {
        state.withLock { state in
            let elapsed = state.deliveredAt.map { moment.timeIntervalSince($0) } ?? .infinity
            if progress.stage == .completed || progress.stage != state.stage || elapsed >= Self.interval {
                state = State(stage: progress.stage, deliveredAt: moment, held: nil)
                return .now
            }
            let alreadyHeld = state.held != nil
            state.held = progress
            return alreadyHeld ? .coalesced : .later(Self.interval - elapsed)
        }
    }

    /// The newest held report, or nil when a report delivered since replaced it.
    func takeHeld(at moment: Date = Date()) -> PodcastDownloadProgress? {
        state.withLock { state in
            guard let held = state.held else { return nil }
            state = State(stage: held.stage, deliveredAt: moment, held: nil)
            return held
        }
    }
}
#endif
