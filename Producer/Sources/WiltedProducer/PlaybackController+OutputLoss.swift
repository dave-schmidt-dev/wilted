import Foundation
import OSLog
import WiltedDomain

private let outputLossLog = Logger(subsystem: "com.zerodelta.wilted", category: "Playback")

/// Whether playback that started on `baseline` may keep running on `current`.
/// `baselineDeviceAvailable` is the route source's live answer for the baseline
/// device; a failed read arrives here as false.
enum OutputLossDecision: Equatable, Sendable {
    case lost
    case keep(MacAudioRoute?)
}

func outputLossDecision(
    baseline: MacAudioRoute?, current: MacAudioRoute?, baselineDeviceAvailable: Bool
) -> OutputLossDecision {
    guard let current, current.isAvailable else { return .lost }
    guard let baseline else { return .keep(current) }
    if current.device != baseline.device {
        guard baseline.isAvailable, baselineDeviceAvailable else { return .lost }
        return .keep(current)
    }
    if baseline.jackConnected == true, current.jackConnected == false { return .lost }
    return .keep(current)
}

private func isLost(_ decision: OutputLossDecision) -> Bool {
    if case .lost = decision { return true }
    return false
}

/// The item a spoken hold's route loss paused, so its checkpoint cannot land on
/// a replacement item if one is loaded before the store answers.
struct OutputLossHoldPause: Sendable {
    let itemID: ItemID?
    let revisionID: RevisionID?
}

/// Pauses when the Mac's output route goes away, matching the iPhone's route-loss
/// response. This watcher uses its own route source, separate from the
/// spoken-bulletin hold's stricter route protection: a hold keeps its own pause,
/// and only the durable checkpoint and UI callback are shared.
@MainActor
extension PlaybackController {
    public func enableOutputLossPause(source: any MacAudioRouteSource = MacAudioRouteLossObserver()) {
        disableOutputLossPause()
        outputLossSource = source
        if isPlaying || backend.isPlaying || speechHeld { beginOutputLossWatch() }
    }

    public func disableOutputLossPause() {
        endOutputLossWatch()
        outputLossSource = nil
    }

    func outputLossPlayingChanged() {
        if isPlaying { beginOutputLossWatch() } else { endOutputLossWatch() }
    }

    func beginOutputLossWatch() {
        guard let source = outputLossSource, !outputLossWatching else { return }
        guard isPlaying || backend.isPlaying || speechHeld else { return }
        outputLossBaseline = source.currentRoute()
        outputLossWatching = true
        guard source.start(changed: { [weak self] in self?.outputLossRouteChanged() }) else {
            outputLossWatching = false
            outputLossBaseline = nil
            return
        }
    }

    func endOutputLossWatch() {
        guard outputLossWatching else { return }
        outputLossWatching = false
        outputLossBaseline = nil
        outputLossSource?.stop()
    }

    func outputLossRouteChanged() {
        guard outputLossWatching, let source = outputLossSource else { return }
        if interruptions?.heldCheckpoint != nil {
            outputLossHoldRouteChanged(source)
            return
        }
        guard isPlaying || backend.isPlaying else {
            endOutputLossWatch()
            return
        }
        let decision = outputLossCurrentDecision(source)
        switch decision {
        case let .keep(route):
            outputLossBaseline = route
        case .lost:
            outputLossPause()
        }
    }

    /// Called before a spoken hold's route-loss pause changes `isPlaying`.
    func outputLossPrepareHoldRouteLoss(_ engine: PlaybackInterruptions) -> OutputLossHoldPause? {
        guard outputLossSource != nil else { return nil }
        var outputLost = false
        if outputLossWatching, let source = outputLossSource {
            outputLost = isLost(outputLossCurrentDecision(source))
        }
        var holdLost = false
        if let source = engine.routeSource {
            let baseline = engine.heldRoute
            let available = baseline.map { source.isDeviceAvailable($0.device) } ?? false
            holdLost = isLost(outputLossDecision(
                baseline: baseline, current: source.currentRoute(), baselineDeviceAvailable: available))
        }
        endOutputLossWatch()
        guard outputLost || holdLost else { return nil }
        return OutputLossHoldPause(itemID: itemID, revisionID: revisionID)
    }

    func outputLossCompleteHoldRouteLoss(_ pause: OutputLossHoldPause?) {
        guard let pause else { return }
        outputLossLog.notice("Paused playback after the audio output was lost during a spoken hold")
        Task { @MainActor [weak self] in
            await self?.outputLossCheckpoint(pause)
        }
    }

    private func outputLossCurrentDecision(_ source: any MacAudioRouteSource) -> OutputLossDecision {
        let baseline = outputLossBaseline
        let current = source.currentRoute()
        let baselineAvailable = baseline.map { source.isDeviceAvailable($0.device) } ?? false
        return outputLossDecision(
            baseline: baseline, current: current, baselineDeviceAvailable: baselineAvailable)
    }

    private func outputLossHoldRouteChanged(_ source: any MacAudioRouteSource) {
        let decision = outputLossCurrentDecision(source)
        guard let engine = interruptions else { return }
        routeChanged(engine)
        // The hold's own source may not have reported this drop yet.
        if case .lost = decision, engine.heldCheckpoint != nil { cancelForRouteLoss(engine) }
    }

    private func outputLossPause() {
        guard outputLossWatching else { return }
        let pause = OutputLossHoldPause(itemID: itemID, revisionID: revisionID)
        endOutputLossWatch()
        do {
            try pauseAudio()
        } catch {
            backend.pause()
            isPlaying = false
            meterListening()
        }
        outputLossLog.notice("Paused playback after the audio output was lost")
        Task { @MainActor [weak self] in
            await self?.outputLossCheckpoint(pause)
        }
    }

    private func outputLossCheckpoint(_ pause: OutputLossHoldPause) async {
        guard itemID == pause.itemID, revisionID == pause.revisionID else { return }
        do {
            try await checkpoint()
        } catch {
            outputLossLog.error(
                "Output-loss checkpoint failed: \(String(describing: error), privacy: .public)")
        }
        guard itemID == pause.itemID, revisionID == pause.revisionID else { return }
        onOutputLostPause?()
    }
}
