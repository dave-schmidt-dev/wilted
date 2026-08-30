import Foundation

private func validatePodcastText(_ value: String, field: String, maxLength: Int) throws {
    guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
          value.count <= maxLength
    else {
        throw DomainError.invalidValue(
            field: field,
            reason: "must contain 1...\(maxLength) characters"
        )
    }
}

private func validatePodcastURL(_ url: URL, field: String) throws -> URL {
    let normalized = try ItemID.canonicalURL(url)
    guard normalized.absoluteString.utf8.count <= 4_096 else {
        throw DomainError.invalidValue(field: field, reason: "must contain at most 4096 UTF-8 bytes")
    }
    return normalized
}

/// A subscribed podcast source identified by its canonical HTTPS feed URL.
public struct PodcastFeed: Codable, Equatable, Sendable {
    public let itemID: ItemID
    public let canonicalURL: URL
    public let title: String
    public let author: String?
    public let artworkURL: URL?
    public let createdAt: Timestamp

    public init(
        itemID: ItemID,
        canonicalURL: URL,
        title: String,
        author: String? = nil,
        artworkURL: URL? = nil,
        createdAt: Timestamp
    ) throws {
        let normalizedURL = try validatePodcastURL(canonicalURL, field: "canonicalURL")
        guard itemID == (try ItemID.derivePodcastFeed(from: normalizedURL)) else {
            throw DomainError.invalidValue(field: "itemID", reason: "must match the canonical feed URL identity")
        }
        try validatePodcastText(title, field: "title", maxLength: 1_024)
        if let author { try validatePodcastText(author, field: "author", maxLength: 512) }
        let normalizedArtworkURL = try artworkURL.map { try validatePodcastURL($0, field: "artworkURL") }

        self.itemID = itemID
        self.canonicalURL = normalizedURL
        self.title = title
        self.author = author
        self.artworkURL = normalizedArtworkURL
        self.createdAt = createdAt
    }

    private enum CodingKeys: CodingKey {
        case itemID, canonicalURL, title, author, artworkURL, createdAt
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            itemID: container.decode(ItemID.self, forKey: .itemID),
            canonicalURL: container.decode(URL.self, forKey: .canonicalURL),
            title: container.decode(String.self, forKey: .title),
            author: container.decodeIfPresent(String.self, forKey: .author),
            artworkURL: container.decodeIfPresent(URL.self, forKey: .artworkURL),
            createdAt: container.decode(Timestamp.self, forKey: .createdAt)
        )
    }
}

/// Podcast episode metadata whose identity is independent from mutable enclosure URLs when a GUID exists.
public struct PodcastEpisode: Codable, Equatable, Sendable {
    public let itemID: ItemID
    public let feedID: ItemID
    public let feedURL: URL
    public let rssGUID: String?
    public let title: String
    public let author: String?
    public let publishedTime: Timestamp?
    public let enclosureURL: URL
    public let enclosureMediaType: String
    public let enclosureByteCount: Int64?
    public let durationSeconds: Double?
    public let artworkURL: URL?
    public let createdAt: Timestamp

