import Foundation
import WiltedDomain
import WiltedLibrary
import WiltedProducer

extension WiltedMacModel {
    /// The owner partition follows the durable binding while offline or held.
    /// Cloud writes still require the separately verified Development transport.
    func notebookLocalScope() async -> NotebookLocalScope? {
        guard let store else { return nil }
        let activeBinding = librarySyncController?.account?.binding
        let persistedBinding = activeBinding == nil ? try? await store.libraryAccountBinding() : nil
        let owner = activeBinding?.ownerToken ?? persistedBinding?.ownerToken
        return try? NotebookLocalScope(ownerToken: owner, deviceID: libraryDeviceID())
    }

    func loadNotebookEntries() async throws -> [LibraryNotebookEntry] {
        guard let store, let scope = await notebookLocalScope() else { return [] }
        return try await store.notebookEntries(in: scope, includingDeleted: false)
    }

    /// Captures a bounded clip from the exact loaded audio revision. The
    /// excerpt is copied from overlapping cues on that same revision when
    /// they are available; later revisions are never used as a substitute.
    func captureNotebookClip(now: Date = Date()) async throws -> LibraryNotebookEntry {
        guard let store, let playback,
              let itemID = playback.itemID, let revisionID = playback.revisionID else {
            throw WiltedMacNotebookError.noCurrentPodcast
        }
        let position = playback.livePositionSeconds
        guard let scope = await notebookLocalScope() else { throw WiltedMacNotebookError.storeUnavailable }
        // The Larder row is a presentation projection and may disappear while
        // the player still has a podcast revision loaded. The durable typed
        // catalog record proves this is a podcast and supplies stable source
        // metadata without depending on that row.
        guard let sourceEpisode = try await store.podcastEpisode(for: itemID) else {
            throw WiltedMacNotebookError.noCurrentPodcast
        }
        let displayedEpisode = currentEpisode.flatMap { $0.id == itemID.rawValue ? $0 : nil }
        let feed = try? await store.podcastFeed(for: sourceEpisode.feedID)
        guard let stored = try await store.readyRevision(for: itemID, revisionID: revisionID),
              FileManager.default.fileExists(atPath: stored.mediaURL.path) else {
            throw WiltedMacNotebookError.originalAudioUnavailable
        }
        let duration = stored.revision.durationSeconds
        let clipEnd = min(max(0, position), duration)
        guard clipEnd > 0 else { throw WiltedMacNotebookError.noPlayedAudio }
        var clipStart = max(0, clipEnd - 30)
        var finalEnd = clipEnd
        var excerpt: String?
        if let transcript = try? await store.transcript(for: itemID, revisionID: revisionID),
           transcript.availability == .available, transcript.timing != .none,
           let cues = transcript.cues {
            let selected = cues.filter { $0.endSeconds >= clipStart && $0.startSeconds <= finalEnd }
            if let first = selected.first, let last = selected.last {
                clipStart = max(0, min(clipStart, first.startSeconds))
                finalEnd = min(duration, max(finalEnd, last.endSeconds))
                excerpt = String(selected.map(\.text).joined(separator: " ").prefix(16_000))
            }
        }
        let entry = try LibraryNotebookEntry(
            id: ItemID(rawValue: "notebook-\(UUID().uuidString.lowercased())"),
            createdAt: now, kind: .clip, sourceKind: .podcast,
            sourceItemID: itemID, sourceRevision: revisionID,
            sourceTitle: displayedEpisode?.title ?? sourceEpisode.title,
            sourceURL: displayedEpisode?.episodeLink ?? sourceEpisode.episodeLink ?? sourceEpisode.enclosureURL,
            sourceName: displayedEpisode?.feedTitle ?? feed?.title ?? sourceEpisode.author,
            startSeconds: clipStart, endSeconds: finalEnd, textExcerpt: excerpt,
            capturedOn: .mac, reviewed: true, updatedAt: now
        )
        guard self.store === store else { throw WiltedMacNotebookError.storeUnavailable }
        guard self.playback === playback, playback.itemID == itemID, playback.revisionID == revisionID else {
            throw WiltedMacNotebookError.noCurrentPodcast
        }
        guard await notebookLocalScope() == scope else { throw WiltedMacNotebookError.storeUnavailable }
        _ = try await store.saveNotebookEntry(entry, in: scope)
        return entry
    }

