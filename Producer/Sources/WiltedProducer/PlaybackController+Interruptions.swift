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
    func speak(_ text: String, finished: @escaping @MainActor () -> Void) -> Bool
    func stop()
}

/// `AVSpeechSynthesizer` behind `BulletinSpeaking`.
@MainActor
public final class SystemBulletinSpeaker: NSObject, BulletinSpeaking, AVSpeechSynthesizerDelegate {
    private let synthesizer = AVSpeechSynthesizer()
    private var current: (id: ObjectIdentifier, finished: @MainActor () -> Void)?

    public override init() {
        super.init()
        synthesizer.delegate = self
    }

    public func speak(_ text: String, finished: @escaping @MainActor () -> Void) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        stop()
        let utterance = AVSpeechUtterance(string: trimmed)
        current = (ObjectIdentifier(utterance), finished)
        synthesizer.speak(utterance)
        return true
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
    /// Transcript cues of an item revision, for pause points.
    let cues: @MainActor (ItemID, RevisionID) async -> (cues: [TranscriptCue]?, timing: TranscriptTiming)
    var tickTask: Task<Void, Never>?
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
    var pausePoint: (bulletinID: String, revisionID: RevisionID, seconds: Double)?
    var pausePointTask: Task<Void, Never>?

    init(reducer: InterruptionReducer, speaker: any BulletinSpeaking, clock: PlaybackInterruptionClock,
         routeSource: (any MacAudioRouteSource)?,
         cues: @escaping @MainActor (ItemID, RevisionID) async -> (cues: [TranscriptCue]?, timing: TranscriptTiming)) {
        self.routeSource = routeSource
        self.reducer = reducer
        self.speaker = speaker
        self.clock = clock
        self.cues = cues
    }

    deinit {
        tickTask?.cancel()
        watchdog?.cancel()
        pausePointTask?.cancel()
        let source = routeSource
        Task { @MainActor in source?.stop() }
    }

    var needsTicks: Bool {
        if !reducer.pending.isEmpty { return true }
        if case .waiting = reducer.state { return true }
        return false
    }

    var isWaiting: Bool {
        if case .waiting = reducer.state { return true }
        return false
    }

    func cancelTasks() {
        tickTask?.cancel()
        tickTask = nil
        watchdog?.cancel()
        watchdog = nil
        pausePointTask?.cancel()
        pausePointTask = nil
        speechToken &+= 1
    }
}

