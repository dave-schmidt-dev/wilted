import Foundation
import WiltedDomain

/// Parses one optional Podcasting 2.0 linked chapter source.
enum PodcastChapterSourceParser {
    static func parse(_ attributes: [String: String], relativeTo feedURL: URL) -> PodcastChapterSource? {
        guard let href = attributes["url"]?.trimmingCharacters(in: .whitespacesAndNewlines),
              !href.isEmpty,
              let relative = URL(string: href),
              let url = URL(string: relative.absoluteString, relativeTo: feedURL)?.absoluteURL,
              PodcastFeedClient.isHTTPS(url),
              let type = attributes["type"]?.trimmingCharacters(in: .whitespacesAndNewlines) else { return nil }
        return try? PodcastChapterSource(url: url, mediaType: type)
    }
}
