import Foundation
import WiltedDomain
import WiltedLibrary

/// One locally observed boundary in an iOS cached start.
///
/// Every stage is a boundary on this phone: `acknowledged` is the publication
/// of the pending row state, `playCalled` the return of the engine's play
/// call. None of them is rendered, scheduled or audible timing, so a derived
/// wait must never be read as "time to sound".
enum LibraryPlaybackTraceStage: String, CaseIterable, Sendable {
    case acknowledged
    case admissionBegan
    case admissionSettled
    case loadCalled
    case sessionActivated
    case playCalled
    case settled
}

/// A wait the trace derives from two stages of one command, named for its
/// boundaries so a report cannot be mistaken for rendered-timing evidence.
enum LibraryPlaybackTraceWait: String, CaseIterable, Sendable {
    case acknowledgedToAdmissionSettled = "acknowledged-to-admissionSettled"
    case acknowledgedToPlayCalled = "acknowledged-to-playCalled"
    case loadCalledToPlayCalled = "loadCalled-to-playCalled"
    case acknowledgedToSettled = "acknowledged-to-settled"

    fileprivate var from: LibraryPlaybackTraceStage {
        switch self {
        case .acknowledgedToAdmissionSettled: .acknowledged
        case .acknowledgedToPlayCalled: .acknowledged
        case .loadCalledToPlayCalled: .loadCalled
        case .acknowledgedToSettled: .acknowledged
        }
    }

    fileprivate var to: LibraryPlaybackTraceStage {
        switch self {
        case .acknowledgedToAdmissionSettled: .admissionSettled
        case .acknowledgedToPlayCalled: .playCalled
        case .loadCalledToPlayCalled: .playCalled
        case .acknowledgedToSettled: .settled
        }
    }
}

/// A bounded, monotonic, owner-data-free trace of cached admissions and
/// player effects.
///
/// It stores stage names, opaque command tokens and monotonic offsets only:
/// no episode or show titles, no entry or revision identifiers, no URLs and
/// no file paths. The event buffer is fixed-size and drops its oldest entry
/// when full, so tracing memory never grows with library size.
final class LibraryPlaybackTrace: @unchecked Sendable {
    struct Event: Equatable, Sendable {
        let sequence: UInt64
        let stage: LibraryPlaybackTraceStage
        let token: UInt64
        let offsetNanos: UInt64
    }

    /// One measured wait with its sample count, in whole microseconds.
    struct Summary: Equatable, Sendable {
        let wait: LibraryPlaybackTraceWait
        let sampleCount: Int
        let medianMicros: Int
        let p95Micros: Int
        let maxMicros: Int
    }

    static let shared = LibraryPlaybackTrace()
    static let capacity = 4096
    /// Task 1.2's pre-audio gate, set from the Task 1.1 baseline: the p95 of
    /// `acknowledged-to-playCalled` on the synthetic held-admission fixture.
    /// It bounds dispatch work only; it says nothing about when audio becomes
    /// audible.
    static let preAudioTargetMilliseconds = 250

    private let lock = NSLock()
    private var origin: ContinuousClock.Instant?
    private var nextSequence: UInt64 = 0
    private var storedEvents: [Event] = []
    private var oldestEventIndex = 0
    private var enabled = false

    var isEnabled: Bool {
        get { lock.withLock { enabled } }
        set { lock.withLock { enabled = newValue } }
    }

    func record(_ stage: LibraryPlaybackTraceStage, token: UInt64 = 0) {
        guard token != 0 else { return }
        lock.withLock {
            guard enabled else { return }
            let now = ContinuousClock.now
            let origin = self.origin ?? now
            self.origin = origin
            let elapsed = origin.duration(to: now)
            let components = elapsed.components
            let nanos = UInt64(max(0, components.seconds)) * 1_000_000_000
                + UInt64(max(0, components.attoseconds)) / 1_000_000_000
            self.nextSequence &+= 1
            let event = Event(sequence: self.nextSequence, stage: stage, token: token, offsetNanos: nanos)
            if storedEvents.count < Self.capacity {
                storedEvents.append(event)
            } else {
                storedEvents[oldestEventIndex] = event
                oldestEventIndex = (oldestEventIndex + 1) % Self.capacity
            }
        }
    }

