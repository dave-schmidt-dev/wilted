import Foundation
import WiltedDomain
import WiltedLibrary

/// Runs voice commands against the same `LibraryAppModel` and `LibraryPlayer` the Larder drives,
/// so position sync, handoff and Mark completed behave exactly as they do from the screen.
@MainActor
final class LibraryVoiceTarget: VoiceCommandTarget {
    private let model: LibraryAppModel
    private let player: LibraryPlayer

    init(model: LibraryAppModel, player: LibraryPlayer) {
        self.model = model
        self.player = player
    }

    func voiceSnapshot() async -> VoiceSnapshot {
        let rows = downloadedRows()
        var seen = Set<String>()
        let shows = model.queued.map(\.showTitle).filter { !$0.isEmpty && seen.insert($0.lowercased()).inserted }
        return VoiceSnapshot(
            downloaded: rows.map(Self.episode), knownShowTitles: shows, nowPlaying: nowPlaying())
    }

    @discardableResult
    func perform(_ action: VoiceAction) async -> VoiceOutcome {
        switch action {
        case .none: return .done
        case let .play(entryID):
            guard let row = model.queued.first(where: { $0.id == entryID }) else { return .failed }
            // Never toggles: a spoken "play" resumes a loaded episode, also when something else loaded it
            // while the cache was being read.
            await model.playCachedWithoutToggling(row)
            return Self.outcome(player.item?.entryID == entryID && player.isPlaying)
        case .pause:
            player.pause()
            return .done
        case .resume: return Self.outcome(player.isPlaying || player.play())
        case .skipForward:
            player.skipForward()
            return .done
        case .skipBack:
            player.skipBack()
            return .done
        case .restart:
            player.seek(to: 0)
            return Self.outcome(player.isPlaying || player.play())
        case let .markCompleted(entryID):
            return await markCompleted(entryID)
        }
    }

    /// Mark completed is a request to the Mac: sent is as done as the phone can make it (the Larder
    /// shows the same optimistic result), an unsent one is queued for retry, and a row that started no
    /// decision, or whose pending decision is some other action, is a failure.
    private func markCompleted(_ entryID: ItemID) async -> VoiceOutcome {
        if model.pendingDecision(for: entryID) == nil { await model.decide(.markDone, entryID: entryID) }
        guard let pending = model.pendingDecision(for: entryID), pending.intent.action == .markDone(entryID: entryID) else {
            return .failed
        }
        return pending.isSent ? .done : .queued
    }

    private static func outcome(_ succeeded: Bool) -> VoiceOutcome { succeeded ? .done : .failed }

    /// On-phone episodes in the Larder's current sort, ignoring whatever filter or search text is
    /// showing: a spoken command must not depend on what the screen happens to be narrowed to.
    private func downloadedRows() -> [LibraryRow] {
        let ids = model.preparedIDs
        return LibraryListing.rows(
            model.queued, offered: ids.offered, onPhone: ids.onPhone, sort: model.sort, filter: .onPhone, query: "")
    }

    private func nowPlaying() -> VoiceNowPlaying? {
        guard let item = player.item else { return nil }
        let episode = VoiceEpisode(id: item.entryID, title: item.title, showTitle: item.showTitle)
        let canMark = model.queued.first { $0.id == item.entryID }
            .map { model.decisionActions(for: $0).contains(.markDone) } ?? false
        return VoiceNowPlaying(episode: episode, isPlaying: player.isPlaying, canMarkCompleted: canMark)
    }

    private static func episode(_ row: LibraryRow) -> VoiceEpisode {
        VoiceEpisode(id: row.id, title: row.title, showTitle: row.showTitle, publishedAt: row.publishedAt)
    }
}