/// Spoken interruptions: news headlines and weather alerts that wait for a pause between spoken
/// cues, hold program audio while a speaker reads them, then put the playhead back and resume.
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

    /// Turns interruptions on. `waitLimit` is how long a non-extreme bulletin waits for a pause point.
    @discardableResult
    public func enableInterruptions(
        speaker: any BulletinSpeaking = SystemBulletinSpeaker(), waitLimit: TimeInterval = 60,
        routeSource: any MacAudioRouteSource = MacAudioRouteLossObserver(),
        protectionFailed: (@MainActor () -> Void)? = nil
    ) -> Bool {
        let enabled = enableInterruptions(speaker: speaker, waitLimit: waitLimit, clock: PlaybackInterruptionClock(),
                                          cues: nil, routeSource: routeSource)
        interruptions?.protectionFailed = protectionFailed
        return enabled
    }

    @discardableResult
    func enableInterruptions(
        speaker: any BulletinSpeaking, waitLimit: TimeInterval, clock: PlaybackInterruptionClock,
        cues: (@MainActor (ItemID, RevisionID) async -> (cues: [TranscriptCue]?, timing: TranscriptTiming))?,
        routeSource: (any MacAudioRouteSource)? = nil
    ) -> Bool {
        disableInterruptions()
        let store = store
        interruptions = PlaybackInterruptions(
            reducer: InterruptionReducer(waitLimit: waitLimit), speaker: speaker, clock: clock, routeSource: routeSource,
            cues: cues ?? { itemID, revisionID in
                let transcript = try? await store.transcript(for: itemID, revisionID: revisionID)
                return (transcript?.cues, transcript?.timing ?? TranscriptTiming.none)
            })
        guard let engine = interruptions else { return false }
        if let routeSource, !routeSource.start(changed: { [weak self, weak engine] in
            guard let self, let engine, self.interruptions === engine else { return }
            self.routeChanged(engine)
        }) {
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
        guard let snapshot = interruptionSnapshot() else { return }
        process(.bulletinArrived(bulletin, snapshot))
    }

    /// The caller's current list of headlines plus its own active alerts; anything waiting that is
    /// no longer listed is dropped.
    public func replaceBulletins(_ list: [Bulletin]) {
        guard let snapshot = interruptionSnapshot() else { return }
        process(.channelReplaced(list, snapshot))
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
        guard let engine = interruptions else { return }
        engine.pausePoint = nil
        engine.pausePointTask?.cancel()
        engine.pausePointTask = nil
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
            case .awaitPausePoint:
                break
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
            // Drop an unspoken bulletin, with the same current-route checks as a completion.
            speechEnded(engine.speechToken, engine: engine)
        }
        ensureTicker()
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
        guard engine.speaker.speak(bulletin.text, finished: { [weak self, weak engine] in
            guard let engine else { return }
            self?.speechEnded(token, engine: engine)
        }) else { return false }
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

    private func routeChanged(_ engine: PlaybackInterruptions) {
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
    private func cancelForRouteLoss(_ engine: PlaybackInterruptions) {
        let checkpoint = engine.heldCheckpoint
        let generation = commandGeneration
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
    }

    // MARK: Ticks and pause points

    private func ensureTicker() {
        guard let engine = interruptions, engine.tickTask == nil, engine.needsTicks else { return }
        engine.tickTask = Task { @MainActor [weak self, weak engine] in
            while !Task.isCancelled {
                guard let engine, let controller = self, controller.interruptions === engine else { return }
                do { try await engine.clock.sleep(engine.isWaiting ? 0.2 : 1) } catch { return }
                controller.interruptionTick()
                if !engine.needsTicks {
                    engine.tickTask = nil
                    return
                }
            }
        }
    }

    /// One look at the clock and the playhead: the wait deadline, a pause point, or an expiry.
    func interruptionTick() {
        guard let engine = interruptions, let snapshot = interruptionSnapshot() else { return }
        if speechHeld {
            // Program audio started under the speech: cut the speech and carry on from the checkpoint.
            if backend.isPlaying { process(.skip(snapshot)) }
            return
        }
        if case let .waiting(bulletin, _) = engine.reducer.state, snapshot.isPlaying {
            if let point = engine.pausePoint, point.bulletinID == bulletin.id, point.revisionID == snapshot.revisionID {
                if snapshot.positionSeconds >= point.seconds {
                    process(.pausePointReached(snapshot))
                    return
                }
            } else {
                findPausePoint(for: bulletin, snapshot: snapshot, engine: engine)
            }
        }
        process(.tick(snapshot))
    }

    private func findPausePoint(for bulletin: Bulletin, snapshot: PlaybackSnapshot, engine: PlaybackInterruptions) {
        guard engine.pausePointTask == nil, case let .waiting(_, deadline) = engine.reducer.state else { return }
        let remaining = max(0, deadline.timeIntervalSince(snapshot.now))
        engine.pausePointTask = Task { @MainActor [weak engine] in
            guard let engine else { return }
            let found = await engine.cues(snapshot.entryID, snapshot.revisionID)
            guard !Task.isCancelled else { return }
            let seconds = PausePointFinder.next(
                after: snapshot.positionSeconds, cues: found.cues, timing: found.timing, waitLimit: remaining)
            engine.pausePointTask = nil
            engine.pausePoint = (bulletin.id, snapshot.revisionID, seconds)
        }
    }
}
