import AppKit
import Foundation
import WiltedDomain
import WiltedProducer

/// Finds an episode's prepared audio file and selects it in Finder.
struct WiltedMacFinderReveal {
    /// The prepared audio file for an entry, or nil when it has none.
    let audioFile: (ItemID) async throws -> URL?
    /// Selects the file in Finder.
    let present: (URL) -> Void

    /// Selects the entry's prepared audio in Finder. False when there is no file on disk to show.
    @MainActor
    func reveal(_ entryID: ItemID) async -> Bool {
        guard let url = try? await audioFile(entryID), url.isFileURL,
              FileManager.default.fileExists(atPath: url.path) else { return false }
        present(url)
        return true
    }
}

extension WiltedMacModel {
    /// Whether the Larder offers Show in Finder: only a prepared episode has audio of its own on disk.
    func canShowInFinder(_ episode: WiltedMacEpisode) -> Bool {
        episode.preparationState.isPrepared
    }

    /// Selects the episode's prepared audio file in Finder, or beeps when the file is gone.
    @discardableResult
    func showInFinder(_ episode: WiltedMacEpisode) -> Task<Void, Never>? {
        guard canShowInFinder(episode), let store, let entryID = try? ItemID(rawValue: episode.id) else { return nil }
        let reveal = WiltedMacFinderReveal(
            audioFile: { try await WiltedMacLibraryReadyAudioSource(store: store).readyAudio(for: $0)?.fileURL },
            present: retainedArtifactPresenter
        )
        return Task { @MainActor in
            if !(await reveal.reveal(entryID)) { NSSound.beep() }
        }
    }
}
