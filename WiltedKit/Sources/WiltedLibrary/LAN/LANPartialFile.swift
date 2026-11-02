import Foundation
import WiltedDomain

/// Why a partial file could not be opened or finished.
public enum LANPartialFileError: Error, Equatable, Sendable {
    /// The offer is not one the direct path may fetch: not prepared, no certified hash, or over the size cap.
    case invalidOffer
    /// Another fetch in this process already owns the partial file for this revision.
    case inUse
    /// More bytes than the offer's `byteCount` were appended.
    case overrun
    /// The finished file's size or SHA-256 is not the offer's. The file has been deleted.
    case mismatch
    /// A file operation failed.
    case storage(String)
}

/// The phone's resumable copy of one prepared revision, `Partial/<entry>-<revision>-<hash prefix>.part`.
///
/// The name carries the revision and the first 16 hex digits of the content hash, so a newer revision
/// never resumes an older file. Revisions are immutable (W-INV-003), so the bytes already on disk are the
/// first bytes of the file still to come, which is what makes resuming from `size` safe.
///
/// `LANPartialFile` owns the path, the size and the one writing handle. `verifiedURL()` is the only way
/// out: it returns the URL after a byte count and SHA-256 match against the offer (W-INV-007), and a
/// mismatch deletes the file. One fetch at a time may hold a given file (`inUse`).
public final class LANPartialFile: @unchecked Sendable {
    public static let directoryName = "Partial"
    public static let fileExtension = "part"

    /// The file's location inside `directory` for `offer`, or nil when the offer cannot be fetched directly.
    public static func url(in directory: URL, for offer: LibraryMediaOffer) -> URL? {
        guard isFetchable(offer), let revision = offer.revisionID else { return nil }
        // Identifiers are `[A-Za-z0-9._:-]`, so a name built from them cannot leave the directory.
        let prefix = offer.contentHash.dropFirst(MediaHash.prefix.count).prefix(16)
        return directory.appendingPathComponent(
            "\(offer.entryID.rawValue)-\(revision.rawValue)-\(prefix).\(fileExtension)", isDirectory: false)
    }

    /// True when the direct path may fetch `offer`: prepared, a certified hash, a size inside the LAN cap.
    /// A legacy `available` offer with an empty hash is never fetched, because nothing could verify it.
    public static func isFetchable(_ offer: LibraryMediaOffer) -> Bool {
        offer.isPrepared && offer.revisionID != nil && offer.byteCount <= LANFrameCodec.maximumByteCount
    }

    /// The bytes already on disk for `offer`, or 0. Does not claim the file.
    public static func resumeOffset(in directory: URL, for offer: LibraryMediaOffer) -> Int64 {
        guard let url = url(in: directory, for: offer),
              let size = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber,
              size.int64Value <= offer.byteCount else { return 0 }
        return size.int64Value
    }

    public let url: URL
    public let byteCount: Int64
    public let contentHash: String
    /// Bytes on disk now.
    public private(set) var size: Int64

    private let lock = NSLock()
    private var handle: FileHandle?
    private var released = false
    private static let claims = ClaimSet()

    private init(url: URL, offer: LibraryMediaOffer, size: Int64, handle: FileHandle) {
        self.url = url
        byteCount = offer.byteCount
        contentHash = offer.contentHash
        self.size = size
        self.handle = handle
    }

    /// Opens (creating if needed) the partial file for `offer` in `directory` and claims it. A file larger
    /// than the offer can never be a prefix of it, so it is replaced by an empty one.
    public static func open(in directory: URL, for offer: LibraryMediaOffer) throws -> LANPartialFile {
        guard let url = url(in: directory, for: offer) else { throw LANPartialFileError.invalidOffer }
        guard claims.insert(url.path) else { throw LANPartialFileError.inUse }
        do {
            try prepare(directory)
            let manager = FileManager.default
            var size = ((try? manager.attributesOfItem(atPath: url.path))?[.size] as? NSNumber)?.int64Value ?? 0
            if size > offer.byteCount {
                try? manager.removeItem(at: url)
                size = 0
            }
            if !manager.fileExists(atPath: url.path) {
                guard manager.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
                    throw LANPartialFileError.storage("could not create the partial file")
                }
            }
            var excluded = URLResourceValues()
            excluded.isExcludedFromBackup = true
            var mutable = url
            try? mutable.setResourceValues(excluded)
            let handle = try FileHandle(forUpdating: url)
            try handle.seekToEnd()
            return LANPartialFile(url: url, offer: offer, size: size, handle: handle)
        } catch {
            claims.remove(url.path)
            if let error = error as? LANPartialFileError { throw error }
            throw LANPartialFileError.storage(error.localizedDescription)
        }
    }

    private static func prepare(_ directory: URL) throws {
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        var excluded = URLResourceValues()
        excluded.isExcludedFromBackup = true
        var mutable = directory
        try? mutable.setResourceValues(excluded)
    }

    /// Cuts the file back to `length` bytes (never longer than it is) and positions the writer there.
    public func truncate(to length: Int64) throws {
        try lock.withLock {
            guard let handle else { throw LANPartialFileError.storage("the partial file is closed") }
            guard length >= 0, length < size else { return }
            do {
                try handle.truncate(atOffset: UInt64(length))
                try handle.seek(toOffset: UInt64(length))
            } catch { throw LANPartialFileError.storage(error.localizedDescription) }
            size = length
        }
    }

    /// Appends received bytes. Never writes past the offer's `byteCount`.
    public func append(_ data: Data) throws {
        try lock.withLock {
            guard let handle else { throw LANPartialFileError.storage("the partial file is closed") }
            guard size + Int64(data.count) <= byteCount else { throw LANPartialFileError.overrun }
            do { try handle.write(contentsOf: data) } catch { throw LANPartialFileError.storage(error.localizedDescription) }
            size += Int64(data.count)
        }
    }

    /// Deletes the file. Used for a mismatch and when the partial can no longer be trusted.
    public func discard() {
        lock.withLock {
            try? handle?.close()
            handle = nil
            try? FileManager.default.removeItem(at: url)
            size = 0
        }
    }

    /// Checks the finished file against the offer: exact size, then streamed SHA-256. Returns the URL only
    /// when both match; otherwise deletes the file and throws `mismatch`. Hashing runs off the caller's
    /// executor, so a 250 MB file does not stall it.
    public func verifiedURL() async throws -> URL {
        let (complete, url, expected) = lock.withLock { (size == byteCount, self.url, contentHash) }
        guard complete else {
            discard()
            throw LANPartialFileError.mismatch
        }
        lock.withLock {
            try? handle?.synchronize()
            try? handle?.close()
            handle = nil
        }
        let hash = try await Task.detached(priority: .utility) { try MediaHash.sha256(fileAt: url) }.value
        guard hash == expected else {
            discard()
            throw LANPartialFileError.mismatch
        }
        return url
    }

    /// Releases the claim and the handle. Keeps the file, so a later fetch resumes it.
    public func close() {
        let firstClose = lock.withLock {
            try? handle?.close()
            handle = nil
            defer { released = true }
            return !released
        }
        // Only the first close gives the claim back, so a late `deinit` cannot release a newer owner's claim.
        if firstClose { Self.claims.remove(url.path) }
    }

    deinit { close() }
}

private final class ClaimSet: @unchecked Sendable {
    private let lock = NSLock()
    private var paths: Set<String> = []

    func insert(_ path: String) -> Bool { lock.withLock { paths.insert(path).inserted } }
    func remove(_ path: String) { lock.withLock { _ = paths.remove(path) } }
}
