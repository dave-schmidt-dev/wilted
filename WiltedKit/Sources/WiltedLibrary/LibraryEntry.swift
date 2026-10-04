import Foundation
import WiltedDomain

/// Kind-specific payload of a `podcast.episode` entry.
public struct PodcastEpisodePayload: Codable, Sendable, Equatable {
    public let enclosureURL: URL
    public let feedURL: URL?
    public let rssGUID: String?
    public let episodeLink: URL?

    public init(enclosureURL: URL, feedURL: URL? = nil, rssGUID: String? = nil, episodeLink: URL? = nil) {
        self.enclosureURL = enclosureURL
        self.feedURL = feedURL
        self.rssGUID = rssGUID
        self.episodeLink = episodeLink
    }

    /// A fresh encoder with a fixed key order, so equal payloads always encode to equal bytes.
    static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }
}

/// One item in the synchronized library, independent of its kind.
public struct LibraryEntry: Codable, Sendable, Equatable, Identifiable {
    /// Exclusive upper bound for `payload`, in bytes (64 KB).
    public static let payloadLimitBytes = 64 * 1024

    public let id: ItemID
    public let kind: LibraryKind
    public let sourceID: ItemID
    public let title: String
    public let summary: String
    public let publishedAt: Date
    public let durationSeconds: Double?
    public let artworkRef: String?
    public let removal: LibraryRemoval
    /// When the Mac retired or dismissed the entry; nil while live, and nil for entries
    /// published before this field existed (decoders treat an absent key as nil).
    public let removedAt: Date?
    /// Kind-specific JSON, strictly smaller than `payloadLimitBytes`.
    public let payload: Data

    public init(
        id: ItemID,
        kind: LibraryKind,
        sourceID: ItemID,
        title: String,
        summary: String,
        publishedAt: Date,
        durationSeconds: Double? = nil,
        artworkRef: String? = nil,
        removal: LibraryRemoval = .none,
        removedAt: Date? = nil,
        payload: Data = Data("{}".utf8)
    ) throws {
        guard payload.count < Self.payloadLimitBytes else {
            throw DomainError.invalidValue(
                field: "payload",
                reason: "must be smaller than \(Self.payloadLimitBytes) bytes"
            )
        }
        if let durationSeconds {
            guard durationSeconds.isFinite, durationSeconds >= 0 else {
                throw DomainError.invalidValue(field: "durationSeconds", reason: "must be finite and non-negative")
            }
        }
        self.id = id
        self.kind = kind
        self.sourceID = sourceID
        self.title = title
        self.summary = summary
        self.publishedAt = publishedAt
        self.durationSeconds = durationSeconds
        self.artworkRef = artworkRef
        self.removal = removal
        self.removedAt = removedAt
        self.payload = payload
    }

    private enum CodingKeys: String, CodingKey {
        case id, kind, sourceID, title, summary, publishedAt, durationSeconds, artworkRef, removal, removedAt, payload
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            id: c.decode(ItemID.self, forKey: .id),
            kind: c.decode(LibraryKind.self, forKey: .kind),
            sourceID: c.decode(ItemID.self, forKey: .sourceID),
            title: c.decode(String.self, forKey: .title),
            summary: c.decode(String.self, forKey: .summary),
            publishedAt: c.decode(Date.self, forKey: .publishedAt),
            durationSeconds: c.decodeIfPresent(Double.self, forKey: .durationSeconds),
            artworkRef: c.decodeIfPresent(String.self, forKey: .artworkRef),
            removal: c.decode(LibraryRemoval.self, forKey: .removal),
            removedAt: c.decodeIfPresent(Date.self, forKey: .removedAt),
            payload: c.decode(Data.self, forKey: .payload)
        )
    }

    /// Returns a copy with a different removal state and removal date (nil when unknown).
    public func with(removal: LibraryRemoval, removedAt: Date? = nil) throws -> LibraryEntry {
        try LibraryEntry(
            id: id, kind: kind, sourceID: sourceID, title: title, summary: summary,
            publishedAt: publishedAt, durationSeconds: durationSeconds, artworkRef: artworkRef,
            removal: removal, removedAt: removedAt, payload: payload
        )
    }

    /// Applies a removal-only change: keeps a known `removedAt` while the entry stays
    /// removed, and clears it when the entry returns to live.
    public func applyingRemoval(_ state: LibraryRemoval) throws -> LibraryEntry {
        try with(removal: state, removedAt: state == .none ? nil : removedAt)
    }

    /// Builds a `podcast.episode` entry from its typed payload. The payload is encoded with
    /// sorted keys: `JSONEncoder`'s default key order varies between encodes, and entry
    /// equality (and so `LibraryStateDiffer`) compares payload bytes, so an unsorted payload
    /// would re-send an unchanged entry on every pass.
    public static func podcastEpisode(
        id: ItemID,
        sourceID: ItemID,
        title: String,
        summary: String,
        publishedAt: Date,
        durationSeconds: Double? = nil,
        artworkRef: String? = nil,
        removal: LibraryRemoval = .none,
        removedAt: Date? = nil,
        payload: PodcastEpisodePayload
    ) throws -> LibraryEntry {
        try LibraryEntry(
            id: id, kind: .podcastEpisode, sourceID: sourceID, title: title, summary: summary,
            publishedAt: publishedAt, durationSeconds: durationSeconds, artworkRef: artworkRef,
            removal: removal, removedAt: removedAt, payload: PodcastEpisodePayload.encoder.encode(payload)
        )
    }

    /// Decodes the payload as a podcast episode; throws for any other kind.
    public func podcastEpisodePayload() throws -> PodcastEpisodePayload {
        guard kind == .podcastEpisode else {
            throw DomainError.invalidValue(field: "kind", reason: "expected \(LibraryKind.podcastEpisode)")
        }
        return try JSONDecoder().decode(PodcastEpisodePayload.self, from: payload)
    }
}
