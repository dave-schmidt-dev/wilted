import Darwin
import Foundation

/// Writes that must survive power loss, not only a crash.
///
/// On macOS `fsync` leaves data in the drive's write cache, so a power loss can
/// still lose it; `F_FULLFSYNC` flushes that cache. Renaming a file is atomic
/// with respect to readers but orders nothing about its bytes, so a durable
/// replacement also syncs the directory that holds the new name.
///
/// `write` is the strict form for callers that must treat an unconfirmed directory entry as a
/// failure, including migration. `replace` is the form for writers that can adopt a replacement
/// that already landed: after the rename, an uncertain directory sync is a power-loss durability
/// risk, not a rejected write. Neither form promises exactly-once processing through power loss.
public enum DurableFile {
    /// What a durable write did, for tests that prove a call site goes through `DurableFile`.
    enum DurableFileEvent: Equatable, Sendable { case write(URL), rename(URL), fullSync(URL) }

    /// The result of `replace`.
    public enum ReplacementResult: Equatable, Sendable {
        /// The new bytes are in place and the directory entry that names them is durable.
        case durable
        /// The rename completed and the new bytes are in place, but both directory-sync attempts
        /// failed. A power loss before the directory entry reaches the drive may undo the
        /// replacement; this is not a rejected write.
        case replacedDirectorySyncUncertain(ReplacementFailure)
    }

    /// The cause of a completed replacement whose directory durability could not be confirmed.
    public struct ReplacementFailure: Error, Equatable, Sendable, CustomStringConvertible {
        /// The `errno` from the last failed directory-sync attempt.
        public let code: Int32

        public var description: String {
            "\(POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO))"
        }
    }

    #if DEBUG
    @TaskLocal static var observer: (@Sendable (DurableFileEvent) -> Void)?
    /// A narrow test seam for a real directory-sync failure. It runs before the real sync; an
    /// error fails that attempt.
    @TaskLocal static var directorySyncInterceptor: (@Sendable (URL) throws -> Void)?
    /// A narrow test seam for a real file-data flush failure. It runs before the real flush; an
    /// error fails the write before the rename.
    @TaskLocal static var fileFlushInterceptor: (@Sendable (Int32) throws -> Void)?
    #endif

    /// Replaces `url` with `data` and distinguishes a landed replacement whose directory sync
    /// could not be confirmed from a write that never reached the file.
    ///
    /// Writes a temporary sibling, flushes it with F_FULLFSYNC, renames it over `url`, then syncs
    /// the directory so the rename itself is durable. After the first directory-sync failure it
    /// retries the sync once without rewriting the file bytes: one rename, at most two
    /// directory-sync attempts. The temporary file is removed on every failure before the rename.
    ///
    /// `.replacedDirectorySyncUncertain` means readers in this process and after a clean restart
    /// see the new bytes, but a power loss before the directory entry reaches the drive may undo
    /// the replacement. Callers that can adopt their landed state should log the cause and
    /// continue. This API does not make a write exactly once through power loss.
    public static func replace(_ data: Data, to url: URL) throws -> ReplacementResult {
        let manager = FileManager.default
        let temporaryURL = url.deletingLastPathComponent()
            .appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).tmp")
        do {
            guard manager.createFile(atPath: temporaryURL.path, contents: nil) else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            let handle = try FileHandle(forWritingTo: temporaryURL)
            do {
                try handle.write(contentsOf: data)
                try flush(handle.fileDescriptor)
                try handle.close()
            } catch {
                try? handle.close()
                throw error
            }
            #if DEBUG
            Self.observer?(.write(url))
            #endif
            guard Darwin.rename(temporaryURL.path, url.path) == 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            #if DEBUG
            Self.observer?(.rename(url))
            #endif
        } catch {
            try? manager.removeItem(at: temporaryURL)
            throw error
        }
        let directory = url.deletingLastPathComponent()
        var lastCode: Int32 = EIO
        for attempt in 0..<2 {
            do {
                try syncDirectory(directory)
                return .durable
            } catch {
                lastCode = errorCode(error)
                if attempt == 0 { continue }
            }
        }
        return .replacedDirectorySyncUncertain(ReplacementFailure(code: lastCode))
    }

    /// Replaces `url` with `data` and returns only when the directory entry is confirmed durable.
    ///
    /// This strict form wraps `replace` and throws its final directory-sync uncertainty. When it
    /// throws that uncertainty the rename has already happened, so the caller must treat the
    /// write as uncertain rather than as proof that the old bytes remain. Failures before the
    /// rename still leave the original file untouched.
    public static func write(_ data: Data, to url: URL) throws {
        let result = try replace(data, to: url)
        if case let .replacedDirectorySyncUncertain(failure) = result {
            throw failure
        }
    }

    /// Flushes an open file to stable storage with F_FULLFSYNC, falling back
    /// to `fsync` on a volume that refuses it. Throws only when both fail.
    /// `url` names the file for errors and the test observer only.
    public static func fullSync(_ handle: FileHandle, at url: URL) throws {
        try flush(handle.fileDescriptor)
        #if DEBUG
        Self.observer?(.fullSync(url))
        #endif
    }

    /// Flushes a file another process wrote, and the directory entry that now
    /// names it, so a file moved into place survives power loss before any
    /// record points at it.
    public static func persist(_ url: URL) throws {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        try flush(handle.fileDescriptor)
        try syncDirectory(url.deletingLastPathComponent())
        #if DEBUG
        Self.observer?(.fullSync(url))
        #endif
    }

    /// Flushes a file descriptor to stable storage with F_FULLFSYNC, falling
    /// back to `fsync` on a volume that refuses it.
    private static func flush(_ fd: Int32) throws {
        #if DEBUG
        if let fileFlushInterceptor { try fileFlushInterceptor(fd) }
        #endif
        if fcntl(fd, F_FULLFSYNC) == -1 {
            guard fsync(fd) == 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
        }
    }

    /// Flushes a directory entry so a rename inside it survives power loss.
    private static func syncDirectory(_ url: URL) throws {
        #if DEBUG
        if let directorySyncInterceptor { try directorySyncInterceptor(url) }
        #endif
        let descriptor = open(url.path, O_RDONLY)
        guard descriptor >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        let fullSyncResult = fcntl(descriptor, F_FULLFSYNC)
        let fallbackResult = fullSyncResult == -1 ? fsync(descriptor) : 0
        let failure = fullSyncResult == -1 && fallbackResult == -1 ? errno : 0
        _ = close(descriptor)
        guard failure == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: failure) ?? .EIO)
        }
    }

    private static func errorCode(_ error: Error) -> Int32 {
        (error as? POSIXError)?.code.rawValue ?? EIO
    }
}

/// Unqualified spelling for tests in the same module.
typealias DurableFileEvent = DurableFile.DurableFileEvent
