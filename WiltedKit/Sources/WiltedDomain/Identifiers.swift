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

    /// Derives an immutable downloaded-audio revision from its verified content hash.
    public static func derive(downloadedAudioContentHash contentHash: String) throws -> RevisionID {
        guard contentHash.range(
            of: #"^sha256:[0-9a-f]{64}$"#,
            options: .regularExpression
        ) != nil else {
            throw DomainError.invalidValue(
                field: "downloadedAudioContentHash",
                reason: "must be a verified lowercase SHA-256 value"
            )
        }
        let digest = namespacedSHA256("downloaded.audio", value: contentHash)
        return try RevisionID(rawValue: "rev-\(digest)")
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
