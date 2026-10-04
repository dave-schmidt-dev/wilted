import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import WiltedDomain

public enum PodcastFeedClientError: Error, Equatable, LocalizedError, Sendable {
    case invalidURL
    case redirectDowngrade
    case invalidResponse(Int?)
    case responseTooLarge
    case transport(String)
    case malformedXML
    case externalEntity
    case invalidMetadata(String)
    case unsupportedEnclosureMediaType(String)
    case cancelled

    public var errorDescription: String? {
        switch self {
        case .invalidURL: "The podcast feed URL must be a complete HTTPS URL."
        case .redirectDowngrade: "The podcast server redirected to an insecure URL."
        case .invalidResponse: "The podcast server returned an invalid response."
        case .responseTooLarge: "The podcast feed is larger than Wilted's safe limit."
        case .transport: "Wilted could not load the podcast feed."
        case .malformedXML: "The podcast feed contains malformed XML."
        case .externalEntity: "The podcast feed references an external XML entity."
        case .invalidMetadata: "The podcast feed contains invalid metadata."
        case .unsupportedEnclosureMediaType: "The podcast feed contains an unsupported audio enclosure."
        case .cancelled: "Podcast feed loading was cancelled."
        }
    }
}

public struct PodcastFeedHTTPResponse: Sendable {
    public let url: URL
    public let statusCode: Int
    public let data: Data

    public init(url: URL, statusCode: Int, data: Data) {
        self.url = url
        self.statusCode = statusCode
        self.data = data
    }
}

/// The transport boundary used by `PodcastFeedClient`.
public protocol PodcastFeedLoading: Sendable {
    func load(_ url: URL, maximumBytes: Int) async throws -> PodcastFeedHTTPResponse
    /// Loads at most the requested prefix of a successful response.
    ///
    /// This is intentionally different from `load`: callers that only need
    /// the opening bytes may accept a resource whose complete body is larger
    /// than `maximumBytes`.
    func loadPrefix(_ url: URL, maximumBytes: Int) async throws -> PodcastFeedHTTPResponse
}

public extension PodcastFeedLoading {
    func loadPrefix(_ url: URL, maximumBytes: Int) async throws -> PodcastFeedHTTPResponse {
        let response = try await load(url, maximumBytes: maximumBytes)
        return PodcastFeedHTTPResponse(
            url: response.url,
            statusCode: response.statusCode,
            data: Data(response.data.prefix(maximumBytes))
        )
    }
}

public struct URLSessionPodcastFeedLoader: PodcastFeedLoading, Sendable {
    private let configuration: URLSessionConfiguration
    private let beforeRequestStart: @Sendable () async -> Void

    public init(configuration: URLSessionConfiguration = .ephemeral) {
        self.configuration = configuration
        self.beforeRequestStart = {}
    }

    init(
        configuration: URLSessionConfiguration,
        beforeRequestStart: @escaping @Sendable () async -> Void
    ) {
        self.configuration = configuration
        self.beforeRequestStart = beforeRequestStart
    }

    public func load(_ url: URL, maximumBytes: Int) async throws -> PodcastFeedHTTPResponse {
        try await load(url, maximumBytes: maximumBytes, acceptsOversizedResponsePrefix: false)
    }

    public func loadPrefix(_ url: URL, maximumBytes: Int) async throws -> PodcastFeedHTTPResponse {
        try await load(url, maximumBytes: maximumBytes, acceptsOversizedResponsePrefix: true)
    }

    private func load(
        _ url: URL,
        maximumBytes: Int,
        acceptsOversizedResponsePrefix: Bool
    ) async throws -> PodcastFeedHTTPResponse {
        try Task.checkCancellation()
        let operation = PodcastFeedRequestOperation(
            maximumBytes: maximumBytes,
            acceptsOversizedResponsePrefix: acceptsOversizedResponsePrefix
        )
        let configuration = configuration.copy() as! URLSessionConfiguration
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        let session = URLSession(configuration: configuration, delegate: operation, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        await beforeRequestStart()
        return try await withTaskCancellationHandler(operation: {
            try await operation.start(session: session, requestURL: url)
        }, onCancel: {
            operation.cancel()
        })
    }
}

public struct LoadedPodcastFeed: Equatable, Sendable {
    public let feed: PodcastFeed
    public let episodes: [PodcastEpisode]
    /// Episodes the feed published that this load dropped because the feed
    /// carries more than `PodcastFeedClient.maximumEpisodeCount`. Callers report
    /// it rather than presenting a truncated back catalogue as the whole feed.
    public let droppedEpisodeCount: Int

