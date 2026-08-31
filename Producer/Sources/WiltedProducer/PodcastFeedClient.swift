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
        try Task.checkCancellation()
        let operation = PodcastFeedRequestOperation(maximumBytes: maximumBytes)
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

    public init(feed: PodcastFeed, episodes: [PodcastEpisode]) {
        self.feed = feed
        self.episodes = episodes
    }
}

public struct PodcastFeedClient: Sendable {
    public static let maximumFeedBytes = 2 * 1_024 * 1_024
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
            return try PodcastRSSParser(feedURL: response.url, createdAt: now()).parse(response.data)
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

    fileprivate static func isHTTPS(_ url: URL) -> Bool {
        url.scheme?.lowercased() == "https" && url.host != nil && url.user == nil && url.password == nil
    }
}

private final class PodcastFeedRequestOperation: NSObject, URLSessionDataDelegate, URLSessionTaskDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private let maximumBytes: Int
    private var continuation: CheckedContinuation<PodcastFeedHTTPResponse, Error>?
    private var task: URLSessionDataTask?
    private var response: HTTPURLResponse?
    private var data = Data()
    private var terminalError: PodcastFeedClientError?
    private var completed = false

    init(maximumBytes: Int) { self.maximumBytes = maximumBytes }

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
            guard response.expectedContentLength <= Int64(maximumBytes) || response.expectedContentLength == NSURLSessionTransferSizeUnknown else {
                terminalError = .responseTooLarge; dataTask.cancel(); completionHandler(.cancel); return
            }
            self.response = http
            completionHandler(.allow)
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.withLock {
            guard !completed, terminalError == nil else { return }
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
}

private final class PodcastRSSParser: NSObject, XMLParserDelegate {
    private struct Item {
        var title: String?
        var guid: String?
        var author: String?
        var publishedAt: Date?
        var enclosureURL: URL?
        var enclosureType: String?
        var enclosureLength: Int64?
        var duration: Double?
        var artworkURL: URL?
    }

    private let feedURL: URL
    private let createdAt: Date
    private var channelTitle: String?
    private var channelAuthor: String?
    private var channelArtworkURL: URL?
    private var currentItem: Item?
    private var completedItems: [Item] = []
    private var text = ""
    private var textElement: String?
    private var parseFailure: PodcastFeedClientError?

    init(feedURL: URL, createdAt: Date) {
        self.feedURL = feedURL
        self.createdAt = createdAt
    }

    func parse(_ data: Data) throws -> LoadedPodcastFeed {
        guard !declaresExternalEntity(data) else { throw PodcastFeedClientError.externalEntity }
        let parser = XMLParser(data: data)
        parser.delegate = self
        parser.shouldProcessNamespaces = true
        parser.shouldReportNamespacePrefixes = true
        parser.shouldResolveExternalEntities = false
        guard parser.parse() else { throw parseFailure ?? PodcastFeedClientError.malformedXML }
        if let parseFailure { throw parseFailure }
        guard let title = bounded(channelTitle, maximum: 1_024) else {
            throw PodcastFeedClientError.invalidMetadata("channel title")
        }
        let author = try optionalText(channelAuthor, maximum: 512, field: "channel author")
        let artworkURL = try optionalHTTPSURL(channelArtworkURL, field: "channel artwork")
        let feedID = try ItemID.derivePodcastFeed(from: feedURL)
        let feed = try PodcastFeed(
            itemID: feedID, canonicalURL: feedURL, title: title, author: author,
            artworkURL: artworkURL, createdAt: Timestamp(createdAt)
        )
        var episodes: [PodcastEpisode] = []
        for item in completedItems {
            guard let enclosureURL = item.enclosureURL else { continue }
            guard PodcastFeedClient.isHTTPS(enclosureURL) else {
                throw PodcastFeedClientError.invalidMetadata("enclosure URL")
            }
            guard let enclosureType = item.enclosureType, supportedAudioTypes.contains(enclosureType) else {
                throw PodcastFeedClientError.unsupportedEnclosureMediaType(item.enclosureType ?? "missing")
            }
            guard let title = bounded(item.title, maximum: 1_024) else {
                throw PodcastFeedClientError.invalidMetadata("episode title")
            }
            let guid = try optionalText(item.guid, maximum: 1_024, field: "episode GUID")
            let author = try optionalText(item.author, maximum: 512, field: "episode author")
            let artworkURL = try optionalHTTPSURL(item.artworkURL, field: "episode artwork")
            let episodeID = try ItemID.derivePodcastEpisode(feedURL: feedURL, rssGUID: guid, enclosureURL: enclosureURL)
            episodes.append(try PodcastEpisode(
                itemID: episodeID, feedID: feedID, feedURL: feedURL, rssGUID: guid,
                title: title, author: author, publishedTime: item.publishedAt.map(Timestamp.init),
                enclosureURL: enclosureURL, enclosureMediaType: enclosureType,
                enclosureByteCount: item.enclosureLength, durationSeconds: item.duration,
                artworkURL: artworkURL, createdAt: Timestamp(createdAt)
            ))
        }
        return LoadedPodcastFeed(feed: feed, episodes: episodes)
    }

