import AVFoundation
import CryptoKit
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import WiltedDomain

public enum PodcastDownloadCoordinatorError: Error, Equatable, LocalizedError, Sendable {
    case episodeNotFound
    case invalidURL
    case insecureRedirect
    case invalidResponse(Int?)
    case unsupportedMediaType(String?)
    case mediaTypeMismatch(expected: String, actual: String)
    case declaredSizeTooLarge(Int64)
    case streamedSizeTooLarge(Int64)
    case declaredSizeMismatch(expected: Int64, actual: Int64)
    case invalidExpectedHash
    case hashMismatch(expected: String, actual: String)
    case invalidAudio
    case destinationExists
    case cancelled
    case transport(String)

    public var errorDescription: String? {
        switch self {
        case .episodeNotFound: "The podcast episode is not in the local library."
        case .invalidURL: "The podcast enclosure and final response must use HTTPS."
        case .insecureRedirect: "The podcast server redirected to an insecure URL."
        case .invalidResponse: "The podcast server returned an invalid response."
        case .unsupportedMediaType: "The podcast enclosure uses an unsupported media type."
        case .mediaTypeMismatch: "The response media type does not match the podcast enclosure."
        case .declaredSizeTooLarge, .streamedSizeTooLarge: "The podcast enclosure exceeds the download limit."
        case .declaredSizeMismatch: "The podcast enclosure size does not match its declared size."
        case .invalidExpectedHash: "The expected podcast hash is invalid."
        case .hashMismatch: "The downloaded podcast hash does not match the expected hash."
        case .invalidAudio: "The downloaded podcast does not contain playable audio."
        case .destinationExists: "A different file already occupies the podcast revision destination."
        case .cancelled: "The podcast download was cancelled."
        case .transport: "Wilted could not download the podcast enclosure."
        }
    }
}

public struct PodcastDownloadHTTPResponse: Equatable, Sendable {
    public let url: URL
    public let statusCode: Int
    public let mediaType: String?
    public let expectedByteCount: Int64?

    public init(url: URL, statusCode: Int, mediaType: String?, expectedByteCount: Int64?) {
        self.url = url
        self.statusCode = statusCode
        self.mediaType = mediaType
        self.expectedByteCount = expectedByteCount
    }
}

public enum PodcastDownloadEvent: Sendable {
    case response(PodcastDownloadHTTPResponse)
    case data(Data)
}

/// Streaming transport boundary used by `PodcastDownloadCoordinator`.
public protocol PodcastDownloadTransporting: Sendable {
    func events(for url: URL) -> AsyncThrowingStream<PodcastDownloadEvent, Error>
}

public struct URLSessionPodcastDownloadTransport: PodcastDownloadTransporting, Sendable {
    private let configuration: URLSessionConfiguration

    public init(configuration: URLSessionConfiguration = .ephemeral) {
        self.configuration = configuration
    }

    public func events(for url: URL) -> AsyncThrowingStream<PodcastDownloadEvent, Error> {
        let configuration = configuration.copy() as! URLSessionConfiguration
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        return AsyncThrowingStream { continuation in
            let operation = PodcastDownloadRequestOperation(continuation: continuation)
            let session = URLSession(configuration: configuration, delegate: operation, delegateQueue: nil)
            operation.start(session: session, url: url)
            continuation.onTermination = { @Sendable _ in operation.cancel() }
        }
    }
}

public protocol PodcastMediaValidating: Sendable {
    func duration(of url: URL, onStatus: @escaping @Sendable (String) -> Void) async throws -> Double
}

public struct AVFoundationPodcastMediaValidator: PodcastMediaValidating, Sendable {
    public init() {}

    public func duration(of url: URL, onStatus: @escaping @Sendable (String) -> Void) async throws -> Double {
        onStatus("stage=media-load")
        let asset = AVURLAsset(url: url)
        let playable = try await asset.load(.isPlayable)
        onStatus("stage=media-audio-tracks")
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        let duration = try await asset.load(.duration).seconds
        guard playable, !tracks.isEmpty, duration.isFinite, duration > 0 else {
            throw PodcastDownloadCoordinatorError.invalidAudio
        }
        return duration
    }
}

public enum PodcastDownloadStage: String, Equatable, Sendable {
    case queued
    case transferring
    case verifying
    case validating
    case publishing
    case completed
}

