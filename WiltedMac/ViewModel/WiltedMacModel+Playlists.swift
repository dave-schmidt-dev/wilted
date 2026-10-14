import Foundation
import SwiftUI
import WiltedDomain
import WiltedProducer

/// What the sidebar's Playlists section and the playlist destination read. One value on the model so
/// a view redraws on any change and a test can build it directly.
struct WiltedMacPlaylistsState: Equatable {
    /// Display order.
    var playlists: [Playlist] = []
    /// Whether the store has been read. A stored playlist selection is only judged after this.
    var isLoaded = false
    /// The newest `loadPlaylists()` started. A load that finds it has moved on discards its read;
    /// every playlist edit moves it on too, so a read that began before the edit is stale.
    var loadGeneration: UInt64 = 0
    /// A manual playlist's entry IDs in order.
    var entryIDs: [String: [String]] = [:]
    /// An automatic playlist's rules in order.
    var rules: [String: [PlaylistRule]] = [:]
    /// Automatic playlists whose stored rule payload could not be read. They fail closed until a
    /// later load succeeds, leaving the untouched stored payload available for recovery.
    var ruleReadErrors: [String: String] = [:]
    /// Rule payloads being retried locally. This prevents duplicate retry taps without claiming a
    /// playlist write is running.
    var retryingRuleIDs: Set<String> = []
    /// The playlist now playing through, if any. Playlists never touch the Larder queue.
    var session: WiltedMacPlaylistSession?
    /// The rename or delete the sidebar is asking about.
    var prompt: WiltedMacPlaylistPrompt?
    /// The last failure or outcome worth saying out loud, shown on the playlist.
    var message: String?
    /// The write a playlist is waiting on, by playlist ID. A second action on the same playlist is
    /// refused while its token stands; different playlists write independently.
    var pending: [String: WiltedMacPlaylistPending] = [:]
    /// How many New Playlist creates are writing. The sidebar shows feedback while it is above zero.
    var creatingCount = 0
    /// The New Playlist menu's last failure, kept until the next create starts.
    var createFailure: String?
    /// The names in-flight creates reserved, so two menus make distinct names.
    var reservedNames: Set<String> = []
    /// Rows a mutation added optimistically; a settling store read may not hold them yet.
    var optimisticCreatedIDs: Set<String> = []
    /// Rows a delete removed optimistically; a settling store read must not resurrect them.
    var optimisticDeletedIDs: Set<String> = []
    /// The last failure for one playlist, shown on its page and sidebar row and cleared only by
    /// that playlist's next operation.
    var failures: [String: String] = [:]
}

/// A playlist being played in order. `entryIDs` is the order taken when Play was pressed and
/// `index` is the entry that is loaded.
struct WiltedMacPlaylistSession: Equatable {
    let playlistID: String
    let entryIDs: [String]
    var index: Int

    var currentEntryID: String { entryIDs[index] }
}

/// A playlist entry whose audio is not ready; the command answer line says so.
enum WiltedMacPlaylistError: Error { case notReady }

enum WiltedMacPlaylistPrompt: Equatable {
    case rename(String)
    case delete(String)
}

/// What a playlist is waiting on. The copy names the operation the reader is waiting for.
enum WiltedMacPlaylistOperation: Equatable, Sendable {
    case creating
    case playlist
    case rules

    var progressCopy: String {
        switch self {
        case .creating: "Creating playlist\u{2026}"
        case .playlist: "Saving playlist\u{2026}"
        case .rules: "Saving rules\u{2026}"
        }
    }
}

/// The write one playlist is waiting on. The token identifies that exact write, so a late call that
/// belongs to an older one can never clear a newer write's pending state.
struct WiltedMacPlaylistPending: Equatable {
    let token: UUID
    let operation: WiltedMacPlaylistOperation
}

/// The matching episodes a rule editor shows: how many, and which.
struct WiltedMacPlaylistRulePreview: Equatable {
    struct Entry: Identifiable, Equatable {
        let id: String
        let title: String
    }

