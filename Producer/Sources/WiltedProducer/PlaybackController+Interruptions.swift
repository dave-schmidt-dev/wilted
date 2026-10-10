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
    var speechToken = 0
    /// Where program audio stood when the hold began; a playhead that moved since was a seek.
    var holdPosition: Double?
    var pausePoint: (bulletinID: String, revisionID: RevisionID, seconds: Double)?
    var pausePointTask: Task<Void, Never>?

    init(reducer: InterruptionReducer, speaker: any BulletinSpeaking, clock: PlaybackInterruptionClock,
         cues: @escaping @MainActor (ItemID, RevisionID) async -> (cues: [TranscriptCue]?, timing: TranscriptTiming)) {
        self.reducer = reducer
        self.speaker = speaker
        self.clock = clock
        self.cues = cues
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
    public func enableInterruptions(speaker: any BulletinSpeaking = SystemBulletinSpeaker(), waitLimit: TimeInterval = 60) {
        enableInterruptions(speaker: speaker, waitLimit: waitLimit, clock: PlaybackInterruptionClock(), cues: nil)
    }

    func enableInterruptions(
        speaker: any BulletinSpeaking, waitLimit: TimeInterval, clock: PlaybackInterruptionClock,
        cues: (@MainActor (ItemID, RevisionID) async -> (cues: [TranscriptCue]?, timing: TranscriptTiming))?
    ) {
        disableInterruptions()
        let store = store
        interruptions = PlaybackInterruptions(
            reducer: InterruptionReducer(waitLimit: waitLimit), speaker: speaker, clock: clock,
            cues: cues ?? { itemID, revisionID in
                let transcript = try? await store.transcript(for: itemID, revisionID: revisionID)
                return (transcript?.cues, transcript?.timing ?? TranscriptTiming.none)
            })
    }

    /// Turns interruptions off. A bulletin being spoken is cut and program audio resumes.
    public func disableInterruptions() {
        guard let engine = interruptions else { return }
        if case .speaking = engine.reducer.state, let snapshot = interruptionSnapshot() {
            process(.skip(snapshot))
        }
        engine.speaker.stop()
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
        for effect in engine.reducer.handle(event) {
            switch effect {
            case .awaitPausePoint:
                break
            case let .speak(bulletin, checkpoint):
                if !hold(for: bulletin, at: checkpoint, engine: engine) { speechFailedToStart = true }
            case .stopSpeech:
                engine.speaker.stop()
                engine.watchdog?.cancel()
                engine.speechToken &+= 1
            case let .restore(checkpoint):
                backend.currentTime = checkpoint.positionSeconds
            case .resume:
                speechHeld = false
                if !backend.play() { isPlaying = false }
                meterListening()
            }
        }
        if case .speaking = engine.reducer.state {} else { releaseHold() }
        if speechFailedToStart, let snapshot = interruptionSnapshot() {
            // Fail safe: nothing to listen to, so drop the bulletin, restore and keep playing.
            process(.speechFinished(snapshot))
        }
        ensureTicker()
    }

    /// Stops program audio and starts the speaker. False when speech cannot start.
    private func hold(for bulletin: Bulletin, at checkpoint: SpeechCheckpoint, engine: PlaybackInterruptions) -> Bool {
        meterListening()
        speechHeld = true
        engine.holdPosition = checkpoint.positionSeconds
        backend.pause()
        meterListening()
        speakingBulletin = bulletin
        engine.speechToken &+= 1
        let token = engine.speechToken
        guard engine.speaker.speak(bulletin.text, finished: { [weak self] in self?.speechEnded(token) }) else {
            return false
        }
        let timeout = Self.speechTimeout(forCharacters: bulletin.text.count)
        engine.watchdog?.cancel()
        let clock = engine.clock
        engine.watchdog = Task { @MainActor [weak self] in
            do { try await clock.sleep(timeout) } catch { return }
            self?.speechEnded(token, timedOut: true)
        }
        return true
    }

    private func speechEnded(_ token: Int, timedOut: Bool = false) {
        guard let engine = interruptions, token == engine.speechToken, let snapshot = interruptionSnapshot() else { return }
        engine.watchdog?.cancel()
        if timedOut { engine.speaker.stop() }
        process(.speechFinished(snapshot))
    }

    /// Leaves the hold without resuming audio: the banner goes and the published state follows the backend.
    private func releaseHold() {
        guard speechHeld || speakingBulletin != nil else { return }
        speechHeld = false
        speakingBulletin = nil
        interruptions?.holdPosition = nil
        if !backend.isPlaying, isPlaying { isPlaying = false }
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