    public init(
        itemID: ItemID,
        feedID: ItemID,
        feedURL: URL,
        rssGUID: String? = nil,
        title: String,
        author: String? = nil,
        publishedTime: Timestamp? = nil,
        enclosureURL: URL,
        enclosureMediaType: String,
        enclosureByteCount: Int64? = nil,
        durationSeconds: Double? = nil,
        artworkURL: URL? = nil,
        createdAt: Timestamp
    ) throws {
        let normalizedFeedURL = try validatePodcastURL(feedURL, field: "feedURL")
        let normalizedEnclosureURL = try validatePodcastURL(enclosureURL, field: "enclosureURL")
        guard feedID == (try ItemID.derivePodcastFeed(from: normalizedFeedURL)) else {
            throw DomainError.invalidValue(field: "feedID", reason: "must match the canonical feed URL identity")
        }
        guard itemID == (try ItemID.derivePodcastEpisode(
            feedURL: normalizedFeedURL,
            rssGUID: rssGUID,
            enclosureURL: normalizedEnclosureURL
        )) else {
            throw DomainError.invalidValue(field: "itemID", reason: "must match the podcast episode identity")
        }
        try validatePodcastText(title, field: "title", maxLength: 1_024)
        if let author { try validatePodcastText(author, field: "author", maxLength: 512) }
        guard enclosureMediaType.range(
            of: #"^audio/[a-z0-9][a-z0-9!#$&^_.+-]*$"#,
            options: .regularExpression
        ) != nil else {
            throw DomainError.invalidValue(field: "enclosureMediaType", reason: "must be a lowercase audio media type")
        }
        if let enclosureByteCount, enclosureByteCount <= 0 {
            throw DomainError.invalidValue(field: "enclosureByteCount", reason: "must be greater than zero")
        }
        if let durationSeconds, !durationSeconds.isFinite || durationSeconds <= 0 {
            throw DomainError.invalidValue(field: "durationSeconds", reason: "must be finite and greater than zero")
        }
        let normalizedArtworkURL = try artworkURL.map { try validatePodcastURL($0, field: "artworkURL") }

        self.itemID = itemID
        self.feedID = feedID
        self.feedURL = normalizedFeedURL
        self.rssGUID = rssGUID?.precomposedStringWithCanonicalMapping
            .trimmingCharacters(in: .whitespacesAndNewlines)
        self.title = title
        self.author = author
        self.publishedTime = publishedTime
        self.enclosureURL = normalizedEnclosureURL
        self.enclosureMediaType = enclosureMediaType
        self.enclosureByteCount = enclosureByteCount
        self.durationSeconds = durationSeconds
        self.artworkURL = normalizedArtworkURL
        self.createdAt = createdAt
    }

    private enum CodingKeys: CodingKey {
        case itemID, feedID, feedURL, rssGUID, title, author, publishedTime, enclosureURL
        case enclosureMediaType, enclosureByteCount, durationSeconds, artworkURL, createdAt
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            itemID: container.decode(ItemID.self, forKey: .itemID),
            feedID: container.decode(ItemID.self, forKey: .feedID),
            feedURL: container.decode(URL.self, forKey: .feedURL),
            rssGUID: container.decodeIfPresent(String.self, forKey: .rssGUID),
            title: container.decode(String.self, forKey: .title),
            author: container.decodeIfPresent(String.self, forKey: .author),
            publishedTime: container.decodeIfPresent(Timestamp.self, forKey: .publishedTime),
            enclosureURL: container.decode(URL.self, forKey: .enclosureURL),
            enclosureMediaType: container.decode(String.self, forKey: .enclosureMediaType),
            enclosureByteCount: container.decodeIfPresent(Int64.self, forKey: .enclosureByteCount),
            durationSeconds: container.decodeIfPresent(Double.self, forKey: .durationSeconds),
            artworkURL: container.decodeIfPresent(URL.self, forKey: .artworkURL),
            createdAt: container.decode(Timestamp.self, forKey: .createdAt)
        )
    }
}

public struct Article: Codable, Equatable, Sendable {
    public let itemID: ItemID
    public let canonicalURL: URL
    public let title: String
    public let source: String
    public let author: String?
    public let publishedTime: Timestamp?
    public let createdAt: Timestamp
    public let isDeleted: Bool

