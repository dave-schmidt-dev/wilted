import Foundation

#if canImport(WiltedProducer)
import WiltedDomain
import WiltedProducer
#endif

/// What a playback command asks for. Every entry point that changes what is
/// loaded, where the playhead is, or whether audio runs is one of these.
enum WiltedMacPlaybackCommandKind: Equatable, Sendable {
    case start, pause, select, seek, restart, recover, stop

    /// Whether the command ends with audio running when it succeeds, so a
    /// later seek knows it is cancelling a start rather than moving playback.
    var startsAudio: Bool { self == .start || self == .select }
}

/// One issued command. The token orders it against every other command; the
/// item and revision record what it was issued against, so a command that
/// acts on the loaded media goes stale when an auto-advance replaces it.
struct WiltedMacPlaybackCommand: Equatable, Sendable {
    let token: UInt64
    let kind: WiltedMacPlaybackCommandKind
    let itemID: String?
    let revisionID: String?
}

struct WiltedMacPlaybackPending: Equatable, Sendable {
    let command: WiltedMacPlaybackCommand
    let message: String
}

enum WiltedMacPlaybackFailureKind: Equatable, Sendable {
    case refused, missingMedia, notReady, unreadable, routeFault, unavailable
}

/// The visible outcome of the newest command that failed. A newer command
/// clears it; a stale command can never write it.
struct WiltedMacPlaybackFailure: Equatable, Sendable {
    let kind: WiltedMacPlaybackFailureKind
    let itemID: String?
    let message: String
}

struct WiltedMacSpeedSaveStatus: Equatable, Sendable {
    enum Phase: Equatable, Sendable { case saving, saved, failed }
    let operation: UInt64
    let itemID: String
    let speed: Double
    let phase: Phase
    let message: String
}

/// The one automatic route recovery is spent per item, revision and session.
struct WiltedMacPlaybackRecoveryScope: Equatable, Sendable {
    let itemID: String
    let revisionID: String
    let sessionID: String
}

/// Thrown inside a command effect when a newer command has taken over.
struct WiltedMacPlaybackSuperseded: Error {}

/// The command owner's state, held in one stored property on the model.
/// An automatic advance owed from one generation.
struct WiltedMacAutomaticAdvance: Equatable {
    let serial: UInt64
    let generation: UInt64
}

/// What an automatic advance may do when its awaits finish.
enum WiltedMacAdvanceClaim: Equatable {
    /// Nothing newer happened: start the next episode.
    case owns
    /// An explicit Pause cancelled it: play nothing next.
    case paused
    /// A newer command or advance owns the player: touch nothing.
    case superseded
}

struct WiltedMacPlaybackCommandState {
    var generation: UInt64 = 0
    /// The newest selection's token, so a selection can tell a newer selection
    /// (skip everything) from a newer pause or seek (keep what landed).
    var selectionToken: UInt64 = 0
    var pending: WiltedMacPlaybackPending?
    var failure: WiltedMacPlaybackFailure?
    var tail: Task<Void, Never>?
    var recoveryScope: WiltedMacPlaybackRecoveryScope?
    /// The owed automatic advance (an episode ending, Mark finished); nil
    /// once claimed, superseded or cancelled by Pause.
    var automaticAdvance: UInt64?
    var advanceSerial: UInt64 = 0
    /// The advance an explicit Pause cancelled, so its owner can unload.
    var pausedAdvance: UInt64?
    var speedOperation: UInt64 = 0
    var speedSave: WiltedMacSpeedSaveStatus?
    /// Speed saves that have finished, current or stale; lets a caller
    /// await a stale save without a timer.
    var settledSpeedSaves = 0
    /// Test seam: runs after a command is admitted and before its effect.
    var beforeEffectForTesting: (@MainActor (WiltedMacPlaybackCommand) async -> Void)?
    /// Test seam: replaces the durable speed write.
    var speedSaveForTesting: (@MainActor (Double) async throws -> Void)?
}

