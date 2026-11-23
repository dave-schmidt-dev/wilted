import Foundation
import WiltedDomain
import WiltedLibrary

/// Runs voice commands against the same `LibraryAppModel` and `LibraryPlayer` the Larder drives,
/// so position sync, handoff and Mark completed behave exactly as they do from the screen.
@MainActor
final class LibraryVoiceTarget: VoiceCommandTarget {
    private let model: LibraryAppModel
    private let player: LibraryPlayer
    /// Where a spoken speed is kept, so it is the app's own speed setting; nil keeps it for the loaded episode only.
    private let settings: LibrarySettingsStore?
    private let sleepTimer: SleepTimer

    init(model: LibraryAppModel, player: LibraryPlayer, settings: LibrarySettingsStore? = nil, sleepTimer: SleepTimer = .shared) {
        self.model = model
        self.player = player
        self.settings = settings
        self.sleepTimer = sleepTimer
    }

    func voiceSnapshot() async -> VoiceSnapshot {
        let resumeTarget: VoiceResumeTarget
        if player.item == nil || player.status == .ended {
            let endedID = player.status == .ended ? player.item?.entryID : nil
            resumeTarget = .library(model.remoteResumeRow(excludingEndedEpisode: endedID).map(Self.episode))
        } else {
            resumeTarget = .loadedEpisode
        }
        let rows = downloadedRows()
        let shows: [String]
        switch model.listOrder {
        case .playOrder:
            var seen = Set<String>()
            shows = InProgressOrdering.orderedShows(
                model.queued.map(\.showTitle).filter { !$0.isEmpty && seen.insert($0.lowercased()).inserted },
                progressByShow: Self.lastPlayedByShow(model.queued, progress: model.progress))
        case .mac:
            var seen = Set<String>()
            var collected: [String] = []
            for title in rows.map(\.showTitle) where !title.isEmpty && seen.insert(title.lowercased()).inserted {
                collected.append(title)
            }
            for title in model.queued.map(\.showTitle) where !title.isEmpty && seen.insert(title.lowercased()).inserted {
                collected.append(title)
            }
            shows = collected
        }
        return VoiceSnapshot(
            downloaded: rows.map(Self.episode), knownShowTitles: shows, nowPlaying: nowPlaying(),
            resumeTarget: resumeTarget)
    }

    @discardableResult
    func perform(_ action: VoiceAction) async -> VoiceOutcome {
        model.journal?.note("voice-action action=\(action)")
        let outcome = await executeAction(action)
        model.journal?.note("voice-action-outcome action=\(action) outcome=\(outcome)")
        return outcome
    }

    private func executeAction(_ action: VoiceAction) async -> VoiceOutcome {
        switch action {
        case .none: return .done
        case let .seekBegin(holdID, direction, entryID, sessionID):
            guard player.item?.entryID == entryID else { return .failed }
            return Self.outcome(await player.beginOwnedSeeking(direction == .forward ? .forward : .backward,
                holdID: holdID, sessionID: sessionID))
        case let .seekEnd(holdID, direction, entryID, sessionID):
            guard player.item?.entryID == entryID else { return .failed }
            return Self.outcome(await player.endOwnedSeeking(direction == .forward ? .forward : .backward,
                holdID: holdID, sessionID: sessionID))
        case let .play(entryID):
            guard let row = model.queued.first(where: { $0.id == entryID }) else { return .failed }
            // Never toggles: a spoken "play" resumes a loaded episode, also when something else loaded it
            // while the cache was being read. A start superseded by another command for the same episode
            // (CarPlay or the phone during the lookup) still succeeds when that episode plays.
            let outcome = await start(row)
            let validSameItemSupersession = outcome == .superseded
                && model.queued.contains(where: { $0.id == entryID }) && model.media[entryID] == .onPhone
                && player.item?.entryID == entryID && player.isPlaying
            return Self.outcome(outcome.opensNowPlaying || validSameItemSupersession)
        case .pause:
            player.pause()
            return .done
        case .resume: return await resume()
        case .skipForward:
            player.skipForward()
            return .done
        case .skipBack:
            player.skipBack()
            return .done
        case .restart: return await resumeLoaded(restarting: true)
        case let .markCompleted(entryID):
            return await markCompleted(entryID)
        case let .setSpeed(rate):
            guard player.supportsRate else { return .failed }
            // The setting makes it stick for the next episodes; the player change is for the loaded one now.
            settings?.defaultSpeed = rate
            player.setRate(rate)
            return .done
        case let .startSleepTimer(minutes):
            player.setStopsAfterCurrentItem(false)
            sleepTimer.start(minutes: minutes) { [player] in player.pause() }
            return .done
        case .stopAfterEpisode:
            sleepTimer.cancel()
            player.setStopsAfterCurrentItem(true)
            return .done
        case .cancelSleepTimer:
            sleepTimer.cancel()
            player.setStopsAfterCurrentItem(false)
            return .done
        }
    }

