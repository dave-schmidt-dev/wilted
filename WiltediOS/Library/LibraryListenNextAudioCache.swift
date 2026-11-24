import CryptoKit
import Darwin
import Foundation
import WiltedLibrary

/// Durable iPhone copy of one exact, request-scoped narrated story offer.
struct LibraryListenNextAudioCache: Sendable {
    private let rootURL: URL?

    init(outboxURL: URL?) {
        rootURL = outboxURL?.deletingLastPathComponent()
            .appendingPathComponent("listen-next-audio", isDirectory: true).standardizedFileURL
    }

    func store(_ sourceURL: URL, for offer: LibraryStoryAudioOffer, ownerToken: String) throws -> URL {
        guard let rootURL, !ownerToken.isEmpty, sourceURL.isFileURL, offer.mediaType == "audio/mp4",
              offer.byteCount > 0, offer.byteCount <= LANFrameCodec.maximumByteCount,
              MediaHash.isWellFormed(offer.contentHash) else {
            throw LibraryListenNextError.notDurable
        }
        try verify(sourceURL, offer: offer)
        let directory = requestDirectory(offer.requestID, ownerToken: ownerToken, under: rootURL)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        LibraryFileProtection.apply(to: rootURL)
        LibraryFileProtection.apply(to: directory.deletingLastPathComponent())
        LibraryFileProtection.apply(to: directory)
        let destination = directory.appendingPathComponent("story-\(try offerDigest(offer)).m4a")
        if FileManager.default.fileExists(atPath: destination.path) {
            do { try verify(destination, offer: offer); return destination }
            catch { /* Replace only this offer's invalid cache file below. */ }
        }

        let temporary = directory.appendingPathComponent(".\(UUID().uuidString).partial")
        defer { try? FileManager.default.removeItem(at: temporary) }
        try FileManager.default.copyItem(at: sourceURL, to: temporary)
        try verify(temporary, offer: offer)
        guard Darwin.rename(temporary.path, destination.path) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        LibraryFileProtection.apply(to: destination)
        for stale in (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
            where stale != destination && stale.lastPathComponent.hasPrefix("story-") {
            try? FileManager.default.removeItem(at: stale)
        }
        return destination
    }

    func url(for offer: LibraryStoryAudioOffer, ownerToken: String) -> URL? {
        guard let rootURL, !ownerToken.isEmpty, let digest = try? offerDigest(offer) else { return nil }
        return requestDirectory(offer.requestID, ownerToken: ownerToken, under: rootURL)
            .appendingPathComponent("story-\(digest).m4a")
    }

    /// Deletes only the hash-named directory belonging to one durable request id.
    func removeAudio(for requestID: String, ownerToken: String) throws {
        guard let rootURL, !ownerToken.isEmpty else { return }
        let directory = requestDirectory(requestID, ownerToken: ownerToken, under: rootURL)
        guard directory.deletingLastPathComponent().deletingLastPathComponent().standardizedFileURL == rootURL else {
            throw LibraryListenNextError.notDurable
        }
        if FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.removeItem(at: directory)
        }
    }

    private func requestDirectory(_ requestID: String, ownerToken: String, under root: URL) -> URL {
        let ownerDigest = SHA256.hash(data: Data(ownerToken.utf8)).map { String(format: "%02x", $0) }.joined()
        let requestDigest = SHA256.hash(data: Data(requestID.utf8)).map { String(format: "%02x", $0) }.joined()
        return root.appendingPathComponent(ownerDigest, isDirectory: true)
            .appendingPathComponent(requestDigest, isDirectory: true).standardizedFileURL
    }

    private func offerDigest(_ offer: LibraryStoryAudioOffer) throws -> String {
        var encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(offer)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func verify(_ fileURL: URL, offer: LibraryStoryAudioOffer) throws {
        let attributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular,
              (attributes[.size] as? NSNumber)?.int64Value == offer.byteCount,
              try MediaHash.sha256(fileAt: fileURL) == offer.contentHash else {
            throw LibraryListenNextError.notDurable
        }
    }
}
