import Foundation

/// A publisher's optional Podcasting 2.0 JSON chapter document.
public struct PodcastChapterSource: Codable, Equatable, Sendable {
    public static let jsonMediaType = "application/json+chapters"
    public static let maximumURLBytes = 4_096

    public let url: URL
    public let mediaType: String

    public init(url: URL, mediaType: String) throws {
        let normalized = try ItemID.canonicalURL(url)
        let type = mediaType.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard normalized.scheme?.lowercased() == "https", normalized.host?.isEmpty == false,
              normalized.user == nil, normalized.password == nil,
              normalized.absoluteString.utf8.count <= Self.maximumURLBytes,
              type == Self.jsonMediaType else {
            throw DomainError.invalidValue(field: "podcastChapterSource", reason: "must be a bounded HTTPS JSON chapters URL")
        }
        self.url = normalized
        self.mediaType = type
    }

    private enum CodingKeys: CodingKey { case url, mediaType }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(url: c.decode(URL.self, forKey: .url), mediaType: c.decode(String.self, forKey: .mediaType))
    }
}

/// A podcast chapter start, in seconds on the clock of its source audio.
public struct PodcastChapterMark: Codable, Equatable, Sendable {
    public let title: String
    public let startSeconds: Double

    public init(title: String, startSeconds: Double) {
        self.title = title
        self.startSeconds = startSeconds
    }
}
