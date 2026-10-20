import Foundation
import WiltedDomain
import WiltedLibrary

extension LibraryMediaCache {
    /// Caches that cannot judge their own proofs reclaim nothing.
    func reclaimUnplayableAudio(keeping kept: Set<ItemID>) async -> Set<ItemID> { [] }
}

extension FileMediaCache {
    /// Deletes audio that can never play again and returns the entries that lost a revision.
    ///
    /// A revision is reclaimed when every canonical audio file in it either has no preparation
    /// marker (downloaded before certification, or a proof write that failed) or carries a proof
    /// for the current owner and epoch whose entry has since been revoked (removed from the
    /// Larder, or replaced by a new preparation). The whole revision folder goes, transcript
    /// included; an entry folder left empty goes too. Nothing is judged without a confirmed,
    /// unheld binding, and a proof for another owner or epoch is left for the account-change path,
    /// so a held, unconfirmed or freshly reset ledger deletes nothing certified. `kept` entries
    /// (a running request, the loaded item, a revocation in progress) are skipped. One actor turn:
    /// no await between a file's check and its deletion.
    func reclaimUnplayableAudio(keeping kept: Set<ItemID>) async -> Set<ItemID> {
        guard let ledger = currentBinding(), safeDirectory(root) else { return [] }
        var reclaimed: Set<ItemID> = []
        for entryDirectory in subdirectories(of: root) {
            guard let entryID = try? ItemID(rawValue: entryDirectory.lastPathComponent), !kept.contains(entryID) else { continue }
            for revisionDirectory in subdirectories(of: entryDirectory) {
                guard (try? RevisionID(rawValue: revisionDirectory.lastPathComponent)) != nil else { continue }
                let files = (try? fileManager.contentsOfDirectory(
                    at: revisionDirectory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
                let audio = files.filter { structurallyAdmitted($0) }
                guard !audio.isEmpty, audio.allSatisfy({ neverPlays($0, entryID: entryID, ledger: ledger) }),
                      (try? fileManager.removeItem(at: revisionDirectory)) != nil else { continue }
                reclaimed.insert(entryID)
            }
            if reclaimed.contains(entryID), (try? fileManager.contentsOfDirectory(atPath: entryDirectory.path))?.isEmpty == true {
                try? fileManager.removeItem(at: entryDirectory)
            }
        }
        return reclaimed
    }

    private func neverPlays(_ audio: URL, entryID: ItemID, ledger: PreparationLedger) -> Bool {
        let marker = markerURL(audio)
        guard fileManager.fileExists(atPath: marker.path) else { return true }
        guard let data = try? Data(contentsOf: marker),
              let proof = try? JSONDecoder().decode(MediaCachePreparationProof.self, from: data),
              proof.ownerToken == ledger.ownerToken, proof.libraryScope == ledger.libraryScope,
              proof.ownerEpoch == ledger.ownerEpoch else { return false }
        return proof.entryRevocationEpoch < (ledger.revocations[entryID.rawValue] ?? 0)
    }
}
