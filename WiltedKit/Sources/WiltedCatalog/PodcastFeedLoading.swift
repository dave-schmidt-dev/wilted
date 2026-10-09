import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

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

/// The transport boundary used by `PodcastFeedClient` and `PodcastCatalogLookupClient`.
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

final class PodcastFeedRequestOperation: NSObject, URLSessionDataDelegate, URLSessionTaskDelegate, @unchecked Sendable {
    static func isHTTPS(_ url: URL) -> Bool {
        url.scheme?.lowercased() == "https" && url.host != nil && url.user == nil && url.password == nil
    }

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
        guard let redirectURL = request.url, PodcastFeedRequestOperation.isHTTPS(redirectURL) else {
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
            guard PodcastFeedRequestOperation.isHTTPS(http.url ?? dataTask.currentRequest?.url ?? dataTask.originalRequest?.url ?? URL(fileURLWithPath: "/")) else {
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
                guard let finalURL, PodcastFeedRequestOperation.isHTTPS(finalURL) else {
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
              PodcastFeedRequestOperation.isHTTPS(finalURL)
        else {
            terminalError = .invalidURL
            dataTask.cancel()
            return
        }
        dataTask.cancel()
        finishLocked(.success(PodcastFeedHTTPResponse(url: finalURL, statusCode: response.statusCode, data: data)))
    }
}
