import Foundation

/// A verified podcast show returned by Apple's ID lookup or search endpoint.
public struct PodcastCatalogShow: Equatable, Sendable {
    public let collectionID: Int
    public let title: String
    public let feedURL: URL
    /// The publisher's name, when Apple supplies one. Search results only.
    public let author: String?
    /// An HTTPS cover image, when Apple supplies one. Search results only.
    public let artworkURL: URL?

    public init(collectionID: Int, title: String, feedURL: URL, author: String? = nil, artworkURL: URL? = nil) {
        self.collectionID = collectionID
        self.title = title
        self.feedURL = feedURL
        self.author = author
        self.artworkURL = artworkURL
    }
}

public enum PodcastCatalogLookupError: Error, Equatable, LocalizedError, Sendable {
    case invalidCollectionID
    case invalidResponse
    case responseTooLarge
    case timedOut
    case unsafeRedirect
    case resultNotFound
    case cancelled

    public var errorDescription: String? {
        switch self {
        case .invalidCollectionID: "That Apple Podcasts address is not a supported show link."
        case .invalidResponse: "Apple Podcasts returned an invalid show record."
        case .responseTooLarge: "Apple Podcasts returned too much data."
        case .timedOut: "Apple Podcasts lookup timed out."
        case .unsafeRedirect: "Apple Podcasts redirected the lookup unexpectedly."
        case .resultNotFound: "Apple Podcasts did not find that podcast show."
        case .cancelled: "Apple Podcasts lookup was cancelled."
        }
    }
}

/// Bounded anonymous Apple directory lookup for an already-pasted show ID,
/// and a bounded anonymous search by name.
public struct PodcastCatalogLookupClient: Sendable {
    public static let maximumResponseBytes = 256 * 1_024
    public static let timeout = Duration.seconds(10)
    /// Results requested per search. Apple allows 1 to 200 (default 50); 25
    /// fills a results list without approaching `maximumResponseBytes`.
    public static let defaultSearchLimit = 25
    /// Quiet time callers wait after the last keystroke before calling `search`.
    /// Apple documents roughly 20 calls per minute (subject to change), so a
    /// search must not fire per keystroke; one second of quiet keeps a typing
    /// session well under that ceiling.
    public static let searchDebounce = Duration.seconds(1)

    private let loader: any PodcastFeedLoading
    private let timeout: Duration

    public init(
        loader: any PodcastFeedLoading = URLSessionPodcastFeedLoader(),
        timeout: Duration = PodcastCatalogLookupClient.timeout
    ) {
        self.loader = loader
        self.timeout = timeout
    }

    public func lookup(collectionID: Int) async throws -> PodcastCatalogShow {
        guard collectionID > 0 else { throw PodcastCatalogLookupError.invalidCollectionID }
        let request = Self.lookupURL(collectionID: collectionID)
        return try await perform(request) { try Self.decode($0, requestedID: collectionID) }
    }

    /// Searches Apple's podcast directory by name. Results without an HTTPS feed
    /// URL are dropped; a blank term makes no request and returns no results.
    public func search(
        term: String,
        limit: Int = PodcastCatalogLookupClient.defaultSearchLimit
    ) async throws -> [PodcastCatalogShow] {
        let trimmed = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        let request = Self.searchURL(term: trimmed, limit: limit)
        return try await perform(request) { try Self.decodeSearch($0) }
    }

    private func perform<Value: Sendable>(
        _ request: URL,
        decode: @escaping @Sendable (Data) throws -> Value
    ) async throws -> Value {
        do {
            return try await withThrowingTaskGroup(of: Value.self) { group in
                defer { group.cancelAll() }
                group.addTask {
                    try Task.checkCancellation()
                    let response = try await loader.load(request, maximumBytes: Self.maximumResponseBytes)
                    try Task.checkCancellation()
                    guard response.url == request else { throw PodcastCatalogLookupError.unsafeRedirect }
                    guard (200..<300).contains(response.statusCode) else { throw PodcastCatalogLookupError.invalidResponse }
                    guard response.data.count <= Self.maximumResponseBytes else { throw PodcastCatalogLookupError.responseTooLarge }
                    return try decode(response.data)
                }
                group.addTask {
                    try await Task.sleep(for: timeout)
                    throw PodcastCatalogLookupError.timedOut
                }
                guard let result = try await group.next() else { throw PodcastCatalogLookupError.invalidResponse }
                return result
            }
        } catch is CancellationError {
            throw PodcastCatalogLookupError.cancelled
        } catch let error as PodcastCatalogLookupError {
            throw error
        } catch {
            if Task.isCancelled { throw PodcastCatalogLookupError.cancelled }
            throw PodcastCatalogLookupError.invalidResponse
        }
    }

