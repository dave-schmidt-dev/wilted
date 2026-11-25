import AVFoundation
import Foundation
import WiltedDomain
import WiltedLibrary

/// Speaks a bulletin. Production uses `SystemBulletinSpeaker`; tests inject a stub so they never
/// make a sound.
@MainActor
public protocol BulletinSpeaking: AnyObject {
    /// Starts speaking and returns whether it did. `finished` is called once, on the main actor,
    /// when the speech ends by itself; stopping with `stop()` does not call it.
    /// Implementations must use the `BulletinSpeechGain` helper that matches their audio source.
    func speak(_ text: String, playbackVolume: Float, finished: @escaping @MainActor () -> Void) -> Bool
    /// Starts a bulletin with its stable identity available to voice-specific speakers.
    /// The default keeps existing alert speakers source-compatible.
    func speak(_ bulletin: Bulletin, playbackVolume: Float, finished: @escaping @MainActor () -> Void) -> Bool
    func stop()
}

public extension BulletinSpeaking {
    func speak(_ bulletin: Bulletin, playbackVolume: Float,
               finished: @escaping @MainActor () -> Void) -> Bool {
        speak(bulletin.text, playbackVolume: playbackVolume, finished: finished)
    }
}

/// The volume rule every bulletin speaker must apply, including future cloned-voice speakers.
public enum BulletinSpeechGain {
    /// System generated alerts remain attenuated because they do not have a measured render level.
    public static let playbackAttenuation: Float = 0.5

    /// Returns a speech level at or below the app's playback volume.
    public static func volume(forPlaybackVolume playbackVolume: Float) -> Float {
        guard playbackVolume.isFinite else { return 0 }
        return min(max(playbackVolume, 0), 1) * playbackAttenuation
    }

    /// Uses the full configured level for narration normalized to the podcast target.
    public static func measuredAudioVolume(forPlaybackVolume playbackVolume: Float) -> Float {
        guard playbackVolume.isFinite else { return 0 }
        return min(max(playbackVolume, 0), 1)
    }
}

/// `AVSpeechSynthesizer` behind `BulletinSpeaking`.
@MainActor
public final class SystemBulletinSpeaker: NSObject, BulletinSpeaking, AVSpeechSynthesizerDelegate {
    private let synthesizer: AVSpeechSynthesizer
    private let enqueueUtterance: @MainActor (AVSpeechUtterance) -> Void
    private var current: (id: ObjectIdentifier, finished: @MainActor () -> Void)?

    public override init() {
        let synthesizer = AVSpeechSynthesizer()
        self.synthesizer = synthesizer
        enqueueUtterance = { synthesizer.speak($0) }
        super.init()
        synthesizer.delegate = self
    }

    init(utteranceHandler: @escaping @MainActor (AVSpeechUtterance) -> Void) {
        synthesizer = AVSpeechSynthesizer()
        enqueueUtterance = utteranceHandler
        super.init()
        synthesizer.delegate = self
    }

    public func speak(_ text: String, playbackVolume: Float,
                      finished: @escaping @MainActor () -> Void) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        stop()
        let utterance = AVSpeechUtterance(string: trimmed)
        utterance.volume = BulletinSpeechGain.volume(forPlaybackVolume: playbackVolume)
        current = (ObjectIdentifier(utterance), finished)
        enqueueUtterance(utterance)
        return true
    }

    public func speak(_ bulletin: Bulletin, playbackVolume: Float,
                      finished: @escaping @MainActor () -> Void) -> Bool {
        guard bulletin.kind == .alert else { return false }
        return speak(bulletin.text, playbackVolume: playbackVolume, finished: finished)
    }

    public func stop() {
        guard current != nil else { return }
        current = nil
        synthesizer.stopSpeaking(at: .immediate)
    }

    nonisolated public func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        let id = ObjectIdentifier(utterance)
        Task { @MainActor [weak self] in self?.complete(id) }
    }

    nonisolated public func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        let id = ObjectIdentifier(utterance)
        Task { @MainActor [weak self] in self?.complete(id) }
    }

    private func complete(_ id: ObjectIdentifier) {
        guard let current, current.id == id else { return }
        self.current = nil
        current.finished()
    }
}