    public init(
        itemID: ItemID,
        canonicalURL: URL,
        title: String,
        source: String,
        author: String? = nil,
        publishedTime: Timestamp? = nil,
        createdAt: Timestamp,
        isDeleted: Bool = false
    ) throws {
        let normalized = try ItemID.canonicalURL(canonicalURL)
        guard normalized.absoluteString.utf8.count <= 4_096 else {
            throw DomainError.invalidValue(field: "canonicalURL", reason: "must contain at most 4096 UTF-8 bytes")
        }
        guard itemID == (try ItemID.derive(from: normalized)) else {
            throw DomainError.invalidValue(field: "itemID", reason: "must match the canonical URL identity")
        }
        guard !title.isEmpty, title.count <= 1_024 else {
            throw DomainError.invalidValue(field: "title", reason: "must contain 1...1024 characters")
        }
        guard !source.isEmpty, source.count <= 512 else {
            throw DomainError.invalidValue(field: "source", reason: "must contain 1...512 characters")
        }
        guard author?.count ?? 0 <= 512 else {
            throw DomainError.invalidValue(field: "author", reason: "must contain at most 512 characters")
        }
        self.itemID = itemID
        self.canonicalURL = normalized
        self.title = title
        self.source = source
        self.author = author
        self.publishedTime = publishedTime
        self.createdAt = createdAt
        self.isDeleted = isDeleted
    }

    private enum CodingKeys: CodingKey {
        case itemID, canonicalURL, title, source, author, publishedTime, createdAt, isDeleted
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            itemID: container.decode(ItemID.self, forKey: .itemID),
            canonicalURL: container.decode(URL.self, forKey: .canonicalURL),
            title: container.decode(String.self, forKey: .title),
            source: container.decode(String.self, forKey: .source),
            author: container.decodeIfPresent(String.self, forKey: .author),
            publishedTime: container.decodeIfPresent(Timestamp.self, forKey: .publishedTime),
            createdAt: container.decode(Timestamp.self, forKey: .createdAt),
            isDeleted: container.decode(Bool.self, forKey: .isDeleted)
        )
    }
}

public enum RevisionReadiness: String, Codable, Sendable { case ready }

/// An immutable, durable audio value. Non-ready candidates are not representable.
public struct AudioRevision: Codable, Equatable, Sendable {
    public let itemID: ItemID
    public let revisionID: RevisionID
    public let durationSeconds: Double
    public let byteCount: Int64
    public let contentHash: String
    public let mediaType: String
    public let createdAt: Timestamp
    public let schemaVersion: Int
    public let readiness: RevisionReadiness

    public init(
        itemID: ItemID,
        revisionID: RevisionID,
        durationSeconds: Double,
        byteCount: Int64,
        contentHash: String,
        mediaType: String,
        createdAt: Timestamp,
        schemaVersion: Int
    ) throws {
        guard durationSeconds.isFinite, durationSeconds > 0 else {
            throw DomainError.invalidValue(field: "durationSeconds", reason: "must be finite and greater than zero")
        }
        guard byteCount > 0 else {
            throw DomainError.invalidValue(field: "byteCount", reason: "must be greater than zero")
        }
        guard contentHash.range(of: #"^sha256:[0-9a-f]{64}$"#, options: .regularExpression) != nil else {
            throw DomainError.invalidValue(field: "contentHash", reason: "must be a lowercase SHA-256 value")
        }
        guard mediaType.range(
            of: #"^[a-z0-9][a-z0-9!#$&^_.+-]*/[a-z0-9][a-z0-9!#$&^_.+-]*$"#,
            options: .regularExpression
        ) != nil else {
            throw DomainError.invalidValue(field: "mediaType", reason: "must be a valid lowercase media type")
        }
        guard schemaVersion > 0 else {
            throw DomainError.invalidValue(field: "schemaVersion", reason: "must be greater than zero")
        }
        self.itemID = itemID
        self.revisionID = revisionID
        self.durationSeconds = durationSeconds
        self.byteCount = byteCount
        self.contentHash = contentHash
        self.mediaType = mediaType
        self.createdAt = createdAt
        self.schemaVersion = schemaVersion
        readiness = .ready
    }