    public init(feed: PodcastFeed, episodes: [PodcastEpisode], droppedEpisodeCount: Int = 0) {
        self.droppedEpisodeCount = droppedEpisodeCount
        self.feed = feed
        self.episodes = episodes
    }
}

public struct PodcastFeedClient: Sendable {
    /// Real podcast feeds are much larger than a first guess suggests: of the 29
    /// feeds in the 2026-08-31 import survey the largest was 10.2 MiB and half
    /// exceeded 2 MiB, so the original 2 MiB ceiling rejected most of them
    /// outright. 16 MiB clears every surveyed feed with headroom and still
    /// bounds what one XML document can cost.
    public static let maximumFeedBytes = 16 * 1_024 * 1_024
    /// Ceiling on the episodes one feed contributes. A feed with a longer back
    /// catalogue is truncated to its newest episodes, never rejected.
    public static let maximumEpisodeCount = 500

    private let loader: any PodcastFeedLoading
    private let now: @Sendable () -> Date

    public init(
        loader: any PodcastFeedLoading = URLSessionPodcastFeedLoader(),
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.loader = loader
        self.now = now
    }

    public func load(_ url: URL) async throws -> LoadedPodcastFeed {
        guard Self.isHTTPS(url) else { throw PodcastFeedClientError.invalidURL }
        do {
            let response = try await loader.load(url, maximumBytes: Self.maximumFeedBytes)
            try Task.checkCancellation()
            guard response.data.count <= Self.maximumFeedBytes else { throw PodcastFeedClientError.responseTooLarge }
            guard (200..<300).contains(response.statusCode) else {
                throw PodcastFeedClientError.invalidResponse(response.statusCode)
            }
            guard Self.isHTTPS(response.url) else { throw PodcastFeedClientError.invalidURL }
            // The requested address is the durable subscription identity. A
            // host migration may change the final fetch URL without creating a
            // different podcast in the listener's library.
            return try PodcastRSSParser(feedURL: url, createdAt: now()).parse(response.data)
        } catch is CancellationError {
            throw PodcastFeedClientError.cancelled
        } catch let error as PodcastFeedClientError {
            throw error
        } catch let error as DomainError {
            throw PodcastFeedClientError.invalidMetadata(String(describing: error))
        } catch let error as URLError where error.code == .cancelled || Task.isCancelled {
            throw PodcastFeedClientError.cancelled
        } catch {
            if Task.isCancelled { throw PodcastFeedClientError.cancelled }
            throw PodcastFeedClientError.transport(String(describing: error))
        }
    }

    static func isHTTPS(_ url: URL) -> Bool {
        url.scheme?.lowercased() == "https" && url.host != nil && url.user == nil && url.password == nil
    }
}

private final class PodcastFeedRequestOperation: NSObject, URLSessionDataDelegate, URLSessionTaskDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private let maximumBytes: Int
    private let acceptsOversizedResponsePrefix: Bool
    private var continuation: CheckedContinuation<PodcastFeedHTTPResponse, Error>?
    private var task: URLSessionDataTask?
    private var response: HTTPURLResponse?
    private var data = Data()
    private var terminalError: PodcastFeedClientError?
    private var completed = false

    init(maximumBytes: Int, acceptsOversizedResponsePrefix: Bool = false) {
        self.maximumBytes = maximumBytes
        self.acceptsOversizedResponsePrefix = acceptsOversizedResponsePrefix
    }

