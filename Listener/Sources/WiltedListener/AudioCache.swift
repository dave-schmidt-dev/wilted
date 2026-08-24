import CryptoKit
import Foundation
import WiltedDomain
import WiltedSync

public struct ListenerDownloadStatistics: Codable, Equatable, Sendable {
    public let fileCount: Int
    public let byteCount: Int64

    public init(fileCount: Int = 0, byteCount: Int64 = 0) {
        self.fileCount = fileCount
        self.byteCount = byteCount
    }
}

/// A content-addressed audio cache. Invalid bytes never replace a valid entry.
public actor ListenerAudioCache {
    public nonisolated let statuses: AsyncStream<SyncStatus>
    private let statusContinuation: AsyncStream<SyncStatus>.Continuation
    private let rootURL: URL

    public init(rootURL: URL) throws {
        self.rootURL = rootURL.standardizedFileURL
        try FileManager.default.createDirectory(at: self.rootURL, withIntermediateDirectories: true)
        let (stream, continuation) = AsyncStream<SyncStatus>.makeStream()
        self.statuses = stream
        self.statusContinuation = continuation
    }

    public func store(fileURL: URL, asset: WiltedAsset) throws -> URL {
        emit(.init(phase: .staging, message: "Validating audio asset"))
        guard FileManager.default.fileExists(atPath: fileURL.path) else { throw ListenerError.cacheUnavailable(asset.assetID) }
        let bytes: Data
        do { bytes = try Data(contentsOf: fileURL) } catch { throw ListenerError.cacheCopyFailed(error.localizedDescription) }
        guard sha256(bytes) == asset.contentHash else { throw ListenerError.cacheHashMismatch(asset.assetID) }
        return try storeValidated(bytes: bytes, asset: asset)
    }

    public func store(data: Data, asset: WiltedAsset) throws -> URL {
        emit(.init(phase: .staging, message: "Validating audio asset"))
        guard sha256(data) == asset.contentHash else { throw ListenerError.cacheHashMismatch(asset.assetID) }
        return try storeValidated(bytes: data, asset: asset)
    }

    public func url(for asset: WiltedAsset) -> URL? {
        let destination = destination(for: asset)
        guard FileManager.default.fileExists(atPath: destination.path),
              let bytes = try? Data(contentsOf: destination), sha256(bytes) == asset.contentHash else { return nil }
        return destination
    }

    public func remove(_ asset: WiltedAsset) throws { try? FileManager.default.removeItem(at: destination(for: asset)) }

    /// Derives truthful local download facts from the content-addressed cache.
    /// Temporary or hidden files are excluded so an interrupted write cannot inflate the count.
    public func statistics() throws -> ListenerDownloadStatistics {
        let files = try FileManager.default.contentsOfDirectory(
            at: rootURL, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey], options: [.skipsHiddenFiles]
        )
        var count = 0
        var bytes: Int64 = 0
        for file in files {
            let values = try file.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard values.isRegularFile == true else { continue }
            count += 1
            bytes += Int64(values.fileSize ?? 0)
        }
        return ListenerDownloadStatistics(fileCount: count, byteCount: bytes)
    }

    private func storeValidated(bytes: Data, asset: WiltedAsset) throws -> URL {
        let destination = destination(for: asset)
        if let existing = try? Data(contentsOf: destination), sha256(existing) == asset.contentHash { return destination }
        let temporary = rootURL.appendingPathComponent(".incoming-\(UUID().uuidString).tmp")
        do {
            try bytes.write(to: temporary, options: .atomic)
            if FileManager.default.fileExists(atPath: destination.path) { try FileManager.default.removeItem(at: destination) }
            try FileManager.default.moveItem(at: temporary, to: destination)
            emit(.init(phase: .completed, message: "Audio asset cached"))
            return destination
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            throw ListenerError.cacheCopyFailed(error.localizedDescription)
        }
    }

    private func destination(for asset: WiltedAsset) -> URL {
        let key = asset.contentHash.dropFirst(7)
        return rootURL.appendingPathComponent(String(key), isDirectory: false)
    }

    private func sha256(_ data: Data) -> String {
        "sha256:" + SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func emit(_ status: SyncStatus) { statusContinuation.yield(status) }
}
