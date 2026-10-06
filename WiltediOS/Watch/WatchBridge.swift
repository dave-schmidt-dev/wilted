import Combine
import Foundation
import WiltedDomain
import WiltedLibrary

/// The phone state the bridge publishes, reduced to watch-sized reads. `LibraryWatchSource` wraps
/// the Larder's model and player; a test fake stands in without a library.
@MainActor
protocol WatchBridgeSource: AnyObject {
    /// Emits after the playback state or the on-phone queue changes.
    var changes: AnyPublisher<Void, Never> { get }
    /// The playing episode, or nil when the phone is idle.
    var currentNowPlaying: NowPlaying? { get }
    /// Downloaded queue rows, in the Larder's play order.
    var currentUpNext: [UpNextRow] { get }
    /// The current playback rate.
    var currentRate: Double { get }
    /// Whether playback should stop at the end of the current episode.
    var stopsAfterCurrentEpisode: Bool { get }
}

/// A reason a watch command had no effect. The raw value travels in the reply dictionary.
enum WatchRejection: String, Error {
    /// Activation, pairing or installation is not complete.
    case notReady
    /// The row's episode is not in the last published snapshot.
    case unknownEpisode
    /// The rate is not one of `PlaybackSpeeds.all`.
    case unsupportedRate
    /// The sleep length is not one of the offered presets.
    case unsupportedSleepDuration
    /// The message is not a command this build understands.
    case invalidCommand
    /// The target ran the action but reported a failure.
    case failed
}

/// The iPhone's half of the Watch link: it publishes the phone's playback state as an application
/// context and performs the Watch's commands through the app's own `VoiceCommandTarget`.
///
/// The Watch is a remote of the phone. The bridge plays no audio, writes no library state and
/// writes no handoff record; a command is only ever carried out by the shared voice target. A
/// command is refused before the target sees it when its episode is outside the last successfully
/// published snapshot, its rate or sleep length is off the offered lists, or it does not decode.
@MainActor
final class WatchBridge {
    /// The sleep lengths a Watch command may ask for, matching `SleepTimerOption`.
    static let allowedSleepMinutes = [5, 10, 15, 20, 30, 45, 60, 90]
    /// Reply key saying whether the command was carried out.
    static let okKey = "ok"
    /// Reply key carrying a `WatchRejection` raw value when it was not.
    static let reasonKey = "reason"

    private let session: any WatchSessionProtocol
    private let target: any VoiceCommandTarget
    private let source: any WatchBridgeSource
    private let sleepTimer: SleepTimer
    /// The clock the bridge reads for publish throttling.
    private let now: () -> Date
    /// How long a snapshot whose only change is the playback position waits to republish.
    private let positionRepublishInterval: TimeInterval = 10
    private var changeSubscription: AnyCancellable?
    private var publishTask: Task<Void, Never>?
    private var lastPublished: WatchSnapshot?
    /// When `lastPublished` was written, measured by `now`.
    private var lastPublishedAt: Date?
    private var activationCompleted = false
    private var started = false

    /// Builds a bridge over the session, the shared voice target, the phone state and the sleep timer.
    init(
        session: any WatchSessionProtocol,
        target: any VoiceCommandTarget,
        source: any WatchBridgeSource,
        sleepTimer: SleepTimer = .shared,
        now: @escaping () -> Date = Date.init
    ) {
        self.session = session
        self.target = target
        self.source = source
        self.sleepTimer = sleepTimer
        self.now = now
    }

    /// The last snapshot the phone successfully published, if any. Commands validate against it.
    var publishedSnapshot: WatchSnapshot? { lastPublished }

    /// Sets the delegate and activates when the device supports watch sessions, unconditionally,
    /// even with no Watch paired; publishing and command handling wait for the ready state.
    func start() {
        guard !started else { return }
        started = true
        guard session.isSupported else { return }
        activationCompleted = session.activationState == .activated
        session.delegate = self
        sleepTimer.onChange = { [weak self] in self?.setNeedsPublish() }
        changeSubscription = source.changes.sink { [weak self] _ in
            MainActor.assumeIsolated { self?.setNeedsPublish() }
        }
        session.activate()
    }