    func reset() {
        lock.withLock {
            storedEvents.removeAll(keepingCapacity: true)
            origin = nil
            nextSequence = 0
            oldestEventIndex = 0
        }
    }

    func events() -> [Event] {
        lock.withLock {
            guard oldestEventIndex != 0 else { return storedEvents }
            return Array(storedEvents[oldestEventIndex...]) + Array(storedEvents[..<oldestEventIndex])
        }
    }

    func offsetNanos(_ stage: LibraryPlaybackTraceStage, token: UInt64) -> UInt64? {
        events().last { $0.token == token && $0.stage == stage }?.offsetNanos
    }

    func measuredWait(_ wait: LibraryPlaybackTraceWait, token: UInt64) -> UInt64? {
        guard let from = offsetNanos(wait.from, token: token),
              let to = offsetNanos(wait.to, token: token),
              to >= from else { return nil }
        return to - from
    }

    /// One summary per wait that has at least one complete sample pair.
    func summaries() -> [Summary] {
        let tokens = Set(events().map(\.token))
        return LibraryPlaybackTraceWait.allCases.compactMap { wait in
            let samples = tokens.compactMap { measuredWait(wait, token: $0) }.sorted()
            guard !samples.isEmpty else { return nil }
            return Summary(
                wait: wait, sampleCount: samples.count,
                medianMicros: Self.micros(Self.percentile(samples, 0.5)),
                p95Micros: Self.micros(Self.percentile(samples, 0.95)),
                maxMicros: Self.micros(samples[samples.count - 1])
            )
        }
    }

    /// The trace as bounded text. It names the call-boundary limits of its own
    /// stages, so no reader can mistake acknowledgment or a play call for
    /// rendered or audible timing, and it carries no owner data.
    func report() -> String {
        let events = events()
        var lines = [
            "ios-playback-stage-trace events=\(events.count) tokens=\(Set(events.map(\.token)).count) capacity=\(Self.capacity)",
            "limits: acknowledged=dispatch-boundary playCalled=call-boundary sessionActivated=session-boundary; not rendered-or-audible timing",
            "target: acknowledged-to-playCalled p95<=\(Self.preAudioTargetMilliseconds)ms before Task 1.2 (dispatch boundary only)"
        ]
        for summary in summaries() {
            lines.append(
                "wait \(summary.wait.rawValue) n=\(summary.sampleCount) medianUs=\(summary.medianMicros) "
                    + "p95Us=\(summary.p95Micros) maxUs=\(summary.maxMicros)"
            )
        }
        return lines.joined(separator: "\n")
    }

    private static func micros(_ nanos: UInt64) -> Int { Int(nanos / 1_000) }

    private static func percentile(_ sorted: [UInt64], _ fraction: Double) -> UInt64 {
        let rank = max(1, Int((Double(sorted.count) * fraction).rounded(.up)))
        return sorted[min(sorted.count, rank) - 1]
    }
}

/// What one start command did, so each caller reacts to its own result rather than reading the
/// player afterwards (which another command may have changed meanwhile).
enum LibraryStartOutcome: Equatable, Sendable {
    /// A new episode was loaded and plays from the start.
    case started
    /// The episode plays from a saved position, or the loaded one was paused and plays again.
    case resumed
    /// The episode was already loaded and playing; nothing changed.
    case alreadyPlaying
    /// The phone's primary toggle paused the playing episode.
    case paused
    case failed(LibraryStartFailure)
    /// A newer command (another start, a pause, a seek, a stop) replaced this one before it reached the player.
    case superseded
    /// Queue/media eligibility or an automatic start condition changed during the cache lookup.
    case declined

