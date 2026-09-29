import Foundation
import WiltedProducer

struct CancelledPodcastFeedLoader: PodcastFeedLoading {
    func load(_ url: URL, maximumBytes: Int) async throws -> PodcastFeedHTTPResponse {
        throw PodcastFeedClientError.cancelled
    }
}

struct URLRoutingPodcastFeedLoader: PodcastFeedLoading {
    let documents: [URL: Data]

    func load(_ url: URL, maximumBytes: Int) async throws -> PodcastFeedHTTPResponse {
        guard let body = documents[url] else { throw URLError(.cannotConnectToHost) }
        return PodcastFeedHTTPResponse(url: url, statusCode: 200, data: body)
    }
}

actor SequencedPodcastFeedLoader: PodcastFeedLoading {
    private let documents: [Data]
    private var nextIndex = 0

    init(documents: [Data]) { self.documents = documents }

    func load(_ url: URL, maximumBytes: Int) async throws -> PodcastFeedHTTPResponse {
        let index = min(nextIndex, documents.count - 1)
        nextIndex += 1
        return PodcastFeedHTTPResponse(url: url, statusCode: 200, data: documents[index])
    }
}
