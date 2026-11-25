import Foundation
import WiltedDomain

/// One Notebook record. The source identity, revision, title, URL and prepared-audio
/// range are snapshots, so a clip remains readable after its episode is removed.
public struct LibraryNotebookEntry: Codable, Sendable, Equatable, Identifiable {
    public enum Kind: String, Codable, Sendable { case clip, note, idea }
    public enum SourceKind: String, Codable, Sendable { case podcast, article, audiobook }
    public enum CaptureOrigin: String, Codable, Sendable { case mac, iphone, watch, siri }

    public static let maximumTextBytes = 16 * 1024
    public static let maximumTagCount = 64

    public let id: ItemID
    public let createdAt: Date
    public let kind: Kind
    public let sourceKind: SourceKind
    public let sourceItemID: ItemID
    public let sourceRevision: RevisionID
    public let sourceTitle: String
    public let sourceURL: URL
    public let sourceName: String?
    /// Seconds from the start of the exact prepared audio revision.
    public let startSeconds: Double?
    public let endSeconds: Double?
    public var textExcerpt: String?
    public var note: String?
    public var tags: [String]
    public let capturedOn: CaptureOrigin
    public var reviewed: Bool
    public var updatedAt: Date
    /// A durable delete marker. CloudKit never hard-deletes Notebook records.
    public var deletedAt: Date?