    /// True for the outcomes that leave the chosen episode playing: CarPlay opens Now Playing only for these.
    var opensNowPlaying: Bool {
        switch self {
        case .started, .resumed, .alreadyPlaying: true
        case .paused, .failed, .superseded, .declined: false
        }
    }
}

/// Why a start failed, in the player's words and in the listener's.
enum LibraryStartFailure: Equatable, Sendable {
    case missingMedia
    case unreadableFile
    case audioSession
    case engineRefused
    /// No player is attached yet (the runtime has not prepared).
    case playerUnavailable

    /// The reason `LibraryPlayer.Status.failed` carries.
    var playerReason: String {
        switch self {
        case .missingMedia: "The audio is not downloaded"
        case .unreadableFile: "Could not open the audio file"
        case .audioSession: "Could not start the audio session"
        case .engineRefused: "The audio engine refused to play"
        case .playerUnavailable: "The player is not ready"
        }
    }

    /// What the listener reads; every message says what to do next.
    var message: String {
        switch self {
        case .missingMedia: "Audio missing. Download it before playing."
        case .unreadableFile: "Audio file could not be opened. Download it again."
        case .audioSession: "Audio route unavailable. Retry playback when ready."
        case .engineRefused: "Playback refused. Your position is kept."
        case .playerUnavailable: "Player not ready yet. Retry playback in a moment."
        }
    }
}

/// Who asked for a start; it decides how a loaded episode and a pending start are treated.
enum LibraryStartKind: Equatable, Sendable {
    /// The phone's primary row or player button: pauses the playing episode, otherwise plays it.
    case toggle
    /// An explicit play (CarPlay row, Siri, Retry): never pauses.
    case select
    /// Auto-continue after a natural end: never replaces a command the listener gave.
    case automatic
}

/// What the Larder shows about the start in flight or the start that just failed.
enum LibraryPlaybackCommandStatus: Equatable, Sendable {
    case starting(entryID: ItemID, title: String)
    case failed(entryID: ItemID, title: String, failure: LibraryStartFailure)

    static let startingText = "Starting playback…"

    var entryID: ItemID {
        switch self {
        case let .starting(entryID, _), let .failed(entryID, _, _): entryID
        }
    }

    var title: String {
        switch self {
        case let .starting(_, title), let .failed(_, title, _): title
        }
    }

    var text: String {
        switch self {
        case .starting: Self.startingText
        case let .failed(_, _, failure): failure.message
        }
    }

    var isFailure: Bool {
        if case .failed = self { true } else { false }
    }
}

/// The one start that owns playback. Every start takes a new token; a start whose token is no
/// longer current when its cache lookup returns was superseded and touches nothing.
@MainActor
final class LibraryStartCommandState {
    struct Pending {
        let token: UInt64
        let entryID: ItemID
        let kind: LibraryStartKind
        let task: Task<LibraryStartOutcome, Never>
    }

    var token: UInt64 = 0
    var pending: Pending?
}

extension LibraryAppModel {
    /// The phone's primary press on a row: plays the cached file from where it was last left, or
    /// pauses it when it is the episode playing now. The start is the newest position (highest
    /// epoch, then latest server date) among the Mac's and this phone's own records for the cached
    /// revision. A second press while the first is still looking up the file joins it: one attempt.
    @discardableResult
    func playCached(_ row: LibraryRow) async -> LibraryStartOutcome {
        await startCached(row, kind: .toggle)
    }

    /// An explicit play (CarPlay row, Siri): a loaded episode plays and is never paused, also when
    /// something else loaded it while the cache was being read.
    @discardableResult
    func playCachedWithoutToggling(_ row: LibraryRow) async -> LibraryStartOutcome {
        await startCached(row, kind: .select)
    }