    public static func collectionID(fromApplePodcastURL url: URL) -> Int? {
        guard url.scheme?.lowercased() == "https", url.host?.lowercased() == "podcasts.apple.com",
              url.user == nil, url.password == nil else { return nil }
        let components = url.pathComponents.filter { $0 != "/" }
        guard components.count >= 4, components[1].lowercased() == "podcast",
              let last = components.last, last.lowercased().hasPrefix("id"),
              let id = Int(last.dropFirst(2)), id > 0, String(id) == String(last.dropFirst(2)) else { return nil }
        return id
    }

    public static func lookupURL(collectionID: Int) -> URL {
        var components = URLComponents(string: "https://itunes.apple.com/lookup")!
        components.queryItems = [URLQueryItem(name: "id", value: String(collectionID)),
                                 URLQueryItem(name: "entity", value: "podcast")]
        return components.url!
    }

    static func searchURL(term: String, limit: Int) -> URL {
        var components = URLComponents(string: "https://itunes.apple.com/search")!
        components.queryItems = [URLQueryItem(name: "term", value: term),
                                 URLQueryItem(name: "media", value: "podcast"),
                                 URLQueryItem(name: "entity", value: "podcast"),
                                 URLQueryItem(name: "limit", value: String(min(max(limit, 1), 200)))]
        return components.url!
    }

    private static func decode(_ data: Data, requestedID: Int) throws -> PodcastCatalogShow {
        let payload = try JSONDecoder().decode(Response.self, from: data)
        guard let result = payload.results.first(where: {
            $0.collectionID == requestedID && $0.kind?.lowercased() == "podcast"
        }), let title = result.collectionName?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty,
           let feedURL = result.feedURL, isSafeFeedURL(feedURL) else {
            throw PodcastCatalogLookupError.resultNotFound
        }
        return PodcastCatalogShow(collectionID: requestedID, title: title, feedURL: feedURL)
    }

    private static func decodeSearch(_ data: Data) throws -> [PodcastCatalogShow] {
        let payload = try JSONDecoder().decode(Response.self, from: data)
        var seen = Set<Int>()
        var shows: [PodcastCatalogShow] = []
        for result in payload.results {
            guard result.kind?.lowercased() == "podcast", let id = result.collectionID, id > 0,
                  let title = result.collectionName?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty,
                  let feedURL = result.feedURL, isSafeFeedURL(feedURL), seen.insert(id).inserted else { continue }
            let author = result.artistName?.trimmingCharacters(in: .whitespacesAndNewlines)
            let artwork = result.artworkURL.flatMap(URL.init(string:)).flatMap { isSafeFeedURL($0) ? $0 : nil }
            shows.append(PodcastCatalogShow(
                collectionID: id, title: title, feedURL: feedURL,
                author: author?.isEmpty == false ? author : nil, artworkURL: artwork
            ))
        }
        return shows
    }

    private static func isSafeFeedURL(_ url: URL) -> Bool {
        url.scheme?.lowercased() == "https" && url.host != nil && url.user == nil && url.password == nil
    }

    private struct Response: Decodable {
        let results: [Result]
    }

    private struct Result: Decodable {
        let collectionID: Int?
        let collectionName: String?
        let feedURL: URL?
        let kind: String?
        let artistName: String?
        let artworkURL: String?

        enum CodingKeys: String, CodingKey {
            case collectionID = "collectionId"
            case collectionName
            case feedURL = "feedUrl"
            case kind
            case artistName
            case artworkURL = "artworkUrl600"
        }
    }
}