    private enum CodingKeys: CodingKey {
        case itemID, revisionID, durationSeconds, byteCount, contentHash, mediaType, createdAt, schemaVersion, readiness
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let readiness = try container.decode(RevisionReadiness.self, forKey: .readiness)
        guard readiness == .ready else {
            throw DomainError.invalidValue(field: "readiness", reason: "only ready revisions are durable")
        }
        try self.init(
            itemID: container.decode(ItemID.self, forKey: .itemID),
            revisionID: container.decode(RevisionID.self, forKey: .revisionID),
            durationSeconds: container.decode(Double.self, forKey: .durationSeconds),
            byteCount: container.decode(Int64.self, forKey: .byteCount),
            contentHash: container.decode(String.self, forKey: .contentHash),
            mediaType: container.decode(String.self, forKey: .mediaType),
            createdAt: container.decode(Timestamp.self, forKey: .createdAt),
            schemaVersion: container.decode(Int.self, forKey: .schemaVersion)
        )
    }
}

public enum PlaybackIntent: String, Codable, Sendable { case progress, rewind, restart }

public struct PlaybackState: Codable, Equatable, Sendable {
    public let itemID: ItemID
    public let revisionID: RevisionID
    public let sessionID: String
    public let sequence: Int64
    public let positionSeconds: Double
    public let durationSeconds: Double
    public let completed: Bool
    public let intent: PlaybackIntent
    public let deviceID: String
    public let encodedCloudKitRecordSystemFields: Data?
    public let updatedAt: Timestamp

    public init(
        itemID: ItemID,
        revisionID: RevisionID,
        sessionID: String,
        sequence: Int64,
        positionSeconds: Double,
        durationSeconds: Double,
        completed: Bool,
        intent: PlaybackIntent,
        deviceID: String,
        encodedCloudKitRecordSystemFields: Data? = nil,
        updatedAt: Timestamp
    ) throws {
        try validateToken(sessionID, field: "sessionID")
        try validateToken(deviceID, field: "deviceID")
        guard sequence >= 1 else { throw DomainError.invalidValue(field: "sequence", reason: "must be at least one") }
        guard positionSeconds.isFinite, positionSeconds >= 0 else {
            throw DomainError.invalidValue(field: "positionSeconds", reason: "must be finite and nonnegative")
        }
        guard durationSeconds.isFinite, durationSeconds > 0 else {
            throw DomainError.invalidValue(field: "durationSeconds", reason: "must be finite and positive")
        }
        self.itemID = itemID
        self.revisionID = revisionID
        self.sessionID = sessionID
        self.sequence = sequence
        self.positionSeconds = positionSeconds
        self.durationSeconds = durationSeconds
        self.completed = completed
        self.intent = intent
        self.deviceID = deviceID
        self.encodedCloudKitRecordSystemFields = encodedCloudKitRecordSystemFields
        self.updatedAt = updatedAt
    }

    private enum CodingKeys: CodingKey {
        case itemID, revisionID, sessionID, sequence, positionSeconds, durationSeconds, completed, intent, deviceID
        case encodedCloudKitRecordSystemFields, updatedAt
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            itemID: container.decode(ItemID.self, forKey: .itemID),
            revisionID: container.decode(RevisionID.self, forKey: .revisionID),
            sessionID: container.decode(String.self, forKey: .sessionID),
            sequence: container.decode(Int64.self, forKey: .sequence),
            positionSeconds: container.decode(Double.self, forKey: .positionSeconds),
            durationSeconds: container.decode(Double.self, forKey: .durationSeconds),
            completed: container.decode(Bool.self, forKey: .completed),
            intent: container.decode(PlaybackIntent.self, forKey: .intent),
            deviceID: container.decode(String.self, forKey: .deviceID),
            encodedCloudKitRecordSystemFields: container.decodeIfPresent(Data.self, forKey: .encodedCloudKitRecordSystemFields),
            updatedAt: container.decode(Timestamp.self, forKey: .updatedAt)
        )
    }
}

private func validateToken(_ value: String, field: String) throws {
    guard value.utf8.count <= 128,
          value.range(of: "^[A-Za-z0-9][A-Za-z0-9._:-]*$", options: .regularExpression) != nil
    else { throw DomainError.invalidValue(field: field, reason: "invalid stable token") }
}