    public init(
        id: ItemID,
        createdAt: Date = Date(),
        kind: Kind = .clip,
        sourceKind: SourceKind = .podcast,
        sourceItemID: ItemID,
        sourceRevision: RevisionID,
        sourceTitle: String,
        sourceURL: URL,
        sourceName: String? = nil,
        startSeconds: Double?,
        endSeconds: Double?,
        textExcerpt: String? = nil,
        note: String? = nil,
        tags: [String] = [],
        capturedOn: CaptureOrigin,
        reviewed: Bool? = nil,
        updatedAt: Date? = nil,
        deletedAt: Date? = nil
    ) throws {
        guard createdAt.timeIntervalSince1970.isFinite,
              let components = URLComponents(url: sourceURL, resolvingAgainstBaseURL: false),
              let scheme = components.scheme?.lowercased(), ["http", "https"].contains(scheme),
              let host = components.host, !host.isEmpty,
              components.user == nil, components.password == nil,
              sourceURL.absoluteString.utf8.count <= 4_096 else {
            throw DomainError.invalidValue(field: "notebook.sourceURL", reason: "must be a bounded HTTP or HTTPS URL without credentials")
        }
        let title = sourceTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, title.utf8.count <= 1_024,
              title.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) else {
            throw DomainError.invalidValue(field: "notebook.sourceTitle", reason: "must be nonempty, bounded, and contain no control characters")
        }
        if let sourceName {
            guard sourceName.utf8.count <= 1_024,
                  sourceName.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) else {
                throw DomainError.invalidValue(field: "notebook.sourceName", reason: "is too long or contains control characters")
            }
        }
        switch (startSeconds, endSeconds) {
        case let (.some(start), .some(end)):
            guard start.isFinite, end.isFinite, start >= 0, end > start else {
                throw DomainError.invalidValue(field: "notebook.range", reason: "must be finite, non-negative, and increasing")
            }
        case (nil, nil):
            guard kind != .clip else {
                throw DomainError.invalidValue(field: "notebook.range", reason: "a clip requires both endpoints")
            }
        default:
            throw DomainError.invalidValue(field: "notebook.range", reason: "both endpoints must be present or absent")
        }
        if kind == .clip, sourceKind == .podcast {
            // v1's only captured source. Other source kinds remain reserved for later slices.
        } else if kind == .clip {
            throw DomainError.invalidValue(field: "notebook.sourceKind", reason: "only podcast clips are supported")
        }
        for (field, value) in [("textExcerpt", textExcerpt), ("note", note)] {
            guard value?.utf8.count ?? 0 <= Self.maximumTextBytes,
                  value?.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) || $0 == "\n" || $0 == "\t" }) ?? true else {
                throw DomainError.invalidValue(field: "notebook.\(field)", reason: "is too long or contains control characters")
            }
        }
        guard tags.count <= Self.maximumTagCount,
              tags.allSatisfy({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0.utf8.count <= 128 }),
              Set(tags).count == tags.count else {
            throw DomainError.invalidValue(field: "notebook.tags", reason: "must be unique, nonempty, and bounded")
        }
        let finalUpdatedAt = updatedAt ?? createdAt
        guard finalUpdatedAt.timeIntervalSince1970.isFinite,
              deletedAt?.timeIntervalSince1970.isFinite ?? true else {
            throw DomainError.invalidValue(field: "notebook.timestamps", reason: "must be finite")
        }
        let finalReviewed = reviewed ?? (capturedOn == .mac || capturedOn == .iphone)

        self.id = id
        self.createdAt = createdAt
        self.kind = kind
        self.sourceKind = sourceKind
        self.sourceItemID = sourceItemID
        self.sourceRevision = sourceRevision
        self.sourceTitle = title
        self.sourceURL = sourceURL
        self.sourceName = sourceName
        self.startSeconds = startSeconds
        self.endSeconds = endSeconds
        self.textExcerpt = textExcerpt
        self.note = note
        self.tags = tags
        self.capturedOn = capturedOn
        self.reviewed = finalReviewed
        self.updatedAt = finalUpdatedAt
        self.deletedAt = deletedAt
    }

    public var isDeleted: Bool { deletedAt != nil }

    private enum CodingKeys: String, CodingKey {
        case id, createdAt, kind, sourceKind, sourceItemID, sourceRevision, sourceTitle, sourceURL, sourceName
        case startSeconds, endSeconds, textExcerpt, note, tags, capturedOn, reviewed, updatedAt, deletedAt
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            id: values.decode(ItemID.self, forKey: .id),
            createdAt: values.decode(Date.self, forKey: .createdAt),
            kind: values.decode(Kind.self, forKey: .kind),
            sourceKind: values.decode(SourceKind.self, forKey: .sourceKind),
            sourceItemID: values.decode(ItemID.self, forKey: .sourceItemID),
            sourceRevision: values.decode(RevisionID.self, forKey: .sourceRevision),
            sourceTitle: values.decode(String.self, forKey: .sourceTitle),
            sourceURL: values.decode(URL.self, forKey: .sourceURL),
            sourceName: values.decodeIfPresent(String.self, forKey: .sourceName),
            startSeconds: values.decodeIfPresent(Double.self, forKey: .startSeconds),
            endSeconds: values.decodeIfPresent(Double.self, forKey: .endSeconds),
            textExcerpt: values.decodeIfPresent(String.self, forKey: .textExcerpt),
            note: values.decodeIfPresent(String.self, forKey: .note),
            tags: values.decodeIfPresent([String].self, forKey: .tags) ?? [],
            capturedOn: values.decode(CaptureOrigin.self, forKey: .capturedOn),
            reviewed: values.decodeIfPresent(Bool.self, forKey: .reviewed),
            updatedAt: values.decodeIfPresent(Date.self, forKey: .updatedAt),
            deletedAt: values.decodeIfPresent(Date.self, forKey: .deletedAt)
        )
    }
}

/// Local partition for Notebook rows and queued writes. Cloud owner tokens never
/// become part of the synchronized entry payload.
public struct NotebookLocalScope: Codable, Hashable, Sendable {
    public let ownerToken: String?
    public let deviceID: String

    public init(ownerToken: String?, deviceID: String) throws {
        guard !deviceID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              deviceID.utf8.count <= 256,
              ownerToken?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != true,
              ownerToken?.utf8.count ?? 0 <= 512 else {
            throw DomainError.invalidValue(field: "notebook.scope", reason: "owner and device identities must be bounded and valid")
        }
        self.ownerToken = ownerToken
        self.deviceID = deviceID
    }

    /// Nil-owner entries remain on this install and are never automatically bound later.
    public var persistenceKey: String { ownerToken.map { "owner:\($0)" } ?? "device:\(deviceID)" }
}

/// Cloud write capability for Notebook records. Production-capable builds remain
/// local-only until the owner explicitly promotes the schema.
public enum NotebookCloudWriteMode: String, Codable, Sendable {
    case localOnly
    case development
}