    func start(session: URLSession, requestURL: URL) async throws -> PodcastFeedHTTPResponse {
        try await withCheckedThrowingContinuation { continuation in
            lock.withLock {
                self.continuation = continuation
                if let terminalError {
                    finishLocked(.failure(terminalError))
                    return
                }
                let request = URLRequest(url: requestURL, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
                let task = session.dataTask(with: request)
                self.task = task
                task.resume()
            }
        }
    }

    func cancel() {
        lock.withLock {
            terminalError = .cancelled
            task?.cancel()
            finishLocked(.failure(PodcastFeedClientError.cancelled))
        }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        guard let redirectURL = request.url, PodcastFeedClient.isHTTPS(redirectURL) else {
            lock.withLock {
                terminalError = .redirectDowngrade
                task.cancel()
            }
            completionHandler(nil)
            return
        }
        completionHandler(request)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse, completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        lock.withLock {
            guard !completed else { completionHandler(.cancel); return }
            guard let http = response as? HTTPURLResponse else {
                terminalError = .invalidResponse(nil); dataTask.cancel(); completionHandler(.cancel); return
            }
            guard (200..<300).contains(http.statusCode) else {
                terminalError = .invalidResponse(http.statusCode); dataTask.cancel(); completionHandler(.cancel); return
            }
            guard PodcastFeedClient.isHTTPS(http.url ?? dataTask.currentRequest?.url ?? dataTask.originalRequest?.url ?? URL(fileURLWithPath: "/")) else {
                terminalError = .invalidURL; dataTask.cancel(); completionHandler(.cancel); return
            }
            guard acceptsOversizedResponsePrefix || response.expectedContentLength <= Int64(maximumBytes) || response.expectedContentLength == NSURLSessionTransferSizeUnknown else {
                terminalError = .responseTooLarge; dataTask.cancel(); completionHandler(.cancel); return
            }
            self.response = http
            if acceptsOversizedResponsePrefix, maximumBytes == 0 {
                completePrefixLocked(dataTask)
                completionHandler(.cancel)
                return
            }
            completionHandler(.allow)
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.withLock {
            guard !completed, terminalError == nil else { return }
            if acceptsOversizedResponsePrefix {
                let remaining = maximumBytes - self.data.count
                guard remaining > 0 else { return }
                self.data.append(data.prefix(remaining))
                if self.data.count == maximumBytes { completePrefixLocked(dataTask) }
                return
            }
            guard self.data.count <= maximumBytes - data.count else {
                terminalError = .responseTooLarge
                dataTask.cancel()
                return
            }
            self.data.append(data)
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.withLock {
            if let terminalError { finishLocked(.failure(terminalError)) }
            else if let urlError = error as? URLError, urlError.code == .cancelled { finishLocked(.failure(PodcastFeedClientError.cancelled)) }
            else if let error { finishLocked(.failure(PodcastFeedClientError.transport(String(describing: error)))) }
            else if let response {
                let finalURL = response.url ?? task.currentRequest?.url ?? task.originalRequest?.url
                guard let finalURL, PodcastFeedClient.isHTTPS(finalURL) else {
                    finishLocked(.failure(PodcastFeedClientError.invalidURL)); return
                }
                finishLocked(.success(PodcastFeedHTTPResponse(url: finalURL, statusCode: response.statusCode, data: data)))
            } else {
                finishLocked(.failure(PodcastFeedClientError.invalidResponse(nil)))
            }
        }
        session.finishTasksAndInvalidate()
    }

    private func finishLocked(_ result: Result<PodcastFeedHTTPResponse, Error>) {
        guard !completed, let continuation else { return }
        completed = true
        self.continuation = nil
        continuation.resume(with: result)
    }

    private func completePrefixLocked(_ dataTask: URLSessionDataTask) {
        guard let response,
              let finalURL = response.url ?? dataTask.currentRequest?.url ?? dataTask.originalRequest?.url,
              PodcastFeedClient.isHTTPS(finalURL)
        else {
            terminalError = .invalidURL
            dataTask.cancel()
            return
        }
        dataTask.cancel()
        finishLocked(.success(PodcastFeedHTTPResponse(url: finalURL, statusCode: response.statusCode, data: data)))
    }
}
