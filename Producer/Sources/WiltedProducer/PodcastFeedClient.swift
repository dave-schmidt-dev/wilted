import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import WiltedDomain

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

