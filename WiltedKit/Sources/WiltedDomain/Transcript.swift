import Foundation

/// The durable state of transcript content for one immutable audio revision.
public enum TranscriptAvailability: String, Codable, CaseIterable, Sendable {
    case absent
    case available
    case stale
    case oversized
    case malformed
}

/// The text representation stored and synced by the version-one transcript contract.
public enum TranscriptFormat: String, Codable, CaseIterable, Sendable {
    case plainText = "text/plain"
}

/// A read-only transcript bound to Wilted's existing item and audio revision identity.
public struct Transcript: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1
    public static let maximumTextUTF8Bytes = 500_000

    public let itemID: ItemID
    public let revisionID: RevisionID
    public let availability: TranscriptAvailability
    public let text: String?
    public let format: TranscriptFormat
    public let languageCode: String?
    public let updatedAt: Timestamp
    public let schemaVersion: Int

    public init(
        itemID: ItemID,
        revisionID: RevisionID,
        availability: TranscriptAvailability,
        text: String? = nil,
        format: TranscriptFormat = .plainText,
        languageCode: String? = nil,
        updatedAt: Timestamp,
        schemaVersion: Int = Transcript.currentSchemaVersion
    ) throws {
        guard schemaVersion == Self.currentSchemaVersion else {
            throw DomainError.invalidValue(field: "transcript.schemaVersion", reason: "must be version 1")
        }
        if let languageCode {
            guard languageCode.utf8.count <= 35,
                  languageCode.range(of: "^[A-Za-z]{2,3}(?:-[A-Za-z0-9]{2,8})*$", options: .regularExpression) != nil else {
                throw DomainError.invalidValue(field: "transcript.languageCode", reason: "must be a BCP 47 language tag")
            }
        }
        switch availability {
        case .available, .stale:
            guard let text, !text.isEmpty else {
                throw DomainError.invalidValue(field: "transcript.text", reason: "must be present for available or stale content")
            }
            guard text.utf8.count <= Self.maximumTextUTF8Bytes else {
                throw DomainError.invalidValue(field: "transcript.text", reason: "exceeds the 500000-byte transport limit")
            }
        case .absent, .oversized, .malformed:
            guard text == nil else {
                throw DomainError.invalidValue(field: "transcript.text", reason: "must be absent for unavailable content")
            }
        }
        self.itemID = itemID
        self.revisionID = revisionID
        self.availability = availability
        self.text = text
        self.format = format
        self.languageCode = languageCode
        self.updatedAt = updatedAt
        self.schemaVersion = schemaVersion
    }

    private enum CodingKeys: CodingKey {
        case itemID, revisionID, availability, text, format, languageCode, updatedAt, schemaVersion
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            itemID: container.decode(ItemID.self, forKey: .itemID),
            revisionID: container.decode(RevisionID.self, forKey: .revisionID),
            availability: container.decode(TranscriptAvailability.self, forKey: .availability),
            text: container.decodeIfPresent(String.self, forKey: .text),
            format: container.decode(TranscriptFormat.self, forKey: .format),
            languageCode: container.decodeIfPresent(String.self, forKey: .languageCode),
            updatedAt: container.decode(Timestamp.self, forKey: .updatedAt),
            schemaVersion: container.decode(Int.self, forKey: .schemaVersion)
        )
    }
}
