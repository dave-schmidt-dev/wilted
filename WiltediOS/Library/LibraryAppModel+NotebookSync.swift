import Foundation
import WiltedDomain
import WiltedLibrary

extension LibraryAppModel {
    /// Called before media revocation deletes the old revision directory, preserving cue text that
    /// belongs to an already captured clip. It never searches a newer revision.
    func preserveNotebookExcerptEvidence(entryID: ItemID, revisionID: RevisionID) async {
        guard canMutateNotebook else { return }
        let candidateIDs = notebookPhoneState.entries.filter {
            $0.sourceItemID == entryID && $0.sourceRevision == revisionID && $0.textExcerpt == nil
        }.map(\.id)
        guard !candidateIDs.isEmpty else { return }
        let transcript: LibraryTranscript?
        if let current = transcripts[entryID], current.revisionID == revisionID {
            transcript = current
        } else {
            transcript = await mediaCache.cachedTranscript(entryID: entryID, revisionID: revisionID)
        }
        guard let transcript,
              transcript.entryID == entryID, transcript.revisionID == revisionID else { return }
        for id in candidateIDs { await fillNotebookExcerpt(id: id, from: transcript) }
    }

    /// Fills only entries with no text and the exact saved revision. A late result after delete is a no-op.
    func fetchNotebookExcerptIfAvailable(entryID: ItemID) async {
        guard canMutateNotebook, let scope = notebookPhoneState.activeScope,
              let entry = notebookPhoneState.entry(id: entryID),
              entry.textExcerpt == nil, !entry.isDeleted,
              notebookPhoneState.beginExcerptCheck(for: entry, now: now()) else { return }
        defer { notebookPhoneState.setExcerptPending(false, for: entryID, in: scope) }
        var transcript = await mediaCache.cachedTranscript(entryID: entry.sourceItemID, revisionID: entry.sourceRevision)
        if transcript == nil, notebookCloudWritesEnabled, let owner = notebookPhoneState.ownerForActions {
            let generation = await transport.operationGeneration()
            guard notebookPhoneState.isCurrent(owner: owner, generation: generation),
                  await transport.verifiedOwnerToken() == owner else { return }
            transcript = try? await transport.transcript(entryID: entry.sourceItemID, revisionID: entry.sourceRevision)
            guard await transport.operationGeneration() == generation,
                  await transport.verifiedOwnerToken() == owner,
                  notebookPhoneState.isCurrent(owner: owner, generation: generation) else { return }
            if let transcript { await mediaCache.storeTranscript(transcript) }
        }
        guard let transcript, transcript.entryID == entry.sourceItemID,
              transcript.revisionID == entry.sourceRevision else { return }
        await fillNotebookExcerpt(id: entryID, from: transcript)
    }

