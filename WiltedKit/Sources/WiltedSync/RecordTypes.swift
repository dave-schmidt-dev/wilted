import Foundation
import WiltedDomain

/// The record types in Wilted's CloudKit-neutral transfer contract.
public enum WiltedRecordType: String, Codable, CaseIterable, Sendable {
    case item = "WiltedItem"
    case revision = "WiltedRevision"
    /// One immutable byte chunk belonging to a revision.
    case revisionChunk = "WiltedRevisionChunk"
    case transcript = "WiltedTranscript"
    case playbackState = "WiltedPlaybackState"
}

/// A validated record identity. It intentionally contains no CloudKit types.
public struct WiltedRecordID: Codable, Hashable, Sendable, CustomStringConvertible {
    public let recordType: WiltedRecordType
    public let recordName: String
    public let zoneName: String

    public init(recordType: WiltedRecordType, recordName: String, zoneName: String = "WiltedZone") throws {
        guard zoneName == "WiltedZone" else { throw WiltedSyncError.invalidZone(zoneName) }
        guard recordName.range(of: "^[A-Za-z0-9][A-Za-z0-9._~:-]*$", options: .regularExpression) != nil else {
            throw WiltedSyncError.invalidRecordName(recordName)
        }
        let components = recordName.split(separator: ":", omittingEmptySubsequences: false)
        switch recordType {
        case .item:
            guard components.count == 2, components[0] == "item", (try? ItemID(rawValue: String(components[1]))) != nil else { throw WiltedSyncError.invalidRecordIdentity }
        case .revision, .transcript, .playbackState:
            let prefix: String
            switch recordType {
            case .revision: prefix = "revision"
            case .transcript: prefix = "transcript"
            default: prefix = "playback"
            }
            guard components.count == 3, components[0] == prefix,
                  (try? ItemID(rawValue: String(components[1]))) != nil,
                  (try? RevisionID(rawValue: String(components[2]))) != nil else { throw WiltedSyncError.invalidRecordIdentity }
        case .revisionChunk:
            guard components.count == 4, components[0] == "revisionChunk",
                  (try? ItemID(rawValue: String(components[1]))) != nil,
                  (try? RevisionID(rawValue: String(components[2]))) != nil,
                  Int(components[3]).map({ $0 >= 0 }) == true else { throw WiltedSyncError.invalidRecordIdentity }
        }
        self.recordType = recordType
        self.recordName = recordName
        self.zoneName = zoneName
    }

    public static func item(_ itemID: ItemID) throws -> Self {
        try Self(recordType: .item, recordName: "item:\(itemID.rawValue)")
    }

    public static func revision(_ itemID: ItemID, _ revisionID: RevisionID) throws -> Self {
        try Self(recordType: .revision, recordName: "revision:\(itemID.rawValue):\(revisionID.rawValue)")
    }

    public static func revisionChunk(_ itemID: ItemID, _ revisionID: RevisionID, index: Int) throws -> Self {
        guard index >= 0 else { throw WiltedSyncError.invalidRecordIdentity }
        return try Self(recordType: .revisionChunk,
                        recordName: "revisionChunk:\(itemID.rawValue):\(revisionID.rawValue):\(index)")
    }

    public static func playback(_ itemID: ItemID, _ revisionID: RevisionID) throws -> Self {
        try Self(recordType: .playbackState, recordName: "playback:\(itemID.rawValue):\(revisionID.rawValue)")
    }

    public static func transcript(_ itemID: ItemID, _ revisionID: RevisionID) throws -> Self {
        try Self(recordType: .transcript, recordName: "transcript:\(itemID.rawValue):\(revisionID.rawValue)")
    }

    public var description: String { "\(recordType.rawValue)/\(zoneName)/\(recordName)" }

    private enum CodingKeys: String, CodingKey { case recordType, recordName, zoneName }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(recordType: c.decode(WiltedRecordType.self, forKey: .recordType),
                      recordName: c.decode(String.self, forKey: .recordName),
                      zoneName: c.decode(String.self, forKey: .zoneName))
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(recordType, forKey: .recordType)
        try c.encode(recordName, forKey: .recordName)
        try c.encode(zoneName, forKey: .zoneName)
    }
}

/// The action requested when following a record reference.
public enum WiltedReferenceAction: String, Codable, Sendable { case none }

/// A typed reference constrained to Wilted's custom zone.
public struct WiltedRecordReference: Codable, Hashable, Sendable {
    public let recordID: WiltedRecordID
    public let action: WiltedReferenceAction

    public init(recordID: WiltedRecordID, action: WiltedReferenceAction = .none) {
        self.recordID = recordID
        self.action = action
    }

    private enum CodingKeys: String, CodingKey { case recordType, recordName, zoneName, action }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let type = try c.decode(WiltedRecordType.self, forKey: .recordType)
        let name = try c.decode(String.self, forKey: .recordName)
        let zone = try c.decode(String.self, forKey: .zoneName)
        try self.init(recordID: WiltedRecordID(recordType: type, recordName: name, zoneName: zone),
                      action: c.decodeIfPresent(WiltedReferenceAction.self, forKey: .action) ?? .none)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(recordID.recordType, forKey: .recordType)
        try c.encode(recordID.recordName, forKey: .recordName)
        try c.encode(recordID.zoneName, forKey: .zoneName)
        try c.encode(action, forKey: .action)
    }
}

/// A file-backed audio asset descriptor. The bytes remain owned by an adapter.
public struct WiltedAsset: Codable, Equatable, Sendable {
    public let assetID: String
    public let contentHash: String