enum WiltedMacPlaybackCopy {
    static let starting = "Starting playback…"
    static let pausing = "Pausing…"
    static let refused = "Playback refused. Your position is kept."
    static let missing = "This episode's saved audio is unavailable."
    static let notReady = "Audio is not ready. Finish preparation first."
    static let unreadable = "This episode's saved audio could not be opened."
    static let routeRetrying = "Audio route unavailable. Retrying once…"
    static let routeRecovering = "Recovering audio…"
    static let routeFailed = "Audio route recovery failed."
    static let unavailable = "Playback is unavailable."
    static let pauseNotSaved = "Paused. Your position could not be saved."
    static let speedSaving = "Saving speed…"
    static let speedSaved = "Speed saved"

    static func speedFailed(current: Double, restart: Double) -> String {
        "Speed save failed. Current speed \(rate(current)); restart uses \(rate(restart))."
    }

    static func rate(_ value: Double) -> String {
        "\(value.formatted(.number.precision(.fractionLength(0...2))))×"
    }
}

#if canImport(WiltedProducer)
extension WiltedMacModel {
    // MARK: Owner

    /// Issues a command: it supersedes every earlier one, publishes its
    /// pending state before any await, and runs after the previous command's
    /// effect has finished, so effects never interleave.
    @discardableResult
    func issuePlaybackCommand(
        _ kind: WiltedMacPlaybackCommandKind,
        pending message: String?,
        target itemID: String? = nil,
        failureMessage: String = WiltedMacPlaybackCopy.unavailable,
        effect: @escaping @MainActor (WiltedMacPlaybackCommand) async throws -> Void
    ) -> WiltedMacPlaybackCommand {
        // While the app is closing (a quit draining, a fixture tearing down)
        // only Pause and Stop are admitted; anything else is a dead command.
        if isClosingTemporaryState, kind != .pause, kind != .stop {
            return WiltedMacPlaybackCommand(token: .max, kind: kind, itemID: itemID, revisionID: nil)
        }
        playbackCommands.generation &+= 1
        let command = WiltedMacPlaybackCommand(
            token: playbackCommands.generation, kind: kind,
            itemID: itemID ?? playback?.itemID?.rawValue,
            revisionID: itemID == nil ? playback?.revisionID?.rawValue : nil
        )
        if kind == .select { playbackCommands.selectionToken = command.token }
        playbackCommands.pending = message.map { WiltedMacPlaybackPending(command: command, message: $0) }
        // The newer intent replaces the older answer, including the error
        // line it wrote, but never an error something else wrote.
        if let failure = playbackCommands.failure, playbackError == failure.message { playbackError = nil }
        playbackCommands.failure = nil
        enqueuePlaybackEffect { [weak self] in
            guard let self else { return }
            defer { self.settlePlaybackCommand(command) }
            guard self.isCurrentPlaybackCommand(command) else { return }
            do {
                if let hook = self.playbackCommands.beforeEffectForTesting {
                    await hook(command)
                    try self.ensureCurrentPlaybackCommand(command)
                }
                try await effect(command)
            } catch is WiltedMacPlaybackSuperseded {
            } catch is CancellationError {
            } catch {
                await self.recordPlaybackCommandFailure(error, for: command, fallback: failureMessage)
            }
        }
        return command
    }

    /// Runs `body` after every effect already queued, without superseding
    /// anything: background checkpoints are serialized, not commands.
    func enqueuePlaybackEffect(_ body: @escaping @MainActor () async -> Void) {
        let previous = playbackCommands.tail
        let task = Task { @MainActor in
            await previous?.value
            await body()
        }
        playbackCommands.tail = task
        playbackOperationTask = task
    }

    /// Current means no newer command exists and, for commands acting on the
    /// loaded media, that media has not been replaced underneath it.
    func isCurrentPlaybackCommand(_ command: WiltedMacPlaybackCommand) -> Bool {
        guard playbackCommands.generation == command.token else { return false }
        switch command.kind {
        case .select, .pause, .stop: return true
        case .start, .seek, .restart, .recover:
            return playback?.itemID?.rawValue == command.itemID
                && playback?.revisionID?.rawValue == command.revisionID
        }
    }

