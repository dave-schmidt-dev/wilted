import CryptoKit
import Foundation

private func lowercaseHex(_ digest: SHA256.Digest) -> String {
    digest.map { String(format: "%02x", $0) }.joined()
}

private func validateIdentifier(_ value: String, maxLength: Int) throws {
    guard !value.isEmpty, value.utf8.count <= maxLength else {
        throw DomainError.invalidIdentifier(value)
    }
    let pattern = "^[A-Za-z0-9][A-Za-z0-9._:-]*$"
    guard value.range(of: pattern, options: .regularExpression) != nil else {
        throw DomainError.invalidIdentifier(value)
    }
}

private func namespacedSHA256(_ namespace: String, value: String) -> String {
    lowercaseHex(SHA256.hash(data: Data("\(namespace)\n\(value)".utf8)))
}

private func normalizedRSSGUID(_ guid: String) throws -> String {
    let normalized = guid
        .precomposedStringWithCanonicalMapping
        .trimmingCharacters(in: .whitespacesAndNewlines)
    guard !normalized.isEmpty, normalized.utf8.count <= 4_096,
          normalized.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) })
    else {
        throw DomainError.invalidValue(
            field: "rssGUID",
            reason: "must contain 1...4096 UTF-8 bytes without control characters"
        )
    }
    return normalized
}

/// Stable source-article identity derived from a canonical HTTPS URL.
public struct ItemID: Codable, Hashable, Sendable, CustomStringConvertible {
    public let rawValue: String

    public init(rawValue: String) throws {
        try validateIdentifier(rawValue, maxLength: 128)
        self.rawValue = rawValue
    }

    public init(from decoder: Decoder) throws {
        try self.init(rawValue: decoder.singleValueContainer().decode(String.self))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    public var description: String { rawValue }

    /// Returns the normalized URL used as the stable hash input.
    public static func canonicalURL(_ url: URL) throws -> URL {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme?.lowercased() == "https",
              let host = components.host, !host.isEmpty
        else {
            throw DomainError.invalidURL(url.absoluteString)
        }
        components.scheme = "https"
        components.host = host.lowercased()
        components.fragment = nil
        if components.port == 443 { components.port = nil }
        guard let canonical = components.url else {
            throw DomainError.invalidURL(url.absoluteString)
        }
        return canonical
    }

    public static func derive(from canonicalURL: URL) throws -> ItemID {
        let normalized = try Self.canonicalURL(canonicalURL)
        let digest = SHA256.hash(data: Data(normalized.absoluteString.utf8))
        return try ItemID(rawValue: "item-\(lowercaseHex(digest))")
    }

    /// Derives a podcast feed identity from its canonical HTTPS feed URL.
    public static func derivePodcastFeed(from canonicalFeedURL: URL) throws -> ItemID {
        let normalized = try Self.canonicalURL(canonicalFeedURL)
        let digest = namespacedSHA256("podcast.feed", value: normalized.absoluteString)
        return try ItemID(rawValue: "item-\(digest)")
    }

    /// Derives a podcast episode identity, preferring an RSS GUID when one is present.
    ///
    /// GUID identity includes the canonical feed URL, so equal GUIDs from different
    /// feeds remain distinct. A GUID-less episode falls back to its canonical HTTPS
    /// enclosure URL and therefore changes identity when that URL changes.
    public static func derivePodcastEpisode(
        feedURL: URL,
        rssGUID: String?,
        enclosureURL: URL
    ) throws -> ItemID {
        let normalizedFeedURL = try Self.canonicalURL(feedURL)
        let normalizedEnclosureURL = try Self.canonicalURL(enclosureURL)
        let digest: String
        if let rssGUID {
            let guid = try normalizedRSSGUID(rssGUID)
            digest = namespacedSHA256(
                "podcast.episode.guid",
                value: "\(normalizedFeedURL.absoluteString)\n\(guid)"
            )
        } else {
            digest = namespacedSHA256(
                "podcast.episode.enclosure",
                value: normalizedEnclosureURL.absoluteString
            )
        }
        return try ItemID(rawValue: "item-\(digest)")
    }

    /// Derives an article feed identity from its canonical HTTPS feed URL.
    ///
    /// The `article.feed` namespace keeps it distinct from the article ID of the
    /// same URL (`derive(from:)`, unchanged) and from the podcast feed ID.
    public static func articleFeed(canonicalFeedURL: URL) throws -> ItemID {
        let normalized = try Self.canonicalURL(canonicalFeedURL)
        let digest = namespacedSHA256("article.feed", value: normalized.absoluteString)
        return try ItemID(rawValue: "item-\(digest)")
    }

    /// Digest of an ordered list of source files for `audiobook(contentDigest:layout:volume:)`.
    ///
    /// SHA-256 over each file's 8-byte big-endian length followed by its bytes, so
    /// moving a byte across a file boundary changes the digest.
    public static func audiobookContentDigest(of files: [Data]) -> String {
        var hasher = AudiobookContentHasher()
        for file in files {
            hasher.beginFile(length: UInt64(file.count))
            hasher.append(file)
        }
        return hasher.finalize()
    }

    /// Derives one audiobook volume's identity.
    ///
    /// - Parameters:
    ///   - contentDigest: lowercase 64-hex digest from `AudiobookContentHasher`.
    ///   - layout: layout key (layout version, encoding policy and, for EPUB/PDF,
    ///     voice and synthesis settings), so regenerated boundaries never reuse an ID.
    ///   - volume: zero-based volume index.
    public static func audiobook(contentDigest: String, layout: String, volume: Int) throws -> ItemID {
        guard contentDigest.range(of: #"^[0-9a-f]{64}$"#, options: .regularExpression) != nil else {
            throw DomainError.invalidValue(field: "contentDigest", reason: "must be a lowercase SHA-256 hex digest")
        }
        guard !layout.isEmpty, !layout.contains("\n") else {
            throw DomainError.invalidValue(field: "layout", reason: "must be nonempty and single-line")
        }
        guard volume >= 0 else {
            throw DomainError.invalidValue(field: "volume", reason: "must be non-negative")
        }
        let digest = namespacedSHA256("audiobook.content", value: "\(contentDigest)\n\(layout)\n\(volume)")
        return try ItemID(rawValue: "item-\(digest)")
    }

    /// Compatibility spelling for callers whose parsed model names the field `guid`.
    public static func derivePodcastEpisode(
        feedURL: URL,
        guid: String?,
        enclosureURL: URL
    ) throws -> ItemID {
        try derivePodcastEpisode(feedURL: feedURL, rssGUID: guid, enclosureURL: enclosureURL)
    }
}

/// Content-derived identity for one immutable audio revision.
public struct RevisionID: Codable, Hashable, Sendable, CustomStringConvertible {
    public let rawValue: String

