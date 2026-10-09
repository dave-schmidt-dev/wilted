import Darwin
import Foundation
import WiltedDomain
import WiltedLibrary

/// One verified file the phone holds for an entry.
struct CachedMedia: Equatable, Sendable {
    let revisionID: RevisionID
    let url: URL
    let byteCount: Int64
    var preparation: MediaCachePreparationProof? = nil

    /// Identity retained in the canonical cache name, independent of a current Mac offer.
    var contentHash: String? {
        Self.canonicalHash(url)
    }

    static func canonicalHash(_ url: URL) -> String? {
        guard ["mp3", "m4a", "aac", "wav", "audio"].contains(url.pathExtension) else { return nil }
        let hash = MediaHash.prefix + url.deletingPathExtension().lastPathComponent
        return MediaHash.isWellFormed(hash) ? hash : nil
    }

    struct FileIdentity: Equatable {
        let inode: UInt64
        let size: Int64
        let modified: Date
    }

    func fileIdentity() -> FileIdentity? {
        var directory = url.deletingLastPathComponent()
        for _ in 0..<3 {
            guard let values = try? directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
                  values.isDirectory == true, values.isSymbolicLink != true else { return nil }
            directory.deleteLastPathComponent()
        }
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              attributes[.type] as? FileAttributeType == .typeRegular,
              let inode = attributes[.systemFileNumber] as? NSNumber,
              let size = attributes[.size] as? NSNumber,
              let modified = attributes[.modificationDate] as? Date else { return nil }
        return FileIdentity(inode: inode.uint64Value, size: size.int64Value, modified: modified)
    }

    func verifies() async -> Bool {
        guard let contentHash else { return false }
        return await MediaFetcher.verifies(url, byteCount: byteCount, contentHash: contentHash)
    }
}

/// A `MediaCacheStore` that can also say what it holds, so the Larder can show "On phone"
/// after the Mac has withdrawn its offer and without asking the network.
protocol LibraryMediaCache: MediaCacheStore {
    func bindOwner(ownerToken: String?, libraryScope: String, held: Bool) async throws
    func admission(entryID: ItemID, ownerToken: String, libraryScope: String, transportGeneration: UInt64) async -> MediaCacheAdmission?
    func revokePreparation(entryID: ItemID) async throws
    /// The newest cached revision for every entry that has one.
    func cachedEntries() async -> [ItemID: CachedMedia]
    /// Physical canonical audio size by entry; conveys no playback permission.
    func storedAudioByteCounts() async -> [ItemID: Int64]
    func verifies(_ cached: CachedMedia) async -> Bool

    /// The transcript stored beside the audio for exactly this revision, or nil.
    func cachedTranscript(entryID: ItemID, revisionID: RevisionID) async -> LibraryTranscript?
    /// Stores `transcript` beside its audio. Does nothing when that revision's audio is not
    /// cached, so a transcript can never outlive or precede the audio it belongs to.
    func storeTranscript(_ transcript: LibraryTranscript) async
}