    func ensureCurrentPlaybackCommand(_ command: WiltedMacPlaybackCommand) throws {
        guard isCurrentPlaybackCommand(command) else { throw WiltedMacPlaybackSuperseded() }
    }

    /// Selections are only fenced by a newer selection: a newer pause or seek
    /// still lets what already landed be reflected, but not started.
    func ensureNewestSelection(_ command: WiltedMacPlaybackCommand) throws {
        guard playbackCommands.selectionToken == command.token else { throw WiltedMacPlaybackSuperseded() }
    }

    private func settlePlaybackCommand(_ command: WiltedMacPlaybackCommand) {
        if playbackCommands.pending?.command.token == command.token { playbackCommands.pending = nil }
        if command.kind == .recover {
            audioRouteRecoveryInFlight = playbackCommands.pending?.command.kind == .recover
        }
    }

    /// Whether the players show the command answer line: something is
    /// pending, or the newest command failed. Every player reads this.
    var showsPlaybackCommandResult: Bool {
        playbackCommands.pending != nil || playbackCommands.failure != nil
    }

    /// Retry is offered for a refused start only; a route fault keeps its
    /// own Recover audio control, so one fault never shows two buttons.
    var canRetryPlayback: Bool {
        playbackCommands.pending == nil && playbackCommands.failure?.kind == .refused
    }

    // MARK: Transport commands

    /// The primary control and the space bar. A press while a command is
    /// pending coalesces into it, so a repeat never reads as Pause -- unless
    /// audio is already audible, in which case the press means Pause.
    func togglePlayback() {
        guard let playback else { return }
        if let pending = playbackCommands.pending {
            if pending.command.kind.startsAudio, playback.liveIsPlaying { pausePlayback() }
            return
        }
        if playback.liveIsPlaying || isPlaying { pausePlayback() } else { startPlayback() }
    }

    /// An explicit start: coalesces into a pending command and is ignored
    /// while audio already runs.
    func startPlayback() {
        guard let playback, playbackCommands.pending == nil,
              !(playback.liveIsPlaying || isPlaying) else { return }
        issuePlaybackCommand(.start, pending: WiltedMacPlaybackCopy.starting) { [weak self] command in
            guard let self else { return }
            // Play reads the phone's newest position first (bounded; a failure changes nothing).
            await self.refreshPhonePositionBeforePlay()
            try self.ensureCurrentPlaybackCommand(command)
            try await self.startLoadedPlayback(playback)
        }
    }

    /// Explicit or system Pause. It supersedes a pending start, so the start
    /// never reaches the backend, and it is honoured with nothing loaded yet.
    func pausePlayback() {
        // An explicit Pause also means "do not move on to the next episode".
        if let owed = playbackCommands.automaticAdvance { playbackCommands.pausedAdvance = owed }
        playbackCommands.automaticAdvance = nil
        guard let playback else { return }
        let startPending = playbackCommands.pending?.command.kind.startsAudio == true
        guard startPending || playback.liveIsPlaying || isPlaying,
              playbackCommands.pending?.command.kind != .pause else { return }
        issuePlaybackCommand(.pause, pending: WiltedMacPlaybackCopy.pausing,
                             failureMessage: WiltedMacPlaybackCopy.pauseNotSaved) { [weak self] _ in
            guard let self else { return }
            defer { self.isPlaying = playback.liveIsPlaying }
            guard playback.revisionID != nil else { return }
            try await playback.pause()
            self.refreshPlaybackReadout()
            await self.queueCurrentPlaybackCheckpoint()
        }
    }

    /// Records that an automatic advance is owed from the current
    /// generation. A later command, a later advance, or an explicit Pause
    /// supersedes it.
    func beginAutomaticAdvance() -> WiltedMacAutomaticAdvance {
        playbackCommands.advanceSerial &+= 1
        playbackCommands.automaticAdvance = playbackCommands.advanceSerial
        return WiltedMacAutomaticAdvance(serial: playbackCommands.advanceSerial,
                                         generation: playbackCommands.generation)
    }

