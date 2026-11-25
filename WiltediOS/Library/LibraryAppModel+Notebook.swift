import Foundation
import WiltedDomain
import WiltedLibrary

struct LibraryNotebookClipRange: Equatable, Sendable {
    let startSeconds: Double
    let endSeconds: Double
    let textExcerpt: String?

    /// Captures the trailing 30 seconds, expanded to whole timed cues when this exact revision has them.
    static func capture(endingAt position: Double, transcript: LibraryTranscript?, entryID: ItemID, revisionID: RevisionID) -> Self? {
        guard position.isFinite, position > 0 else { return nil }
        let end = position
        let start = max(0, end - 30)
        guard let transcript, transcript.entryID == entryID, transcript.revisionID == revisionID,
              transcript.isTimed else {
            return .init(startSeconds: start, endSeconds: end, textExcerpt: nil)
        }
        let clipped = transcript.cues.filter { $0.end > start && $0.start < end }
        guard !clipped.isEmpty else { return .init(startSeconds: start, endSeconds: end, textExcerpt: nil) }
        return .init(
            startSeconds: clipped.map(\.start).min() ?? start,
            endSeconds: clipped.map(\.end).max() ?? end,
            textExcerpt: Self.boundedCueText(clipped))
    }

    private static func boundedCueText(_ cues: [LibraryTranscriptCue]) -> String? {
        var pieces: [String] = []
        var byteCount = 0
        for cue in cues {
            let cleanScalars = cue.text.unicodeScalars.map { scalar -> Unicode.Scalar in
                CharacterSet.controlCharacters.contains(scalar) && scalar != "\n" && scalar != "\t" ? " " : scalar
            }
            let clean = String(String.UnicodeScalarView(cleanScalars)).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !clean.isEmpty else { continue }
            let additional = clean.utf8.count + (pieces.isEmpty ? 0 : 1)
            guard byteCount + additional <= LibraryNotebookEntry.maximumTextBytes else { break }
            pieces.append(clean)
            byteCount += additional
        }
        let result = pieces.joined(separator: "\n")
        return result.isEmpty ? nil : result
    }
}

enum LibraryNotebookReplayPolicy {
    static func matches(_ entry: LibraryNotebookEntry, cached: CachedMedia?) -> Bool {
        entry.kind == .clip && entry.sourceKind == .podcast
            && cached?.revisionID == entry.sourceRevision
    }
}

extension LibraryAppModel {
    static let notebookIntentAction = "setNotebookEntry"

    var notebookEntries: [LibraryNotebookEntry] { notebookPhoneState.entries }

    func canCaptureNotebook(_ item: LibraryPlayer.Item?) -> Bool {
        guard canMutateNotebook, let item, item.feedbackRevisionID != nil,
              queued.contains(where: { $0.id == item.entryID && $0.kind == .podcastEpisode }) else { return false }
        return true
    }

    func notebookStatus(for entryID: ItemID) -> String {
        let isCheckingTranscript = notebookPhoneState.excerptPendingIDs.contains(entryID)
        if let command = notebookPhoneState.commands.last(where: { $0.entry.id == entryID }) {
            switch command.delivery {
            case .pending:
                return isCheckingTranscript ? "Saved on this phone · waiting to sync · checking for transcript text" : "Saved on this phone · waiting to sync"
            case .sent:
                return isCheckingTranscript ? "Saved on this phone · waiting for your Mac · checking for transcript text" : "Saved on this phone · waiting for your Mac"
            case .conflict: return command.detail ?? "Changed on your Mac. Review before reapplying."
            case .failed: return command.detail ?? "Your Mac could not save this entry. Try again."
            }
        }
        return isCheckingTranscript ? "Saved on this phone · checking for transcript text" : "Saved on this phone"
    }

