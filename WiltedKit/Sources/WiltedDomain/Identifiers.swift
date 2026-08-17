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
