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
    /// The newest `loadPlaylists()` started. A load that finds it has moved on discards its read.
    var loadGeneration: UInt64 = 0
    /// A manual playlist's entry IDs in order.
    var entryIDs: [String: [String]] = [:]
    /// An automatic playlist's rules in order.
    var rules: [String: [PlaylistRule]] = [:]
    /// The playlist now playing through, if any. Playlists never touch the Larder queue.
    var session: WiltedMacPlaylistSession?
    /// The rename or delete the sidebar is asking about.
    var prompt: WiltedMacPlaylistPrompt?
    /// The last failure or outcome worth saying out loud, shown on the playlist.
    var message: String?
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

    /// Reads every playlist, its entries and its rules, then judges a stored playlist selection.
    /// Loads can overlap (a reload, then a create), so only the newest one started may write; an
    /// older read is stale by the time it returns.
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
            for playlist in all {
                switch playlist.kind {
                case .manual: entries[playlist.id] = try await store.playlistEntryIDs(playlistID: playlist.id)
                case .automatic: rules[playlist.id] = try await store.playlistRules(playlistID: playlist.id)
                }
            }
            await Self.afterPlaylistsRead?()
            guard generation == playlists.loadGeneration else { return }
            playlists.playlists = all
            playlists.entryIDs = entries
            playlists.rules = rules
            playlists.isLoaded = true
            reconcilePlaylistSelection()
        } catch {
            guard generation == playlists.loadGeneration else { return }
            playlists.message = "Playlists could not be read."
        }
    }

    /// A selected playlist that no longer exists resolves to the Larder.
    func reconcilePlaylistSelection() {
        guard playlists.isLoaded else { return }
        let reconciled = selectedNavigation.reconciled(knownPlaylistIDs: Set(playlists.playlists.map(\.id)))
        if reconciled != selectedNavigation { selectedNavigation = reconciled }
    }

    // MARK: - Editing

    /// A name no other playlist has: "New Playlist", then "New Playlist 2" and so on.
    func newPlaylistName() -> String {
        let taken = Set(playlists.playlists.map(\.name))
        guard taken.contains("New Playlist") else { return "New Playlist" }
        var number = 2
        while taken.contains("New Playlist \(number)") { number += 1 }
        return "New Playlist \(number)"
    }

    /// Creates a playlist after the existing ones and opens it.
    @discardableResult
    func createPlaylist(kind: PlaylistKind, name: String? = nil, adding entryID: String? = nil) async -> Playlist? {
        guard let store else { return nil }
        do {
            let created = try await store.createPlaylist(name: name ?? newPlaylistName(), kind: kind)
            if let entryID, kind == .manual {
                try await store.addPlaylistEntry(playlistID: created.id, entryID: entryID)
            }
            await loadPlaylists()
            selectedNavigation = .playlist(created.id)
            return created
        } catch {
            playlists.message = "The playlist could not be created."
            return nil
        }
    }

    func renamePlaylist(_ id: String, to name: String) async {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let store, !trimmed.isEmpty else { return }
        do {
            try await store.updatePlaylist(id: id, name: trimmed)
            await loadPlaylists()
        } catch { playlists.message = "The playlist could not be renamed." }
    }

    /// Deletes the playlist and its entries and rules. Library items are untouched. A deleted
    /// selection resolves to the Larder, and a session playing it ends.
    func deletePlaylist(_ id: String) async {
        guard let store else { return }
        do {
            try await store.deletePlaylist(id: id)
            if playlists.session?.playlistID == id { playlists.session = nil }
            await loadPlaylists()
        } catch { playlists.message = "The playlist could not be deleted." }
    }

    func addToPlaylist(_ playlistID: String, entryID: String) async {
        guard let store else { return }
        do {
            try await store.addPlaylistEntry(playlistID: playlistID, entryID: entryID)
            await loadPlaylists()
        } catch { playlists.message = "That could not be added to the playlist." }
    }

    func removeFromPlaylist(_ playlistID: String, entryID: String) async {
        guard let store else { return }
        do {
            try await store.removePlaylistEntry(playlistID: playlistID, entryID: entryID)
            await loadPlaylists()
        } catch { playlists.message = "That could not be removed from the playlist." }
    }

    /// Moves a manual playlist's entry so it sits at `index` in the resulting order.
    func movePlaylistEntry(_ playlistID: String, entryID: String, to index: Int) async {
        guard let store else { return }
        do {
            try await store.movePlaylistEntry(playlistID: playlistID, entryID: entryID, to: index)
            await loadPlaylists()
        } catch { playlists.message = "The playlist could not be reordered." }
    }

    /// Saves an automatic playlist's rules and its all-of or any-of choice.
    func savePlaylistRules(_ playlistID: String, rules: [PlaylistRule], matchAll: Bool) async -> Bool {
        guard let store else { return false }
        do {
            try await store.setPlaylistRules(playlistID: playlistID, rules: rules)
            try await store.updatePlaylist(id: playlistID, matchAll: matchAll)
            await loadPlaylists()
            return true
        } catch {
            playlists.message = "The rules could not be saved."
            return false
        }
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
            let ordered = larderEntries.sorted { $0.date > $1.date }
            let byID = Dictionary(ordered.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            let matched = PlaylistRules.evaluate(
                playlists.rules[playlist.id] ?? [], matchAll: playlist.matchAll,
                candidates: ordered.map(Self.playlistCandidate), now: now)
            return matched.compactMap { byID[$0.entryID] }
        }
    }

    /// Every Larder entry a playlist can hold: the episodes and books on the shelf, and the articles.
    private var larderEntries: [WiltedMacLibraryItem] {
        larderVisibleEpisodes.map(WiltedMacLibraryItem.init(episode:)) + articles.map(WiltedMacLibraryItem.article)
    }

    nonisolated static func playlistCandidate(_ item: WiltedMacLibraryItem) -> PlaylistCandidate {
        switch item {
        case .article(let article):
            return PlaylistCandidate(
                entryID: article.id, feedID: nil, kind: "article", durationSeconds: article.durationSeconds,
                publishedAt: article.createdAt,
                playedState: article.isPlayed ? .played : (article.playbackSeconds != 0 ? .inProgress : .unplayed))
        case .episode(let episode), .audiobook(let episode):
            return PlaylistCandidate(
                entryID: episode.id, feedID: episode.feedID,
                kind: episode.isAudiobook ? "audiobook" : "podcast.episode",
                durationSeconds: episode.durationSeconds, publishedAt: episode.publishedAt ?? episode.releasedAt,
                playedState: episode.isPlayed ? .played : (episode.playbackSeconds != 0 ? .inProgress : .unplayed))
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