    /// Captures from the currently loaded podcast file. Position and item are passed in as a snapshot
    /// so a Watch or Siri request cannot drift to a later player state while local evidence is read.
    @discardableResult
    func captureNotebookClip(
        for item: LibraryPlayer.Item,
        at position: TimeInterval,
        capturedOn origin: LibraryNotebookEntry.CaptureOrigin
    ) async -> LibraryNotebookEntry? {
        guard canCaptureNotebook(item), notebookPhoneState.beginCapture() else {
            notebookPhoneState.notice = "Open a prepared podcast episode before saving a moment."
            return nil
        }
        defer { notebookPhoneState.finishCapture() }
        guard let scope = notebookPhoneState.activeScope,
              let revision = item.feedbackRevisionID,
              let row = queued.first(where: { $0.id == item.entryID && $0.kind == .podcastEpisode }),
              let source = decisionContent.entries[item.entryID], source.kind == .podcastEpisode,
              let player = handoffState.player, player.item?.entryID == item.entryID,
              player.item?.feedbackRevisionID == revision else {
            notebookPhoneState.notice = "Open a prepared podcast episode before saving a moment."
            return nil
        }
        guard let context = await mediaContext(), context.ownerToken == scope.ownerToken else {
            notebookPhoneState.notice = "Notebook is unavailable while your library account is being checked."
            return nil
        }
        let cached = await mediaCache.cachedEntries()[item.entryID]
        guard let cached, cached.revisionID == revision, cachedProofMatches(cached, entryID: item.entryID, context: context),
              await mediaCache.verifies(cached),
              await mediaContextIsCurrent(context), player.item?.entryID == item.entryID,
              player.item?.feedbackRevisionID == revision else {
            notebookPhoneState.notice = "This podcast audio changed. Play its current prepared version before saving a moment."
            return nil
        }
        let end = min(max(0, position), player.duration)
        guard end.isFinite, end > 0 else {
            notebookPhoneState.notice = "Play a little of the episode before saving a moment."
            return nil
        }
        let payload = try? source.podcastEpisodePayload()
        let sourceURL = [payload?.episodeLink, payload?.enclosureURL].compactMap { $0 }.first(where: Self.isSafeNotebookURL)
        guard let sourceURL else {
            notebookPhoneState.notice = "This episode has no safe source link to save."
            return nil
        }
        let transcript: LibraryTranscript?
        if let current = transcripts[item.entryID], current.revisionID == revision {
            transcript = current
        } else {
            transcript = await mediaCache.cachedTranscript(entryID: item.entryID, revisionID: revision)
        }
        guard !accountQuarantined, notebookPhoneState.activeScope == scope,
              !mediaRevocations.contains(item.entryID),
              player.item?.entryID == item.entryID, player.item?.feedbackRevisionID == revision,
              await mediaContextIsCurrent(context), await mediaCache.verifies(cached) else { return nil }
        guard let range = LibraryNotebookClipRange.capture(
            endingAt: end, transcript: transcript, entryID: item.entryID, revisionID: revision),
              let notebookID = Self.newNotebookID() else {
            notebookPhoneState.notice = "This moment could not be saved. Try again."
            return nil
        }
        let createdAt = now()
        let entry: LibraryNotebookEntry
        do {
            entry = try LibraryNotebookEntry(
                id: notebookID, createdAt: createdAt, kind: .clip, sourceKind: .podcast,
                sourceItemID: item.entryID, sourceRevision: revision, sourceTitle: row.title,
                sourceURL: sourceURL, sourceName: row.showTitle,
                startSeconds: range.startSeconds, endSeconds: range.endSeconds, textExcerpt: range.textExcerpt,
                capturedOn: origin, updatedAt: createdAt)
        } catch {
            notebookPhoneState.notice = "This episode cannot be saved as a Notebook clip."
            return nil
        }
        let storeState = await store.state()
        guard !accountQuarantined, storeState.ownerToken == scope.ownerToken,
              !mediaRevocations.contains(item.entryID), decisionContent.entries[item.entryID] == source,
              player.item?.entryID == item.entryID, player.item?.feedbackRevisionID == revision,
              await mediaContextIsCurrent(context), await mediaCache.verifies(cached) else { return nil }
        let version = storeState.versions[LibraryRecordKey(kind: .notebookEntry, id: notebookID)] ?? 0
        let shouldSync = notebookCloudWritesEnabled && scope.ownerToken != nil
        let command = shouldSync ? try? notebookCommand(entry, baseVersion: version, scope: scope, createdAt: createdAt) : nil
        guard notebookPhoneState.store(entry, serverVersion: version, command: command) else {
            if notebookPhoneState.notice == nil { notebookPhoneState.notice = "Notebook could not save this moment on this phone." }
            return nil
        }
        notebookPhoneState.markJustCaptured(entry.id)
        notebookPhoneState.notice = nil
        if shouldSync { Task { [weak self] in await self?.sendPendingNotebookCommands() } }
        if transcript == nil {
            notebookPhoneState.notice = shouldSync
                ? "Saved on this phone. Checking for transcript text from this recording…"
                : "Saved on this phone. Transcript text is not available yet."
            if shouldSync { Task { [weak self] in await self?.fetchNotebookExcerptIfAvailable(entryID: entry.id) } }
        }
        return entry
    }

