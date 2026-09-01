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
/// A transcript the feed itself publishes for one episode, from a
/// `<podcast:transcript>` tag.
///
/// A feed may list several -- different languages, or the same words as both
/// WebVTT and a plain web page. They are kept as published rather than reduced
/// to one at parse time, because which one is usable depends on what the
/// caller needs: only some formats carry timing, and a caller that must
/// synchronise with audio cannot settle for one that does not.
public struct PodcastTranscriptSource: Codable, Equatable, Sendable {
    /// Formats whose timing is stated by the publisher rather than inferred.
    /// A `text/html` or `text/plain` transcript is words without a clock; it
    /// can be read, but nothing about it says when anything was said.
    public static let timedMediaTypes: Set<String> = [
        "text/vtt",
        "application/x-subrip",
        "application/srt",
        "text/srt",
        "application/json",
    ]

    public let url: URL
    public let mediaType: String
    public let languageCode: String?
    /// `rel="captions"`, which marks a source intended to be displayed
    /// alongside playback rather than read on its own.
    public let isCaptions: Bool

    public var carriesTiming: Bool { Self.timedMediaTypes.contains(mediaType) }

    public init(url: URL, mediaType: String, languageCode: String? = nil, isCaptions: Bool = false) throws {
        let normalizedURL = try validatePodcastURL(url, field: "transcriptSource.url")
        let normalizedType = mediaType.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard normalizedType.range(of: #"^[a-z0-9][a-z0-9!#$&^_.+-]*/[a-z0-9][a-z0-9!#$&^_.+-]*$"#,
                                   options: .regularExpression) != nil else {
            throw DomainError.invalidValue(field: "transcriptSource.mediaType", reason: "must be a media type")
        }
        if let languageCode {
            guard languageCode.utf8.count <= 35,
                  languageCode.range(of: "^[A-Za-z]{2,3}(?:-[A-Za-z0-9]{2,8})*$", options: .regularExpression) != nil else {
                throw DomainError.invalidValue(field: "transcriptSource.languageCode", reason: "must be a BCP 47 language tag")
            }
        }
        self.url = normalizedURL
        self.mediaType = normalizedType
        self.languageCode = languageCode
        self.isCaptions = isCaptions
    }

    private enum CodingKeys: CodingKey { case url, mediaType, languageCode, isCaptions }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(url: c.decode(URL.self, forKey: .url),
                      mediaType: c.decode(String.self, forKey: .mediaType),
                      languageCode: c.decodeIfPresent(String.self, forKey: .languageCode),
                      isCaptions: c.decodeIfPresent(Bool.self, forKey: .isCaptions) ?? false)
    }
}

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
    /// Transcripts the feed publishes for this episode, in feed order.
    ///
    /// Deliberately outside `itemID` derivation: a publisher adding or fixing a
    /// transcript URL must not re-identify an episode already in the Larder,
    /// with its download and playback position attached.
    public let transcriptSources: [PodcastTranscriptSource]
    /// The show notes the feed publishes for this episode, as plain text with
    /// paragraph breaks; nil when the feed publishes none.
    ///
    /// Notes name the hosts, guests, stories, products, and sponsors an
    /// episode talks about, which is exactly the vocabulary speech-to-text
    /// gets wrong. They are kept for the listener to read and handed to
    /// preparation as the glossary for correcting the transcript. Outside
    /// `itemID` derivation for the same reason transcript sources are.
    public let notes: String?
    public let createdAt: Timestamp

    /// The most useful published transcript for synchronising with audio, or
    /// nil when the feed publishes none that carries timing. Captions win ties
    /// because they are authored against the audio clock by definition.
    public var timedTranscriptSource: PodcastTranscriptSource? {
        let timed = transcriptSources.filter(\.carriesTiming)
        return timed.first(where: \.isCaptions) ?? timed.first
    }

    public static let maximumTranscriptSources = 8
    /// Generous for show notes (TWiT's run about 3,000 characters) and small
    /// enough that a feed cannot turn the episode table into a blob store.
    public static let maximumNotesLength = 32_768

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
        transcriptSources: [PodcastTranscriptSource] = [],
        notes: String? = nil,
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
        guard transcriptSources.count <= Self.maximumTranscriptSources else {
            throw DomainError.invalidValue(field: "transcriptSources", reason: "must not exceed 8 published transcripts")
        }
        // Empty notes are no notes: a feed that publishes "<p></p>" has not
        // said anything, and every reader would otherwise have to check twice.
        let trimmedNotes = notes?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let trimmedNotes, !trimmedNotes.isEmpty {
            guard trimmedNotes.count <= Self.maximumNotesLength else {
                throw DomainError.invalidValue(field: "notes", reason: "must not exceed \(Self.maximumNotesLength) characters")
            }
            self.notes = trimmedNotes
        } else {
            self.notes = nil
        }

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
        self.transcriptSources = transcriptSources
        self.createdAt = createdAt
    }

    private enum CodingKeys: CodingKey {
        case itemID, feedID, feedURL, rssGUID, title, author, publishedTime, enclosureURL
        case enclosureMediaType, enclosureByteCount, durationSeconds, artworkURL, transcriptSources, notes, createdAt
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
            transcriptSources: container.decodeIfPresent([PodcastTranscriptSource].self, forKey: .transcriptSources) ?? [],
            notes: container.decodeIfPresent(String.self, forKey: .notes),
            createdAt: container.decode(Timestamp.self, forKey: .createdAt)
        )
    }
}

/// Durable, local-only podcast order and the episode selected for playback.
/// Positions are derived from `episodeIDs`, so a persisted queue cannot expose
/// gaps or duplicate ordering values after add, remove, or reorder operations.
public struct PodcastQueueState: Codable, Equatable, Sendable {
    public let episodeIDs: [ItemID]
    public let currentEpisodeID: ItemID?

    public init(episodeIDs: [ItemID], currentEpisodeID: ItemID? = nil) throws {
        guard Set(episodeIDs).count == episodeIDs.count else {
            throw DomainError.invalidValue(field: "episodeIDs", reason: "must be unique")
        }
        if let currentEpisodeID, !episodeIDs.contains(currentEpisodeID) {
            throw DomainError.invalidValue(field: "currentEpisodeID", reason: "must belong to the queue")
        }
        self.episodeIDs = episodeIDs
        self.currentEpisodeID = currentEpisodeID
    }

    public var currentIndex: Int? {
        currentEpisodeID.flatMap { episodeIDs.firstIndex(of: $0) }
    }

    public var nextEpisodeID: ItemID? {
        guard let currentIndex else { return episodeIDs.first }
        let next = episodeIDs.index(after: currentIndex)
        return next < episodeIDs.endIndex ? episodeIDs[next] : nil
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