    func parser(
        _ parser: XMLParser,
        foundExternalEntityDeclarationWithName name: String,
        publicID: String?,
        systemID: String?
    ) {
        parseFailure = .externalEntity
        parser.abortParsing()
    }

    func parser(_ parser: XMLParser, resolveExternalEntityName name: String, systemID: String?) -> Data? {
        parseFailure = .externalEntity
        parser.abortParsing()
        return nil
    }

    func parser(_ parser: XMLParser, parseErrorOccurred parseError: Error) {
        if parseFailure == nil { parseFailure = .malformedXML }
    }

    func parser(
        _ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]
    ) {
        let name = elementName.lowercased()
        if name == "item" {
            guard completedItems.count < PodcastFeedClient.maximumEpisodeCount else {
                parseFailure = .invalidMetadata("too many episodes"); parser.abortParsing(); return
            }
            currentItem = Item()
        }
        if name == "enclosure", currentItem != nil {
            currentItem?.enclosureURL = attributeDict["url"].flatMap { URL(string: $0.trimmingCharacters(in: .whitespacesAndNewlines)) }
            currentItem?.enclosureType = normalizedMediaType(attributeDict["type"])
            currentItem?.enclosureLength = attributeDict["length"].flatMap(Int64.init).flatMap { $0 > 0 ? $0 : nil }
        } else if name == "image", let href = attributeDict["href"], let url = URL(string: href.trimmingCharacters(in: .whitespacesAndNewlines)) {
            if currentItem != nil { currentItem?.artworkURL = url } else { channelArtworkURL = url }
        }
        if capturesText(name) {
            textElement = name
            text = ""
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        guard textElement != nil else { return }
        guard text.utf8.count + string.utf8.count <= 4_096 else {
            parseFailure = .invalidMetadata("text field too long"); parser.abortParsing(); return
        }
        text.append(string)
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        let name = elementName.lowercased()
        if textElement == name {
            applyText(text, element: name)
            textElement = nil
            text = ""
        }
        if name == "item", let item = currentItem {
            completedItems.append(item)
            currentItem = nil
        }
    }

    private func capturesText(_ name: String) -> Bool {
        switch name {
        case "title", "guid", "pubdate", "published", "updated", "duration", "author", "creator", "managingeditor": true
        default: false
        }
    }

    private func applyText(_ value: String, element: String) {
        let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        if currentItem != nil {
            switch element {
            case "title": currentItem?.title = value
            case "guid": currentItem?.guid = value
            case "author", "creator": currentItem?.author = value
            case "pubdate", "published", "updated": currentItem?.publishedAt = parseDate(value)
            case "duration":
                guard let duration = parseDuration(value), duration.isFinite, duration > 0 else {
                    parseFailure = .invalidMetadata("episode duration")
                    return
                }
                currentItem?.duration = duration
            default: break
            }
        } else {
            switch element {
            case "title": channelTitle = value
            case "author", "creator", "managingeditor": channelAuthor = value
            default: break
            }
        }
    }
}