    func reconcileNotebookCommands(outcomes: [IntentOutcome], expectedOwner: String?, generation: UInt64) async {
        guard let expectedOwner, !accountQuarantined,
              notebookPhoneState.isCurrent(owner: expectedOwner, generation: generation) else { return }
        let current = await store.state()
        guard current.ownerToken == expectedOwner,
              await transport.operationGeneration() == generation,
              await transport.verifiedOwnerToken() == expectedOwner,
              notebookPhoneState.isCurrent(owner: expectedOwner, generation: generation) else { return }
        for command in notebookPhoneState.commands where command.delivery == .sent {
            guard let outcome = outcomes.first(where: { $0.intentID == command.id && $0.deviceID == deviceID }) else { continue }
            let canonical = current.content.notebookEntries[command.entry.id]
            let version = current.versions[LibraryRecordKey(kind: .notebookEntry, id: command.entry.id)] ?? 0
            if outcome.isApplied {
                guard let canonical, canonical == command.entry else { continue }
                let local = notebookPhoneState.entry(id: command.entry.id, includeDeleted: true)
                _ = notebookPhoneState.store(canonical, serverVersion: version)
                _ = notebookPhoneState.removeCommand(id: command.id)
                if let local, local != command.entry {
                    await stageNotebookEntry(local, basedOnVersion: version)
                }
            } else if outcome.reason == IntentOutcome.reasonStaleRevision {
                var conflict = command
                conflict.delivery = .conflict
                conflict.serverEntry = canonical
                conflict.detail = canonical?.isDeleted == true
                    ? "This entry was deleted on your Mac. Reapply creates a new Notebook entry."
                    : "This entry changed on your Mac. Review the latest version before reapplying."
                _ = notebookPhoneState.update(conflict)
                if let canonical { _ = notebookPhoneState.store(canonical, serverVersion: version) }
            } else {
                var failed = command
                failed.delivery = .failed
                failed.detail = outcome.reason == IntentOutcome.reasonUnsupportedAction
                    ? "Update Wilted on your Mac to sync Notebook entries."
                    : "Your Mac could not save this entry. Try again."
                _ = notebookPhoneState.update(failed)
            }
        }
        if notebookCloudWritesEnabled {
            for entry in notebookPhoneState.entries where entry.kind == .clip && entry.textExcerpt == nil {
                Task { [weak self] in await self?.fetchNotebookExcerptIfAvailable(entryID: entry.id) }
            }
        }
    }

    func sendPendingNotebookCommands() async {
        guard !accountQuarantined, notebookCloudWritesEnabled,
              let scope = notebookPhoneState.activeScope, let owner = scope.ownerToken else { return }
        let pending = notebookPhoneState.commands.filter { $0.delivery == .pending && $0.scope == scope }
        guard !pending.isEmpty else { return }
        if macAddActions == nil || macAddCheckFailed || macAddActions?.contains(Self.notebookIntentAction) != true {
            await loadAddCapability()
        }
        guard !accountQuarantined, macAddActions?.contains(Self.notebookIntentAction) == true else {
            for var command in pending {
                command.detail = "Update Wilted on your Mac to sync Notebook entries."
                _ = notebookPhoneState.update(command)
            }
            return
        }
        for command in pending {
            guard !accountQuarantined, command.scope == notebookPhoneState.activeScope,
                  notebookPhoneState.commands.contains(where: { $0.id == command.id && $0.delivery == .pending }) else { continue }
            let generation = await transport.operationGeneration()
            guard await transport.verifiedOwnerToken() == owner,
                  notebookPhoneState.isCurrent(owner: owner, generation: generation) else { continue }
            var reserved = command
            reserved.delivery = .sent
            reserved.detail = "Saved on this phone · waiting for your Mac"
            guard notebookPhoneState.update(reserved) else { continue }
            do {
                let intent = try LibraryIntent.setNotebookEntry(
                    entry: command.entry, basedOnVersion: command.baseVersion,
                    deviceID: deviceID, createdAt: command.createdAt, id: command.id)
                try await transport.send(intent: intent)
                guard await transport.operationGeneration() == generation,
                      await transport.verifiedOwnerToken() == owner,
                      notebookPhoneState.isCurrent(owner: owner, generation: generation) else { continue }
            } catch {
                guard await transport.operationGeneration() == generation,
                      await transport.verifiedOwnerToken() == owner,
                      notebookPhoneState.isCurrent(owner: owner, generation: generation) else { continue }
                var retry = reserved
                retry.delivery = .pending
                retry.detail = "Waiting for a connection to your Mac."
                _ = notebookPhoneState.update(retry)
            }
        }
    }

    var canMutateNotebook: Bool {
        !accountQuarantined && notebookPhoneState.isBoundToLocalScope && !notebookPhoneState.isHeldForAccountReview
    }

    var notebookCloudWritesEnabled: Bool {
        transport.notebookCloudWriteMode == .development
    }