public struct PodcastDownloadProgress: Equatable, Sendable {
    public let stage: PodcastDownloadStage
    public let bytesReceived: Int64
    public let expectedByteCount: Int64?

    public init(stage: PodcastDownloadStage, bytesReceived: Int64, expectedByteCount: Int64?) {
        self.stage = stage
        self.bytesReceived = bytesReceived
        self.expectedByteCount = expectedByteCount
    }
}

public struct PodcastDownloadResult: Equatable, Sendable {
    public let revision: AudioRevision
    public let mediaURL: URL
    public let download: PodcastDownload

    public init(revision: AudioRevision, mediaURL: URL, download: PodcastDownload) {
        self.revision = revision
        self.mediaURL = mediaURL
        self.download = download
    }
}

/// Downloads one stored episode into immutable library-owned media.
public actor PodcastDownloadCoordinator {
    public static let maximumDownloadBytes: Int64 = 500_000_000

    private let store: LocalLibraryStore
    private let transport: any PodcastDownloadTransporting
    private let mediaValidator: any PodcastMediaValidating
    private let libraryDirectory: URL
    private let maximumBytes: Int64
    private let now: @Sendable () -> Date

    public init(
        store: LocalLibraryStore,
        libraryDirectory: URL,
        transport: any PodcastDownloadTransporting = URLSessionPodcastDownloadTransport(),
        mediaValidator: any PodcastMediaValidating = AVFoundationPodcastMediaValidator(),
        maximumBytes: Int64 = PodcastDownloadCoordinator.maximumDownloadBytes,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.store = store
        self.libraryDirectory = libraryDirectory
        self.transport = transport
        self.mediaValidator = mediaValidator
        self.maximumBytes = maximumBytes
        self.now = now
    }

    public func download(
        episodeID: ItemID,
        expectedContentHash: String? = nil,
        onStatus: @escaping @Sendable (PodcastDownloadProgress) -> Void = { _ in }
    ) async throws -> PodcastDownloadResult {
        guard let episode = try await store.podcastEpisode(for: episodeID) else {
            throw PodcastDownloadCoordinatorError.episodeNotFound
        }
        let existing: PodcastDownloadResult?
        do {
            existing = try await completedResult(
                for: episodeID, expectedContentHash: expectedContentHash, onStatus: onStatus
            )
        } catch is CancellationError {
            throw PodcastDownloadCoordinatorError.cancelled
        }
        if let existing {
            onStatus(.init(stage: .completed, bytesReceived: existing.download.bytesReceived,
                           expectedByteCount: existing.download.expectedByteCount))
            return existing
        }

        var received: Int64 = 0
        var expected = episode.enclosureByteCount
        var responseSeen = false
        var responseMediaType: String?
        let storedMediaType: String
        let queued = try PodcastDownload(episodeID: episodeID, status: .queued, updatedAt: Timestamp(now()))
        try await store.save(download: queued)
        onStatus(.init(stage: .queued, bytesReceived: 0, expectedByteCount: expected))

        do {
            guard Self.isHTTPS(episode.enclosureURL) else { throw PodcastDownloadCoordinatorError.invalidURL }
            if let expectedContentHash, !Self.isContentHash(expectedContentHash) {
                throw PodcastDownloadCoordinatorError.invalidExpectedHash
            }
            if let declared = episode.enclosureByteCount, declared > maximumBytes {
                throw PodcastDownloadCoordinatorError.declaredSizeTooLarge(declared)
            }
            storedMediaType = try Self.validatedMediaType(episode.enclosureMediaType)
        } catch let error as PodcastDownloadCoordinatorError {
            try? await store.save(download: PodcastDownload(
                episodeID: episodeID, status: .failed, bytesReceived: 0,
                expectedByteCount: expected, updatedAt: Timestamp(now())
            ))
            throw error
        }

        let stagingDirectory = libraryDirectory.appendingPathComponent(".podcast-staging", isDirectory: true)
        let stagingExtension = Self.fileExtension(for: storedMediaType)
        let stagingURL = stagingDirectory.appendingPathComponent(UUID().uuidString + "." + stagingExtension)
        let handle: FileHandle
        do {
            try FileManager.default.createDirectory(at: stagingDirectory, withIntermediateDirectories: true)
            guard FileManager.default.createFile(atPath: stagingURL.path, contents: nil) else {
                throw CocoaError(.fileWriteUnknown)
            }
            handle = try FileHandle(forWritingTo: stagingURL)
        } catch {
            try? await store.save(download: PodcastDownload(
                episodeID: episodeID, status: .failed, bytesReceived: 0,
                expectedByteCount: expected, updatedAt: Timestamp(now())
            ))
            throw PodcastDownloadCoordinatorError.transport(String(describing: error))
        }
        var hasher = SHA256()
        defer {
            try? handle.close()
            try? FileManager.default.removeItem(at: stagingURL)
        }

        do {
            try await store.save(download: PodcastDownload(
                episodeID: episodeID, status: .downloading, bytesReceived: 0,
                expectedByteCount: expected, updatedAt: Timestamp(now())
            ))
            onStatus(.init(stage: .transferring, bytesReceived: 0, expectedByteCount: expected))
            for try await event in transport.events(for: episode.enclosureURL) {
                try Task.checkCancellation()
                switch event {
                case .response(let response):
                    guard !responseSeen else { throw PodcastDownloadCoordinatorError.invalidResponse(nil) }
                    responseSeen = true
                    guard Self.isHTTPS(response.url) else { throw PodcastDownloadCoordinatorError.invalidURL }
                    guard (200..<300).contains(response.statusCode) else {
                        throw PodcastDownloadCoordinatorError.invalidResponse(response.statusCode)
                    }
                    let actualType = try Self.validatedMediaType(response.mediaType)
                    let episodeType = storedMediaType
                    guard actualType == episodeType else {
                        throw PodcastDownloadCoordinatorError.mediaTypeMismatch(expected: episodeType, actual: actualType)
                    }
                    responseMediaType = actualType
                    if let responseExpected = response.expectedByteCount, responseExpected >= 0 {
                        guard responseExpected <= maximumBytes else {
                            throw PodcastDownloadCoordinatorError.declaredSizeTooLarge(responseExpected)
                        }
                        expected = responseExpected
                    }
                    try await store.save(download: PodcastDownload(
                        episodeID: episodeID, status: .downloading, bytesReceived: received,
                        expectedByteCount: expected, updatedAt: Timestamp(now())
                    ))
                    onStatus(.init(stage: .transferring, bytesReceived: received, expectedByteCount: expected))
                case .data(let data):
                    guard responseSeen else { throw PodcastDownloadCoordinatorError.invalidResponse(nil) }
                    guard Int64(data.count) <= maximumBytes - received else {
                        throw PodcastDownloadCoordinatorError.streamedSizeTooLarge(received + Int64(data.count))
                    }
                    if let expected, Int64(data.count) > expected - received {
                        throw PodcastDownloadCoordinatorError.streamedSizeTooLarge(received + Int64(data.count))
                    }
                    try handle.write(contentsOf: data)
                    hasher.update(data: data)
                    received += Int64(data.count)
                    try await store.save(download: PodcastDownload(
                        episodeID: episodeID, status: .downloading, bytesReceived: received,
                        expectedByteCount: expected, updatedAt: Timestamp(now())
                    ))
                    onStatus(.init(stage: .transferring, bytesReceived: received, expectedByteCount: expected))
                }
            }
            try Task.checkCancellation()
            guard responseSeen else { throw PodcastDownloadCoordinatorError.invalidResponse(nil) }
            if let expected, received != expected {
                throw PodcastDownloadCoordinatorError.declaredSizeMismatch(expected: expected, actual: received)
            }
            guard received > 0 else { throw PodcastDownloadCoordinatorError.invalidAudio }
            try handle.synchronize()
            try handle.close()

            let contentHash = "sha256:" + hasher.finalize().map { String(format: "%02x", $0) }.joined()
            if let expectedContentHash, expectedContentHash != contentHash {
                throw PodcastDownloadCoordinatorError.hashMismatch(expected: expectedContentHash, actual: contentHash)
            }
            onStatus(.init(stage: .validating, bytesReceived: received, expectedByteCount: expected))
            let duration: Double
            let validationReceived = received
            let validationExpected = expected
            do {
                duration = try await mediaValidator.duration(of: stagingURL) { _ in
                    onStatus(.init(stage: .validating, bytesReceived: validationReceived,
                                   expectedByteCount: validationExpected))
                }
            } catch is CancellationError {
                throw PodcastDownloadCoordinatorError.cancelled
            } catch let error as PodcastDownloadCoordinatorError {
                throw error
            } catch {
                throw PodcastDownloadCoordinatorError.invalidAudio
            }
            guard duration.isFinite, duration > 0 else { throw PodcastDownloadCoordinatorError.invalidAudio }

            let revisionID = try RevisionID.derive(downloadedAudioContentHash: contentHash)
            let mediaType = responseMediaType!
            let extensionName = Self.fileExtension(for: mediaType)
            let finalDirectory = libraryDirectory.appendingPathComponent("PodcastAudio", isDirectory: true)
                .appendingPathComponent(episodeID.rawValue, isDirectory: true)
            let finalURL = finalDirectory.appendingPathComponent(revisionID.rawValue + "." + extensionName)
            try FileManager.default.createDirectory(at: finalDirectory, withIntermediateDirectories: true)
            onStatus(.init(stage: .publishing, bytesReceived: received, expectedByteCount: expected))
            if FileManager.default.fileExists(atPath: finalURL.path) {
                guard try await verificationHash(of: finalURL, onStatus: onStatus) == contentHash else {
                    throw PodcastDownloadCoordinatorError.destinationExists
                }
            } else {
                do { try FileManager.default.moveItem(at: stagingURL, to: finalURL) }
                catch {
                    guard FileManager.default.fileExists(atPath: finalURL.path) else { throw error }
                    guard try await verificationHash(of: finalURL, onStatus: onStatus) == contentHash else {
                        throw PodcastDownloadCoordinatorError.destinationExists
                    }
                }
            }
            let revision = try AudioRevision(
                itemID: episodeID, revisionID: revisionID, durationSeconds: duration,
                byteCount: received, contentHash: contentHash, mediaType: mediaType,
                createdAt: Timestamp(now()), schemaVersion: 3
            )
            let completed = try PodcastDownload(
                episodeID: episodeID, status: .completed, bytesReceived: received,
                expectedByteCount: expected, localURL: finalURL, contentHash: contentHash,
                updatedAt: Timestamp(now())
            )
            try await store.finalizePodcastDownload(revision: revision, mediaURL: finalURL, download: completed)
            onStatus(.init(stage: .completed, bytesReceived: received, expectedByteCount: expected))
            return PodcastDownloadResult(revision: revision, mediaURL: finalURL, download: completed)
        } catch {
            let cancelled = error is CancellationError || Task.isCancelled ||
                (error as? PodcastDownloadCoordinatorError) == .cancelled
            let status: PodcastDownloadStatus = cancelled ? .cancelled : .failed
            try? await store.save(download: PodcastDownload(
                episodeID: episodeID, status: status, bytesReceived: received,
                expectedByteCount: expected.map { max($0, received) }, updatedAt: Timestamp(now())
            ))
            if cancelled { throw PodcastDownloadCoordinatorError.cancelled }
            if let typed = error as? PodcastDownloadCoordinatorError { throw typed }
            throw PodcastDownloadCoordinatorError.transport(String(describing: error))
        }
    }

    private func completedResult(
        for episodeID: ItemID,
        expectedContentHash: String?,
        onStatus: @escaping @Sendable (PodcastDownloadProgress) -> Void
    ) async throws -> PodcastDownloadResult? {
        guard let download = try await store.download(for: episodeID), download.status == .completed,
              let hash = download.contentHash, expectedContentHash == nil || expectedContentHash == hash,
              let url = download.localURL, FileManager.default.fileExists(atPath: url.path),
              let stored = try await store.readyRevision(for: episodeID), stored.revision.contentHash == hash,
              stored.mediaURL == url else { return nil }
        guard try await verificationHash(of: url, onStatus: onStatus) == hash else { return nil }
        return PodcastDownloadResult(revision: stored.revision, mediaURL: url, download: download)
    }

    fileprivate static func isHTTPS(_ url: URL) -> Bool {
        url.scheme?.lowercased() == "https" && url.host != nil && url.user == nil && url.password == nil
    }

    private static func isContentHash(_ value: String) -> Bool {
        value.range(of: #"^sha256:[0-9a-f]{64}$"#, options: .regularExpression) != nil
    }

    private static let supportedMediaTypes: Set<String> = [
        "audio/aac", "audio/flac", "audio/m4a", "audio/mp3", "audio/mp4", "audio/mpeg", "audio/ogg", "audio/opus",
        "audio/vnd.wave", "audio/wav", "audio/webm", "audio/x-aac", "audio/x-flac",
        "audio/x-m4a", "audio/x-wav"
    ]

    private static func validatedMediaType(_ value: String?) throws -> String {
        guard let value else { throw PodcastDownloadCoordinatorError.unsupportedMediaType(nil) }
        let normalized = value.split(separator: ";", maxSplits: 1).first?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        guard supportedMediaTypes.contains(normalized) else {
            throw PodcastDownloadCoordinatorError.unsupportedMediaType(normalized.isEmpty ? nil : normalized)
        }
        return normalized
    }

    private static func fileExtension(for mediaType: String) -> String {
        switch mediaType {
        case "audio/mp3", "audio/mpeg": "mp3"
        case "audio/m4a", "audio/mp4", "audio/x-m4a": "m4a"
        case "audio/flac", "audio/x-flac": "flac"
        case "audio/ogg", "audio/opus": "ogg"
        case "audio/webm": "webm"
        case "audio/aac", "audio/x-aac": "aac"
        default: "wav"
        }
    }

    private func verificationHash(
        of url: URL,
        onStatus: @escaping @Sendable (PodcastDownloadProgress) -> Void
    ) async throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let total = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value
        var hasher = SHA256()
        var processed: Int64 = 0
        var lastReported: Int64 = -4 * 1_024 * 1_024
        while true {
            try Task.checkCancellation()
            guard let data = try handle.read(upToCount: 64 * 1_024), !data.isEmpty else { break }
            hasher.update(data: data)
            processed += Int64(data.count)
            if processed - lastReported >= 4 * 1_024 * 1_024 || processed == total {
                onStatus(.init(stage: .verifying, bytesReceived: processed, expectedByteCount: total))
                lastReported = processed
            }
            await Task.yield()
        }
        try Task.checkCancellation()
        if processed != lastReported {
            onStatus(.init(stage: .verifying, bytesReceived: processed, expectedByteCount: total))
        }
        return "sha256:" + hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

private final class PodcastDownloadRequestOperation: NSObject, URLSessionDataDelegate, URLSessionTaskDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private let continuation: AsyncThrowingStream<PodcastDownloadEvent, Error>.Continuation
    private var session: URLSession?
    private var task: URLSessionDataTask?
    private var terminalError: PodcastDownloadCoordinatorError?
    private var completed = false

    init(continuation: AsyncThrowingStream<PodcastDownloadEvent, Error>.Continuation) {
        self.continuation = continuation
    }

    func start(session: URLSession, url: URL) {
        lock.withLock {
            self.session = session
            let request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
            let task = session.dataTask(with: request)
            self.task = task
            task.resume()
        }
    }

    func cancel() {
        lock.withLock { task?.cancel() }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        guard let url = request.url, PodcastDownloadCoordinator.isHTTPS(url) else {
            lock.withLock { terminalError = .insecureRedirect }
            completionHandler(nil)
            task.cancel()
            return
        }
        completionHandler(request)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let http = response as? HTTPURLResponse else {
            lock.withLock { terminalError = .invalidResponse(nil) }
            completionHandler(.cancel)
            return
        }
        let url = http.url ?? dataTask.currentRequest?.url ?? dataTask.originalRequest!.url!
        let mediaType = (http.allHeaderFields.first { String(describing: $0.key).lowercased() == "content-type" }?.value as? String) ?? response.mimeType
        let expected = response.expectedContentLength == NSURLSessionTransferSizeUnknown ? nil : response.expectedContentLength
        continuation.yield(.response(.init(url: url, statusCode: http.statusCode, mediaType: mediaType,
                                           expectedByteCount: expected)))
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        continuation.yield(.data(data))
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let completion: (Result<Void, Error>, URLSession)? = lock.withLock {
            guard !completed, let retainedSession = self.session else { return nil }
            completed = true
            let result: Result<Void, Error>
            if let terminalError { result = .failure(terminalError) }
            else if let urlError = error as? URLError, urlError.code == .cancelled {
                result = .failure(PodcastDownloadCoordinatorError.cancelled)
            } else if let error { result = .failure(error) }
            else { result = .success(()) }
            self.session = nil
            self.task = nil
            return (result, retainedSession)
        }
        guard let completion else { return }
        switch completion.0 {
        case .success: continuation.finish()
        case .failure(let error): continuation.finish(throwing: error)
        }
        completion.1.finishTasksAndInvalidate()
    }
}
