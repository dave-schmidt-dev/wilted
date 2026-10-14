import Foundation
import SwiftUI
import WiltedDomain
import WiltedProducer

extension WiltedMacModel {
    // MARK: - Editing

    /// Claims the write for one playlist. Returns nil when one is already in flight there, which is
    /// what makes a duplicate rename, save or delete on the same playlist visibly refuse while
    /// other playlists stay free to run.
    private func beginPlaylistOperation(_ id: String, _ operation: WiltedMacPlaylistOperation) -> UUID? {
        guard playlists.pending[id] == nil else {
            failPlaylistOperation(id, message: "Another change was not applied while this playlist was saving. Try again.")
            return nil
        }
        let token = UUID()
        playlists.pending[id] = WiltedMacPlaylistPending(token: token, operation: operation)
        playlists.failures[id] = nil
        playlists.loadGeneration &+= 1
        return token
    }

    /// Settles one playlist's write, if it is still the same write. The generation moves on so a
    /// load that began while the write was in flight cannot settle over the edit afterwards.
    private func finishPlaylistOperation(_ id: String, token: UUID) {
        guard playlists.pending[id]?.token == token else { return }
        playlists.pending[id] = nil
        let refusal = "Another change was not applied while this playlist was saving. Try again."
        if playlists.failures[id] == refusal {
            playlists.failures[id] = nil
            if playlists.message == refusal { playlists.message = nil }
        }
        playlists.loadGeneration &+= 1
        guard playlists.pending.isEmpty else { return }
        Task { [weak self] in
            guard let self, !self.isClosingTemporaryState else { return }
            await self.loadPlaylists()
        }
    }

    private func failPlaylistOperation(_ id: String, message: String) {
        playlists.failures[id] = message
        playlists.message = message
    }

    /// A name no other playlist has: "New Playlist", then "New Playlist 2" and so on. In-flight
    /// creates hold their names, so a second menu opened at once cannot reuse one.
    func newPlaylistName() -> String { uniquePlaylistName(base: nil) }

    func uniquePlaylistName(base: String?) -> String {
        let taken = Set(playlists.playlists.map(\.name)).union(playlists.reservedNames)
        let trimmed = base?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let stem = trimmed.isEmpty ? "New Playlist" : trimmed
        guard taken.contains(stem) else { return stem }
        var number = 2
        while taken.contains("\(stem) \(number)") { number += 1 }
        return "\(stem) \(number)"
    }

    /// Creates a playlist after the existing ones and opens it. The row and the selection appear
    /// before the first await, and a failed write removes only the new row and restores the prior
    /// selection only while the reader is still on it.
    @discardableResult
    func createPlaylist(kind: PlaylistKind, name: String? = nil, adding entryID: String? = nil) async -> Playlist? {
        guard let store else { return nil }
        let id = UUID().uuidString
        let trimmedName = name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let resolvedName = trimmedName.isEmpty ? newPlaylistName() : trimmedName
        let previousSelection = selectedNavigation
        let created = Playlist(
            id: id, name: resolvedName, kind: kind, matchAll: true,
            sortIndex: (playlists.playlists.map(\.sortIndex).max() ?? -1) + 1)
        playlists.reservedNames.insert(resolvedName)
        playlists.optimisticCreatedIDs.insert(id)
        playlists.playlists.append(created)
        if kind == .manual, let entryID { playlists.entryIDs[id] = [entryID] }
        playlists.creatingCount += 1
        playlists.createFailure = nil
        selectedNavigation = .playlist(id)
        guard let token = beginPlaylistOperation(id, .creating) else {
            removeOptimisticCreate(id, named: resolvedName, selection: previousSelection)
            return nil
        }
        do {
            try await Self.playlistWriteHookForTesting?()
            let stored = try await store.createPlaylist(
                id: id, name: resolvedName, kind: kind, matchAll: true,
                initialEntryID: kind == .manual ? entryID : nil)
            if let index = playlists.playlists.firstIndex(where: { $0.id == id }) {
                playlists.playlists[index] = stored
            }
            playlists.optimisticCreatedIDs.remove(id)
            playlists.reservedNames.remove(resolvedName)
            playlists.creatingCount = max(0, playlists.creatingCount - 1)
            finishPlaylistOperation(id, token: token)
            return stored
        } catch {
            removeOptimisticCreate(id, named: resolvedName, selection: previousSelection)
            playlists.createFailure = "The playlist could not be created."
            finishPlaylistOperation(id, token: token)
            return nil
        }
    }

