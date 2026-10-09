import Darwin
import Foundation
import WiltedDomain
import WiltedLibrary

/// Durable provenance for one exact canonical audio identity.
struct MediaCachePreparationProof: Codable, Equatable, Sendable {
    let offer: LibraryMediaOffer
    let ownerToken: String
    let libraryScope: String
    let ownerEpoch: UUID
    let entryRevocationEpoch: UInt64
}

struct PreparationLedger: Codable {
    var version = 1
    var ownerToken: String?
    var libraryScope: String
    var held: Bool
    var ownerEpoch: UUID
    var revocations: [String: UInt64]
}

extension FileMediaCache {
    private var ledgerURL: URL { root.appendingPathComponent(".preparation-ledger.json") }
    func markerURL(_ audio: URL) -> URL {
        audio.deletingLastPathComponent().appendingPathComponent(".\(audio.lastPathComponent).preparation.json")
    }

    private func loadLedger() {
        guard !ledgerLoaded else { return }
        ledgerLoaded = true
        guard safeDirectory(root), regularFile(ledgerURL),
              let data = try? Data(contentsOf: ledgerURL),
              let ledger = try? JSONDecoder().decode(PreparationLedger.self, from: data), ledger.version == 1 else { return }
        preparationLedger = ledger
        ledgerDurable = true
    }

    private func persist(_ ledger: PreparationLedger) throws {
        do {
            try prepareRoot()
            if fileManager.fileExists(atPath: ledgerURL.path), !regularFile(ledgerURL) {
                throw CocoaError(.fileWriteInvalidFileName)
            }
            try JSONEncoder().encode(ledger).write(to: ledgerURL, options: [.atomic, LibraryFileProtection.writingOption])
            preparationLedger = ledger
            ledgerDurable = true
        } catch {
            // A failed journal operation invalidates all live admissions in this process.
            ledgerDurable = false
            cacheGeneration = UUID()
            throw error
        }
    }

    func bindOwner(ownerToken: String?, libraryScope: String, held: Bool) async throws {
        loadLedger()
        let owner = ownerToken.flatMap { $0.isEmpty ? nil : $0 }
        guard !libraryScope.isEmpty else { ledgerDurable = false; throw CocoaError(.fileWriteInvalidFileName) }
        if let ledger = preparationLedger, ledgerDurable, ledger.ownerToken == owner,
           ledger.libraryScope == libraryScope, ledger.held == held { bindingConfirmed = true; return }
        // Fresh durable nonce prevents old markers surviving a missing/corrupt ledger or reset.
        cacheGeneration = UUID()
        let replacement = PreparationLedger(ownerToken: owner, libraryScope: libraryScope, held: held,
                                             ownerEpoch: UUID(), revocations: [:])
        try persist(replacement)
        bindingConfirmed = true
    }

    func currentBinding() -> PreparationLedger? {
        loadLedger()
        guard bindingConfirmed, ledgerDurable, let ledger = preparationLedger, !ledger.held,
              let owner = ledger.ownerToken, !owner.isEmpty, !ledger.libraryScope.isEmpty else { return nil }
        return ledger
    }

    func admission(entryID: ItemID, ownerToken: String, libraryScope: String,
                   transportGeneration: UInt64) async -> MediaCacheAdmission? {
        guard let ledger = currentBinding(), ledger.ownerToken == ownerToken,
              ledger.libraryScope == libraryScope else { return nil }
        return MediaCacheAdmission(entryID: entryID, ownerToken: ownerToken, libraryScope: libraryScope,
            ownerEpoch: ledger.ownerEpoch, entryRevocationEpoch: ledger.revocations[entryID.rawValue] ?? 0,
            cacheGeneration: cacheGeneration, transportGeneration: transportGeneration)
    }

    func current(_ admission: MediaCacheAdmission) -> Bool {
        guard let ledger = currentBinding() else { return false }
        return ledger.ownerToken == admission.ownerToken && ledger.libraryScope == admission.libraryScope
            && ledger.ownerEpoch == admission.ownerEpoch && cacheGeneration == admission.cacheGeneration
            && (ledger.revocations[admission.entryID.rawValue] ?? 0) == admission.entryRevocationEpoch
    }

    func permits(_ admission: MediaCacheAdmission, for offer: LibraryMediaOffer) async -> Bool {
        offer.isPrepared && offer.state == .ready && offer.entryID == admission.entryID && current(admission)
    }

    /// Explicit deletion needs no grant when no valid journal has ever been loaded.
    /// A retained ledger with a failed write must still withdraw durably before deletion.
    func withdrawPreparationForRemoval(entryID: ItemID) async throws {
        loadLedger()
        guard preparationLedger != nil else {
            cacheGeneration = UUID()
            return
        }
        try await revokePreparation(entryID: entryID)
    }

    func revokePreparation(entryID: ItemID) async throws {
        loadLedger()
        guard var ledger = preparationLedger, ledgerDurable else {
            cacheGeneration = UUID(); throw CocoaError(.fileWriteUnknown)
        }
        let old = ledger.revocations[entryID.rawValue] ?? 0
        if old == UInt64.max { ledger.ownerEpoch = UUID(); ledger.revocations = [:] }
        else { ledger.revocations[entryID.rawValue] = old + 1 }
        try persist(ledger)
    }

