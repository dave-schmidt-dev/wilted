import Foundation

#if canImport(WiltedProducer)
import WiltedProducer
#endif

extension WiltedMacModel {
#if canImport(WiltedProducer)
    static func subscriptionIntakeFixtureClient(
        enabled: Bool, fallback: PodcastFeedClient
    ) -> PodcastFeedClient {
        enabled ? PodcastFeedClient(loader: WiltedMacSubscriptionIntakeFixtureLoader()) : fallback
    }

    /// Starts one bounded subscription request. The stored setting controls
    /// only the first metadata window; it never requests audio or queue work.
    func startPodcastSubscriptionIntake(_ url: URL, initialMetadataCount: Int? = nil) {
        guard url.scheme?.lowercased() == "https", url.host != nil else {
            podcastFeedDraftStatus = "Enter a complete HTTPS podcast feed URL."
            return
        }
        guard !isClosingTemporaryState else { return }
        let limit = initialMetadataCount ?? automationSettings.initialEpisodeMetadataCount
        guard podcastRefreshTask == nil else {
            // A classifier can finish while a manual refresh owns the single
            // fetch slot. Do not overwrite an active subscription request's
            // status, but settle this classifier's local handoff visibly.
            if podcastSubscriptionRequestID == nil {
                isCheckingPodcastSubscription = false
                pendingPodcastSubscriptionInitialMetadataCount = nil
                let showName = url.host ?? "this podcast"
                podcastFeedDraftStatus = "A refresh is already running for \(showName) (\(limit) initial episodes). Try again when it finishes."
            }
            return
        }
        guard WiltedAutomationSettings.validInitialEpisodeMetadataCount(limit) != nil else {
            podcastFeedDraftStatus = "Choose between 1 and 100 initial episodes."
            return
        }
        let requestID = UUID()
        podcastSubscriptionRequestID = requestID
        isCheckingPodcastSubscription = true
        podcastFeedDraftStatus = "Adding podcast feed…"
        pendingPodcastSubscriptionInitialMetadataCount = nil
        startPodcastRefresh(
            urls: [url], subscribing: true, initialMetadataLimit: limit, requestID: requestID
        )
    }
#endif
}

private struct WiltedMacSubscriptionIntakeFixtureLoader: PodcastFeedLoading {
    func load(_ url: URL, maximumBytes _: Int) async throws -> PodcastFeedHTTPResponse {
        let items = (1...26).map { index in
            "<item><guid>fixture-\(index)</guid><title>Fixture episode \(index)</title>"
                + "<pubDate>Mon, \(String(format: "%02d", index)) Jan 2024 12:00:00 GMT</pubDate>"
                + "<enclosure url=\"https://media.example.test/fixture-\(index).mp3\" type=\"audio/mpeg\" /></item>"
        }.joined()
        let xml = "<rss version=\"2.0\"><channel><title>Fixture intake</title>\(items)</channel></rss>"
        return PodcastFeedHTTPResponse(url: url, statusCode: 200, data: Data(xml.utf8))
    }
}
