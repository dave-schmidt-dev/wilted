import Foundation
import Observation

/// The playback speeds the watch offers.
///
/// The watch cannot import `PlaybackSpeeds` from WiltedKit, so this mirrors its
/// range, step and resulting list exactly; a test keeps the two lists equal.
enum WatchSpeeds {
    /// The increment between offered speeds, matching `PlaybackSpeeds.step`.
    static let step = 0.25
    /// The slowest and fastest speeds, matching `PlaybackSpeeds.range`.
    static let range: ClosedRange<Double> = 0.5...2.0
    /// Every offered speed, slowest first: 0.5, 0.75, 1, 1.25, 1.5, 1.75, 2.
    static let all: [Double] = stride(from: range.lowerBound, through: range.upperBound, by: step).map { $0 }

    /// Whether `rate` is exactly one of the offered speeds.
    static func contains(_ rate: Double) -> Bool { all.contains(rate) }

    /// The next offered speed above `current`, wrapping from the fastest to the slowest.
    static func next(after current: Double) -> Double {
        all.first { $0 > current + 0.001 } ?? range.lowerBound
    }

    /// The next offered speed below `current`, wrapping from the slowest to the fastest.
    static func previous(before current: Double) -> Double {
        all.last { $0 < current - 0.001 } ?? range.upperBound
    }
}

/// The Watch's read model of the phone's playback state.
///
/// The watch renders the last `WatchSnapshot` it decoded and never blocks on the
/// link: while the phone is unreachable it keeps that snapshot on screen with its
/// controls disabled. A command reaches the injected sender only when the phone
/// is reachable and a snapshot exists.
@Observable
@MainActor
final class WatchViewModel {
    /// The sleep lengths the watch offers, matching `WatchBridge.allowedSleepMinutes`.
    static let sleepMinutes = [5, 10, 15, 20, 30, 45, 60, 90]
    /// How long a control may stay pending without the phone confirming or refusing it.
    static let pendingTimeout: TimeInterval = 3

    /// The last successfully decoded snapshot, or nil before one arrives.
    private(set) var snapshot: WatchSnapshot?
    /// When `snapshot` was last decoded; the age falls back to this only when
    /// the snapshot carries no `publishedAt`.
    private(set) var lastReceivedAt: Date?
    /// A short note for the UI after the phone refused a command or could not
    /// receive it; nil while no command has failed.
    private(set) var commandFailed: String?
    /// Whether the system reports the phone as reachable right now.
    var isPhoneReachable = false { didSet { if !isPhoneReachable { endHold() } } }
    /// The transport commands are handed to; set by the session client.
    @ObservationIgnored var commandSender: (@MainActor (WatchCommand) -> Void)?

    /// A semantic control, independent of other choices on the same screen.
    enum ControlKey: Hashable {
        case toggle, skipBack, skipForward
        case episode(String), rate(Double), sleepMinutes(Int), sleepEnd, sleepCancel
    }

    /// What an inbound snapshot must show before a pending control is confirmed.
    private enum Expectation {
        case playing(Bool)
        case speed(Double)
        case movedPosition
        case episode(String)
        case sleepChanged
        case sleepEndOfEpisode
        case sleepOff
    }

    /// The bookkeeping that keeps one pending control from being cleared by a
    /// snapshot the phone published before it applied the command.
    private struct PendingCommand {
        let generation: UUID
        let sentAt: Date
        let baseline: WatchSnapshot?
        let expected: Expectation
    }

    private(set) var pendingControls: Set<ControlKey> = []
    @ObservationIgnored private var pendingCommands: [ControlKey: PendingCommand] = [:]
    /// Owned expiries; read-only internally so regressions can await actual completion.
    @ObservationIgnored private(set) var pendingExpiryTasks: [ControlKey: Task<Void, Never>] = [:]
    private let pendingSleep: @MainActor (TimeInterval) async throws -> Void
    private let now: @MainActor () -> Date
    private(set) var heldAction: WatchCommand.Action?
    @ObservationIgnored private(set) var holdRenewTask: Task<Void, Never>?
    private let holdSleep: @MainActor (TimeInterval) async throws -> Void