    private func regularFile(_ url: URL) -> Bool {
        guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]) else { return false }
        return values.isRegularFile == true && values.isSymbolicLink != true
    }

    func validPreparation(at audio: URL, entryID: ItemID) -> MediaCachePreparationProof? {
        guard structurallyAdmitted(audio), let ledger = currentBinding(), regularFile(markerURL(audio)),
              let data = try? Data(contentsOf: markerURL(audio)),
              let proof = try? JSONDecoder().decode(MediaCachePreparationProof.self, from: data),
              proof.offer.isPrepared, proof.offer.state == .ready, proof.offer.entryID == entryID,
              proof.ownerToken == ledger.ownerToken, proof.libraryScope == ledger.libraryScope,
              proof.ownerEpoch == ledger.ownerEpoch,
              proof.entryRevocationEpoch == (ledger.revocations[entryID.rawValue] ?? 0),
              location(for: proof.offer)?.standardizedFileURL == audio.standardizedFileURL,
              let size = (try? fileManager.attributesOfItem(atPath: audio.path)[.size]) as? NSNumber,
              size.int64Value == proof.offer.byteCount else { return nil }
        return proof
    }

    func verifies(_ cached: CachedMedia) async -> Bool {
        guard let proof = cached.preparation,
              validPreparation(at: cached.url, entryID: proof.offer.entryID) == proof,
              cached.revisionID == proof.offer.revisionID, cached.byteCount == proof.offer.byteCount,
              let identity = cached.fileIdentity() else { return false }
        let valid = await byteVerifier(cached.url, cached.byteCount, proof.offer.contentHash)
        return valid && cached.fileIdentity() == identity
            && validPreparation(at: cached.url, entryID: proof.offer.entryID) == proof
    }

    func cachedFile(for offer: LibraryMediaOffer, admission: MediaCacheAdmission) async -> URL? {
        guard await permits(admission, for: offer), let url = location(for: offer),
              let proof = validPreparation(at: url, entryID: admission.entryID), proof.offer == offer,
              let revision = offer.revisionID else { return nil }
        let cached = CachedMedia(revisionID: revision, url: url, byteCount: offer.byteCount, preparation: proof)
        guard await verifies(cached), current(admission),
              validPreparation(at: url, entryID: admission.entryID) == proof else { return nil }
        return url
    }

    func adopt(verifiedFile: URL, for offer: LibraryMediaOffer, admission: MediaCacheAdmission) async throws -> URL {
        guard await permits(admission, for: offer), let destination = location(for: offer) else {
            throw CocoaError(.fileWriteInvalidFileName)
        }
        if let existing = await cachedFile(for: offer, admission: admission) {
            guard current(admission) else { throw CocoaError(.fileWriteUnknown) }
            if verifiedFile.standardizedFileURL != existing.standardizedFileURL { try? fileManager.removeItem(at: verifiedFile) }
            return existing
        }
        guard current(admission), let identity = sourceIdentity(verifiedFile) else { throw CocoaError(.fileReadCorruptFile) }
        let verified = await byteVerifier(verifiedFile, offer.byteCount, offer.contentHash)
        guard verified, current(admission), sourceIdentity(verifiedFile) == identity else { throw CocoaError(.fileReadCorruptFile) }
        try prepareRoot()
        let directory = destination.deletingLastPathComponent()
        for path in [directory.deletingLastPathComponent(), directory] {
            if fileManager.fileExists(atPath: path.path) {
                guard safeDirectory(path) else { throw CocoaError(.fileWriteInvalidFileName) }
            } else {
                try fileManager.createDirectory(at: path, withIntermediateDirectories: false)
            }
        }
        let proof = MediaCachePreparationProof(offer: offer, ownerToken: admission.ownerToken,
            libraryScope: admission.libraryScope, ownerEpoch: admission.ownerEpoch,
            entryRevocationEpoch: admission.entryRevocationEpoch)
        let encoded = try JSONEncoder().encode(proof)
        let marker = markerURL(destination)
        // No await after this local fence: marker removal, audio rename and atomic proof publication
        // are one actor turn. A crash/write failure leaves bytes without an admitted marker.
        guard current(admission), safeDirectory(root), safeDirectory(directory),
              safeDirectory(directory.deletingLastPathComponent()) else { throw CocoaError(.fileWriteUnknown) }
        if fileManager.fileExists(atPath: marker.path) {
            guard regularFile(marker) else { throw CocoaError(.fileWriteInvalidFileName) }
            try fileManager.removeItem(at: marker)
        }
        guard Darwin.rename(verifiedFile.path, destination.path) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        LibraryFileProtection.apply(to: destination)
        try preparationWriter(encoded, marker)
        guard validPreparation(at: destination, entryID: admission.entryID) == proof else { throw CocoaError(.fileWriteUnknown) }
        return destination
    }

    private func sourceIdentity(_ url: URL) -> CachedMedia.FileIdentity? {
        guard regularFile(url), let values = try? fileManager.attributesOfItem(atPath: url.path),
              let inode = values[.systemFileNumber] as? NSNumber,
              let size = values[.size] as? NSNumber, let modified = values[.modificationDate] as? Date else { return nil }
        return CachedMedia.FileIdentity(inode: inode.uint64Value, size: size.int64Value, modified: modified)
    }
}