    /// Whether `advance` still owns what plays next. Claiming consumes it, so
    /// it can start at most one episode.
    func claimAutomaticAdvance(_ advance: WiltedMacAutomaticAdvance) -> WiltedMacAdvanceClaim {
        guard playbackCommands.generation == advance.generation else { return .superseded }
        if playbackCommands.automaticAdvance == advance.serial {
            playbackCommands.automaticAdvance = nil
            return .owns
        }
        return playbackCommands.pausedAdvance == advance.serial ? .paused : .superseded
    }

    /// The idle and refusal retry: a fresh explicit start.
    func retryPlayback() { startPlayback() }

    /// A selection's start: only the newest command starts audio, and once
    /// the backend has answered the press is answered too, so a toggle made
    /// while the selection finishes its bookkeeping reads as Pause.
    func startIfCurrent(_ playback: PlaybackController, for command: WiltedMacPlaybackCommand) throws {
        guard isCurrentPlaybackCommand(command) else { return }
        _ = try playback.start()
        isPlaying = playback.isPlaying
        if playbackCommands.pending?.command.token == command.token { playbackCommands.pending = nil }
    }

    /// Starts the loaded media and mirrors only what the backend reports.
    func startLoadedPlayback(_ playback: PlaybackController) async throws {
        _ = try playback.start()
        isPlaying = playback.isPlaying
        refreshPlaybackReadout()
        await queueCurrentPlaybackCheckpoint()
    }

    /// A seek or scrub. Superseding a pending start cancels that start, so
    /// the result is paused at the new position rather than playing.
    func seekPlayback(publishesJump: Bool = false,
                      _ move: @escaping @MainActor (PlaybackController) async throws -> Void) {
        guard let playback else { return }
        let cancelsStart = playbackCommands.pending?.command.kind.startsAudio == true
        issuePlaybackCommand(.seek, pending: nil) { [weak self] _ in
            guard let self else { return }
            if cancelsStart, playback.liveIsPlaying { try await playback.pause() }
            try await move(playback)
            self.isPlaying = playback.isPlaying
            self.refreshPlaybackReadout()
            if publishesJump { self.publishNowPlaying(force: true) }
            await self.queueCurrentPlaybackCheckpoint()
        }
    }

    /// Starts a new playback session and publishes its durable checkpoint.
    func restartPlayback() {
        guard let playback else { return }
        issuePlaybackCommand(.restart, pending: nil,
                             failureMessage: "Playback restart is unavailable.") { [weak self] _ in
            guard let self else { return }
            try await playback.restart()
            self.isPlaying = playback.isPlaying
            self.refreshPlaybackReadout()
            await self.queueCurrentPlaybackCheckpoint()
        }
    }

    /// Records a playback fault and gives the backend one automatic chance to
    /// rebuild itself, per item, revision and session, before exposing a
    /// manual retry.
    func reportAudioRouteFault(_ message: String) {
        playbackError = message
        refreshAudioRouteRecoveryBudget()
        audioRouteFault = true
        guard !audioRouteRecoveryAttempted else { return }
        audioRouteRecoveryAttempted = true
        recoverAudioRoute(automatic: true)
    }

    func recoverAudioRoute() { recoverAudioRoute(automatic: false) }

    private func recoverAudioRoute(automatic: Bool) {
        guard let playback, !audioRouteRecoveryInFlight else { return }
        audioRouteRecoveryInFlight = true
        audioRouteFault = false
        let message = automatic ? WiltedMacPlaybackCopy.routeRetrying : WiltedMacPlaybackCopy.routeRecovering
        issuePlaybackCommand(.recover, pending: message) { [weak self] command in
            guard let self else { return }
            do {
                try await playback.recoverFromRouteChange()
            } catch {
                guard self.playbackCommands.generation == command.token else { return }
                self.markAudioRouteRecoveryFailed(itemID: command.itemID)
                return
            }
            try self.ensureCurrentPlaybackCommand(command)
            self.audioRouteFault = false
            self.playbackError = nil
            self.isPlaying = playback.isPlaying
            self.refreshPlaybackReadout()
        }
    }

