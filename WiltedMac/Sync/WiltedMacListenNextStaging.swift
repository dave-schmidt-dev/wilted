import CryptoKit
import Darwin
import Foundation

/// Owns request-scoped narration staging and removes abandoned files after a restart.
struct WiltedMacListenNextStaging {
    struct LeaseMetadata: Codable, Equatable {
        let coordinatorDeviceID: String
        let ownerToken: String
        let operationGeneration: UInt64
        let requesterDeviceID: String
        let requestID: String
        let taskID: UUID
    }

    final class Lease {
        let stagingURL: URL
        let leaseURL: URL
        private let descriptor: Int32
        private var released = false

        fileprivate init(stagingURL: URL, leaseURL: URL, descriptor: Int32) {
            self.stagingURL = stagingURL
            self.leaseURL = leaseURL
            self.descriptor = descriptor
        }

        /// Removes only this task's temporary files before releasing its advisory lock.
        func finish() {
            guard !released else { return }
            released = true
            try? FileManager.default.removeItem(at: stagingURL)
            try? FileManager.default.removeItem(at: leaseURL)
            _ = Darwin.close(descriptor)
        }
    }

    private let directory: URL
    private let coordinatorDeviceID: String

    init(directory: URL, coordinatorDeviceID: String) {
        self.directory = directory
        self.coordinatorDeviceID = coordinatorDeviceID
    }

    func stagingURL(
        ownerToken: String,
        operationGeneration: UInt64,
        requesterDeviceID: String,
        requestID: String,
        taskID: UUID
    ) -> URL {
        let metadata = LeaseMetadata(
            coordinatorDeviceID: coordinatorDeviceID, ownerToken: ownerToken,
            operationGeneration: operationGeneration, requesterDeviceID: requesterDeviceID,
            requestID: requestID, taskID: taskID)
        return directory.appendingPathComponent(Self.stagingFilename(for: metadata), isDirectory: false)
    }

    /// Acquires a per-attempt lock while serialized against startup cleanup.
    func acquire(
        ownerToken: String,
        operationGeneration: UInt64,
        requesterDeviceID: String,
        requestID: String,
        taskID: UUID
    ) throws -> Lease {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let metadata = LeaseMetadata(
            coordinatorDeviceID: coordinatorDeviceID, ownerToken: ownerToken,
            operationGeneration: operationGeneration, requesterDeviceID: requesterDeviceID,
            requestID: requestID, taskID: taskID)
        let stagingURL = directory.appendingPathComponent(Self.stagingFilename(for: metadata), isDirectory: false)
        let leaseURL = Self.leaseURL(for: stagingURL)
        let sweepDescriptor = try Self.openLockFile(at: Self.sweepLockURL(in: directory), create: true)
        defer { _ = Darwin.close(sweepDescriptor) }

        let descriptor = Darwin.open(
            leaseURL.path,
            O_CREAT | O_EXCL | O_RDWR | O_CLOEXEC | O_NOFOLLOW | O_EXLOCK,
            mode_t(S_IRUSR | S_IWUSR))
        guard descriptor >= 0 else { throw Self.posixError() }
        do {
            try Self.write(metadata, to: descriptor)
            return Lease(stagingURL: stagingURL, leaseURL: leaseURL, descriptor: descriptor)
        } catch {
            try? FileManager.default.removeItem(at: leaseURL)
            _ = Darwin.close(descriptor)
            throw error
        }
    }

    /// Removes abandoned staging owned by this coordinator and verified account.
    /// Active tasks hold their lease lock; the sweep lock prevents a new task from
    /// creating a lease between enumeration and the per-file lock check.
    @discardableResult
    func sweepAbandoned(ownerToken: String) -> Bool {
        guard !ownerToken.isEmpty,
              (try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)) != nil,
              let sweepDescriptor = try? Self.openLockFile(at: Self.sweepLockURL(in: directory), create: true) else {
            return false
        }
        defer { _ = Darwin.close(sweepDescriptor) }
        guard let files = try? FileManager.default.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]) else {
            return false
        }

        for leaseURL in files where Self.isLeaseURL(leaseURL) {
            let descriptor = Darwin.open(
                leaseURL.path, O_RDWR | O_CLOEXEC | O_NOFOLLOW | O_EXLOCK | O_NONBLOCK)
            guard descriptor >= 0 else { continue }
            defer { _ = Darwin.close(descriptor) }

            guard let metadata = try? Self.readMetadata(from: descriptor),
                  metadata.coordinatorDeviceID == coordinatorDeviceID,
                  metadata.ownerToken == ownerToken,
                  Self.stagingFilename(for: metadata) + ".lease" == leaseURL.lastPathComponent else { continue }
            let stagingURL = directory.appendingPathComponent(Self.stagingFilename(for: metadata), isDirectory: false)
            if Self.isRegularFile(stagingURL) { try? FileManager.default.removeItem(at: stagingURL) }
            try? FileManager.default.removeItem(at: leaseURL)
        }
        return true
    }

    static func stagingFilename(for metadata: LeaseMetadata) -> String {
        let identity = [
            metadata.coordinatorDeviceID, metadata.ownerToken, String(metadata.operationGeneration),
            metadata.requesterDeviceID, metadata.requestID, metadata.taskID.uuidString
        ].joined(separator: "\0")
        let digest = SHA256.hash(data: Data(identity.utf8)).map { String(format: "%02x", $0) }.joined()
        return "listen-next-staging-\(digest).m4a"
    }

    private static func sweepLockURL(in directory: URL) -> URL {
        directory.appendingPathComponent(".listen-next-staging-sweep.lock", isDirectory: false)
    }

    private static func leaseURL(for stagingURL: URL) -> URL {
        URL(fileURLWithPath: stagingURL.path + ".lease", isDirectory: false)
    }

    private static func isLeaseURL(_ url: URL) -> Bool {
        url.lastPathComponent.hasPrefix("listen-next-staging-")
            && url.lastPathComponent.hasSuffix(".m4a.lease")
    }

    private static func isRegularFile(_ url: URL) -> Bool {
        guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey]) else { return false }
        return values.isRegularFile == true
    }

    private static func openLockFile(at url: URL, create: Bool) throws -> Int32 {
        let flags = O_RDWR | O_CLOEXEC | O_NOFOLLOW | O_EXLOCK | (create ? O_CREAT : 0)
        let descriptor = Darwin.open(url.path, flags, mode_t(S_IRUSR | S_IWUSR))
        guard descriptor >= 0 else { throw posixError() }
        return descriptor
    }

    private static func write(_ metadata: LeaseMetadata, to descriptor: Int32) throws {
        let data = try JSONEncoder().encode(metadata)
        guard Darwin.ftruncate(descriptor, 0) == 0 else { throw posixError() }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
        try handle.seek(toOffset: 0)
        try handle.write(contentsOf: data)
        try handle.synchronize()
    }

    private static func readMetadata(from descriptor: Int32) throws -> LeaseMetadata {
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
        try handle.seek(toOffset: 0)
        guard let data = try handle.readToEnd(), data.count <= 16_384 else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return try JSONDecoder().decode(LeaseMetadata.self, from: data)
    }

    private static func posixError() -> POSIXError {
        POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
}