    /// Schedules one coalesced publish for the next main-actor turn; a burst of changes publishes once.
    func setNeedsPublish() {
        guard started, publishTask == nil else { return }
        publishTask = Task { @MainActor [weak self] in
            await Task.yield()
            guard let self else { return }
            self.publishTask = nil
            self.publishIfPossible()
        }
    }

    /// Waits for a scheduled publish to run; tests drive coalescing with this instead of sleeping.
    func settlePendingPublish() async {
        await publishTask?.value
    }

    /// Activation complete, paired, installed: only then may the phone publish or answer commands.
    private var isReady: Bool {
        session.isSupported && activationCompleted && session.activationState == .activated
            && session.isPaired && session.isWatchAppInstalled
    }

    private func publishIfPossible() {
        guard isReady else { return }
        let snapshot = WatchSnapshot(
            nowPlaying: source.currentNowPlaying,
            upNext: source.currentUpNext,
            rate: source.currentRate,
            sleep: sleepState(),
            publishedAt: now())
        if let lastPublished, let lastPublishedAt, Self.differsOnlyByPosition(lastPublished, snapshot),
           now().timeIntervalSince(lastPublishedAt) < positionRepublishInterval {
            return
        }
        guard let context = try? WatchLinkCodec.encode(snapshot) else { return }
        guard (try? session.updateApplicationContext(context)) != nil else { return }
        lastPublished = snapshot
        lastPublishedAt = now()
    }

    private func sleepState() -> SleepState {
        if let deadline = sleepTimer.deadlineDate { return .untilDate(deadline) }
        return source.stopsAfterCurrentEpisode ? .endOfEpisode : .off
    }

    private func resolution(for action: WatchCommand.Action) -> Resolution {
        switch action {
        case let .playRow(episodeID):
            guard let published = lastPublished, Self.contains(published, episodeID: episodeID),
                  let entryID = try? ItemID(rawValue: episodeID) else { return .reject(.unknownEpisode) }
            return .perform(.play(entryID))
        case .toggle:
            return .perform(source.currentNowPlaying?.isPlaying == true ? .pause : .resume)
        case .skipForward:
            return .perform(.skipForward)
        case .skipBack:
            return .perform(.skipBack)
        case let .setRate(rate):
            guard PlaybackSpeeds.contains(rate) else { return .reject(.unsupportedRate) }
            return .perform(.setSpeed(rate))
        case let .startSleep(minutes):
            guard Self.allowedSleepMinutes.contains(minutes) else { return .reject(.unsupportedSleepDuration) }
            return .perform(.startSleepTimer(minutes: minutes))
        case .startSleepEndOfEpisode:
            return .perform(.stopAfterEpisode)
        case .cancelSleep:
            return .perform(.cancelSleepTimer)
        }
    }

    private static func contains(_ snapshot: WatchSnapshot, episodeID: String) -> Bool {
        snapshot.nowPlaying?.episodeID == episodeID || snapshot.upNext.contains { $0.episodeID == episodeID }
    }

    /// Whether two snapshots, both playing, carry identical state except for the playback position,
    /// ignoring `publishedAt`, which every snapshot stamps fresh.
    private static func differsOnlyByPosition(_ old: WatchSnapshot, _ new: WatchSnapshot) -> Bool {
        guard old.version == new.version, old.upNext == new.upNext, old.rate == new.rate,
              old.sleep == new.sleep,
              let oldPlaying = old.nowPlaying, let newPlaying = new.nowPlaying,
              oldPlaying.positionSeconds != newPlaying.positionSeconds,
              // Only while playing: the next tick republishes. A paused seek has no later tick.
              newPlaying.isPlaying
        else { return false }
        return oldPlaying.episodeID == newPlaying.episodeID
            && oldPlaying.title == newPlaying.title
            && oldPlaying.showTitle == newPlaying.showTitle
            && oldPlaying.durationSeconds == newPlaying.durationSeconds
            && oldPlaying.isPlaying == newPlaying.isPlaying
    }