    private func markAudioRouteRecoveryFailed(itemID: String?) {
        self.audioRouteFault = true
        playbackError = WiltedMacPlaybackCopy.routeFailed
        playbackCommands.failure = WiltedMacPlaybackFailure(
            kind: .routeFault, itemID: itemID, message: WiltedMacPlaybackCopy.routeFailed
        )
    }

    /// A new item, revision or session earns a fresh automatic recovery.
    func refreshAudioRouteRecoveryBudget() {
        guard let playback, let itemID = playback.itemID, let revisionID = playback.revisionID else { return }
        let scope = WiltedMacPlaybackRecoveryScope(
            itemID: itemID.rawValue, revisionID: revisionID.rawValue, sessionID: playback.sessionID ?? ""
        )
        guard playbackCommands.recoveryScope != scope else { return }
        playbackCommands.recoveryScope = scope
        audioRouteRecoveryAttempted = false
    }

    // MARK: Failures

    /// Classifies a failure for the newest command only. Missing or unready
    /// media never touches the route budget; only a typed route fault does.
    private func recordPlaybackCommandFailure(
        _ error: Error, for command: WiltedMacPlaybackCommand, fallback: String
    ) async {
        guard playbackCommands.generation == command.token else { return }
        if let playback { isPlaying = playback.liveIsPlaying }
        let failure: WiltedMacPlaybackFailure
        switch error {
        case PlaybackTransportError.backendRefused(let id):
            failure = .init(kind: .refused, itemID: id.rawValue, message: WiltedMacPlaybackCopy.refused)
        case PlaybackTransportError.routeUnavailable:
            await recoverRouteForCommand(command)
            return
        case PlaybackControllerError.podcastMediaUnavailable(let id):
            let episodeIndex = episodes.firstIndex { $0.id == id.rawValue }
            let notReady = episodeIndex.map {
                episodes[$0].downloadState != .completed || !episodes[$0].preparationState.isPrepared
            } ?? false
            if let episodeIndex { episodes[episodeIndex].isReadyMediaAvailable = false }
            failure = .init(kind: notReady ? .notReady : .missingMedia, itemID: id.rawValue,
                            message: notReady ? WiltedMacPlaybackCopy.notReady : WiltedMacPlaybackCopy.missing)
        case PlaybackControllerError.podcastMediaUnreadable(let id):
            failure = .init(kind: .unreadable, itemID: id.rawValue, message: WiltedMacPlaybackCopy.unreadable)
        default:
            failure = .init(kind: .unavailable, itemID: command.itemID, message: fallback)
        }
        playbackCommands.failure = failure
        playbackError = failure.message
    }

    /// A typed route fault inside a command spends the scope's one automatic
    /// recovery, then resumes the command's start if it had one.
    private func recoverRouteForCommand(_ command: WiltedMacPlaybackCommand) async {
        refreshAudioRouteRecoveryBudget()
        guard let playback, !audioRouteRecoveryAttempted else {
            markAudioRouteRecoveryFailed(itemID: command.itemID)
            return
        }
        audioRouteRecoveryAttempted = true
        playbackCommands.pending = WiltedMacPlaybackPending(command: command, message: WiltedMacPlaybackCopy.routeRetrying)
        do {
            try await playback.recoverFromRouteChange()
            guard isCurrentPlaybackCommand(command) else { return }
            if command.kind.startsAudio { _ = try playback.start() }
            audioRouteFault = false
            playbackError = nil
            isPlaying = playback.isPlaying
            refreshPlaybackReadout()
        } catch {
            guard playbackCommands.generation == command.token else { return }
            isPlaying = playback.liveIsPlaying
            markAudioRouteRecoveryFailed(itemID: command.itemID)
        }
    }
}
#endif