    func stageNotebookTombstone(id: ItemID, offersUndo: Bool) async {
        guard canMutateNotebook, let scope = notebookPhoneState.activeScope,
              let entry = notebookPhoneState.entry(id: id), !entry.isDeleted else { return }
        let deletedAt = now()
        guard let tombstone = try? LibraryNotebookEntry(
            id: entry.id, createdAt: entry.createdAt, kind: entry.kind, sourceKind: entry.sourceKind,
            sourceItemID: entry.sourceItemID, sourceRevision: entry.sourceRevision,
            sourceTitle: entry.sourceTitle, sourceURL: entry.sourceURL, sourceName: entry.sourceName,
            startSeconds: entry.startSeconds, endSeconds: entry.endSeconds, textExcerpt: entry.textExcerpt,
            note: entry.note, tags: entry.tags, capturedOn: entry.capturedOn, reviewed: entry.reviewed,
            updatedAt: deletedAt, deletedAt: deletedAt) else { return }
        let version = await notebookBaseVersion(for: id)
        let existing = notebookPhoneState.commands.last(where: { $0.entry.id == id })
        if let existing, existing.delivery == .sent {
            guard notebookPhoneState.store(tombstone, serverVersion: version) else { return }
        } else if let existing, existing.delivery == .pending {
            var replacement = existing
            replacement.entry = tombstone
            guard notebookPhoneState.store(tombstone, serverVersion: version, command: replacement) else { return }
        } else if existing == nil {
            let shouldSync = notebookCloudWritesEnabled && scope.ownerToken != nil
            let command = shouldSync ? try? notebookCommand(tombstone, baseVersion: version, scope: scope, createdAt: deletedAt) : nil
            guard notebookPhoneState.store(tombstone, serverVersion: version, command: command) else { return }
        } else {
            notebookPhoneState.notice = "Review the Notebook conflict before deleting this entry."
            return
        }
        if notebookPhoneState.lastCapturedEntryID == id { notebookPhoneState.markJustCaptured(nil) }
        notebookPhoneState.markJustDeleted(offersUndo ? id : nil)
        if notebookCloudWritesEnabled { Task { [weak self] in await self?.sendPendingNotebookCommands() } }
    }

    func stageNotebookEntry(_ entry: LibraryNotebookEntry, basedOnVersion version: UInt64) async {
        guard canMutateNotebook, let scope = notebookPhoneState.activeScope else { return }
        let shouldSync = notebookCloudWritesEnabled && scope.ownerToken != nil
        let command = shouldSync ? try? notebookCommand(entry, baseVersion: version, scope: scope, createdAt: now()) : nil
        guard notebookPhoneState.store(entry, serverVersion: version, command: command) else { return }
        if command != nil { Task { [weak self] in await self?.sendPendingNotebookCommands() } }
    }

    func fillNotebookExcerpt(id: ItemID, from transcript: LibraryTranscript) async {
        guard canMutateNotebook, let current = notebookPhoneState.entry(id: id),
              !current.isDeleted, current.textExcerpt == nil,
              transcript.entryID == current.sourceItemID, transcript.revisionID == current.sourceRevision,
              let end = current.endSeconds,
              let range = LibraryNotebookClipRange.capture(
                endingAt: end, transcript: transcript, entryID: current.sourceItemID, revisionID: current.sourceRevision) else { return }
        guard let filled = try? LibraryNotebookEntry(
            id: current.id, createdAt: current.createdAt, kind: current.kind, sourceKind: current.sourceKind,
            sourceItemID: current.sourceItemID, sourceRevision: current.sourceRevision,
            sourceTitle: current.sourceTitle, sourceURL: current.sourceURL, sourceName: current.sourceName,
            startSeconds: range.startSeconds, endSeconds: range.endSeconds, textExcerpt: range.textExcerpt,
            note: current.note, tags: current.tags, capturedOn: current.capturedOn, reviewed: current.reviewed,
            updatedAt: now()), filled.textExcerpt != nil else { return }
        let existing = notebookPhoneState.commands.last(where: { $0.entry.id == id })
        if let existing, existing.delivery == .pending {
            var replacement = existing
            replacement.entry = filled
            _ = notebookPhoneState.store(filled, serverVersion: notebookPhoneState.storedVersion(for: id), command: replacement)
            return
        }
        if existing != nil {
            // The sent command is immutable. The next sync round stages this exact-revision enrichment after it settles.
            _ = notebookPhoneState.store(filled, serverVersion: notebookPhoneState.storedVersion(for: id))
            return
        }
        let version = await notebookBaseVersion(for: id)
        await stageNotebookEntry(filled, basedOnVersion: version)
    }