    /// Immediately hides a saved entry by persisting its tombstone before any send.
    func deleteNotebookEntry(id: ItemID) async {
        await stageNotebookTombstone(id: id, offersUndo: true)
    }

    /// Capture Undo removes the just-created clip without turning Undo into a duplicate restore.
    func undoNotebookCapture(id: ItemID) async {
        await stageNotebookTombstone(id: id, offersUndo: false)
    }

    /// Undo for a prior deletion creates a fresh id. The original tombstone stays immutable.
    @discardableResult
    func restoreNotebookEntryAsNewID(id: ItemID) async -> LibraryNotebookEntry? {
        guard canMutateNotebook, let scope = notebookPhoneState.activeScope,
              let deleted = notebookPhoneState.entry(id: id, includeDeleted: true), deleted.isDeleted,
              let newID = Self.newNotebookID() else { return nil }
        let createdAt = now()
        guard let restored = try? LibraryNotebookEntry(
            id: newID, createdAt: createdAt, kind: deleted.kind, sourceKind: deleted.sourceKind,
            sourceItemID: deleted.sourceItemID, sourceRevision: deleted.sourceRevision,
            sourceTitle: deleted.sourceTitle, sourceURL: deleted.sourceURL, sourceName: deleted.sourceName,
            startSeconds: deleted.startSeconds, endSeconds: deleted.endSeconds,
            textExcerpt: deleted.textExcerpt, note: deleted.note, tags: deleted.tags,
            capturedOn: deleted.capturedOn, reviewed: deleted.reviewed, updatedAt: createdAt) else { return nil }
        let version = await notebookBaseVersion(for: newID)
        let command = notebookCloudWritesEnabled && scope.ownerToken != nil
            ? try? notebookCommand(restored, baseVersion: version, scope: scope, createdAt: createdAt) : nil
        guard notebookPhoneState.store(restored, serverVersion: version, command: command) else { return nil }
        notebookPhoneState.markJustDeleted(nil)
        notebookPhoneState.markJustCaptured(nil)
        if command != nil { Task { [weak self] in await self?.sendPendingNotebookCommands() } }
        return restored
    }

