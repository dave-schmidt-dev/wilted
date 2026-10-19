import Darwin
import Foundation

/// Writes that must survive power loss, not only a crash.
///
/// On macOS `fsync` leaves data in the drive's write cache, so a power loss can
/// still lose it; `F_FULLFSYNC` flushes that cache. Renaming a file is atomic
/// with respect to readers but orders nothing about its bytes, so a durable
/// replacement also syncs the directory that holds the new name.
public enum DurableFile {
    /// What a durable write did, for tests that prove a call site goes through `DurableFile`.
    enum DurableFileEvent: Equatable, Sendable { case write(URL), fullSync(URL) }

    #if DEBUG
    @TaskLocal static var observer: (@Sendable (DurableFileEvent) -> Void)?
    #endif

    /// Replaces `url` with `data`: writes a temporary sibling, flushes it with
    /// F_FULLFSYNC, renames it over `url`, then syncs the directory so the
    /// rename itself is durable. The temporary file is removed on every failure
    /// path, and `url` is untouched unless the rename happened.
    public static func write(_ data: Data, to url: URL) throws {
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
            try syncDirectory(url.deletingLastPathComponent())
        } catch {
            try? manager.removeItem(at: temporaryURL)
            throw error
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

    /// Flushes a file descriptor to stable storage with F_FULLFSYNC, falling
    /// back to `fsync` on a volume that refuses it.
    private static func flush(_ fd: Int32) throws {
        if fcntl(fd, F_FULLFSYNC) == -1 {
            guard fsync(fd) == 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
        }
    }

    /// Flushes a directory entry so a rename inside it survives power loss.
    private static func syncDirectory(_ url: URL) throws {
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
}

/// Unqualified spelling for tests in the same module.
typealias DurableFileEvent = DurableFile.DurableFileEvent
