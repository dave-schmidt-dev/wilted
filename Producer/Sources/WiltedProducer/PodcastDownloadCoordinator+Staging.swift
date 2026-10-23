import CryptoKit
import Foundation
import WiltedDomain

/// An episode's original audio, fetched again and held outside the library's
/// records while a preparation decides whether to use it.
public struct StagedPodcastAudio: Equatable, Sendable {
    public let url: URL
    public let contentHash: String
    public let byteCount: Int64
    public let durationSeconds: Double
    public let mediaType: String

    public init(url: URL, contentHash: String, byteCount: Int64, durationSeconds: Double, mediaType: String) {
        self.url = url
        self.contentHash = contentHash
        self.byteCount = byteCount
        self.durationSeconds = durationSeconds
        self.mediaType = mediaType
    }

    /// Releases the file's in-flight claim and deletes it. Safe to call more
    /// than once, and after a commit already moved or removed the file.
    public func discard(in store: LocalLibraryStore) {
        try? FileManager.default.removeItem(at: url)
        store.inFlightMedia.end(url)
    }
}

extension PodcastDownloadCoordinator {
    /// Downloads an episode's enclosure into a staging file and hashes it,
    /// without touching the episode's download record or any revision.
    ///
    /// Preparing a cut episode again needs the original it was cut from, and
    /// the cut has to stay the ready revision, playable, until a successor is
    /// committed. `download` cannot do that: it writes queued and downloading
    /// records, which would move the episode out of Ready for the length of the
    /// transfer, and it publishes the file as a revision. This keeps the same
    /// transport rules (HTTPS, the size ceiling, the declared type, a playable
    /// file) and stops at the staging file.
    ///
    /// The file stays registered as in flight until the caller discards it, so a
    /// media sweep cannot reclaim it mid-run. Any failure or cancellation
    /// deletes the file before it returns.
    public func stageOriginal(
        episodeID: ItemID,
        enclosureURL: URL,
        onStatus: @escaping @Sendable (PodcastDownloadProgress) -> Void = { _ in }
    ) async throws -> StagedPodcastAudio {
        guard let episode = try await store.podcastEpisode(for: episodeID) else {
            throw PodcastDownloadCoordinatorError.episodeNotFound
        }
        guard Self.isHTTPS(enclosureURL) else { throw PodcastDownloadCoordinatorError.invalidURL }
        let storedMediaType = try Self.validatedMediaType(episode.enclosureMediaType)
        let stagingDirectory = libraryDirectory.appendingPathComponent(".podcast-staging", isDirectory: true)
        let stagingURL = stagingDirectory.appendingPathComponent(
            UUID().uuidString + "." + Self.fileExtension(for: storedMediaType)
        )
        let handle: FileHandle
        do {
            try FileManager.default.createDirectory(at: stagingDirectory, withIntermediateDirectories: true)
            guard FileManager.default.createFile(atPath: stagingURL.path, contents: nil) else {
                throw CocoaError(.fileWriteUnknown)
            }
            handle = try FileHandle(forWritingTo: stagingURL)
        } catch {
            throw PodcastDownloadCoordinatorError.transport(LogSafeError.describe(error))
        }
        store.inFlightMedia.begin(stagingURL)
        var keep = false
        defer {
            try? handle.close()
            if !keep {
                try? FileManager.default.removeItem(at: stagingURL)
                store.inFlightMedia.end(stagingURL)
            }
        }

        var expected = episode.enclosureByteCount.flatMap { $0 > 0 ? $0 : nil }
        var enforcedExpected: Int64?
        var received: Int64 = 0
        var responseMediaType: String?
        var hasher = SHA256()
        onStatus(.init(stage: .transferring, bytesReceived: 0, expectedByteCount: expected))
        do {
            for try await event in transport.events(for: enclosureURL) {
                try Task.checkCancellation()
                switch event {
                case .response(let response):
                    guard responseMediaType == nil else { throw PodcastDownloadCoordinatorError.invalidResponse(nil) }
                    guard Self.isHTTPS(response.url) else { throw PodcastDownloadCoordinatorError.invalidURL }
                    guard (200..<300).contains(response.statusCode) else {
                        throw PodcastDownloadCoordinatorError.invalidResponse(response.statusCode)
                    }
                    let actualType = try Self.validatedMediaType(response.mediaType)
                    guard Self.comparisonMediaType(actualType) == Self.comparisonMediaType(storedMediaType) else {
                        throw PodcastDownloadCoordinatorError.mediaTypeMismatch(
                            expected: storedMediaType, actual: actualType)
                    }
                    responseMediaType = actualType
                    if let declared = response.expectedByteCount, declared > 0 {
                        guard declared <= maximumBytes else {
                            throw PodcastDownloadCoordinatorError.declaredSizeTooLarge(declared)
                        }
                        expected = declared
                        enforcedExpected = declared
                    }
                    onStatus(.init(stage: .transferring, bytesReceived: received, expectedByteCount: expected))
                case .data(let data):
                    guard responseMediaType != nil else { throw PodcastDownloadCoordinatorError.invalidResponse(nil) }
                    guard Int64(data.count) <= maximumBytes - received else {
                        throw PodcastDownloadCoordinatorError.streamedSizeTooLarge(received + Int64(data.count))
                    }
                    try handle.write(contentsOf: data)
                    hasher.update(data: data)
                    received += Int64(data.count)
                    onStatus(.init(stage: .transferring, bytesReceived: received, expectedByteCount: expected))
                }
            }
            try Task.checkCancellation()
            guard let mediaType = responseMediaType else { throw PodcastDownloadCoordinatorError.invalidResponse(nil) }
            if let enforcedExpected, received != enforcedExpected {
                throw PodcastDownloadCoordinatorError.declaredSizeMismatch(expected: enforcedExpected, actual: received)
            }
            guard received > 0 else { throw PodcastDownloadCoordinatorError.invalidAudio }
            try DurableFile.fullSync(handle, at: stagingURL)
            try handle.close()
            let contentHash = "sha256:" + hasher.finalize().map { String(format: "%02x", $0) }.joined()
            onStatus(.init(stage: .validating, bytesReceived: received, expectedByteCount: expected))
            let duration: Double
            do {
                duration = try await mediaValidator.duration(of: stagingURL) { _ in }
            } catch is CancellationError {
                throw PodcastDownloadCoordinatorError.cancelled
            } catch let error as PodcastDownloadCoordinatorError {
                throw error
            } catch {
                throw PodcastDownloadCoordinatorError.invalidAudio
            }
            guard duration.isFinite, duration > 0 else { throw PodcastDownloadCoordinatorError.invalidAudio }
            keep = true
            onStatus(.init(stage: .completed, bytesReceived: received, expectedByteCount: expected))
            return StagedPodcastAudio(url: stagingURL, contentHash: contentHash, byteCount: received,
                                      durationSeconds: duration, mediaType: mediaType)
        } catch let error as PodcastDownloadCoordinatorError {
            throw error
        } catch is CancellationError {
            throw PodcastDownloadCoordinatorError.cancelled
        } catch {
            if Task.isCancelled { throw PodcastDownloadCoordinatorError.cancelled }
            throw PodcastDownloadCoordinatorError.transport(LogSafeError.describe(error))
        }
    }
}