    var matchCount: Int
    var entries: [Entry]
}

extension WiltedMacModel {
    // MARK: - Reading

    var selectedPlaylistID: String? {
        if case let .playlist(id) = selectedNavigation { return id }
        return nil
    }

    func playlist(_ id: String) -> Playlist? { playlists.playlists.first { $0.id == id } }

    /// Test seam: suspends a load after its store read and before it writes, so a test can finish an
    /// older load last. Nil in production.
    static var afterPlaylistsRead: (@MainActor () async -> Void)?

    /// Test seam: runs before each playlist store write. A test holds it open to observe the
    /// optimistic state (or to fail the write and exercise the rollback path); when it returns the
    /// real store is written. Nil in production.
    static var playlistWriteHookForTesting: (@MainActor () async throws -> Void)?

    /// Reads every playlist, its entries and its rules, then judges a stored playlist selection.
    /// Loads can overlap (a reload, a create, a sync pass), so a load only writes when it is still
    /// the newest start and no edit began after it read; a pending playlist's optimistic fields and
    /// an optimistically deleted row are merged rather than overwritten.
    func loadPlaylists() async {
        playlists.loadGeneration &+= 1
        let generation = playlists.loadGeneration
        guard let store else {
            playlists.isLoaded = true
            reconcilePlaylistSelection()
            return
        }
        do {
            let all = try await store.playlists()
            var entries: [String: [String]] = [:]
            var rules: [String: [PlaylistRule]] = [:]
            var ruleReadErrors: [String: String] = [:]
            for playlist in all {
                switch playlist.kind {
                case .manual: entries[playlist.id] = try await store.playlistEntryIDs(playlistID: playlist.id)
                case .automatic:
                    do {
                        rules[playlist.id] = try await store.playlistRules(playlistID: playlist.id)
                    } catch {
                        ruleReadErrors[playlist.id] = "The playlist rules could not be read."
                    }
                }
            }
            await Self.afterPlaylistsRead?()
            guard generation == playlists.loadGeneration else { return }
            applyLoadedPlaylists(all, entries: entries, rules: rules, ruleReadErrors: ruleReadErrors)
            playlists.isLoaded = true
            reconcilePlaylistSelection()
        } catch {
            guard generation == playlists.loadGeneration else { return }
            playlists.message = "Playlists could not be read."
        }
    }

    /// Merges a settle store read into the visible state. A playlist with a write in flight keeps
    /// its optimistic row and its rows' entries; a row deleted optimistically is never resurrected.
    private func applyLoadedPlaylists(
        _ all: [Playlist], entries: [String: [String]], rules: [String: [PlaylistRule]],
        ruleReadErrors: [String: String]
    ) {
        var merged = all.filter { !playlists.optimisticDeletedIDs.contains($0.id) }
        for current in playlists.playlists
        where playlists.pending[current.id] != nil || playlists.optimisticCreatedIDs.contains(current.id) {
            if let index = merged.firstIndex(where: { $0.id == current.id }) {
                merged[index] = current
            } else {
                merged.append(current)
            }
        }
        merged.sort { ($0.sortIndex, $0.id) < ($1.sortIndex, $1.id) }
        playlists.playlists = merged
        var mergedEntries = entries
        var mergedRules = rules
        var mergedRuleReadErrors = ruleReadErrors
        for id in playlists.pending.keys where !playlists.optimisticDeletedIDs.contains(id) {
            if let current = playlists.entryIDs[id] { mergedEntries[id] = current }
            if let current = playlists.rules[id] { mergedRules[id] = current }
            mergedRuleReadErrors[id] = playlists.ruleReadErrors[id]
        }
        for id in playlists.optimisticDeletedIDs {
            mergedEntries[id] = nil
            mergedRules[id] = nil
            mergedRuleReadErrors[id] = nil
        }
        playlists.entryIDs = mergedEntries
        playlists.rules = mergedRules
        playlists.ruleReadErrors = mergedRuleReadErrors
    }

