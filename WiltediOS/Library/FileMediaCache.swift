import Foundation
import WiltedDomain
import WiltedLibrary

/// One verified file the phone holds for an entry.
struct CachedMedia: Equatable, Sendable {
    let revisionID: RevisionID
    let url: URL
    let byteCount: Int64
}

/// A `MediaCacheStore` that can also say what it holds, so the Larder can show "On phone"
/// after the Mac has withdrawn its offer and without asking the network.
protocol LibraryMediaCache: MediaCacheStore {
    /// The newest cached revision for every entry that has one.
    func cachedEntries() async -> [ItemID: CachedMedia]
}

/// Directory-backed cache for verified episode audio.
///
/// Layout: `<root>/<entryID>/<revisionID>/<sha256 hex>.<ext>`. The hash is in the file
/// name, so `cachedFile(for:)` finds exactly the bytes an offer describes. `adopt` moves the
/// file to a hidden name inside the root first and renames it into place, so a partial file
/// is never visible under a cached name, and a failed adopt leaves nothing behind.
///
/// This is not `ListenerAudioCache`: that cache stores by the legacy `WiltedAsset`
/// contract and reads whole files into memory to hash them, which the streaming media
/// path exists to avoid.
actor FileMediaCache: LibraryMediaCache {
    private let root: URL
    private let fileManager = FileManager.default

    init(rootURL: URL) { root = rootURL.standardizedFileURL }

    /// `Application Support/Wilted/Media`.
    nonisolated static func defaultRoot() -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Wilted", isDirectory: true)
            .appendingPathComponent("Media", isDirectory: true)
    }

    func cachedFile(for offer: LibraryMediaOffer) async -> URL? {
        guard let url = location(for: offer), fileManager.fileExists(atPath: url.path) else { return nil }
        return url
    }

    func adopt(verifiedFile: URL, for offer: LibraryMediaOffer) async throws -> URL {
        guard let destination = location(for: offer) else {
            throw CocoaError(.fileWriteInvalidFileName)
        }
        if fileManager.fileExists(atPath: destination.path) {
            if verifiedFile.standardizedFileURL != destination { try? fileManager.removeItem(at: verifiedFile) }
            return destination
        }
        try prepareRoot()
        let staging = root.appendingPathComponent(".incoming-\(UUID().uuidString)")
        do {
            try fileManager.moveItem(at: verifiedFile, to: staging)
            try fileManager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fileManager.moveItem(at: staging, to: destination)
        } catch {
            try? fileManager.removeItem(at: staging)
            throw error
        }
        return destination
    }

    func remove(entryID: ItemID) async throws {
        let directory = root.appendingPathComponent(entryID.rawValue, isDirectory: true)
        guard fileManager.fileExists(atPath: directory.path) else { return }
        try fileManager.removeItem(at: directory)
    }

    func cachedEntries() async -> [ItemID: CachedMedia] {
        var found: [ItemID: (media: CachedMedia, modified: Date)] = [:]
        for entryDirectory in subdirectories(of: root) {
            guard let entryID = try? ItemID(rawValue: entryDirectory.lastPathComponent) else { continue }
            for revisionDirectory in subdirectories(of: entryDirectory) {
                guard let revisionID = try? RevisionID(rawValue: revisionDirectory.lastPathComponent) else { continue }
                let files = (try? fileManager.contentsOfDirectory(
                    at: revisionDirectory, includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey],
                    options: [.skipsHiddenFiles])) ?? []
                for file in files {
                    let values = try? file.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
                    let modified = values?.contentModificationDate ?? .distantPast
                    let media = CachedMedia(revisionID: revisionID, url: file, byteCount: Int64(values?.fileSize ?? 0))
                    if let existing = found[entryID], existing.modified >= modified { continue }
                    found[entryID] = (media, modified)
                }
            }
        }
        return found.mapValues(\.media)
    }

    private func location(for offer: LibraryMediaOffer) -> URL? {
        guard offer.state == .ready, let revisionID = offer.revisionID, MediaHash.isWellFormed(offer.contentHash) else { return nil }
        let name = offer.contentHash.dropFirst(MediaHash.prefix.count) + "." + Self.fileExtension(for: offer.mediaType)
        return root
            .appendingPathComponent(offer.entryID.rawValue, isDirectory: true)
            .appendingPathComponent(revisionID.rawValue, isDirectory: true)
            .appendingPathComponent(String(name), isDirectory: false)
    }

    private func subdirectories(of url: URL) -> [URL] {
        let children = (try? fileManager.contentsOfDirectory(
            at: url, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])) ?? []
        return children.filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true }
    }

    /// Creates the root and keeps re-downloadable audio out of device backups.
    private func prepareRoot() throws {
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var mutableRoot = root
        try? mutableRoot.setResourceValues(values)
    }

    /// A recognizable extension so a player can identify the container.
    static func fileExtension(for mediaType: String) -> String {
        switch mediaType.lowercased() {
        case "audio/mpeg", "audio/mp3": "mp3"
        case "audio/mp4", "audio/x-m4a", "audio/m4a": "m4a"
        case "audio/aac": "aac"
        case "audio/wav", "audio/x-wav": "wav"
        default: "audio"
        }
    }
}