    private func removeOptimisticCreate(_ id: String, named name: String, selection: WiltedMacNavigation) {
        playlists.playlists.removeAll { $0.id == id }
        playlists.entryIDs[id] = nil
        playlists.rules[id] = nil
        playlists.optimisticCreatedIDs.remove(id)
        playlists.reservedNames.remove(name)
        playlists.creatingCount = max(0, playlists.creatingCount - 1)
        if selectedNavigation == .playlist(id) { selectedNavigation = selection }
    }

    func renamePlaylist(_ id: String, to name: String) async {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let store, !trimmed.isEmpty,
              let index = playlists.playlists.firstIndex(where: { $0.id == id }) else { return }
        guard let token = beginPlaylistOperation(id, .playlist) else { return }
        let previousName = playlists.playlists[index].name
        playlists.playlists[index] = playlists.playlists[index].replacing(name: trimmed)
        do {
            try await Self.playlistWriteHookForTesting?()
            try await store.updatePlaylist(id: id, name: trimmed)
            finishPlaylistOperation(id, token: token)
        } catch {
            if let index = playlists.playlists.firstIndex(where: { $0.id == id }),
               playlists.playlists[index].name == trimmed {
                playlists.playlists[index] = playlists.playlists[index].replacing(name: previousName)
            }
            failPlaylistOperation(id, message: "The playlist could not be renamed.")
            finishPlaylistOperation(id, token: token)
        }
    }

    /// Deletes the playlist and its entries and rules. Library items are untouched. A deleted
    /// selection resolves to the Larder and a session playing it ends; a failure restores the row's
    /// relative order, the session only while nothing else owns playback, and the selection only
    /// while the reader is still on the Larder fallback this delete chose.
    func deletePlaylist(_ id: String) async {
        guard let store, let index = playlists.playlists.firstIndex(where: { $0.id == id }) else { return }
        guard let token = beginPlaylistOperation(id, .playlist) else { return }
        let removed = playlists.playlists.remove(at: index)
        let removedEntries = playlists.entryIDs.removeValue(forKey: id)
        let removedRules = playlists.rules.removeValue(forKey: id)
        playlists.optimisticDeletedIDs.insert(id)
        let selectionBefore = selectedNavigation
        if selectedNavigation == .playlist(id) { selectedNavigation = .larder }
        let sessionBefore = playlists.session
        let playbackGenerationBefore = playbackCommands.generation
        if playlists.session?.playlistID == id { playlists.session = nil }
        do {
            try await Self.playlistWriteHookForTesting?()
            try await store.deletePlaylist(id: id)
            playlists.optimisticDeletedIDs.remove(id)
            finishPlaylistOperation(id, token: token)
        } catch {
            playlists.optimisticDeletedIDs.remove(id)
            playlists.playlists.insert(removed, at: min(index, playlists.playlists.count))
            if let removedEntries { playlists.entryIDs[id] = removedEntries }
            if let removedRules { playlists.rules[id] = removedRules }
            if playlists.session == nil, let sessionBefore, sessionBefore.playlistID == id,
               playbackCommands.generation == playbackGenerationBefore {
                playlists.session = sessionBefore
            }
            if selectedNavigation == .larder, selectionBefore == .playlist(id) { selectedNavigation = selectionBefore }
            failPlaylistOperation(id, message: "The playlist could not be deleted.")
            finishPlaylistOperation(id, token: token)
        }
    }

    func addToPlaylist(_ playlistID: String, entryID: String) async {
        guard let store else { return }
        guard let token = beginPlaylistOperation(playlistID, .playlist) else { return }
        let appended = playlists.entryIDs[playlistID]?.contains(entryID) != true
        if appended { playlists.entryIDs[playlistID, default: []].append(entryID) }
        do {
            try await Self.playlistWriteHookForTesting?()
            try await store.addPlaylistEntry(playlistID: playlistID, entryID: entryID)
            finishPlaylistOperation(playlistID, token: token)
        } catch {
            if appended { playlists.entryIDs[playlistID]?.removeAll { $0 == entryID } }
            failPlaylistOperation(playlistID, message: "That could not be added to the playlist.")
            finishPlaylistOperation(playlistID, token: token)
        }
    }