    private static func rejectionReply(_ reason: WatchRejection) -> [String: Any] {
        [okKey: false, reasonKey: reason.rawValue]
    }

    private static func outcomeReply(_ outcome: VoiceOutcome) -> [String: Any] {
        switch outcome {
        case .done: return [okKey: true]
        case .queued: return [okKey: true, "queued": true]
        case .failed: return rejectionReply(.failed)
        }
    }

    /// What a decoded action should become: a `VoiceAction` to perform, or a refusal.
    private enum Resolution {
        case perform(VoiceAction)
        case reject(WatchRejection)
    }
}

extension WatchBridge: WatchSessionDelegate {
    func watchSessionDidActivate() {
        activationCompleted = true
        setNeedsPublish()
    }

    func watchSessionDidBecomeInactive() {
        activationCompleted = false
        reactivate()
    }

    func watchSessionDidDeactivate() {
        activationCompleted = false
        reactivate()
    }

    func watchSessionWatchStateDidChange() {
        setNeedsPublish()
    }

    func watchSessionDidReceiveMessage(_ message: [String: Any], replyHandler: @escaping ([String: Any]) -> Void) {
        guard isReady else {
            replyHandler(Self.rejectionReply(.notReady))
            return
        }
        guard let command = try? WatchLinkCodec.decodeCommand(message) else {
            replyHandler(Self.rejectionReply(.invalidCommand))
            return
        }
        switch resolution(for: command.action) {
        case let .reject(reason):
            replyHandler(Self.rejectionReply(reason))
        case let .perform(action):
            Task { @MainActor [weak self] in
                guard let self else {
                    replyHandler(Self.rejectionReply(.notReady))
                    return
                }
                let outcome = await self.target.perform(action)
                replyHandler(Self.outcomeReply(outcome))
            }
        }
    }

    private func reactivate() {
        guard session.isSupported else { return }
        session.activate()
    }
}

/// The production `WatchBridgeSource`: the Larder's model and player seen through watch-sized
/// reads. It only reads; it never writes library state or a handoff record.
@MainActor
final class LibraryWatchSource: WatchBridgeSource {
    private let model: LibraryAppModel
    private let player: LibraryPlayer

    init(model: LibraryAppModel, player: LibraryPlayer) {
        self.model = model
        self.player = player
    }

    var changes: AnyPublisher<Void, Never> {
        Publishers.MergeMany(
            player.objectWillChange.map { _ in () }.eraseToAnyPublisher(),
            model.$queued.map { _ in () }.eraseToAnyPublisher(),
            model.$media.map { _ in () }.eraseToAnyPublisher(),
            model.$progress.map { _ in () }.eraseToAnyPublisher(),
            model.$finished.map { _ in () }.eraseToAnyPublisher())
            .eraseToAnyPublisher()
    }

    var currentNowPlaying: NowPlaying? {
        guard let item = player.item else { return nil }
        return NowPlaying(
            episodeID: item.entryID.rawValue,
            title: item.title,
            showTitle: item.showTitle,
            positionSeconds: player.position,
            durationSeconds: player.duration > 0 ? player.duration : nil,
            isPlaying: player.isPlaying)
    }

    var currentUpNext: [UpNextRow] {
        let playing = player.item?.entryID
        return downloadedRows().filter { $0.id != playing }.map(Self.row)
    }

    var currentRate: Double { player.rate }

    var stopsAfterCurrentEpisode: Bool { player.stopsAfterCurrentItem }

    /// Episodes whose audio is on the phone, in the Larder's shared play order.
    private func downloadedRows() -> [LibraryRow] {
        let ids = model.preparedIDs
        return LibraryListing.rows(
            model.queued, offered: ids.offered, onPhone: ids.onPhone, filter: .onPhone, query: "",
            progress: model.progress, finished: model.finished)
    }

    private static func row(_ row: LibraryRow) -> UpNextRow {
        UpNextRow(
            episodeID: row.id.rawValue, title: row.title, showTitle: row.showTitle,
            durationSeconds: row.durationSeconds)
    }
}