    /// Builds the view model with an injectable clock and, when already known, a sender.
    init(
        now: @escaping @MainActor () -> Date = { Date() },
        commandSender: (@MainActor (WatchCommand) -> Void)? = nil,
        pendingSleep: @escaping @MainActor (TimeInterval) async throws -> Void = { try await Task.sleep(for: .seconds($0)) },
        holdSleep: @escaping @MainActor (TimeInterval) async throws -> Void = { try await Task.sleep(for: .seconds($0)) }
    ) {
        self.now = now
        self.commandSender = commandSender
        self.pendingSleep = pendingSleep
        self.holdSleep = holdSleep
    }

    /// How fresh the snapshot on screen is: "Updated just now" under a minute,
    /// "Updated N min ago" after that, and "No update yet" before any arrives.
    ///
    /// The age measures from the phone's `publishedAt`, so a snapshot replayed
    /// at activation shows its true age; receipt time is the fallback for a
    /// legacy payload without the field. A future stamp is clamped to now.
    var ageText: String {
        guard let reference = ageReference else { return "No update yet" }
        let seconds = now().timeIntervalSince(reference)
        guard seconds >= 60 else { return "Updated just now" }
        return "Updated \(Int(seconds / 60)) min ago"
    }

    private var ageReference: Date? {
        guard let snapshot else { return nil }
        if let publishedAt = snapshot.publishedAt { return min(publishedAt, now()) }
        return lastReceivedAt
    }

    /// Whether the phone is reachable and there is state to control.
    var controlsEnabled: Bool { isPhoneReachable && snapshot != nil }

    /// The one-line note shown while the phone is unreachable; nil when reachable.
    var unreachableNote: String? {
        isPhoneReachable ? nil : "iPhone not reachable. Showing the last update."
    }

    /// The rate the last snapshot reports, or 1 before one arrives.
    var currentSpeed: Double { snapshot?.rate ?? 1 }

    /// The active future deadline, checked against the native view's render clock.
    func activeSleepDeadline(at date: Date) -> Date? {
        guard case let .untilDate(deadline) = snapshot?.sleep, deadline > date else { return nil }
        return deadline
    }

    /// Decodes an application context and adopts it, reporting whether it was
    /// adopted. An undecodable context is ignored, so the previous snapshot
    /// stays on screen. A decoded snapshot clears a pending control only when
    /// it shows that control's requested value already applied, when the
    /// command's bounded timeout has passed, or when the control failed; a
    /// snapshot the phone published before applying a command leaves it pending.
    @discardableResult
    func receive(context: [String: Any]) -> Bool {
        guard let decoded = try? WatchLinkCodec.decodeSnapshot(context) else { return false }
        if let heldAction, case let .seek(_, _, _, episode, session, load) = heldAction,
           decoded.nowPlaying?.episodeID != episode || decoded.controlSessionID != session
            || decoded.nowPlaying?.seekSessionID != load || decoded.nowPlaying?.canSeek != true { endHold() }
        expireTimedOutPending()
        clearAppliedPending(against: decoded)
        snapshot = decoded
        lastReceivedAt = now()
        return true
    }

    /// Hands one action to the phone through the injected sender when the phone
    /// is reachable and a snapshot exists; otherwise it is a no-op returning false.
    @discardableResult
    func send(_ action: WatchCommand.Action) -> Bool {
        guard canSend(action), let commandSender else { return false }
        let key = Self.key(for: action), generation = UUID(), sleep = pendingSleep
        let baseline = snapshot
        pendingControls.insert(key)
        pendingCommands[key] = PendingCommand(
            generation: generation, sentAt: now(), baseline: baseline,
            expected: Self.expectation(for: action, in: baseline))
        commandFailed = nil
        pendingExpiryTasks[key] = Task { [weak self] in
            guard !Task.isCancelled else { return }
            try? await sleep(Self.pendingTimeout)
            guard let self, self.pendingCommands[key]?.generation == generation else { return }
            self.clearPending(key)
        }
        commandSender(WatchCommand(action: action))
        return true
    }