    func notebookBaseVersion(for entryID: ItemID) async -> UInt64 {
        let scope = notebookPhoneState.activeScope
        let state = await store.state()
        guard !accountQuarantined, notebookPhoneState.activeScope == scope,
              state.ownerToken == scope?.ownerToken else { return notebookPhoneState.storedVersion(for: entryID) }
        return state.versions[LibraryRecordKey(kind: .notebookEntry, id: entryID)]
            ?? notebookPhoneState.storedVersion(for: entryID)
    }

    func notebookCommand(
        _ entry: LibraryNotebookEntry, baseVersion: UInt64, scope: NotebookLocalScope, createdAt: Date
    ) throws -> LibraryNotebookOutbox.Command {
        let intent = try LibraryIntent.setNotebookEntry(
            entry: entry, basedOnVersion: baseVersion, deviceID: deviceID, createdAt: createdAt)
        return .init(id: intent.id, scope: scope, createdAt: createdAt, entry: entry,
                     baseVersion: baseVersion, delivery: .pending, detail: "Waiting to sync")
    }

    func replaceNotebookCommand(_ commandID: String, retrying: Bool) async {
        guard canMutateNotebook, let old = notebookPhoneState.commands.first(where: { $0.id == commandID }),
              retrying ? old.delivery == .failed : old.delivery == .conflict,
              let scope = notebookPhoneState.activeScope else { return }
        var desired = old.delivery == .conflict ? old.entry : (notebookPhoneState.entry(id: old.entry.id, includeDeleted: true) ?? old.entry)
        if old.delivery == .conflict, old.serverEntry?.isDeleted == true, !desired.isDeleted,
           let newID = Self.newNotebookID() {
            let createdAt = now()
            guard let copy = try? LibraryNotebookEntry(
                id: newID, createdAt: createdAt, kind: desired.kind, sourceKind: desired.sourceKind,
                sourceItemID: desired.sourceItemID, sourceRevision: desired.sourceRevision,
                sourceTitle: desired.sourceTitle, sourceURL: desired.sourceURL, sourceName: desired.sourceName,
                startSeconds: desired.startSeconds, endSeconds: desired.endSeconds,
                textExcerpt: desired.textExcerpt, note: desired.note, tags: desired.tags,
                capturedOn: desired.capturedOn, reviewed: desired.reviewed, updatedAt: createdAt) else { return }
            desired = copy
        }
        let version = await notebookBaseVersion(for: desired.id)
        guard let new = try? notebookCommand(desired, baseVersion: version, scope: scope, createdAt: now()) else { return }
        guard notebookPhoneState.replaceTerminalCommand(oldID: commandID, with: new, entry: desired, serverVersion: version) else { return }
        if notebookCloudWritesEnabled, scope.ownerToken != nil { Task { [weak self] in await self?.sendPendingNotebookCommands() } }
    }

    static func newNotebookID() -> ItemID? {
        try? ItemID(rawValue: "notebook-\(UUID().uuidString.lowercased())")
    }

    static func isSafeNotebookURL(_ url: URL) -> Bool {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let scheme = components.scheme?.lowercased(), ["http", "https"].contains(scheme),
              let host = components.host, !host.isEmpty, components.user == nil, components.password == nil else { return false }
        return url.absoluteString.utf8.count <= 4_096
    }
}