/// Time for the interruption engine, replaceable in tests.
struct PlaybackInterruptionClock: Sendable {
    var now: @Sendable () -> Date = { Date() }
    var sleep: @Sendable (TimeInterval) async throws -> Void = { try await Task.sleep(for: .seconds($0)) }
}

/// The reducer and the things its effects act on, held by the controller while interruptions are on.
@MainActor
final class PlaybackInterruptions {
    var reducer: InterruptionReducer
    let speaker: any BulletinSpeaking
    let clock: PlaybackInterruptionClock
    let shouldSpeakHeadline: @MainActor (Bulletin) -> Bool
    let didStartHeadline: @MainActor (Bulletin) -> Void
    var watchdog: Task<Void, Never>?
    var routeSource: (any MacAudioRouteSource)?
    var protectionFailed: (@MainActor () -> Void)?
    var heldRoute: MacAudioRoute?
    var heldCheckpoint: SpeechCheckpoint?
    var speechToken = 0
    var seekRoute: MacAudioRoute?
    var seekOwner: UInt64?
    var seekRouteInvalidations: UInt64 = 0
    var seekIntent: (generation: UInt64, holdSerial: UInt64, wasPlaying: Bool,
                     item: ItemID?, revision: RevisionID?, routeInvalidations: UInt64)?
    /// Where program audio stood when the hold began; a playhead that moved since was a seek.
    var holdPosition: Double?

    init(reducer: InterruptionReducer, speaker: any BulletinSpeaking, clock: PlaybackInterruptionClock,
         routeSource: (any MacAudioRouteSource)?,
         shouldSpeakHeadline: @escaping @MainActor (Bulletin) -> Bool = { _ in true },
         didStartHeadline: @escaping @MainActor (Bulletin) -> Void = { _ in }) {
        self.routeSource = routeSource
        self.reducer = reducer
        self.speaker = speaker
        self.clock = clock
        self.shouldSpeakHeadline = shouldSpeakHeadline
        self.didStartHeadline = didStartHeadline
    }

    deinit {
        watchdog?.cancel()
        let source = routeSource
        Task { @MainActor in source?.stop() }
    }

    func cancelTasks() {
        watchdog?.cancel()
        watchdog = nil
        speechToken &+= 1
    }
}

/// Spoken interruptions: each removed-ad seam snapshots the ready bulletin backlog, holds program
/// audio while that batch is read, then puts the playhead back and resumes.
///
/// The decisions are `InterruptionReducer`'s; this file performs its effects. A hold is not a
/// pause. The hold stops the backend directly, so the published state stays playing, the pause
/// is never reported to the reducer as the listener's, and the listening meter is stopped for
/// its duration. If speech cannot start or never ends, the bulletin is dropped and playback
/// resumes where it was.
@MainActor
extension PlaybackController {
    /// How long a spoken bulletin may take before it is treated as finished.
    static func speechTimeout(forCharacters count: Int) -> TimeInterval { 20 + Double(count) * 0.15 }

    public var interruptionsEnabled: Bool { interruptions != nil }

    /// Enables spoken batches at marked ad seams.
    @discardableResult
    public func enableInterruptions(
        speaker: any BulletinSpeaking = SystemBulletinSpeaker(),
        routeSource: any MacAudioRouteSource = MacAudioRouteLossObserver(),
        spokenHeadlineExpiries: [String: Date] = [:],
        shouldSpeakHeadline: @escaping @MainActor (Bulletin) -> Bool = { _ in true },
        didStartHeadline: @escaping @MainActor (Bulletin) -> Void = { _ in },
        now: @escaping @Sendable () -> Date = { Date() },
        protectionFailed: (@MainActor () -> Void)? = nil
    ) -> Bool {
        let enabled = enableInterruptions(
            speaker: speaker, clock: PlaybackInterruptionClock(now: now),
            routeSource: routeSource, spokenHeadlineExpiries: spokenHeadlineExpiries,
            shouldSpeakHeadline: shouldSpeakHeadline, didStartHeadline: didStartHeadline)
        interruptions?.protectionFailed = protectionFailed
        return enabled
    }