    /// Plays the row whose start just failed again, as an explicit play.
    @discardableResult
    func retryFailedStart() async -> LibraryStartOutcome? {
        guard case let .failed(entryID, _, _) = playbackCommand,
              let row = queued.first(where: { $0.id == entryID }) else { return nil }
        return await startCached(row, kind: .select)
    }

    /// Starts `row` under the shared pending, duplicate and supersession rules, applied before the
    /// cache lookup. `onlyIf` is asked after the lookup, so an automatic start never overrides a
    /// command given while it looked.
    func startCached(
        _ row: LibraryRow, kind: LibraryStartKind, onlyIf: (@MainActor (LibraryPlayer) -> Bool)? = nil
    ) async -> LibraryStartOutcome {
        guard let player = handoffState.player else { return .failed(.playerUnavailable) }
        let state = commandState
        if let pending = state.pending {
            // The listener's own command always outranks auto-continue.
            if kind == .automatic, pending.kind != .automatic { return .superseded }
            // The same press again while it is still looking: one attempt, one outcome.
            if kind != .automatic, pending.kind == kind, pending.entryID == row.id { return await pending.task.value }
        }
        // The primary toggle on the playing episode is a pause: nothing to look up. The player's
        // command hook cancels any start still pending.
        if kind == .toggle, sameLogicalEpisode(player.item?.entryID, row.id), player.isPlaying {
            player.pause()
            return .paused
        }
        state.token &+= 1
        let token = state.token
        playbackCommand = .starting(entryID: row.id, title: row.title)
        LibraryPlaybackTrace.shared.record(.acknowledged, token: token)
        let task = Task { @MainActor in await self.runStart(row, kind: kind, token: token, onlyIf: onlyIf) }
        state.pending = .init(token: token, entryID: row.id, kind: kind, task: task)
        return await task.value
    }

    /// The lookup and the player effect of one start. Pending is settled before the player is
    /// touched, so the player's own command hook never cancels the start that issued it.
    private func runStart(
        _ row: LibraryRow, kind: LibraryStartKind, token: UInt64, onlyIf: (@MainActor (LibraryPlayer) -> Bool)?
    ) async -> LibraryStartOutcome {
        defer {
            LibraryPlaybackTrace.shared.record(.settled, token: token)
            if commandState.token == token {
                commandState.pending = nil
                if case .starting = playbackCommand { playbackCommand = nil }
            }
        }
        let rawID = backingEntryID(for: row.id)
        // One cache walk serves this start: the verification and a grouped episode's position lookup.
        let walked = await mediaCache.cachedEntries()
        let cached = await verifiedCachedMedia(rawID, token: token, walked: walked)
        guard commandState.token == token else { return .superseded }
        guard let player = handoffState.player else { return failStart(row, .playerUnavailable, kind: kind) }
        if let onlyIf, !onlyIf(player) { return .declined }
        guard queued.contains(where: { $0.id == rawID }), media[rawID] == .onPhone,
              sameLogicalEpisode(rawID, row.id),
              !accountQuarantined else { return .declined }
        guard let cached else { return failStart(row, .missingMedia, kind: kind) }
        let isManual = kind != .automatic
        let item = LibraryPlayer.Item(
            entryID: rawID, title: row.title, showTitle: row.showTitle, fileURL: cached.url, artworkURL: row.artworkURL,
            chapters: row.chapters)
        guard player.item?.entryID != rawID || player.item?.fileURL != cached.url else {
            // Loaded already: playing stays playing (a start made during the lookup is not undone).
            if player.isPlaying { return .alreadyPlaying }
            commandState.pending = nil
            playbackCommand = nil
            guard player.playAdmitted(traceToken: token) else { return failStart(row, player.lastFailure ?? .engineRefused, kind: kind) }
            // A manual resume of the row that is already loaded adopts its forward suffix only
            // when no valid one exists (empty, or captured around another episode): a suffix
            // that already holds this row is never rebased because progress reordered the list.
            if isManual, !handoffState.forwardSequenceIDs.contains(row.id) {
                handoffState.forwardSequenceIDs = manualForwardSuffix(from: row.id)
            }
            return .resumed
        }
        let forwardSequence: [ItemID] = isManual ? manualForwardSuffix(from: row.id) : []
        guard let position = await associatedStartPosition(rawID, revision: cached.revisionID, walked: walked) else {
            return failStart(row, .engineRefused, kind: kind)
        }
        guard commandState.token == token else { return .superseded }
        guard queued.contains(where: { $0.id == rawID }), media[rawID] == .onPhone,
              !accountQuarantined else { return .declined }
        if episodeGroup(rawID) != nil {
            // Re-admit the file verified above after the position lookup's awaits: every fence runs
            // again, without a second walk or a second hash of unchanged bytes.
            guard let final = await verifiedCachedMedia(rawID, token: token, walked: [rawID: cached]),
                  final == cached else { return .declined }
            guard commandState.token == token else { return .superseded }
            guard sameLogicalEpisode(rawID, row.id) else { return .declined }
            if let onlyIf, !onlyIf(player) { return .declined }
        }
        commandState.pending = nil
        playbackCommand = nil
        guard player.start(item, at: position, traceToken: token) else {
            return failStart(row, player.lastFailure ?? .engineRefused, kind: kind)
        }
        if isManual { handoffState.forwardSequenceIDs = forwardSequence }
        return position > 0 ? .resumed : .started
    }

