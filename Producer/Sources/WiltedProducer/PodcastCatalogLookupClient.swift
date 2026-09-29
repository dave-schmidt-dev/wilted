import Foundation

/// A verified podcast show returned by Apple's ID lookup endpoint.
public struct PodcastCatalogShow: Equatable, Sendable {
    public let collectionID: Int
    public let title: String
    public let feedURL: URL

    public init(collectionID: Int, title: String, feedURL: URL) {
        self.collectionID = collectionID
        self.title = title
        self.feedURL = feedURL
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

/// Bounded anonymous Apple directory lookup for an already-pasted show ID.
public struct PodcastCatalogLookupClient: Sendable {
    public static let maximumResponseBytes = 256 * 1_024
    public static let timeout = Duration.seconds(10)

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
        do {
            return try await withThrowingTaskGroup(of: PodcastCatalogShow.self) { group in
                defer { group.cancelAll() }
                group.addTask {
                    try Task.checkCancellation()
                    let response = try await loader.load(request, maximumBytes: Self.maximumResponseBytes)
                    try Task.checkCancellation()
                    guard response.url == request else { throw PodcastCatalogLookupError.unsafeRedirect }
                    guard (200..<300).contains(response.statusCode) else { throw PodcastCatalogLookupError.invalidResponse }
                    guard response.data.count <= Self.maximumResponseBytes else { throw PodcastCatalogLookupError.responseTooLarge }
                    return try Self.decode(response.data, requestedID: collectionID)
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

    static func lookupURL(collectionID: Int) -> URL {
        var components = URLComponents(string: "https://itunes.apple.com/lookup")!
        components.queryItems = [URLQueryItem(name: "id", value: String(collectionID)),
                                 URLQueryItem(name: "entity", value: "podcast")]
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

        enum CodingKeys: String, CodingKey {
            case collectionID = "collectionId"
            case collectionName
            case feedURL = "feedUrl"
            case kind
        }
    }
}