    @discardableResult
    func enableInterruptions(
        speaker: any BulletinSpeaking, clock: PlaybackInterruptionClock,
        routeSource: (any MacAudioRouteSource)? = nil,
        spokenHeadlineExpiries: [String: Date] = [:],
        shouldSpeakHeadline: @escaping @MainActor (Bulletin) -> Bool = { _ in true },
        didStartHeadline: @escaping @MainActor (Bulletin) -> Void = { _ in }
    ) -> Bool {
        disableInterruptions()
        interruptions = PlaybackInterruptions(
            reducer: InterruptionReducer(alreadySpoken: spokenHeadlineExpiries),
            speaker: speaker, clock: clock, routeSource: routeSource,
            shouldSpeakHeadline: shouldSpeakHeadline, didStartHeadline: didStartHeadline)
        guard let engine = interruptions else { return false }
        if let routeSource, !routeSource.start(changed: { [weak self, weak engine] in
            guard let self, let engine, self.interruptions === engine else { return }
            self.routeChanged(engine)
        }) || !routeSource.monitoringAvailable {
            disableInterruptions(resuming: false)
            return false
        }
        return true
    }

    /// Turns interruptions off. A bulletin being spoken is cut and program audio resumes.
    public func disableInterruptions(resuming: Bool = true) {
        guard let engine = interruptions else { return }
        engine.cancelTasks()
        if case .speaking = engine.reducer.state, let snapshot = interruptionSnapshot() {
            process(resuming ? .skip(snapshot) : .routeLost(snapshot))
        }
        engine.routeSource?.stop()
        engine.routeSource = nil
        engine.speaker.stop()
        // Processing a hold's end can schedule pending work. Teardown owns that work too.
        engine.cancelTasks()
        releaseHold()
        interruptions = nil
    }

    /// A bulletin arrived (a headline from the producer, or an alert from the monitor).
    public func deliverBulletin(_ bulletin: Bulletin) {
        if bulletin.kind == .headline, let engine = interruptions,
           !engine.shouldSpeakHeadline(bulletin) { return }
        guard let snapshot = interruptionSnapshot() else { return }
        process(.bulletinArrived(bulletin, snapshot))
    }

    /// The caller's current headlines and active alerts, retaining valid queued headlines.
    public func replaceBulletins(_ list: [Bulletin]) {
        guard let engine = interruptions, let snapshot = interruptionSnapshot() else { return }
        let inactiveHeadlines = (engine.reducer.pending + engine.reducer.remainingInBatch).filter {
            $0.kind == .headline && !engine.shouldSpeakHeadline($0)
        }
        engine.reducer.removePendingBulletins(withIDs: Set(inactiveHeadlines.map(\.id)))
        process(.channelReplaced(list, snapshot))
    }

    /// Starts one batch at the prepared seam where an advertisement was removed.
    @discardableResult
    public func adBreakReached() -> Bool {
        guard let engine = interruptions, let snapshot = interruptionSnapshot(), snapshot.isPlaying else { return false }
        let inactiveHeadlines = engine.reducer.pending.filter {
            $0.kind == .headline && !engine.shouldSpeakHeadline($0)
        }
        engine.reducer.removePendingBulletins(withIDs: Set(inactiveHeadlines.map(\.id)))
        process(.adBreakReached(snapshot))
        if case .speaking = engine.reducer.state { return true }
        return false
    }

    /// The banner's Skip: stop speaking, put the playhead back and resume.
    public func skipSpokenBulletin() {
        guard speechHeld, let snapshot = interruptionSnapshot() else { return }
        process(.skip(snapshot))
    }

    // MARK: Hooks from the controller

    /// `explicitHoldSerial` moved: the listener paused. Speech stops and the playhead goes back;
    /// the pause itself carries on in the caller.
    func interruptionUserPaused() {
        commandGeneration &+= 1
        guard interruptions != nil, let snapshot = interruptionSnapshot() else { return }
        process(.userPaused(snapshot))
    }