    /// A selected playlist that no longer exists resolves to the Larder.
    func reconcilePlaylistSelection() {
        guard playlists.isLoaded else { return }
        let reconciled = selectedNavigation.reconciled(knownPlaylistIDs: Set(playlists.playlists.map(\.id)))
        if reconciled != selectedNavigation { selectedNavigation = reconciled }
    }

    // MARK: - Editing

    /// The operation a playlist is waiting on, for its spinner.
    func playlistOperation(_ id: String) -> WiltedMacPlaylistOperation? {
        playlists.pending[id]?.operation
    }

    /// Rereads a broken automatic playlist's rules. The retry state is local so a second tap gets
    /// immediate feedback without blocking writes for a different playlist.
    func retryPlaylistRules(_ id: String) async {
        guard playlists.ruleReadErrors[id] != nil, !playlists.retryingRuleIDs.contains(id) else { return }
        playlists.retryingRuleIDs.insert(id)
        defer { playlists.retryingRuleIDs.remove(id) }
        await loadPlaylists()
    }

    // MARK: - Items

    /// The library items a playlist shows now, in play order. A manual playlist keeps its own order
    /// and skips entries that left the library; an automatic one evaluates its rules over the
    /// Larder, newest first.
    func playlistItems(_ playlist: Playlist, now: Date = Date()) -> [WiltedMacLibraryItem] {
        switch playlist.kind {
        case .manual:
            let byID = Dictionary(
                larderEntries.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            return (playlists.entryIDs[playlist.id] ?? []).compactMap { byID[$0] }
        case .automatic:
            guard playlists.ruleReadErrors[playlist.id] == nil else { return [] }
            let ordered = larderEntries.sorted { $0.date > $1.date }
            let byID = Dictionary(ordered.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            let matched = PlaylistRules.evaluate(
                playlists.rules[playlist.id] ?? [], matchAll: playlist.matchAll,
                candidates: ordered.map { Self.playlistCandidate($0, ready: canPlayPlaylistItem($0)) },
                now: now)
            return matched.compactMap { byID[$0.entryID] }
        }
    }

    /// Every candidate an automatic playlist evaluates today, newest first, carrying the same
    /// readiness the playlist page uses to decide Play. The rule editor's preview evaluates exactly
    /// this list, so preview and page cannot disagree.
    func playlistCandidates() -> [PlaylistCandidate] {
        larderEntries.sorted { $0.date > $1.date }
            .map { Self.playlistCandidate($0, ready: canPlayPlaylistItem($0)) }
    }

    /// All facts the evaluator reads, so a change of played state, duration, date or feed refreshes
    /// the preview even when the same entries remain ready.
    var playlistPreviewFingerprint: String {
        let facts = playlistCandidates().map {
            "\($0.entryID.debugDescription):\($0.feedID.debugDescription):\($0.kind):"
                + "\($0.durationSeconds.debugDescription):\($0.publishedAt.timeIntervalSinceReferenceDate):"
                + "\($0.playedState.rawValue):\($0.isReady)"
        }.joined(separator: ",")
        return facts + "|" + larderEntries.map { "\($0.id.debugDescription):\($0.title.debugDescription)" }
            .joined(separator: ",")
    }

    /// Evaluates `rules` over `playlistCandidates()`, off the main actor, and names what matched.
    /// The editor's preview and its Save both go through the compiled rule and this evaluation.
    func playlistRulePreview(
        for rules: [PlaylistRule], matchAll: Bool, now: Date = Date()
    ) async -> WiltedMacPlaylistRulePreview {
        let candidates = playlistCandidates()
        let titles = Dictionary(
            larderEntries.map { ($0.id, $0.title) }, uniquingKeysWith: { first, _ in first })
        let matched = await Task.detached(priority: .userInitiated) {
            PlaylistRules.evaluate(rules, matchAll: matchAll, candidates: candidates, now: now)
        }.value
        return WiltedMacPlaylistRulePreview(
            matchCount: matched.count,
            entries: matched.compactMap { candidate -> WiltedMacPlaylistRulePreview.Entry? in
                guard let title = titles[candidate.entryID] else { return nil }
                return WiltedMacPlaylistRulePreview.Entry(id: candidate.entryID, title: title)
            })
    }

    /// The Larder item behind a preview row, so its title's popover opens the same notes the
    /// playlist page shows. Nothing here touches playback or a transcript.
    func playlistLibraryItem(_ entryID: String) -> WiltedMacLibraryItem? {
        larderEntries.first { $0.id == entryID }
    }

    /// Every Larder entry a playlist can hold: the episodes and books on the shelf, and the articles.
    private var larderEntries: [WiltedMacLibraryItem] {
        larderVisibleEpisodes.map(WiltedMacLibraryItem.init(episode:)) + articles.map(WiltedMacLibraryItem.article)
    }

    /// The facts a rule reads of one entry. The ready flag is passed in by the caller so a candidate
    /// carries the same readiness the page uses; the compatibility default reads as not ready.
    nonisolated static func playlistCandidate(
        _ item: WiltedMacLibraryItem, ready: Bool = false
    ) -> PlaylistCandidate {
        candidate(item, isReady: ready)
    }

    /// The explicit-readiness spelling of `playlistCandidate(_:ready:)`.
    nonisolated static func playlistCandidate(
        _ item: WiltedMacLibraryItem, isReady: Bool
    ) -> PlaylistCandidate {
        candidate(item, isReady: isReady)
    }

    private nonisolated static func candidate(
        _ item: WiltedMacLibraryItem, isReady: Bool
    ) -> PlaylistCandidate {
        switch item {
        case .article(let article):
            return PlaylistCandidate(
                entryID: article.id, feedID: nil, kind: "article", durationSeconds: article.durationSeconds,
                publishedAt: article.createdAt,
                playedState: article.isPlayed ? .played : (article.playbackSeconds != 0 ? .inProgress : .unplayed),
                isReady: isReady)
        case .episode(let episode), .audiobook(let episode):
            return PlaylistCandidate(
                entryID: episode.id, feedID: episode.feedID,
                kind: episode.isAudiobook ? "audiobook" : "podcast.episode",
                durationSeconds: episode.durationSeconds, publishedAt: episode.publishedAt ?? episode.releasedAt,
                playedState: episode.isPlayed ? .played : (episode.playbackSeconds != 0 ? .inProgress : .unplayed),
                isReady: isReady)
        }
    }

    /// Whether a playlist entry has audio ready to play now.
    func canPlayPlaylistItem(_ item: WiltedMacLibraryItem) -> Bool {
        switch item {
        case .article(let article): article.isReady
        case .audiobook(let book):
            !hiddenEpisodeIDs.contains(book.id) && book.retiredAt == nil && book.removalKind == nil
                && book.isReadyMediaAvailable
        case .episode(let episode): canPlayEpisode(episode)
        }
    }

    // MARK: - Playing

    /// Whether the loaded audio is the playlist session's current entry. A session whose entry is no
    /// longer loaded (the reader played something else) is not current, and every Larder rule
    /// applies again.
    var playlistSessionIsCurrent: Bool {
        guard let session = playlists.session else { return false }
        return playback?.itemID?.rawValue == session.currentEntryID
    }

    /// Plays the playlist's ready entries in order, without touching the Larder queue.
    func playPlaylist(_ playlist: Playlist) {
        let playable = playlistItems(playlist).filter(canPlayPlaylistItem).map(\.id)
        guard !playable.isEmpty else {
            playlists.message = "Nothing in this playlist is ready to play."
            return
        }
        playlists.message = nil
        playlists.session = WiltedMacPlaylistSession(playlistID: playlist.id, entryIDs: playable, index: 0)
        startPlaylistEntry(at: 0)
    }

    /// Steps to the next or previous playable entry of the session. Returns whether there was one.
    @discardableResult
    func stepPlaylist(previous: Bool) -> Bool {
        guard let index = playlistNeighbourIndex(previous: previous) else { return false }
        startPlaylistEntry(at: index)
        return true
    }

    func playlistNeighbourIndex(previous: Bool) -> Int? {
        guard playlistSessionIsCurrent, let session = playlists.session else { return nil }
        let index = previous ? session.index - 1 : session.index + 1
        return session.entryIDs.indices.contains(index) ? index : nil
    }

    var canStepPlaylistNext: Bool { playlistNeighbourIndex(previous: false) != nil }
    var canStepPlaylistPrevious: Bool { playlistNeighbourIndex(previous: true) != nil }

    /// The loaded entry finished. Returns true when the playlist session owns the end of the audio,
    /// so the Larder's continuation does not run. The finished entry is not retired and no queue
    /// state is written.
    func playlistEntryFinished() -> Bool {
        guard playlistSessionIsCurrent, var session = playlists.session else {
            playlists.session = nil
            return false
        }
        refreshPlaybackReadout()
        guard playback?.completed == true else { return true }
        if session.index + 1 < session.entryIDs.count {
            session.index += 1
            playlists.session = session
            startPlaylistEntry(at: session.index)
        } else {
            playlists.session = nil
            playlists.message = "Finished the playlist."
        }
        return true
    }

    /// Loads and starts one entry of the session as a selection (W-INV-017): it supersedes any
    /// pending command, and only the newest command may start the audio. The entry loads outside
    /// the durable queue, so the Larder order and its current episode stay as they were.
    private func startPlaylistEntry(at index: Int) {
        guard let session = playlists.session, session.entryIDs.indices.contains(index),
              let playback, let store else { return }
        let entryID = session.entryIDs[index]
        guard let item = (episodes.map(WiltedMacLibraryItem.init(episode:)) + articles.map(WiltedMacLibraryItem.article))
            .first(where: { $0.id == entryID }),
              let itemID = try? ItemID(rawValue: entryID) else { return }
        let opening = "Opening \(item.title)…"
        playbackOperationStatus = opening
        issuePlaybackCommand(.select, pending: opening, target: entryID,
                             failureMessage: WiltedMacPlaybackCopy.missing) { [weak self] command in
            guard let self else { return }
            defer { if self.playbackOperationStatus == opening { self.playbackOperationStatus = nil } }
            guard let stored = try await store.readyRevision(for: itemID) else {
                self.playlists.session = nil
                throw WiltedMacPlaylistError.notReady
            }
            let savedRate = try? await store.playbackSpeed(for: itemID)
            try self.ensureCurrentPlaybackCommand(command)
            self.refreshPlaybackReadout(shouldPublishNowPlaying: false)
            try await playback.load(stored)
            try self.ensureNewestSelection(command)
            if let savedRate { playback.setRate(Float(savedRate.speed)) }
            self.playlists.session?.index = index
            switch item {
            case .article(let article):
                self.beginArticlePlaybackTransition(article)
            case .episode, .audiobook:
                self.cancelSeamMarker()
                self.selectedArticleID = nil
                self.currentPodcastEpisodeID = entryID
                self.isPodcastPlayback = true
                self.isLarderQueuePlayback = false
                self.isNowPlaying = true
                self.currentTranscript = nil
            }
            try self.startIfCurrent(playback, for: command)
            self.isPlaying = playback.isPlaying
            self.refreshPlaybackReadout(shouldPublishNowPlaying: false)
            self.publishNowPlaying(force: true)
            switch item {
            case .article: await self.loadTranscript(itemID: itemID, revisionID: stored.revision.revisionID)
            case .episode, .audiobook: await self.loadEpisodeTranscript(itemID: itemID)
            }
            self.refreshPlaybackReadout()
            if self.isCurrentPlaybackCommand(command) { self.playbackError = nil }
        }
    }
}