private let supportedAudioTypes: Set<String> = [
    "audio/aac", "audio/flac", "audio/m4a", "audio/mp3", "audio/mp4", "audio/mpeg",
    "audio/ogg", "audio/opus", "audio/wav", "audio/x-flac", "audio/x-m4a", "audio/x-wav",
]

private func declaresExternalEntity(_ data: Data) -> Bool {
    let document = decodeXMLDocument(data)
    let pattern = #"(?is)<!--.*?-->|<!\[CDATA\[.*?\]\]>|<!\s*(?:doctype|entity)\b"#
    let tokenPattern = #"(?is)^<!\s*(?:doctype|entity)\b"#
    guard let expression = try? NSRegularExpression(pattern: pattern) else { return false }
    let range = NSRange(document.startIndex..<document.endIndex, in: document)
    return expression.matches(in: document, range: range).contains { match in
        guard let range = Range(match.range, in: document) else { return false }
        return document[range].range(of: tokenPattern, options: .regularExpression) != nil
    }
}

private func decodeXMLDocument(_ data: Data) -> String {
    let prefix = Array(data.prefix(4))
    if prefix.starts(with: [0x00, 0x00, 0xFE, 0xFF]) || prefix.starts(with: [0xFF, 0xFE, 0x00, 0x00]) {
        return String(data: data, encoding: .utf32) ?? ""
    }
    if prefix.starts(with: [0xFE, 0xFF]) || prefix.starts(with: [0xFF, 0xFE]) {
        return String(data: data, encoding: .utf16) ?? ""
    }
    if prefix.starts(with: [0x00, 0x00, 0x00, 0x3C]) {
        return String(data: data, encoding: .utf32BigEndian) ?? ""
    }
    if prefix.starts(with: [0x3C, 0x00, 0x00, 0x00]) {
        return String(data: data, encoding: .utf32LittleEndian) ?? ""
    }
    if prefix.starts(with: [0x00, 0x3C]) {
        return String(data: data, encoding: .utf16BigEndian) ?? ""
    }
    if prefix.count >= 2, prefix[0] == 0x3C, prefix[1] == 0x00 {
        return String(data: data, encoding: .utf16LittleEndian) ?? ""
    }
    return String(decoding: data, as: UTF8.self)
}

private func normalizedMediaType(_ value: String?) -> String? {
    value?.split(separator: ";", maxSplits: 1).first.map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
}

private func bounded(_ value: String?, maximum: Int) -> String? {
    guard let value else { return nil }
    let normalized = value.precomposedStringWithCanonicalMapping.trimmingCharacters(in: .whitespacesAndNewlines)
    return !normalized.isEmpty && normalized.utf8.count <= maximum ? normalized : nil
}

private func optionalText(_ value: String?, maximum: Int, field: String) throws -> String? {
    guard let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
    guard let bounded = bounded(value, maximum: maximum) else { throw PodcastFeedClientError.invalidMetadata(field) }
    return bounded
}

private func optionalHTTPSURL(_ value: URL?, field: String) throws -> URL? {
    guard let value else { return nil }
    guard PodcastFeedClient.isHTTPS(value) else { throw PodcastFeedClientError.invalidMetadata(field) }
    return value
}

private func parseDate(_ value: String) -> Date? {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
    return formatter.date(from: value)
}

private func parseDuration(_ value: String) -> Double? {
    let fields = value.split(separator: ":", omittingEmptySubsequences: false)
    guard fields.count > 1 else { return Double(value) }
    guard fields.count <= 3 else { return nil }
    let components = fields.compactMap { Double($0) }
    guard components.count == fields.count, components.allSatisfy({ $0.isFinite && $0 >= 0 }) else { return nil }
    let duration = components.reversed().enumerated().reduce(0) { $0 + $1.element * pow(60, Double($1.offset)) }
    return duration.isFinite ? duration : nil
}