    func interruptionItemChanged() {
        guard interruptions != nil else { return }
        process(.itemChanged)
    }

    func beginSeek() -> SeekOwnership {
        let pending = interruptions?.seekIntent
        let inherits = pending.map {
            $0.generation == commandGeneration && $0.holdSerial == explicitHoldSerial
                && $0.item == itemID && $0.revision == revisionID
        } ?? false
        commandGeneration &+= 1
        let engine = (speechHeld || inherits) ? interruptions : nil
        let owner = SeekOwnership(
            generation: commandGeneration, holdSerial: explicitHoldSerial, item: itemID, revision: revisionID,
            wasPlaying: inherits ? pending!.wasPlaying : backend.isPlaying || isPlaying || speechHeld,
            engine: engine, route: inherits ? engine?.seekRoute : engine?.heldRoute,
            routeInvalidations: inherits ? pending!.routeInvalidations : engine?.seekRouteInvalidations ?? 0)
        if let engine {
            engine.seekRoute = owner.route
            engine.seekOwner = owner.generation
            updateSeekIntent(owner, generation: owner.generation)
            // Invalidate before stop(), which may synchronously deliver an old completion.
            engine.speechToken &+= 1
            if let snapshot = interruptionSnapshot() { process(.seekStarted(snapshot)) }
        }
        return owner
    }

    // MARK: Events and effects

    /// The reducer's view of the player now, or nil with nothing loaded.
    func interruptionSnapshot() -> PlaybackSnapshot? {
        guard let engine = interruptions, let itemID, let revisionID else { return nil }
        var generation = commandGeneration
        if speechHeld, let hold = engine.holdPosition, abs(backend.currentTime - hold) > 0.05 { generation &+= 1 }
        return PlaybackSnapshot(
            entryID: itemID, revisionID: revisionID, positionSeconds: livePositionSeconds,
            commandGeneration: generation, isPlaying: backend.isPlaying, now: engine.clock.now())
    }

    private func process(_ event: InterruptionEvent) {
        guard let engine = interruptions else { return }
        var speechFailedToStart = false
        let effectGeneration = commandGeneration
        for effect in engine.reducer.handle(event) {
            guard interruptions === engine, commandGeneration == effectGeneration else { return }
            switch effect {
            case let .speak(bulletin, checkpoint):
                if !hold(for: bulletin, at: checkpoint, engine: engine) { speechFailedToStart = true }
            case .stopSpeech:
                engine.speechToken &+= 1
                engine.watchdog?.cancel()
                engine.speaker.stop()
            case let .restore(checkpoint):
                backend.currentTime = checkpoint.positionSeconds
            case .resume:
                guard routeIsSafe(engine) else {
                    cancelForRouteLoss(engine)
                    return
                }
                speechHeld = false
                if !backend.play() { isPlaying = false }
                meterListening()
            }
        }
        guard interruptions === engine, commandGeneration == effectGeneration else { return }
        if case .speaking = engine.reducer.state {} else { releaseHold() }
        if speechFailedToStart {
            // Keep an unspoken bulletin eligible for the next ad-break batch.
            guard let snapshot = interruptionSnapshot() else { return }
            process(.speechStartFailed(snapshot))
        }
    }