    /// Reuses the shared selected-start cache/token checks; a restart seeks only after
    /// validation succeeds for the item that was loaded when the request began.
    private func resumeLoaded(restarting: Bool) async -> VoiceOutcome {
        guard let entryID = player.item?.entryID,
              let row = model.queued.first(where: { $0.id == entryID }), model.media[entryID] == .onPhone else { return .failed }
        let outcome = await start(row) { $0.item?.entryID == entryID }
        guard outcome.opensNowPlaying, player.item?.entryID == entryID else { return .failed }
        if restarting { player.seek(to: 0) }
        return .done
    }

    /// A paused item resumes in place. With nothing loaded, or after the loaded item ended,
    /// use the same unfinished library row as CarPlay and the other remote Play commands.
    private func resume() async -> VoiceOutcome {
        if case .starting = model.playbackCommand { return .failed }
        guard player.item == nil || player.status == .ended else { return await resumeLoaded(restarting: false) }
        model.rememberEndBeforeRemoteResume(player)
        guard let row = model.remoteResumeRow else { return .failed }
        let outcome = await start(row) { $0.item == nil || $0.status == .ended }
        guard outcome.opensNowPlaying, player.item?.entryID == row.id else { return .failed }
        return .done
    }

    private func start(
        _ row: LibraryRow, onlyIf: (@MainActor (LibraryPlayer) -> Bool)? = nil
    ) async -> LibraryStartOutcome {
        var outcome = LibraryStartOutcome.superseded
        await IntentDonor.shared.withoutDonatingPlay(of: row.id) {
            outcome = await model.startCached(row, kind: .select, onlyIf: onlyIf)
        }
        return outcome
    }

    /// Mark completed is a request to the Mac: sent is as done as the phone can make it (the Larder
    /// shows the same optimistic result), an unsent one saved in the outbox is queued for retry, and an
    /// unsent one that could not be saved, a row that started no decision, or one whose pending decision
    /// is some other action, is a failure: Siri never promises what a relaunch could lose.
    private func markCompleted(_ entryID: ItemID) async -> VoiceOutcome {
        if model.pendingDecision(for: entryID) == nil {
            await IntentDonor.shared.withoutDonatingMark(of: entryID) { await model.decide(.markDone, entryID: entryID) }
        }
        guard let pending = model.pendingDecision(for: entryID), pending.intent.action == .markDone(entryID: entryID) else {
            return .failed
        }
        if pending.isSent { return .done }
        return model.isDurablyQueued(pending.id) ? .queued : .failed
    }

    private static func outcome(_ succeeded: Bool) -> VoiceOutcome { succeeded ? .done : .failed }

    /// On-phone episodes in the selected list order, ignoring whatever filter or search text is
    /// showing: a spoken command must not depend on what the screen happens to be narrowed to.
    /// Episodes the listener finished on this phone are ordered as completed, so "play something"
    /// never picks one while another is left; one asked for by name still plays.
    private func downloadedRows() -> [LibraryRow] {
        let ids = model.preparedIDs
        return LibraryListing.rows(
            model.queued, offered: ids.offered, onPhone: ids.onPhone, filter: .onPhone, query: "",
            progress: model.progress, finished: model.finishedIncludingHere, order: model.listOrder)
    }

    /// When each show was last played, for the shows with an in-progress episode.
    static func lastPlayedByShow(_ rows: [LibraryRow], progress: [ItemID: EpisodeProgress]) -> [String: Date] {
        var result: [String: Date] = [:]
        for row in rows {
            guard let played = progress[row.id]?.lastPlayedAt else { continue }
            result[row.showTitle] = max(result[row.showTitle] ?? .distantPast, played)
        }
        return result
    }

    private func nowPlaying() -> VoiceNowPlaying? {
        guard let item = player.item else { return nil }
        let episode = VoiceEpisode(id: item.entryID, title: item.title, showTitle: item.showTitle)
        let canMark = model.queued.first { $0.id == item.entryID }
            .map { model.decisionActions(for: $0).contains(.markDone) } ?? false
        return VoiceNowPlaying(
            episode: episode, isPlaying: player.isPlaying, canMarkCompleted: canMark,
            position: player.position, duration: player.duration, rate: player.rate)
    }

    private static func episode(_ row: LibraryRow) -> VoiceEpisode {
        VoiceEpisode(id: row.id, title: row.title, showTitle: row.showTitle, publishedAt: row.publishedAt)
    }
}