/// Directory-backed cache for verified episode audio.
///
/// Layout: `<root>/<entryID>/<revisionID>/<sha256 hex>.<ext>` plus a hidden preparation
/// proof for each exact file and a root owner/revocation journal. Legacy bytes remain on
/// disk but are inventory-inert until a certified delivery commits a current proof.
/// `.transcript.json` stays beside its revision's audio and is removed with the entry.
/// Audio rename and atomic proof publication run under one final synchronous actor fence;
/// failed proof publication never reports a cached result.
///
/// This is not `ListenerAudioCache`: that cache stores by the legacy `WiltedAsset`
/// contract and reads whole files into memory to hash them, which the streaming media
/// path exists to avoid.
actor FileMediaCache: LibraryMediaCache {
    let root: URL
    let fileManager = FileManager.default
    private var protectionRepaired = false
    var preparationLedger: PreparationLedger?
    var ledgerLoaded = false
    var ledgerDurable = false
    var bindingConfirmed = false
    var cacheGeneration = UUID()
    let byteVerifier: @Sendable (URL, Int64, String) async -> Bool
    let preparationWriter: @Sendable (Data, URL) throws -> Void

    init(rootURL: URL, byteVerifier: @escaping @Sendable (URL, Int64, String) async -> Bool = {
        await MediaFetcher.verifies($0, byteCount: $1, contentHash: $2)
    }, preparationWriter: @escaping @Sendable (Data, URL) throws -> Void = {
        try $0.write(to: $1, options: [.atomic, LibraryFileProtection.writingOption])
    }) {
        root = rootURL.standardizedFileURL
        self.byteVerifier = byteVerifier
        self.preparationWriter = preparationWriter
    }

    /// `Application Support/Wilted/Media`.
    nonisolated static func defaultRoot() -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Wilted", isDirectory: true)
            .appendingPathComponent("Media", isDirectory: true)
    }

    func remove(entryID: ItemID) async throws {
        try await withdrawPreparationForRemoval(entryID: entryID)
        let directory = root.appendingPathComponent(entryID.rawValue, isDirectory: true)
        guard fileManager.fileExists(atPath: directory.path) else { return }
        try fileManager.removeItem(at: directory)
    }

    /// Counts retained regular canonical audio across every revision, regardless of proof.
    /// Storage maintenance must not bind an owner or expose a playable file or URL.
    func storedAudioByteCounts() async -> [ItemID: Int64] {
        guard safeDirectory(root) else { return [:] }
        var counts: [ItemID: Int64] = [:]
        for entryDirectory in subdirectories(of: root) {
            guard let entryID = try? ItemID(rawValue: entryDirectory.lastPathComponent) else { continue }
            for revisionDirectory in subdirectories(of: entryDirectory) {
                guard (try? RevisionID(rawValue: revisionDirectory.lastPathComponent)) != nil else { continue }
                let files = (try? fileManager.contentsOfDirectory(at: revisionDirectory,
                    includingPropertiesForKeys: [.fileSizeKey], options: [.skipsHiddenFiles])) ?? []
                for file in files where structurallyAdmitted(file) {
                    guard let size = try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize, size >= 0 else { continue }
                    let (total, overflow) = (counts[entryID] ?? 0).addingReportingOverflow(Int64(size))
                    counts[entryID] = overflow ? Int64.max : total
                }
            }
        }
        return counts
    }

    func cachedEntries() async -> [ItemID: CachedMedia] {
        guard safeDirectory(root), currentBinding() != nil else { return [:] }
        repairProtectionOnce()
        var found: [ItemID: (media: CachedMedia, modified: Date)] = [:]
        for entryDirectory in subdirectories(of: root) {
            guard let entryID = try? ItemID(rawValue: entryDirectory.lastPathComponent) else { continue }
            for revisionDirectory in subdirectories(of: entryDirectory) {
                guard let revisionID = try? RevisionID(rawValue: revisionDirectory.lastPathComponent) else { continue }
                let files = (try? fileManager.contentsOfDirectory(
                    at: revisionDirectory, includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey],
                    options: [.skipsHiddenFiles])) ?? []
                for file in files where structurallyAdmitted(file) {
                    guard let proof = validPreparation(at: file, entryID: entryID) else { continue }
                    let values = try? file.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
                    let modified = values?.contentModificationDate ?? .distantPast
                    let media = CachedMedia(revisionID: revisionID, url: file, byteCount: Int64(values?.fileSize ?? 0), preparation: proof)
                    if let existing = found[entryID], existing.modified >= modified { continue }
                    found[entryID] = (media, modified)
                }
            }
        }
        return found.mapValues(\.media)
    }

    /// File name of the transcript inside a revision directory.
    nonisolated static let transcriptFileName = ".transcript.json"

    func cachedTranscript(entryID: ItemID, revisionID: RevisionID) async -> LibraryTranscript? {
        guard let data = try? Data(contentsOf: transcriptURL(entryID, revisionID)),
              let transcript = try? JSONDecoder().decode(LibraryTranscript.self, from: data),
              transcript.entryID == entryID, transcript.revisionID == revisionID
        else { return nil }
        return transcript
    }

    func storeTranscript(_ transcript: LibraryTranscript) async {
        let url = transcriptURL(transcript.entryID, transcript.revisionID)
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: url.deletingLastPathComponent().path, isDirectory: &isDirectory), isDirectory.boolValue,
              let data = try? JSONEncoder().encode(transcript)
        else { return }
        try? data.write(to: url, options: [.atomic, LibraryFileProtection.writingOption])
    }

    private func transcriptURL(_ entryID: ItemID, _ revisionID: RevisionID) -> URL {
        root
            .appendingPathComponent(entryID.rawValue, isDirectory: true)
            .appendingPathComponent(revisionID.rawValue, isDirectory: true)
            .appendingPathComponent(Self.transcriptFileName, isDirectory: false)
    }

    func location(for offer: LibraryMediaOffer) -> URL? {
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
        return children.filter { safeDirectory($0) }
    }

    func safeDirectory(_ url: URL) -> Bool {
        guard let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]) else { return false }
        return values.isDirectory == true && values.isSymbolicLink != true
    }

    func structurallyAdmitted(_ url: URL) -> Bool {
        let revision = url.deletingLastPathComponent(), entry = revision.deletingLastPathComponent()
        guard entry.deletingLastPathComponent().standardizedFileURL.path == root.path,
              safeDirectory(root), safeDirectory(entry), safeDirectory(revision),
              let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]),
              values.isRegularFile == true, values.isSymbolicLink != true,
              FileManager.default.isReadableFile(atPath: url.path) else { return false }
        return CachedMedia.canonicalHash(url) != nil
    }

    /// Audio downloaded before the cache set its protection class explicitly may carry a stronger one
    /// from its CloudKit download, which would not open once the phone locks. Fixed once per launch,
    /// before the first listing exposes those files to the car.
    private func repairProtectionOnce() {
        guard !protectionRepaired else { return }
        protectionRepaired = true
        guard let walker = fileManager.enumerator(at: root, includingPropertiesForKeys: nil) else { return }
        LibraryFileProtection.apply(to: root)
        for case let url as URL in walker {
            if (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink == true {
                walker.skipDescendants()
            } else { LibraryFileProtection.apply(to: url) }
        }
    }

    /// Creates the root, keeps re-downloadable audio out of device backups, and keeps it
    /// readable while the phone is locked.
    func prepareRoot() throws {
        if fileManager.fileExists(atPath: root.path), !safeDirectory(root) { throw CocoaError(.fileWriteInvalidFileName) }
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        LibraryFileProtection.apply(to: root)
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