    public init(rawValue: String) throws {
        try validateIdentifier(rawValue, maxLength: 192)
        self.rawValue = rawValue
    }

    public init(from decoder: Decoder) throws {
        try self.init(rawValue: decoder.singleValueContainer().decode(String.self))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    public var description: String { rawValue }

    public static func derive(
        extractedTextSHA256: String,
        voiceID: String,
        synthesisSettingsCanonicalJSON: String,
        audioFormatCanonicalJSON: String
    ) throws -> RevisionID {
        guard !extractedTextSHA256.isEmpty, !voiceID.isEmpty else {
            throw DomainError.invalidValue(field: "revision identity", reason: "hash and voice must be nonempty")
        }
        let input = [
            extractedTextSHA256,
            voiceID,
            synthesisSettingsCanonicalJSON,
            audioFormatCanonicalJSON,
        ].joined(separator: "\n")
        let digest = SHA256.hash(data: Data(input.utf8))
        return try RevisionID(rawValue: "rev-\(lowercaseHex(digest))")
    }

    /// Derives the legacy immutable downloaded-audio revision from its verified content hash.
    ///
    /// This content-only form remains available to read existing stores. New
    /// podcast downloads use `derive(podcastDownloadedAudioItemID:contentHash:)`
    /// so identical audio from different episodes cannot share a revision.
    public static func derive(downloadedAudioContentHash contentHash: String) throws -> RevisionID {
        try validateDownloadedAudioContentHash(contentHash)
        let digest = namespacedSHA256("downloaded.audio", value: contentHash)
        return try RevisionID(rawValue: "rev-\(digest)")
    }

    /// Derives an immutable podcast revision from its episode identity and
    /// verified downloaded-audio hash.
    public static func derive(
        podcastDownloadedAudioItemID itemID: ItemID,
        contentHash: String
    ) throws -> RevisionID {
        try validateDownloadedAudioContentHash(contentHash)
        let digest = namespacedSHA256(
            "podcast.downloaded.audio",
            value: "\(itemID.rawValue)\n\(contentHash)"
        )
        return try RevisionID(rawValue: "rev-\(digest)")
    }

    private static func validateDownloadedAudioContentHash(_ contentHash: String) throws {
        guard contentHash.range(
            of: #"^sha256:[0-9a-f]{64}$"#,
            options: .regularExpression
        ) != nil else {
            throw DomainError.invalidValue(
                field: "downloadedAudioContentHash",
                reason: "must be a verified lowercase SHA-256 value"
            )
        }
    }

    /// Encodes a JSON object with sorted keys for revision identity input.
    public static func canonicalJSON(_ object: [String: any Sendable]) throws -> String {
        guard JSONSerialization.isValidJSONObject(object) else {
            throw DomainError.invalidValue(field: "canonical JSON", reason: "unsupported value")
        }
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        guard let result = String(data: data, encoding: .utf8) else {
            throw DomainError.invalidValue(field: "canonical JSON", reason: "not UTF-8")
        }
        return result
    }
}

/// Incremental form of `ItemID.audiobookContentDigest(of:)` for files too large to hold in memory.
///
/// Call `beginFile(length:)` with each file's exact byte count, then `append` its bytes.
public struct AudiobookContentHasher: Sendable {
    private var hasher = SHA256()

    public init() {}

    public mutating func beginFile(length: UInt64) {
        var big = length.bigEndian
        withUnsafeBytes(of: &big) { hasher.update(bufferPointer: $0) }
    }

    public mutating func append(_ data: Data) { hasher.update(data: data) }

    public mutating func finalize() -> String { lowercaseHex(hasher.finalize()) }
}
