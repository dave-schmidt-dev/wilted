import Foundation
import Observation

#if canImport(WiltedProducer)
import WiltedDomain
import WiltedProducer

/// Shares one playback readout ticker among the mounted player surfaces.
/// Controller state changes refresh immediately; the one-second ticker only
/// runs while the controller is playing and at least one surface is mounted.
@MainActor
final class WiltedMacPlaybackReadoutClock {
    private struct Snapshot: Equatable {
        let controllerID: ObjectIdentifier
        let itemID: ItemID?
        let revisionID: RevisionID?
        let positionSeconds: TimeInterval
        let durationSeconds: TimeInterval
        let modelRate: Double
        let isPlaying: Bool
        let completed: Bool
        let fault: PlaybackControllerError?
        let isClosing: Bool
    }

    private weak var model: WiltedMacModel?
    private let tickInterval: Duration
    private var subscribers: Set<UUID> = []
    private var continuations: [UUID: CheckedContinuation<Void, Never>] = [:]
    private var tickTask: Task<Void, Never>?
    private var observationGeneration: UInt64 = 0
    private var lastSnapshot: Snapshot?
    private var isActive = false

    private(set) var tickLoopStartCountForTesting = 0
    private(set) var tickCountForTesting = 0

    var subscriberCountForTesting: Int { subscribers.count }
    var isTickingForTesting: Bool { tickTask != nil }

    init(model: WiltedMacModel, tickInterval: Duration = .seconds(1)) {
        self.model = model
        self.tickInterval = tickInterval
    }

    /// Holds one view subscription until its SwiftUI task is cancelled.
    func subscribe() async {
        guard let model, !model.isClosingTemporaryState else { return }
        let id = UUID()
        let wasEmpty = subscribers.isEmpty
        subscribers.insert(id)

        if wasEmpty {
            lastSnapshot = observeControllerState()
            model.refreshPlaybackReadout(preservingSeamDeadline: true)
        }

        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if Task.isCancelled {
                    removeSubscriber(id)
                    continuation.resume()
                } else {
                    continuations[id] = continuation
                }
            }
        } onCancel: { [weak self] in
            Task { @MainActor [weak self] in
                self?.removeSubscriber(id)
            }
        }
    }

    /// Updates clock ownership after any model-owned immediate readout refresh.
    func readoutRefreshed() {
        guard model?.isClosingTemporaryState != true else {
            stop()
            return
        }
        lastSnapshot = currentSnapshot()
        setActive(!subscribers.isEmpty && model?.playback?.isPlaying == true)
    }

    /// Cancels the shared ticker and releases any suspended view tasks.
    func stop() {
        observationGeneration &+= 1
        isActive = false
        stopTicking()
        let pending = Array(continuations.values)
        continuations.removeAll()
        subscribers.removeAll()
        for continuation in pending { continuation.resume() }
    }

    /// Drives the production tick path without waiting for wall-clock time.
    func tickForTesting() {
        guard tickTask != nil, !subscribers.isEmpty else { return }
        guard model?.playback?.isPlaying == true else {
            model?.refreshPlaybackReadout()
            return
        }
        tick()
    }

    private func removeSubscriber(_ id: UUID) {
        guard subscribers.remove(id) != nil else { return }
        continuations.removeValue(forKey: id)?.resume()
        guard subscribers.isEmpty else { return }

        observationGeneration &+= 1
        setActive(false)
        lastSnapshot = nil
    }

    private func observeControllerState() -> Snapshot? {
        guard !subscribers.isEmpty, let model else { return nil }
        observationGeneration &+= 1
        let generation = observationGeneration
        return withObservationTracking {
            snapshot(for: model)
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                self?.controllerStateChanged(generation: generation)
            }
        }
    }

    private func controllerStateChanged(generation: UInt64) {
        guard generation == observationGeneration, !subscribers.isEmpty else { return }
        guard model?.isClosingTemporaryState != true else {
            stop()
            return
        }
        let previous = lastSnapshot
        let current = observeControllerState()
        guard previous != current else { return }
        lastSnapshot = current
        model?.refreshPlaybackReadout()
    }

    private func currentSnapshot() -> Snapshot? {
        guard let model else { return nil }
        return snapshot(for: model)
    }

    private func snapshot(for model: WiltedMacModel) -> Snapshot? {
        guard let playback = model.playback else { return nil }
        return Snapshot(
            controllerID: ObjectIdentifier(playback),
            itemID: playback.itemID,
            revisionID: playback.revisionID,
            positionSeconds: playback.positionSeconds,
            durationSeconds: playback.durationSeconds,
            modelRate: model.playbackRate,
            isPlaying: playback.isPlaying,
            completed: playback.completed,
            fault: playback.recoverableFault,
            isClosing: model.isClosingTemporaryState
        )
    }

    private func setActive(_ active: Bool) {
        guard active != isActive else { return }
        isActive = active
        if active {
            startTicking()
        } else {
            stopTicking()
        }
    }

    private func startTicking() {
        guard tickTask == nil, !subscribers.isEmpty else { return }
        tickLoopStartCountForTesting += 1
        let interval = tickInterval
        tickTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: interval)
                } catch {
                    return
                }
                guard !Task.isCancelled, let self, self.isActive, !self.subscribers.isEmpty else { return }
                guard self.model?.playback?.isPlaying == true else {
                    self.model?.refreshPlaybackReadout()
                    return
                }
                self.tick()
            }
        }
    }

    private func stopTicking() {
        tickTask?.cancel()
        tickTask = nil
    }

    private func tick() {
        tickCountForTesting += 1
        // A queued Observation callback may not have run yet. If controller
        // state changed since the last readout, this tick must apply the new
        // seam schedule instead of consuming that change while preserving it.
        let canPreserveSeamDeadline = lastSnapshot == currentSnapshot()
        model?.refreshPlaybackReadout(preservingSeamDeadline: canPreserveSeamDeadline)
    }
}

extension WiltedMacModel {
    /// Subscribes a visible player surface to the shared readout clock.
    func subscribeToPlaybackReadout() async {
        let clock: WiltedMacPlaybackReadoutClock
        if let playbackReadoutClock {
            clock = playbackReadoutClock
        } else {
            clock = WiltedMacPlaybackReadoutClock(model: self)
            playbackReadoutClock = clock
        }
        await clock.subscribe()
    }
}
#endif
