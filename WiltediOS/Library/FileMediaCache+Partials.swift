import Foundation
import WiltedDomain
import WiltedLibrary

extension LibraryMediaCache {
    /// Caches with no room for unfinished direct transfers offer none, so the direct path stays off.
    func partialDirectory(for entryID: ItemID) -> URL? { nil }
    func discardPartials(entryID: ItemID, keeping offer: LibraryMediaOffer?) async {}
    func discardAllPartials() async {}
    func purgePartials(olderThan cutoff: Date) async {}
}

/// Unfinished direct (LAN) transfers.
///
/// They live in `<root>/.partial/<entryID>/`, hidden so every cache walk, which lists only visible
/// folders, skips them: a partial is neither playable nor an entry. The client names a file
/// `<entry>-<revision>-<hash prefix>.part`, one folder per entry keeps "this entry's partials" exact
/// even though identifiers contain dashes, and the folder shares the cache's volume. Partial bytes are
/// counted in `storedAudioByteCounts`, so the Storage total and "Remove all downloads" cover them.
///
/// They are removed with the entry, when its preparation is revoked or its identity changes, when a
/// download of the same entry completes any other way (DS-5), when the owner changes, and after
/// `partialLifetime`.
extension FileMediaCache {
    nonisolated static let partialFolderName = ".partial"
    nonisolated static let partialFileExtension = LANPartialFile.fileExtension
    /// How long an unfinished transfer is kept before it is deleted.
    nonisolated static let partialLifetime: TimeInterval = 7 * 24 * 60 * 60

    nonisolated var partialRoot: URL { root.appendingPathComponent(Self.partialFolderName, isDirectory: true) }

    nonisolated func partialDirectory(for entryID: ItemID) -> URL? {
        partialRoot.appendingPathComponent(entryID.rawValue, isDirectory: true)
    }

    /// Deletes `entryID`'s partial files, except the one `offer` would resume.
    func discardPartials(entryID: ItemID, keeping offer: LibraryMediaOffer?) async {
        guard let directory = partialDirectory(for: entryID), fileManager.fileExists(atPath: directory.path) else { return }
        let kept = offer.flatMap { LANPartialFile.url(in: directory, for: $0) }?.standardizedFileURL
        for file in partialFiles(in: directory) where file.standardizedFileURL != kept {
            try? fileManager.removeItem(at: file)
        }
        removeIfEmpty(directory)
    }

    func discardAllPartials() async {
        try? fileManager.removeItem(at: partialRoot)
    }

    /// Deletes every partial not written to since `cutoff`.
    func purgePartials(olderThan cutoff: Date) async {
        for directory in partialDirectories() {
            for file in partialFiles(in: directory) {
                let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
                if let modified, modified < cutoff { try? fileManager.removeItem(at: file) }
            }
            removeIfEmpty(directory)
        }
    }

    /// Bytes on disk in each entry's partial files.
    func partialByteCounts() -> [ItemID: Int64] {
        var counts: [ItemID: Int64] = [:]
        for directory in partialDirectories() {
            guard let entryID = try? ItemID(rawValue: directory.lastPathComponent) else { continue }
            for file in partialFiles(in: directory) {
                guard let size = try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize, size > 0 else { continue }
                counts[entryID, default: 0] += Int64(size)
            }
        }
        return counts
    }

    private func partialDirectories() -> [URL] {
        let children = (try? fileManager.contentsOfDirectory(
            at: partialRoot, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
        return children.filter { safeDirectory($0) }
    }

    private func partialFiles(in directory: URL) -> [URL] {
        let children = (try? fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return children.filter { $0.pathExtension == Self.partialFileExtension }
    }

    private func removeIfEmpty(_ directory: URL) {
        if (try? fileManager.contentsOfDirectory(atPath: directory.path))?.isEmpty == true {
            try? fileManager.removeItem(at: directory)
        }
    }
}
