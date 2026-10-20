import Darwin
import Foundation

extension CachedMedia {
    /// What the file system says one regular file is: where it resolves, which file object on which
    /// volume it is, how big it is, and when its bytes and its attributes last changed, to the
    /// nanosecond. Read with `lstat`, so a symbolic link is never followed or admitted.
    struct FileIdentity: Equatable, Sendable {
        struct Stamp: Equatable, Sendable {
            let seconds: Int
            let nanoseconds: Int
            init(_ time: timespec) { seconds = time.tv_sec; nanoseconds = time.tv_nsec }
        }

        /// The fully resolved path (`realpath`), which keys the verification memo.
        let path: String
        let volume: UInt64
        let inode: UInt64
        let size: Int64
        let modified: Stamp
        /// `st_ctime`: moves on every write and attribute change and cannot be set back by a caller,
        /// so a rewrite that restores the size and the modification date still reads as a change.
        let statusChanged: Stamp

        init?(regularFileAt url: URL) {
            var status = stat()
            guard lstat(url.path, &status) == 0, status.st_mode & S_IFMT == S_IFREG,
                  let path = MediaVerificationMemo.resolvedPath(url) else { return nil }
            self.path = path
            volume = UInt64(UInt32(bitPattern: status.st_dev))
            inode = UInt64(status.st_ino)
            size = Int64(status.st_size)
            modified = Stamp(status.st_mtimespec)
            statusChanged = Stamp(status.st_ctimespec)
        }
    }
}

/// Byte verifications this process has already passed, so resuming, seeking or starting an
/// unchanged file again does not re-read and re-hash all of it in front of the listener (W-INV-040).
///
/// Contract (the hash exists so that only verified bytes ever play):
/// - An entry is recorded only after a full SHA-256 check of the file succeeded with the file's
///   identity unchanged across the hash, and only when no write, replace or removal through the
///   cache overlapped it. A failed check is never recorded and also drops the path's entry.
/// - A lookup admits a file only when everything matches the recorded check: resolved path,
///   volume, inode, size, modification and status-change times, expected hash and byte count, and
///   the cache generation. Any difference hashes the file again before it can play.
/// - Every write, replace or removal of audio through `FileMediaCache` forgets the affected paths.
/// - It lives in memory only, owned by the cache actor and never persisted, so a new process
///   verifies each file at least once before its first play. It stands in for the hash alone: the
///   preparation proof and the ledger are still checked on every call.
struct MediaVerificationMemo {
    struct Check: Equatable {
        let file: CachedMedia.FileIdentity
        let contentHash: String
        let byteCount: Int64
        let generation: UUID
    }

    private var checks: [String: Check] = [:]
    /// Advanced by every forget, so a hash that began before a write is never recorded after it.
    private(set) var changes: UInt64 = 0

    func admits(_ check: Check) -> Bool { checks[check.file.path] == check }

    /// Looks up a resolved path (`FileIdentity.path`) as recorded, so it still answers after removal.
    func remembers(path: String) -> Bool { checks[path] != nil }

    mutating func record(_ check: Check, ifUnchangedSince mark: UInt64) {
        guard changes == mark else { return }
        checks[check.file.path] = check
    }

    /// Forgets `url` itself and everything beneath it. Call it before the file system change, while
    /// the path still resolves; a path that no longer resolves has nothing left that can match.
    mutating func forget(_ url: URL) {
        changes &+= 1
        for path in Set([Self.resolvedPath(url), url.standardizedFileURL.path].compactMap { $0 }) {
            checks = checks.filter { $0.key != path && !$0.key.hasPrefix(path + "/") }
        }
    }

    static func resolvedPath(_ url: URL) -> String? {
        guard let resolved = realpath(url.path, nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }
}