    func removeFromPlaylist(_ playlistID: String, entryID: String) async {
        guard let store else { return }
        guard let token = beginPlaylistOperation(playlistID, .playlist) else { return }
        let previous = playlists.entryIDs[playlistID] ?? []
        guard let index = previous.firstIndex(of: entryID) else {
            finishPlaylistOperation(playlistID, token: token)
            return
        }
        let optimistic = previous.enumerated().compactMap { $0.offset == index ? nil : $0.element }
        playlists.entryIDs[playlistID] = optimistic
        do {
            try await Self.playlistWriteHookForTesting?()
            try await store.removePlaylistEntry(playlistID: playlistID, entryID: entryID)
            finishPlaylistOperation(playlistID, token: token)
        } catch {
            if playlists.entryIDs[playlistID] == optimistic { playlists.entryIDs[playlistID] = previous }
            failPlaylistOperation(playlistID, message: "That could not be removed from the playlist.")
            finishPlaylistOperation(playlistID, token: token)
        }
    }

    /// Moves a manual playlist's entry so it sits at `index` in the resulting order.
    func movePlaylistEntry(_ playlistID: String, entryID: String, to index: Int) async {
        guard let store else { return }
        guard let token = beginPlaylistOperation(playlistID, .playlist) else { return }
        let previous = playlists.entryIDs[playlistID] ?? []
        guard let from = previous.firstIndex(of: entryID), previous.indices.contains(index) else {
            finishPlaylistOperation(playlistID, token: token)
            return
        }
        var reordered = previous
        reordered.remove(at: from)
        reordered.insert(entryID, at: min(index, reordered.count))
        playlists.entryIDs[playlistID] = reordered
        do {
            try await Self.playlistWriteHookForTesting?()
            try await store.movePlaylistEntry(playlistID: playlistID, entryID: entryID, to: index)
            finishPlaylistOperation(playlistID, token: token)
        } catch {
            if playlists.entryIDs[playlistID] == reordered { playlists.entryIDs[playlistID] = previous }
            failPlaylistOperation(playlistID, message: "The playlist could not be reordered.")
            finishPlaylistOperation(playlistID, token: token)
        }
    }

    /// Saves an automatic playlist's rules and its all-of or any-of choice. The projection is
    /// visible before the first await; a failure restores only this playlist's rules and mode.
    func savePlaylistRules(_ playlistID: String, rules: [PlaylistRule], matchAll: Bool) async -> Bool {
        guard let store, let index = playlists.playlists.firstIndex(where: { $0.id == playlistID }) else {
            return false
        }
        guard playlists.ruleReadErrors[playlistID] == nil else {
            failPlaylistOperation(playlistID, message: "The playlist rules could not be read.")
            return false
        }
        guard let token = beginPlaylistOperation(playlistID, .rules) else { return false }
        let previousRules = playlists.rules[playlistID]
        let previousMatchAll = playlists.playlists[index].matchAll
        playlists.rules[playlistID] = rules
        playlists.playlists[index] = playlists.playlists[index].replacing(matchAll: matchAll)
        do {
            try await Self.playlistWriteHookForTesting?()
            try await store.setPlaylistRules(playlistID: playlistID, rules: rules, matchAll: matchAll)
            playlists.failures[playlistID] = nil
            finishPlaylistOperation(playlistID, token: token)
            return true
        } catch {
            if playlists.rules[playlistID] == rules { playlists.rules[playlistID] = previousRules }
            if let index = playlists.playlists.firstIndex(where: { $0.id == playlistID }),
               playlists.playlists[index].matchAll == matchAll {
                playlists.playlists[index] = playlists.playlists[index].replacing(matchAll: previousMatchAll)
            }
            failPlaylistOperation(playlistID, message: "The rules could not be saved.")
            finishPlaylistOperation(playlistID, token: token)
            return false
        }
    }
}

private extension Playlist {
    /// One playlist value with a single field replaced, for a field-scoped optimistic edit.
    func replacing(name: String? = nil, matchAll: Bool? = nil) -> Playlist {
        Playlist(
            id: id, name: name ?? self.name, kind: kind,
            matchAll: matchAll ?? self.matchAll, sortIndex: sortIndex)
    }
}
