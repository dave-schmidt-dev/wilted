import Foundation

/// Appends each CloudKit operation summary to a small file, so a device whose unified log keeps
/// only a few hours (the iPhone) still has a day's counts to read after a soak. Summary lines carry
/// no record names, tokens, device or account IDs. The file rotates to one `.1` backup at `maxBytes`.
public final class CloudKitOperationArchive: @unchecked Sendable {
    public let url: URL
    private let maxBytes: Int
    private let lock = NSLock()
    private let stamp = ISO8601DateFormatter()

    public init(url: URL, maxBytes: Int = 1_000_000) {
        self.url = url
        self.maxBytes = maxBytes
    }

    /// The phone's archive under the app's `Library/Logs`.
    public static func standard(fileManager: FileManager = .default) -> CloudKitOperationArchive? {
        guard let library = fileManager.urls(for: .libraryDirectory, in: .userDomainMask).first else { return nil }
        return CloudKitOperationArchive(url: library.appendingPathComponent("Logs/cloudkit-operations.log"))
    }

    /// Writes one timestamped line. A write failure is dropped: diagnostics never break sync.
    public func append(_ line: String, at date: Date) {
        lock.withLock {
            let fileManager = FileManager.default
            try? fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let size = (try? fileManager.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
            if size >= maxBytes {
                let backup = url.appendingPathExtension("1")
                try? fileManager.removeItem(at: backup)
                try? fileManager.moveItem(at: url, to: backup)
            }
            let data = Data("\(stamp.string(from: date)) \(line)\n".utf8)
            if let handle = try? FileHandle(forWritingTo: url) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
            } else {
                try? data.write(to: url)
            }
        }
    }
}
