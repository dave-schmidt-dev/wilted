import Foundation

/// Open, string-backed kind of a library entry or source.
///
/// Unknown kinds decode and re-encode unchanged so an older reader never drops
/// entries written by a newer publisher.
public struct LibraryKind: RawRepresentable, Codable, Hashable, Sendable, ExpressibleByStringLiteral,
    CustomStringConvertible
{
    public let rawValue: String

    public init(rawValue: String) { self.rawValue = rawValue }
    public init(stringLiteral value: String) { self.init(rawValue: value) }

    public init(from decoder: Decoder) throws {
        self.init(rawValue: try decoder.singleValueContainer().decode(String.self))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    public var description: String { rawValue }

    /// A podcast episode; the first kind the library carries.
    public static let podcastEpisode: LibraryKind = "podcast.episode"
    /// A podcast feed source.
    public static let podcastFeed: LibraryKind = "podcast.feed"
    /// A single article prepared for listening.
    public static let article: LibraryKind = "article"
    /// A followed feed of articles (no audio enclosures).
    public static let articleFeed: LibraryKind = "article.feed"
    /// One volume of an audiobook.
    public static let audiobook: LibraryKind = "audiobook"
}

/// Removal state of an entry. The Mac is the single writer of this value.
public enum LibraryRemoval: String, Codable, Sendable, Equatable, CaseIterable {
    case none
    case retired
    case dismissed
}