    /// Publishes a failure after the player effect, so the effect's own command hook cannot clear
    /// it. Auto-continue skips a missing file silently and tries the next candidate.
    private func failStart(_ row: LibraryRow, _ failure: LibraryStartFailure, kind: LibraryStartKind) -> LibraryStartOutcome {
        if !(kind == .automatic && failure == .missingMedia) {
            playbackCommand = .failed(entryID: row.id, title: row.title, failure: failure)
        }
        return .failed(failure)
    }

    /// The player's command hook: any transport command replaces a pending start and clears a shown failure.
    func playerCommandArrived() {
        if commandState.pending != nil {
            commandState.token &+= 1
            commandState.pending = nil
        }
        if playbackCommand != nil { playbackCommand = nil }
    }

    /// Takes ownership for a start that does not go through `startCached` (Continue from Mac).
    /// Returns its token; the caller checks it is still current before touching the player.
    func beginExternalStart() -> UInt64 {
        playerCommandArrived()
        commandState.token &+= 1
        return commandState.token
    }

    /// The forward suffix a manual start captures: the shared play order from `entryID` on, so
    /// auto-continue advances through what the list said when the listener chose the row and
    /// never wraps backwards. A row the list does not show still captures itself alone.
    func manualForwardSuffix(from entryID: ItemID) -> [ItemID] {
        let order = playOrderRows
        guard let index = order.firstIndex(where: { sameLogicalEpisode($0.id, entryID) }) else { return [entryID] }
        return Array(order[index...].map(\.id))
    }
}

/// A CarPlay row press: an explicit play, never a toggle. Now Playing opens only when the episode
/// ends up playing, a failure is presented for retry, and the template's completion runs exactly once
/// whatever the outcome.
@MainActor
enum CarRowSelection {
    @discardableResult
    static func run(
        _ row: LibraryRow, model: LibraryAppModel?, openNowPlaying: () -> Void,
        presentFailure: (LibraryStartFailure) -> Void, completion: () -> Void
    ) async -> LibraryStartOutcome {
        defer { completion() }
        guard let model else { return .failed(.playerUnavailable) }
        let outcome = await model.playCachedWithoutToggling(row)
        switch outcome {
        case .started, .resumed, .alreadyPlaying: openNowPlaying()
        case let .failed(failure): presentFailure(failure)
        case .paused, .superseded, .declined: break
        }
        return outcome
    }
}
