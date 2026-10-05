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

    /// The last successfully decoded snapshot, or nil before one arrives.
    private(set) var snapshot: WatchSnapshot?
    /// When `snapshot` was last decoded; `ageText` measures from here.
    private(set) var lastReceivedAt: Date?
    /// Whether the system reports the phone as reachable right now.
    var isPhoneReachable = false
    /// The transport commands are handed to; set by the session client.
    @ObservationIgnored var commandSender: (@MainActor (WatchCommand) -> Void)?

    private let now: @MainActor () -> Date

    /// Builds the view model with an injectable clock and, when already known, a sender.
    init(
        now: @escaping @MainActor () -> Date = { Date() },
        commandSender: (@MainActor (WatchCommand) -> Void)? = nil
    ) {
        self.now = now
        self.commandSender = commandSender
    }

    /// How fresh the snapshot on screen is: "Updated just now" under a minute,
    /// "Updated N min ago" after that, and "No update yet" before any arrives.
    var ageText: String {
        guard let lastReceivedAt else { return "No update yet" }
        let seconds = now().timeIntervalSince(lastReceivedAt)
        guard seconds >= 60 else { return "Updated just now" }
        return "Updated \(Int(seconds / 60)) min ago"
    }

    /// Whether the phone is reachable and there is state to control.
    var controlsEnabled: Bool { isPhoneReachable && snapshot != nil }

    /// The one-line note shown while the phone is unreachable; nil when reachable.
    var unreachableNote: String? {
        isPhoneReachable ? nil : "iPhone not reachable. Showing the last update."
    }

    /// The rate the last snapshot reports, or 1 before one arrives.
    var currentSpeed: Double { snapshot?.rate ?? 1 }

    /// Decodes an application context and adopts it. An undecodable context is
    /// ignored, so the previous snapshot stays on screen.
    func receive(context: [String: Any]) {
        guard let decoded = try? WatchLinkCodec.decodeSnapshot(context) else { return }
        snapshot = decoded
        lastReceivedAt = now()
    }

    /// Hands one action to the phone through the injected sender when the phone
    /// is reachable and a snapshot exists; otherwise it is a no-op returning false.
    @discardableResult
    func send(_ action: WatchCommand.Action) -> Bool {
        guard isPhoneReachable, snapshot != nil, let commandSender else { return false }
        commandSender(WatchCommand(action: action))
        return true
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
