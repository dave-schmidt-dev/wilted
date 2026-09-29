import CryptoKit
import Foundation

/// Streaming SHA-256 over files. Reads fixed-size chunks so a multi-hundred-megabyte
/// episode never sits in memory.
public enum MediaHash {
    public static let prefix = "sha256:"
    public static let defaultChunkSize = 1 << 20

    /// `sha256:<lowercase hex>` of the file's bytes.
    public static func sha256(fileAt url: URL, chunkSize: Int = defaultChunkSize) throws -> String {
        precondition(chunkSize > 0, "chunk size must be positive")
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            // Each chunk is released before the next is read.
            let finished: Bool = try autoreleasepool {
                guard let chunk = try handle.read(upToCount: chunkSize), !chunk.isEmpty else { return true }
                hasher.update(data: chunk)
                return false
            }
            if finished { break }
        }
        return prefix + hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// True for `sha256:` followed by exactly 64 lowercase hex digits.
    public static func isWellFormed(_ value: String) -> Bool {
        guard value.hasPrefix(prefix) else { return false }
        let digest = value.dropFirst(prefix.count)
        return digest.utf8.count == 64 && digest.utf8.allSatisfy { ($0 >= 48 && $0 <= 57) || ($0 >= 97 && $0 <= 102) }
    }
}
