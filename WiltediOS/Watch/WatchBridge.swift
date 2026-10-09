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
    /// The intervals the actual phone player currently uses.
    var currentSkipBackSeconds: Int { get }
    var currentSkipForwardSeconds: Int { get }
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
    private var controlSessionID = UUID()
    private struct HeldSeek {
        let action: WatchCommand.Action
        let generation = UUID()
    }
    private var heldSeek: HeldSeek?
    private var seekLeaseTask: Task<Void, Never>?
    private var seekBeginTask: Task<VoiceOutcome, Never>?
    private let seekLeaseNow: @MainActor () -> TimeInterval
    private let seekLeaseSleep: @MainActor (TimeInterval) async throws -> Void
    private var seekLeaseDeadline: TimeInterval = 0

    /// Builds a bridge over the session, the shared voice target, the phone state and the sleep timer.
    init(
        session: any WatchSessionProtocol,
        target: any VoiceCommandTarget,
        source: any WatchBridgeSource,
        sleepTimer: SleepTimer = .shared,
        now: @escaping () -> Date = Date.init,
        seekLeaseNow: @escaping @MainActor () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
        seekLeaseSleep: @escaping @MainActor (TimeInterval) async throws -> Void = { try await Task.sleep(for: .seconds($0)) }
    ) {
        self.session = session
        self.target = target
        self.source = source
        self.sleepTimer = sleepTimer
        self.now = now
        self.seekLeaseNow = seekLeaseNow
        self.seekLeaseSleep = seekLeaseSleep
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
        if let heldSeek, !seekFenceIsCurrent(heldSeek.action) { cancelHeldSeek() }
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
            nowPlaying: source.currentNowPlaying, controlSessionID: controlSessionID,
            upNext: source.currentUpNext,
            rate: source.currentRate,
            sleep: sleepState(),
            skipBackSeconds: source.currentSkipBackSeconds,
            skipForwardSeconds: source.currentSkipForwardSeconds,
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
        case .seek: return .reject(.invalidCommand) // Owned seeking is handled before ordinary actions.
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
              old.controlSessionID == new.controlSessionID,
              old.skipBackSeconds == new.skipBackSeconds,
              old.skipForwardSeconds == new.skipForwardSeconds,
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
            && oldPlaying.seekSessionID == newPlaying.seekSessionID
            && oldPlaying.canSeek == newPlaying.canSeek
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
        cancelHeldSeek(); controlSessionID = UUID()
        activationCompleted = true
        setNeedsPublish()
    }

    func watchSessionDidBecomeInactive() {
        cancelHeldSeek(); controlSessionID = UUID()
        activationCompleted = false
        reactivate()
    }

    func watchSessionDidDeactivate() {
        cancelHeldSeek(); controlSessionID = UUID()
        activationCompleted = false
        reactivate()
    }

    func watchSessionWatchStateDidChange() {
        if !isReady { cancelHeldSeek(); controlSessionID = UUID() }
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
        if case .seek = command.action { receiveSeek(command.action, replyHandler: replyHandler); return }
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

    private func seekFenceIsCurrent(_ action: WatchCommand.Action) -> Bool {
        guard case let .seek(_, _, _, episode, session, load) = action,
              isReady, session == controlSessionID,
              let current = source.currentNowPlaying, current.episodeID == episode,
              current.seekSessionID == load, current.canSeek == true else { return false }
        return true
    }

    private func seekVoiceAction(_ action: WatchCommand.Action, ending: Bool) -> VoiceAction? {
        guard case let .seek(_, direction, id, episode, _, load) = action,
              let entry = try? ItemID(rawValue: episode) else { return nil }
        let voiceDirection: VoiceSeekDirection = direction == .forward ? .forward : .backward
        return ending ? .seekEnd(holdID: id, direction: voiceDirection, entryID: entry, seekSessionID: load)
            : .seekBegin(holdID: id, direction: voiceDirection, entryID: entry, seekSessionID: load)
    }

    private func matchesHeldSeek(_ action: WatchCommand.Action) -> Bool {
        guard let held = heldSeek,
              case let .seek(_, d, id, episode, session, load) = action,
              case let .seek(_, oldD, oldID, oldEpisode, oldSession, oldLoad) = held.action else { return false }
        return d == oldD && id == oldID && episode == oldEpisode && session == oldSession && load == oldLoad
    }

    private func renewSeekLease() {
        seekLeaseTask?.cancel()
        seekLeaseDeadline = seekLeaseNow() + 2.5
        guard let generation = heldSeek?.generation else { return }
        seekLeaseTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do { try await self.seekLeaseSleep(2.5) } catch { return }
            guard !Task.isCancelled, self.heldSeek?.generation == generation,
                  self.seekLeaseNow() >= self.seekLeaseDeadline else { return }
            self.cancelHeldSeek()
        }
    }

    private func cancelHeldSeek() {
        let action = heldSeek?.action
        heldSeek = nil; seekLeaseTask?.cancel(); seekLeaseTask = nil
        seekBeginTask?.cancel(); seekBeginTask = nil
        guard let action, let end = seekVoiceAction(action, ending: true) else { return }
        let target = target
        Task { @MainActor in _ = await target.perform(end) }
    }

    private func receiveSeek(_ action: WatchCommand.Action, replyHandler: @escaping ([String: Any]) -> Void) {
        guard case let .seek(phase, _, _, _, _, _) = action, seekFenceIsCurrent(action) else {
            replyHandler(Self.rejectionReply(.failed)); return
        }
        if phase == .renew {
            guard matchesHeldSeek(action) else { replyHandler(Self.rejectionReply(.failed)); return }
            renewSeekLease(); replyHandler(Self.outcomeReply(.done)); return
        }
        if phase == .end {
            guard matchesHeldSeek(action), let end = seekVoiceAction(action, ending: true) else {
                replyHandler(Self.rejectionReply(.failed)); return
            }
            heldSeek = nil; seekLeaseTask?.cancel(); seekLeaseTask = nil
            Task { @MainActor [target] in replyHandler(Self.outcomeReply(await target.perform(end))) }
            return
        }
        if matchesHeldSeek(action) {
            renewSeekLease()
            guard let begin = seekBeginTask else { replyHandler(Self.rejectionReply(.failed)); return }
            Task { @MainActor in replyHandler(Self.outcomeReply(await begin.value)) }
            return
        }
        // Transfer to the new player-owned hold without a resume gap between directions.
        let superseded = heldSeek?.action
        heldSeek = nil; seekLeaseTask?.cancel(); seekLeaseTask = nil
        guard let begin = seekVoiceAction(action, ending: false) else { replyHandler(Self.rejectionReply(.failed)); return }
        let held = HeldSeek(action: action)
        heldSeek = held; renewSeekLease()
        let task = Task { @MainActor [weak self] () -> VoiceOutcome in
            guard let self, self.heldSeek?.generation == held.generation, self.seekFenceIsCurrent(action) else {
                return .failed
            }
            let outcome = await self.target.perform(begin)
            guard self.heldSeek?.generation == held.generation, self.seekFenceIsCurrent(action) else {
                if let end = self.seekVoiceAction(action, ending: true) { _ = await self.target.perform(end) }
                return .failed
            }
            if outcome == .failed {
                self.cancelHeldSeek()
                if let superseded, let end = self.seekVoiceAction(superseded, ending: true) {
                    _ = await self.target.perform(end)
                }
            }
            return outcome
        }
        seekBeginTask = task
        Task { @MainActor in replyHandler(Self.outcomeReply(await task.value)) }
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
            isPlaying: player.isPlaying, seekSessionID: player.seekSessionID,
            canSeek: player.status == .playing || player.status == .paused)
    }

    var currentUpNext: [UpNextRow] {
        let playing = player.item?.entryID
        return downloadedRows().filter { $0.id != playing }.map(Self.row)
    }

    var currentRate: Double { player.rate }
    var currentSkipBackSeconds: Int { player.skipBackSeconds }
    var currentSkipForwardSeconds: Int { player.skipForwardSeconds }

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