    func updateNotebookNote(id: ItemID, note: String?) async -> Bool {
        guard canMutateNotebook, let current = notebookPhoneState.entry(id: id),
              let scope = notebookPhoneState.activeScope else { return false }
        let normalized = note?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        guard let updated = try? LibraryNotebookEntry(
            id: current.id, createdAt: current.createdAt, kind: current.kind, sourceKind: current.sourceKind,
            sourceItemID: current.sourceItemID, sourceRevision: current.sourceRevision,
            sourceTitle: current.sourceTitle, sourceURL: current.sourceURL, sourceName: current.sourceName,
            startSeconds: current.startSeconds, endSeconds: current.endSeconds, textExcerpt: current.textExcerpt,
            note: normalized, tags: current.tags, capturedOn: current.capturedOn, reviewed: true, updatedAt: now()) else {
            notebookPhoneState.notice = "The note is too long to save."
            return false
        }
        let version = await notebookBaseVersion(for: id)
        let existing = notebookPhoneState.commands.last(where: { $0.entry.id == id })
        if let existing, existing.delivery == .sent {
            // Keep the new local draft; a fresh versioned write follows the immutable sent receipt.
            return notebookPhoneState.store(updated, serverVersion: version)
        }
        if let existing, existing.delivery == .pending {
            var command = existing
            command.entry = updated
            return notebookPhoneState.store(updated, serverVersion: version, command: command)
        }
        guard existing == nil else {
            notebookPhoneState.notice = "Review the pending Notebook conflict before editing this entry."
            return false
        }
        let shouldSync = notebookCloudWritesEnabled && scope.ownerToken != nil
        let command = shouldSync ? try? notebookCommand(updated, baseVersion: version, scope: scope, createdAt: now()) : nil
        guard notebookPhoneState.store(updated, serverVersion: version, command: command) else { return false }
        if command != nil { Task { [weak self] in await self?.sendPendingNotebookCommands() } }
        return true
    }

    func reapplyNotebookCommand(_ commandID: String) async { await replaceNotebookCommand(commandID, retrying: false) }
    func retryNotebookCommand(_ commandID: String) async { await replaceNotebookCommand(commandID, retrying: true) }

    /// Exact-revision replay works even after the episode leaves the Larder.
    func replayNotebookEntry(id: ItemID) async -> Bool {
        guard canMutateNotebook, let entry = notebookPhoneState.entry(id: id),
              let player = handoffState.player, let context = await mediaContext() else { return false }
        let transportCount = player.transportCount
        let cached = await mediaCache.cachedEntries()[entry.sourceItemID]
        guard LibraryNotebookReplayPolicy.matches(entry, cached: cached), let cached,
              cachedProofMatches(cached, entryID: entry.sourceItemID, context: context),
              let fileIdentity = cached.fileIdentity(), await mediaCache.verifies(cached),
              await mediaContextIsCurrent(context), player.transportCount == transportCount,
              !mediaRevocations.contains(entry.sourceItemID), cached.fileIdentity() == fileIdentity,
              let start = entry.startSeconds, start.isFinite, start >= 0 else {
            notebookPhoneState.setReplayable(false, for: id)
            notebookPhoneState.notice = "Audio for this saved version is no longer available on this phone."
            return false
        }
        let item = LibraryPlayer.Item(
            entryID: entry.sourceItemID, title: entry.sourceTitle, showTitle: entry.sourceName ?? "",
            fileURL: cached.url, feedbackRevisionID: entry.sourceRevision)
        guard player.start(item, at: start, autoplay: true) else {
            notebookPhoneState.notice = "This clip could not start playing."
            return false
        }
        notebookPhoneState.notice = nil
        return true
    }

    func refreshNotebookReplayAvailability() async {
        guard canMutateNotebook, let context = await mediaContext() else {
            notebookPhoneState.clearReplayableIDs()
            return
        }
        let cached = await mediaCache.cachedEntries()
        guard await mediaContextIsCurrent(context) else { return }
        var replayable = Set<ItemID>()
        for entry in notebookPhoneState.entries where entry.sourceKind == .podcast && entry.kind == .clip {
            guard let value = cached[entry.sourceItemID], LibraryNotebookReplayPolicy.matches(entry, cached: value),
                  cachedProofMatches(value, entryID: entry.sourceItemID, context: context),
                  await mediaCache.verifies(value), await mediaContextIsCurrent(context) else { continue }
            replayable.insert(entry.id)
        }
        notebookPhoneState.replaceReplayableIDs(replayable)
    }
}

extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