    /// Stops program audio and starts the speaker. False when speech cannot start.
    private func hold(for bulletin: Bulletin, at checkpoint: SpeechCheckpoint, engine: PlaybackInterruptions) -> Bool {
        if engine.heldCheckpoint == nil {
            engine.heldCheckpoint = checkpoint
            engine.heldRoute = engine.routeSource?.currentRoute()
        }
        guard routeIsSafe(engine) else {
            cancelForRouteLoss(engine)
            return true // Cancellation already settled the reducer; do not finish speech again.
        }
        meterListening()
        speechHeld = true
        engine.holdPosition = checkpoint.positionSeconds
        backend.pause()
        meterListening()
        speakingBulletin = bulletin
        engine.speechToken &+= 1
        let token = engine.speechToken
        guard engine.speaker.speak(bulletin, playbackVolume: backend.volume, finished: { [weak self, weak engine] in
            guard let engine else { return }
            self?.speechEnded(token, engine: engine)
        }) else { return false }
        if bulletin.kind == .headline {
            engine.didStartHeadline(bulletin)
            let newlyIneligibleIDs = (engine.reducer.pending + engine.reducer.remainingInBatch).compactMap { candidate in
                candidate.kind == .headline && !engine.shouldSpeakHeadline(candidate) ? candidate.id : nil
            }
            engine.reducer.removePendingBulletins(withIDs: Set(newlyIneligibleIDs))
        }
        let timeout = Self.speechTimeout(forCharacters: bulletin.text.count)
        engine.watchdog?.cancel()
        let clock = engine.clock
        engine.watchdog = Task { @MainActor [weak self, weak engine] in
            do { try await clock.sleep(timeout) } catch { return }
            guard let engine else { return }
            self?.speechEnded(token, engine: engine, timedOut: true)
        }
        return true
    }

    private func speechEnded(_ token: Int, engine: PlaybackInterruptions, timedOut: Bool = false) {
        guard interruptions === engine, token == engine.speechToken,
              let snapshot = interruptionSnapshot() else { return }
        let generation = commandGeneration
        guard routeIsSafe(engine) else { cancelForRouteLoss(engine); return }
        guard interruptions === engine, commandGeneration == generation, token == engine.speechToken else { return }
        engine.watchdog?.cancel()
        engine.speechToken &+= 1
        let endingToken = engine.speechToken
        if timedOut { engine.speaker.stop() }
        guard interruptions === engine, commandGeneration == generation,
              engine.speechToken == endingToken else { return }
        process(.speechFinished(snapshot))
    }

    /// Leaves the hold without resuming audio: the banner goes and the published state follows the backend.
    private func releaseHold() {
        interruptions?.heldRoute = nil
        interruptions?.heldCheckpoint = nil
        guard speechHeld || speakingBulletin != nil else { return }
        speechHeld = false
        speakingBulletin = nil
        interruptions?.holdPosition = nil
        if !backend.isPlaying, isPlaying { isPlaying = false }
    }

    private func routeIsSafe(_ engine: PlaybackInterruptions) -> Bool {
        guard let source = engine.routeSource else { return true }
        guard let current = source.currentRoute(), current.isAvailable,
              let baseline = engine.heldRoute, baseline.isAvailable else { return false }
        return current == baseline
    }

    func routeChanged(_ engine: PlaybackInterruptions) {
        if let route = engine.seekRoute, engine.routeSource?.currentRoute() != route {
            engine.seekRouteInvalidations &+= 1
        }
        if engine.heldCheckpoint != nil, !routeIsSafe(engine) { cancelForRouteLoss(engine) }
        if engine.routeSource?.monitoringAvailable == false {
            let reportFailure = engine.protectionFailed
            disableInterruptions(resuming: false)
            reportFailure?()
        }
    }

    /// Also covers a failed read after restore, when the reducer has already become idle.
    func cancelForRouteLoss(_ engine: PlaybackInterruptions) {
        let checkpoint = engine.heldCheckpoint
        let generation = commandGeneration
        let outputLossPause = outputLossPrepareHoldRouteLoss(engine)
        engine.speechToken &+= 1
        engine.watchdog?.cancel()
        isPlaying = false
        backend.pause()
        guard interruptions === engine, commandGeneration == generation else { return }
        if case .speaking = engine.reducer.state, let snapshot = interruptionSnapshot() {
            process(.routeLost(snapshot))
        } else {
            engine.speaker.stop()
        }
        guard interruptions === engine, commandGeneration == generation else { return }
        if let checkpoint, checkpoint.entryID == itemID, checkpoint.revisionID == revisionID,
           checkpoint.commandGeneration == generation {
            backend.currentTime = checkpoint.positionSeconds
        }
        guard interruptions === engine, commandGeneration == generation else { return }
        releaseHold()
        meterListening()
        outputLossCompleteHoldRouteLoss(outputLossPause)
    }

}