    public init(assetID: String, contentHash: String) throws {
        guard !assetID.isEmpty else { throw WiltedSyncError.invalidValue(field: "assetID") }
        guard contentHash.range(of: "^sha256:[0-9a-f]{64}$", options: .regularExpression) != nil else {
            throw WiltedSyncError.invalidValue(field: "contentHash")
        }
        self.assetID = assetID
        self.contentHash = contentHash
    }
}

/// CloudKit-neutral field values used by record envelopes and test fakes.
public enum WiltedFieldValue: Codable, Equatable, Sendable {
    case string(String)
    case int64(Int64)
    case double(Double)
    case date(Timestamp)
    case reference(WiltedRecordReference)
    case asset(WiltedAsset)
    case bytes(Data)

    private enum CodingKeys: String, CodingKey { case type, value }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let type = try c.decode(String.self, forKey: .type)
        switch type {
        case "String": self = .string(try c.decode(String.self, forKey: .value))
        case "Int64": self = .int64(try c.decode(Int64.self, forKey: .value))
        case "Double": self = .double(try c.decode(Double.self, forKey: .value))
        case "Date": self = .date(try c.decode(Timestamp.self, forKey: .value))
        case "Reference": self = .reference(try c.decode(WiltedRecordReference.self, forKey: .value))
        case "Asset": self = .asset(try c.decode(WiltedAsset.self, forKey: .value))
        case "Bytes": self = .bytes(try c.decode(Data.self, forKey: .value))
        default: throw WiltedSyncError.invalidFieldType(type)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .string(value): try c.encode("String", forKey: .type); try c.encode(value, forKey: .value)
        case let .int64(value): try c.encode("Int64", forKey: .type); try c.encode(value, forKey: .value)
        case let .double(value): try c.encode("Double", forKey: .type); try c.encode(value, forKey: .value)
        case let .date(value): try c.encode("Date", forKey: .type); try c.encode(value, forKey: .value)
        case let .reference(value): try c.encode("Reference", forKey: .type); try c.encode(value, forKey: .value)
        case let .asset(value): try c.encode("Asset", forKey: .type); try c.encode(value, forKey: .value)
        case let .bytes(value): try c.encode("Bytes", forKey: .type); try c.encode(value, forKey: .value)
        }
    }
}

/// Opaque local metadata associated with one fetched record.
public struct WiltedOpaqueSidecar: Codable, Equatable, Sendable {
    public let changeTag: String?
    public let encodedSystemFields: Data?

    public init(changeTag: String? = nil, encodedSystemFields: Data? = nil) {
        self.changeTag = changeTag
        self.encodedSystemFields = encodedSystemFields
    }
}

/// A complete, schema-versioned transfer record.
public struct WiltedRecordEnvelope: Codable, Equatable, Sendable {
    public let id: WiltedRecordID
    public let schemaVersion: Int
    public let fields: [String: WiltedFieldValue]
    public let sidecar: WiltedOpaqueSidecar?

    public init(id: WiltedRecordID, schemaVersion: Int = 1, fields: [String: WiltedFieldValue], sidecar: WiltedOpaqueSidecar? = nil) throws {
        guard schemaVersion == 1 else { throw WiltedSyncError.unsupportedSchemaVersion(schemaVersion) }
        self.id = id
        self.schemaVersion = schemaVersion
        self.fields = fields
        self.sidecar = sidecar
    }

    private enum CodingKeys: String, CodingKey { case id, recordType, recordName, zoneName, schemaVersion, fields, sidecar }

    /// Decodes both the internal representation and the frozen fixture record shape.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let fields = try c.decode([String: WiltedFieldValue].self, forKey: .fields)
        let id: WiltedRecordID
        if let fixtureType = try c.decodeIfPresent(WiltedRecordType.self, forKey: .recordType) {
            id = try WiltedRecordID(recordType: fixtureType,
                                    recordName: c.decode(String.self, forKey: .recordName),
                                    zoneName: c.decode(String.self, forKey: .zoneName))
        } else {
            id = try c.decode(WiltedRecordID.self, forKey: .id)
        }
        let version: Int
        if let explicit = try c.decodeIfPresent(Int.self, forKey: .schemaVersion) {
            version = explicit
        } else if case let .int64(value)? = fields["schemaVersion"] {
            version = Int(value)
        } else {
            throw WiltedSyncError.missingRequiredField("schemaVersion")
        }
        try self.init(id: id, schemaVersion: version, fields: fields,
                      sidecar: c.decodeIfPresent(WiltedOpaqueSidecar.self, forKey: .sidecar))
    }

    /// Encodes records using the same flat shape as the checked-in contract fixtures.
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id.recordType, forKey: .recordType)
        try c.encode(id.recordName, forKey: .recordName)
        try c.encode(id.zoneName, forKey: .zoneName)
        try c.encode(fields, forKey: .fields)
        if let sidecar { try c.encode(sidecar, forKey: .sidecar) }
    }
}

public enum WiltedSyncError: Error, Equatable, Sendable {
    case missingRequiredField(String)
    case invalidFieldType(String)
    case invalidValue(field: String)
    case unsupportedSchemaVersion(Int)
    case invalidRecordName(String)
    case invalidRecordIdentity
    case invalidZone(String)
    case referenceOutsideZone(String)
    case ownershipViolation(role: SyncDeviceRole, operation: SyncOperation, recordType: WiltedRecordType)
    case missingEngineState
    case staleStagedBatch
    case injectedFailure(String)
    case transport(String)

    /// Every queued change was withheld because its record is conflicted, so the
    /// send moved nothing. Reported instead of a success so a fully blocked queue
    /// cannot present as an upload that worked.
    case sendBlockedByConflicts(count: Int, accountReviewRequired: Bool)
}
