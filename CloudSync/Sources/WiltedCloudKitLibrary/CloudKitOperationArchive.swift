import Foundation

/// Appends each CloudKit operation summary to a small file, so a device whose unified log keeps
/// only a few hours (the iPhone) still has a day's counts to read after a soak. Summary lines carry
/// no record names, tokens, device or account IDs. The file rotates to one `.1` backup at `maxBytes`.
public final class CloudKitOperationArchive: @unchecked Sendable {
    public let url: URL
    private let maxBytes: Int
    private let requirePrivateFile: Bool
    private let lock = NSLock()
    private let stamp = ISO8601DateFormatter()

    public init(url: URL, maxBytes: Int = 1_000_000, requirePrivateFile: Bool = false) {
        self.url = url
        self.maxBytes = maxBytes
        self.requirePrivateFile = requirePrivateFile
    }

    /// The phone's archive under the app's `Library/Logs`.
    public static func standard(fileManager: FileManager = .default) -> CloudKitOperationArchive? {
        guard let library = fileManager.urls(for: .libraryDirectory, in: .userDomainMask).first else { return nil }
        return CloudKitOperationArchive(url: library.appendingPathComponent("Logs/cloudkit-operations.log"))
    }

    /// Writes one timestamped line. A write failure is dropped: diagnostics never break sync.
    @discardableResult
    public func append(_ line: String, at date: Date) -> Bool {
        lock.withLock {
            guard maxBytes > 0 else { return false }
            let fileManager = FileManager.default
            do {
                try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            } catch {
                return false
            }
            if requirePrivateFile, !preparePrivateStorage(fileManager: fileManager) { return false }
            let size = (try? fileManager.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
            if size >= maxBytes, fileManager.fileExists(atPath: url.path) {
                let backup = url.appendingPathExtension("1")
                do {
                    if fileManager.fileExists(atPath: backup.path) { try fileManager.removeItem(at: backup) }
                    try fileManager.moveItem(at: url, to: backup)
                } catch {
                    return false
                }
            }
            if !fileManager.fileExists(atPath: url.path) {
                guard fileManager.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
                    return false
                }
            }
            if requirePrivateFile {
                do {
                    try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
                    let attributes = try fileManager.attributesOfItem(atPath: url.path)
                    guard (attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600 else { return false }
                } catch {
                    return false
                }
            }
            let data = Data("\(stamp.string(from: date)) \(line)\n".utf8)
            do {
                let handle = try FileHandle(forWritingTo: url)
                defer { try? handle.close() }
                _ = try handle.seekToEnd()
                try handle.write(contentsOf: data)
                return true
            } catch {
                return false
            }
        }
    }

    /// Restricts only this archive's dedicated directory and files before rotation or append.
    private func preparePrivateStorage(fileManager: FileManager) -> Bool {
        let directory = url.deletingLastPathComponent()
        do {
            try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
            let directoryAttributes = try fileManager.attributesOfItem(atPath: directory.path)
            guard (directoryAttributes[.posixPermissions] as? NSNumber)?.intValue == 0o700 else { return false }
            for file in [url, url.appendingPathExtension("1")] where fileManager.fileExists(atPath: file.path) {
                try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
                let attributes = try fileManager.attributesOfItem(atPath: file.path)
                guard (attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600 else { return false }
            }
            return true
        } catch {
            return false
        }
    }
}