    /// Clears the pending state for a command the phone refused or could not
    /// receive, and sets the short note the UI shows.
    func commandDidFail(_ command: WatchCommand, note: String) {
        switch command.action {
        case let .seek(_, _, holdID, _, _, _):
            guard case let .seek(_, _, current, _, _, _) = heldAction, current == holdID else { return }
            endHold()
        default:
            let key = Self.key(for: command.action)
            guard pendingControls.contains(key) else { return }
            clearPending(key)
        }
        commandFailed = note
    }

    /// Eligibility and pending feedback use the exact same semantic key as sending.
    func isPending(_ action: WatchCommand.Action) -> Bool { pendingControls.contains(Self.key(for: action)) }

    func canSend(_ action: WatchCommand.Action) -> Bool {
        guard controlsEnabled, commandSender != nil, !isPending(action) else { return false }
        switch action {
        case let .setRate(rate): return WatchSpeeds.contains(rate)
        case let .startSleep(minutes): return Self.sleepMinutes.contains(minutes)
        default: return true
        }
    }

    var hasPendingSpeed: Bool {
        pendingControls.contains { if case .rate = $0 { return true }; return false }
    }
    var hasPendingSleep: Bool {
        pendingControls.contains {
            switch $0 { case .sleepMinutes, .sleepEnd, .sleepCancel: return true; default: return false }
        }
    }

    private func clearPending(_ key: ControlKey) {
        pendingExpiryTasks[key]?.cancel()
        pendingExpiryTasks.removeValue(forKey: key)
        pendingCommands.removeValue(forKey: key)
        pendingControls.remove(key)
    }

    /// Drops every pending control whose bounded timeout passed, read from the
    /// injectable clock so a test can advance time without sleeping.
    private func expireTimedOutPending() {
        let cutoff = now().addingTimeInterval(-Self.pendingTimeout)
        for key in pendingControls {
            if let sentAt = pendingCommands[key]?.sentAt, sentAt <= cutoff { clearPending(key) }
        }
    }

    /// Clears the pending controls whose requested value the snapshot shows as
    /// applied. Each control checks only its own field, so an unrelated change
    /// in a snapshot cannot confirm it.
    private func clearAppliedPending(against snapshot: WatchSnapshot) {
        for key in pendingControls {
            guard let pending = pendingCommands[key] else { continue }
            if Self.isApplied(pending, to: snapshot) { clearPending(key) }
        }
    }

    private static func isApplied(_ pending: PendingCommand, to snapshot: WatchSnapshot) -> Bool {
        if let baseline = pending.baseline?.publishedAt, let published = snapshot.publishedAt,
           published <= baseline { return false }
        switch pending.expected {
        case let .playing(expected): return snapshot.nowPlaying?.isPlaying == expected
        case let .speed(expected): return snapshot.rate == expected
        case .movedPosition:
            return snapshot.nowPlaying?.positionSeconds != pending.baseline?.nowPlaying?.positionSeconds
        case let .episode(episodeID): return snapshot.nowPlaying?.episodeID == episodeID
        case .sleepChanged: return snapshot.sleep != pending.baseline?.sleep
        case .sleepEndOfEpisode: return snapshot.sleep == .endOfEpisode
        case .sleepOff: return snapshot.sleep == .off
        }
    }

    private static func expectation(
        for action: WatchCommand.Action, in baseline: WatchSnapshot?
    ) -> Expectation {
        switch action {
        case .toggle: return .playing(!(baseline?.nowPlaying?.isPlaying ?? false))
        case .skipBack, .skipForward, .seek: return .movedPosition
        case let .playRow(episodeID): return .episode(episodeID)
        case let .setRate(rate): return .speed(rate)
        case .startSleep: return .sleepChanged
        case .startSleepEndOfEpisode: return .sleepEndOfEpisode
        case .cancelSleep: return .sleepOff
        }
    }