    func saveNotebookNote(_ entry: LibraryNotebookEntry, note: String?) async throws -> LibraryNotebookEntry {
        guard let store, let scope = await notebookLocalScope() else { throw WiltedMacNotebookError.storeUnavailable }
        let updated = try LibraryNotebookEntry(
            id: entry.id, createdAt: entry.createdAt, kind: entry.kind, sourceKind: entry.sourceKind,
            sourceItemID: entry.sourceItemID, sourceRevision: entry.sourceRevision,
            sourceTitle: entry.sourceTitle, sourceURL: entry.sourceURL, sourceName: entry.sourceName,
            startSeconds: entry.startSeconds, endSeconds: entry.endSeconds, textExcerpt: entry.textExcerpt,
            note: note, tags: entry.tags, capturedOn: entry.capturedOn, reviewed: entry.reviewed,
            updatedAt: Date(), deletedAt: entry.deletedAt
        )
        _ = try await store.saveNotebookEntry(updated, in: scope)
        return updated
    }

    func deleteNotebookEntry(_ entry: LibraryNotebookEntry) async throws -> LibraryNotebookEntry? {
        guard let store, let scope = await notebookLocalScope() else { throw WiltedMacNotebookError.storeUnavailable }
        return try await store.tombstoneNotebookEntry(id: entry.id, in: scope)
    }

    func undoNotebookDelete(_ entry: LibraryNotebookEntry) async throws -> LibraryNotebookEntry? {
        guard let store, let scope = await notebookLocalScope() else { throw WiltedMacNotebookError.storeUnavailable }
        let newID = try ItemID(rawValue: "notebook-\(UUID().uuidString.lowercased())")
        return try await store.restoreNotebookEntry(id: entry.id, as: newID, in: scope)
    }

    /// Uses only the saved source revision. If routine cleanup reclaimed it,
    /// the Notebook remains readable and reports that its original audio is gone.
    func playNotebookClip(_ entry: LibraryNotebookEntry) {
        guard entry.kind == .clip, entry.sourceKind == .podcast,
              let start = entry.startSeconds, let store, let playback else { return }
        let opening = "Opening saved clip…"
        playbackOperationStatus = opening
        issuePlaybackCommand(.select, pending: opening, target: entry.sourceItemID.rawValue,
                             failureMessage: "Original audio unavailable.") { [weak self] command in
            guard let self else { return }
            do {
                guard let stored = try await store.readyRevision(
                    for: entry.sourceItemID, revisionID: entry.sourceRevision
                ), FileManager.default.fileExists(atPath: stored.mediaURL.path) else {
                    self.playbackOperationStatus = nil
                    self.playbackError = "Original audio unavailable."
                    return
                }
                try await playback.loadNotebookClip(stored, startSeconds: start)
                try self.ensureNewestSelection(command)
                self.currentPodcastEpisodeID = entry.sourceItemID.rawValue
                self.selectedArticleID = nil
                self.isPodcastPlayback = true
                self.isNowPlaying = true
                self.playbackError = nil
                try self.startIfCurrent(playback, for: command)
                self.requestPlaybackPresentation(itemID: entry.sourceItemID, includesCuts: true)
                self.refreshPlaybackReadout()
                self.playbackOperationStatus = nil
            } catch {
                self.playbackOperationStatus = nil
                self.playbackError = "Original audio unavailable."
            }
        }
    }
}

enum WiltedMacNotebookError: Error, Equatable {
    case noCurrentPodcast
    case originalAudioUnavailable
    case noPlayedAudio
    case storeUnavailable

    var message: String {
        switch self {
        case .noCurrentPodcast: "Play a podcast episode before capturing a clip."
        case .originalAudioUnavailable: "Original audio unavailable."
        case .noPlayedAudio: "Play a little farther before capturing a clip."
        case .storeUnavailable: "Notebook is unavailable right now."
        }
    }
}