    private static func key(for action: WatchCommand.Action) -> ControlKey {
        switch action {
        case let .seek(_, direction, _, _, _, _): return direction == .forward ? .skipForward : .skipBack
        case .toggle: return .toggle
        case .skipBack: return .skipBack
        case .skipForward: return .skipForward
        case let .playRow(episodeID): return .episode(episodeID)
        case let .setRate(rate): return .rate(rate)
        case let .startSleep(minutes): return .sleepMinutes(minutes)
        case .startSleepEndOfEpisode: return .sleepEnd
        case .cancelSleep: return .sleepCancel
        }
    }

    /// Toggles between play and pause.
    @discardableResult
    func togglePlayPause() -> Bool { send(.toggle) }

    /// Skips back by the phone's standard interval.
    @discardableResult
    func skipBack() -> Bool { send(.skipBack) }

    /// Skips forward by the phone's standard interval.
    @discardableResult
    func skipForward() -> Bool { send(.skipForward) }

    /// Asks the phone to play an up-next row.
    @discardableResult
    func play(episodeID: String) -> Bool { send(.playRow(episodeID: episodeID)) }

    /// Steps to the next offered speed, wrapping at either end.
    @discardableResult
    func stepSpeed(forward: Bool) -> Bool {
        let next = forward ? WatchSpeeds.next(after: currentSpeed) : WatchSpeeds.previous(before: currentSpeed)
        return send(.setRate(next))
    }

    /// Asks the phone to use `rate`; a rate off the phone's list is ignored.
    @discardableResult
    func setSpeed(_ rate: Double) -> Bool {
        guard WatchSpeeds.contains(rate) else { return false }
        return send(.setRate(rate))
    }

    /// Starts a sleep timer of `minutes`; a length off the phone's list is ignored.
    @discardableResult
    func startSleep(minutes: Int) -> Bool {
        guard Self.sleepMinutes.contains(minutes) else { return false }
        return send(.startSleep(minutes: minutes))
    }

    /// Starts a sleep timer that stops at the end of the current episode.
    @discardableResult
    func sleepAtEndOfEpisode() -> Bool { send(.startSleepEndOfEpisode) }

    /// Cancels any running sleep timer.
    @discardableResult
    func cancelSleep() -> Bool { send(.cancelSleep) }
}

extension WatchViewModel {
    @discardableResult
    func beginHold(_ direction: WatchCommand.SeekDirection) -> Bool {
        guard controlsEnabled, let sender = commandSender, let playing = snapshot?.nowPlaying,
              playing.canSeek == true, let load = playing.seekSessionID,
              let session = snapshot?.controlSessionID else { return false }
        endHold()
        let action = WatchCommand.Action.seek(phase: .begin, direction: direction, holdID: UUID(),
            episodeID: playing.episodeID, controlSessionID: session, seekSessionID: load)
        heldAction = action; sender(WatchCommand(action: action))
        guard heldAction == action else { return false }
        holdRenewTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                do { try await self.holdSleep(0.75) } catch { return }
                guard !Task.isCancelled, self.heldAction == action, self.controlsEnabled else { return }
                if case let .seek(_, direction, id, episode, session, load) = action {
                    self.commandSender?(WatchCommand(action: .seek(phase: .renew, direction: direction,
                        holdID: id, episodeID: episode, controlSessionID: session, seekSessionID: load)))
                }
            }
        }
        return true
    }

    func endHold(holdID: UUID? = nil) {
        if let holdID {
            guard case let .seek(_, _, current, _, _, _) = heldAction, current == holdID else { return }
        }
        let action = heldAction; heldAction = nil
        holdRenewTask?.cancel(); holdRenewTask = nil
        if case let .seek(_, direction, id, episode, session, load) = action {
            commandSender?(WatchCommand(action: .seek(phase: .end, direction: direction,
                holdID: id, episodeID: episode, controlSessionID: session, seekSessionID: load)))
        }
    }

    func holdCommandFailed(_ id: UUID) {
        if case let .seek(_, _, current, _, _, _) = heldAction, current == id { endHold() }
    }
}
