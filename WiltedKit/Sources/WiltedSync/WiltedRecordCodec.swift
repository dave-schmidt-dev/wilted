import Foundation
import WiltedDomain

/// A decoded domain value together with the envelope needed to preserve opaque fields.
public struct WiltedDecodedRecord<Value: Sendable>: Sendable {
    public let value: Value
    public let envelope: WiltedRecordEnvelope
    public let opaqueFields: [String: WiltedFieldValue]

    public init(value: Value, envelope: WiltedRecordEnvelope, opaqueFields: [String: WiltedFieldValue] = [:]) {
        self.value = value
        self.envelope = envelope
        self.opaqueFields = opaqueFields
    }
}

/// Strict schema codec between Wilted domain values and CloudKit-neutral records.
public struct WiltedRecordCodec: Sendable {
    public static let currentSchemaVersion = 1
    public static let zoneName = "WiltedZone"

    public init() {}

    /// Encodes an article. The current revision is required by the frozen item schema.
    public func encode(article: Article, currentRevisionID: RevisionID, sidecar: WiltedOpaqueSidecar? = nil,
                       opaqueFields: [String: WiltedFieldValue] = [:]) throws -> WiltedRecordEnvelope {
        let id = try WiltedRecordID.item(article.itemID)
        var fields: [String: WiltedFieldValue] = [
            "itemID": .string(article.itemID.rawValue),
            "canonicalURL": .string(article.canonicalURL.absoluteString),
            "title": .string(article.title),
            "source": .string(article.source),
            "createdAt": .date(article.createdAt),
            "isDeleted": .int64(article.isDeleted ? 1 : 0),
            "schemaVersion": .int64(Int64(Self.currentSchemaVersion)),
            "currentRevisionID": .string(currentRevisionID.rawValue),
        ]
        if let author = article.author { fields["author"] = .string(author) }
        if let publishedTime = article.publishedTime { fields["publishedTime"] = .date(publishedTime) }
        fields.merge(opaqueFields) { existing, _ in existing }
        return try WiltedRecordEnvelope(id: id, fields: fields, sidecar: sidecar)
    }

    /// Fails closed because Article alone cannot supply the schema's current revision identity.
    public func encode(article: Article) throws -> WiltedRecordEnvelope {
        throw WiltedSyncError.missingRequiredField("currentRevisionID")
    }

    /// Decodes an item record while retaining unknown fields for an adapter to round-trip.
    public func decodeArticleRecord(_ envelope: WiltedRecordEnvelope) throws -> WiltedDecodedRecord<Article> {
        try validate(envelope, expected: .item)
        let itemID = try itemID(envelope)
        guard envelope.id == (try .item(itemID)) else { throw WiltedSyncError.invalidRecordIdentity }
        _ = try RevisionID(rawValue: string(envelope, "currentRevisionID"))
        let url = try URL(string: string(envelope, "canonicalURL")) ?? {
            throw WiltedSyncError.invalidValue(field: "canonicalURL")
        }()
        let canonical = try ItemID.canonicalURL(url)
        guard let derived = try? ItemID.derive(from: canonical), derived == itemID else {
            throw WiltedSyncError.invalidRecordIdentity
        }
        let article = try Article(itemID: itemID, canonicalURL: canonical,
                                  title: string(envelope, "title"), source: string(envelope, "source"),
                                  author: try optionalString(envelope, "author"),
                                  publishedTime: try optionalDate(envelope, "publishedTime"),
                                  createdAt: date(envelope, "createdAt"),
                                  isDeleted: try boolean01(envelope, "isDeleted"))
        let known = Set(["itemID", "canonicalURL", "title", "source", "author", "publishedTime", "createdAt", "isDeleted", "schemaVersion", "currentRevisionID"])
        return WiltedDecodedRecord(value: article, envelope: envelope,
                                   opaqueFields: envelope.fields.filter { !known.contains($0.key) })
    }

    public func decodeArticle(_ envelope: WiltedRecordEnvelope) throws -> Article {
        try decodeArticleRecord(envelope).value
    }

    /// Encodes an immutable audio revision and its required file-backed asset.
    public func encode(revision: AudioRevision, audioAsset: WiltedAsset, sidecar: WiltedOpaqueSidecar? = nil,
                       opaqueFields: [String: WiltedFieldValue] = [:]) throws -> WiltedRecordEnvelope {
        guard audioAsset.contentHash == revision.contentHash else { throw WiltedSyncError.invalidValue(field: "audioAsset.contentHash") }
        let itemReference = try WiltedRecordReference(recordID: .item(revision.itemID))
        var fields: [String: WiltedFieldValue] = [
            "itemID": .string(revision.itemID.rawValue), "revisionID": .string(revision.revisionID.rawValue),
            "itemReference": .reference(itemReference), "durationSeconds": .double(revision.durationSeconds),
            "byteCount": .int64(revision.byteCount), "contentHash": .string(revision.contentHash),
            "mediaType": .string(revision.mediaType), "createdAt": .date(revision.createdAt),
            "schemaVersion": .int64(Int64(Self.currentSchemaVersion)), "readiness": .string("ready"),
            "audioAsset": .asset(audioAsset),
        ]
        fields.merge(opaqueFields) { existing, _ in existing }
        return try WiltedRecordEnvelope(id: .revision(revision.itemID, revision.revisionID), fields: fields, sidecar: sidecar)
    }

    /// Encodes a revision's metadata and immutable chunk manifest without placing
    /// audio bytes on the revision record. Chunk bytes are separate records.
    public func encode(revision: AudioRevision, manifest: AudioChunkManifest,
                       sidecar: WiltedOpaqueSidecar? = nil,
                       opaqueFields: [String: WiltedFieldValue] = [:]) throws -> WiltedRecordEnvelope {
        guard manifest.totalByteCount == revision.byteCount,
              "sha256:\(manifest.contentSHA256)" == revision.contentHash else {
            throw WiltedSyncError.invalidValue(field: "audioManifest")
        }
        let itemReference = try WiltedRecordReference(recordID: .item(revision.itemID))
        var fields: [String: WiltedFieldValue] = [
            "itemID": .string(revision.itemID.rawValue), "revisionID": .string(revision.revisionID.rawValue),
            "itemReference": .reference(itemReference), "durationSeconds": .double(revision.durationSeconds),
            "byteCount": .int64(revision.byteCount), "contentHash": .string(revision.contentHash),
            "mediaType": .string(revision.mediaType), "createdAt": .date(revision.createdAt),
            "schemaVersion": .int64(Int64(Self.currentSchemaVersion)), "readiness": .string("ready"),
            "audioManifest": .bytes(try JSONEncoder().encode(manifest)),
        ]
        fields.merge(opaqueFields) { existing, _ in existing }
        return try WiltedRecordEnvelope(id: .revision(revision.itemID, revision.revisionID), fields: fields, sidecar: sidecar)
    }

    public func decodeRevisionRecord(_ envelope: WiltedRecordEnvelope) throws -> WiltedDecodedRecord<AudioRevision> {
        try validate(envelope, expected: .revision)
        let item = try itemID(envelope)
        let revisionID = try RevisionID(rawValue: string(envelope, "revisionID"))
        guard envelope.id == (try .revision(item, revisionID)) else { throw WiltedSyncError.invalidRecordIdentity }
        let reference = try reference(envelope, "itemReference")
        guard reference.recordID == (try .item(item)) else { throw WiltedSyncError.invalidRecordIdentity }
        if let assetValue = envelope.fields["audioAsset"] {
            guard case let .asset(asset) = assetValue else { throw WiltedSyncError.invalidFieldType("audioAsset") }
            guard asset.contentHash == (try string(envelope, "contentHash")) else { throw WiltedSyncError.invalidValue(field: "audioAsset.contentHash") }
        } else if let manifestValue = envelope.fields["audioManifest"] {
            guard case let .bytes(data) = manifestValue,
                  let manifest = try? JSONDecoder().decode(AudioChunkManifest.self, from: data),
                  manifest.totalByteCount == (try int64(envelope, "byteCount")),
                  "sha256:\(manifest.contentSHA256)" == (try string(envelope, "contentHash")) else {
                throw WiltedSyncError.invalidValue(field: "audioManifest")
            }
        } else {
            throw WiltedSyncError.missingRequiredField("audioAsset or audioManifest")
        }
        guard try string(envelope, "readiness") == "ready" else { throw WiltedSyncError.invalidValue(field: "readiness") }
        let revision = try AudioRevision(itemID: item, revisionID: revisionID,
                                         durationSeconds: double(envelope, "durationSeconds"), byteCount: int64(envelope, "byteCount"),
                                         contentHash: string(envelope, "contentHash"), mediaType: string(envelope, "mediaType"),
                                         createdAt: date(envelope, "createdAt"), schemaVersion: Int(int64(envelope, "schemaVersion")))
        let known = Set(["itemID", "revisionID", "itemReference", "durationSeconds", "byteCount", "contentHash", "mediaType", "createdAt", "schemaVersion", "readiness", "audioAsset", "audioManifest"])
        return WiltedDecodedRecord(value: revision, envelope: envelope, opaqueFields: envelope.fields.filter { !known.contains($0.key) })
    }

    public func decodeRevision(_ envelope: WiltedRecordEnvelope) throws -> AudioRevision { try decodeRevisionRecord(envelope).value }

    /// Encodes transcript state independently from audio bytes so retrying or fetching
    /// transcript content never requires restaging the immutable audio asset.
    public func encode(transcript: Transcript, sidecar: WiltedOpaqueSidecar? = nil,
                       opaqueFields: [String: WiltedFieldValue] = [:]) throws -> WiltedRecordEnvelope {
        let itemReference = try WiltedRecordReference(recordID: .item(transcript.itemID))
        let revisionReference = try WiltedRecordReference(recordID: .revision(transcript.itemID, transcript.revisionID))
        var fields: [String: WiltedFieldValue] = [
            "itemID": .string(transcript.itemID.rawValue),
            "revisionID": .string(transcript.revisionID.rawValue),
            "itemReference": .reference(itemReference),
            "revisionReference": .reference(revisionReference),
            "availability": .string(transcript.availability.rawValue),
            "format": .string(transcript.format.rawValue),
            "updatedAt": .date(transcript.updatedAt),
            "schemaVersion": .int64(Int64(transcript.schemaVersion)),
        ]
        if let text = transcript.text { fields["text"] = .string(text) }
        if let languageCode = transcript.languageCode { fields["languageCode"] = .string(languageCode) }
        fields.merge(opaqueFields) { existing, _ in existing }
        return try WiltedRecordEnvelope(id: .transcript(transcript.itemID, transcript.revisionID),
                                        fields: fields, sidecar: sidecar)
    }

    public func decodeTranscriptRecord(_ envelope: WiltedRecordEnvelope) throws -> WiltedDecodedRecord<Transcript> {
        try validate(envelope, expected: .transcript)
        let item = try itemID(envelope)
        let revisionID = try RevisionID(rawValue: string(envelope, "revisionID"))
        guard envelope.id == (try .transcript(item, revisionID)),
              try reference(envelope, "itemReference").recordID == .item(item),
              try reference(envelope, "revisionReference").recordID == .revision(item, revisionID),
              let availability = TranscriptAvailability(rawValue: try string(envelope, "availability")),
              let format = TranscriptFormat(rawValue: try string(envelope, "format")) else {
            throw WiltedSyncError.invalidRecordIdentity
        }
        let transcript: Transcript
        do {
            transcript = try Transcript(
                itemID: item,
                revisionID: revisionID,
                availability: availability,
                text: try optionalString(envelope, "text"),
                format: format,
                languageCode: try optionalString(envelope, "languageCode"),
                updatedAt: date(envelope, "updatedAt"),
                schemaVersion: Int(int64(envelope, "schemaVersion"))
            )
        } catch {
            throw WiltedSyncError.invalidValue(field: "transcript")
        }
        let known = Set(["itemID", "revisionID", "itemReference", "revisionReference", "availability", "text", "format", "languageCode", "updatedAt", "schemaVersion"])
        return WiltedDecodedRecord(value: transcript, envelope: envelope,
                                   opaqueFields: envelope.fields.filter { !known.contains($0.key) })
    }

    public func decodeTranscript(_ envelope: WiltedRecordEnvelope) throws -> Transcript {
        try decodeTranscriptRecord(envelope).value
    }

    /// Encodes one immutable chunk record. The bytes are supplied separately by
    /// the CloudKit adapter through the `chunkAsset` descriptor.
    public func encode(revisionChunk itemID: ItemID, revisionID: RevisionID,
                       descriptor: AudioChunkDescriptor, chunkAsset: WiltedAsset,
                       sidecar: WiltedOpaqueSidecar? = nil,
                       opaqueFields: [String: WiltedFieldValue] = [:]) throws -> WiltedRecordEnvelope {
        guard chunkAsset.contentHash == "sha256:\(descriptor.sha256)" else {
            throw WiltedSyncError.invalidValue(field: "chunkAsset.contentHash")
        }
        let revisionReference = try WiltedRecordReference(recordID: .revision(itemID, revisionID))
        var fields: [String: WiltedFieldValue] = [
            "itemID": .string(itemID.rawValue), "revisionID": .string(revisionID.rawValue),
            "revisionReference": .reference(revisionReference), "identity": .string(descriptor.identity),
            "index": .int64(Int64(descriptor.index)), "byteCount": .int64(descriptor.byteCount),
            "sha256": .string(descriptor.sha256), "schemaVersion": .int64(Int64(Self.currentSchemaVersion)),
            "chunkAsset": .asset(chunkAsset),
        ]
        fields.merge(opaqueFields) { existing, _ in existing }
        return try WiltedRecordEnvelope(id: .revisionChunk(itemID, revisionID, index: descriptor.index),
                                        fields: fields, sidecar: sidecar)
    }

    public func decodeRevisionChunkRecord(_ envelope: WiltedRecordEnvelope) throws -> WiltedDecodedRecord<AudioChunkDescriptor> {
        try validate(envelope, expected: .revisionChunk)
        guard case let .string(itemValue)? = envelope.fields["itemID"],
              case let .string(revisionValue)? = envelope.fields["revisionID"],
              let itemID = try? ItemID(rawValue: itemValue),
              let revisionID = try? RevisionID(rawValue: revisionValue),
              envelope.id == (try .revisionChunk(itemID, revisionID, index: Int(int64(envelope, "index")))) else {
            throw WiltedSyncError.invalidRecordIdentity
        }
        let reference = try reference(envelope, "revisionReference")
        guard reference.recordID == (try .revision(itemID, revisionID)) else { throw WiltedSyncError.invalidRecordIdentity }
        let descriptor = try AudioChunkDescriptor(identity: string(envelope, "identity"),
                                                   index: Int(int64(envelope, "index")),
                                                   byteCount: int64(envelope, "byteCount"),
                                                   sha256: string(envelope, "sha256"))
        let asset = try asset(envelope, "chunkAsset")
        guard asset.contentHash == "sha256:\(descriptor.sha256)" else { throw WiltedSyncError.invalidValue(field: "chunkAsset.contentHash") }
        let known = Set(["itemID", "revisionID", "revisionReference", "identity", "index", "byteCount", "sha256", "schemaVersion", "chunkAsset"])
        return WiltedDecodedRecord(value: descriptor, envelope: envelope,
                                   opaqueFields: envelope.fields.filter { !known.contains($0.key) })
    }

    /// Encodes playback state and both non-cascading references.
    public func encode(playback: PlaybackState, sidecar: WiltedOpaqueSidecar? = nil,
                       opaqueFields: [String: WiltedFieldValue] = [:]) throws -> WiltedRecordEnvelope {
        let itemReference = try WiltedRecordReference(recordID: .item(playback.itemID))
        let revisionReference = try WiltedRecordReference(recordID: .revision(playback.itemID, playback.revisionID))
        let effectiveSidecar = sidecar ?? WiltedOpaqueSidecar(encodedSystemFields: playback.encodedCloudKitRecordSystemFields)
        var fields: [String: WiltedFieldValue] = [
            "itemID": .string(playback.itemID.rawValue), "revisionID": .string(playback.revisionID.rawValue),
            "itemReference": .reference(itemReference), "revisionReference": .reference(revisionReference),
            "sessionID": .string(playback.sessionID), "sequence": .int64(playback.sequence),
            "positionSeconds": .double(playback.positionSeconds), "durationSeconds": .double(playback.durationSeconds),
            "completed": .int64(playback.completed ? 1 : 0), "intent": .string(playback.intent.rawValue),
            "deviceID": .string(playback.deviceID), "updatedAt": .date(playback.updatedAt),
            "schemaVersion": .int64(Int64(Self.currentSchemaVersion)),
        ]
        fields.merge(opaqueFields) { existing, _ in existing }
        return try WiltedRecordEnvelope(id: .playback(playback.itemID, playback.revisionID), fields: fields, sidecar: effectiveSidecar)
    }

    public func decodePlaybackRecord(_ envelope: WiltedRecordEnvelope) throws -> WiltedDecodedRecord<PlaybackState> {
        try validate(envelope, expected: .playbackState)
        let item = try itemID(envelope)
        let revisionID = try RevisionID(rawValue: string(envelope, "revisionID"))
        guard envelope.id == (try .playback(item, revisionID)) else { throw WiltedSyncError.invalidRecordIdentity }
        guard try reference(envelope, "itemReference").recordID == .item(item),
              try reference(envelope, "revisionReference").recordID == .revision(item, revisionID) else {
            throw WiltedSyncError.invalidRecordIdentity
        }
        guard let intent = PlaybackIntent(rawValue: try string(envelope, "intent")) else { throw WiltedSyncError.invalidValue(field: "intent") }
        let playback = try PlaybackState(itemID: item, revisionID: revisionID, sessionID: string(envelope, "sessionID"),
                                         sequence: int64(envelope, "sequence"), positionSeconds: double(envelope, "positionSeconds"),
                                         durationSeconds: double(envelope, "durationSeconds"), completed: try boolean01(envelope, "completed"),
                                         intent: intent, deviceID: string(envelope, "deviceID"),
                                         encodedCloudKitRecordSystemFields: envelope.sidecar?.encodedSystemFields,
                                         updatedAt: date(envelope, "updatedAt"))
        let known = Set(["itemID", "revisionID", "itemReference", "revisionReference", "sessionID", "sequence", "positionSeconds", "durationSeconds", "completed", "intent", "deviceID", "updatedAt", "schemaVersion"])
        return WiltedDecodedRecord(value: playback, envelope: envelope, opaqueFields: envelope.fields.filter { !known.contains($0.key) })
    }

    public func decodePlayback(_ envelope: WiltedRecordEnvelope) throws -> PlaybackState { try decodePlaybackRecord(envelope).value }

    private func validate(_ envelope: WiltedRecordEnvelope, expected: WiltedRecordType) throws {
        guard envelope.id.recordType == expected else { throw WiltedSyncError.invalidRecordIdentity }
        guard envelope.schemaVersion == Self.currentSchemaVersion else { throw WiltedSyncError.unsupportedSchemaVersion(envelope.schemaVersion) }
        guard let version = envelope.fields["schemaVersion"] else { throw WiltedSyncError.missingRequiredField("schemaVersion") }
        guard case let .int64(value) = version else { throw WiltedSyncError.invalidFieldType("schemaVersion") }
        guard value == 1 else { throw WiltedSyncError.unsupportedSchemaVersion(Int(value)) }
        for name in requiredFields(for: expected) where envelope.fields[name] == nil { throw WiltedSyncError.missingRequiredField(name) }
    }

    private func requiredFields(for type: WiltedRecordType) -> [String] {
        switch type {
        case .item: return ["itemID", "canonicalURL", "title", "source", "createdAt", "isDeleted", "schemaVersion", "currentRevisionID"]
        case .revision: return ["itemID", "revisionID", "itemReference", "durationSeconds", "byteCount", "contentHash", "mediaType", "createdAt", "schemaVersion", "readiness"]
        case .revisionChunk: return ["itemID", "revisionID", "revisionReference", "identity", "index", "byteCount", "sha256", "schemaVersion", "chunkAsset"]
        case .transcript: return ["itemID", "revisionID", "itemReference", "revisionReference", "availability", "format", "updatedAt", "schemaVersion"]
        case .playbackState: return ["itemID", "revisionID", "itemReference", "revisionReference", "sessionID", "sequence", "positionSeconds", "durationSeconds", "completed", "intent", "deviceID", "updatedAt", "schemaVersion"]
        }
    }

    private func value(_ envelope: WiltedRecordEnvelope, _ name: String) throws -> WiltedFieldValue {
        guard let value = envelope.fields[name] else { throw WiltedSyncError.missingRequiredField(name) }
        return value
    }
    private func string(_ e: WiltedRecordEnvelope, _ n: String) throws -> String { guard case let .string(v) = try value(e, n) else { throw WiltedSyncError.invalidFieldType(n) }; return v }
    private func int64(_ e: WiltedRecordEnvelope, _ n: String) throws -> Int64 { guard case let .int64(v) = try value(e, n) else { throw WiltedSyncError.invalidFieldType(n) }; return v }
    private func double(_ e: WiltedRecordEnvelope, _ n: String) throws -> Double { guard case let .double(v) = try value(e, n), v.isFinite else { throw WiltedSyncError.invalidFieldType(n) }; return v }
    private func date(_ e: WiltedRecordEnvelope, _ n: String) throws -> Timestamp { guard case let .date(v) = try value(e, n) else { throw WiltedSyncError.invalidFieldType(n) }; return v }
    private func reference(_ e: WiltedRecordEnvelope, _ n: String) throws -> WiltedRecordReference { guard case let .reference(v) = try value(e, n), v.recordID.zoneName == Self.zoneName else { throw WiltedSyncError.referenceOutsideZone(n) }; return v }
    private func asset(_ e: WiltedRecordEnvelope, _ n: String) throws -> WiltedAsset { guard case let .asset(v) = try value(e, n) else { throw WiltedSyncError.invalidFieldType(n) }; return v }
    private func boolean01(_ e: WiltedRecordEnvelope, _ n: String) throws -> Bool {
        let number = try int64(e, n)
        guard number == 0 || number == 1 else { throw WiltedSyncError.invalidValue(field: n) }
        return number == 1
    }
    private func itemID(_ e: WiltedRecordEnvelope) throws -> ItemID { try ItemID(rawValue: string(e, "itemID")) }
    private func optionalString(_ e: WiltedRecordEnvelope, _ n: String) throws -> String? {
        guard let value = e.fields[n] else { return nil }
        guard case let .string(value) = value else { throw WiltedSyncError.invalidFieldType(n) }
        return value
    }
    private func optionalDate(_ e: WiltedRecordEnvelope, _ n: String) throws -> Timestamp? {
        guard let value = e.fields[n] else { return nil }
        guard case let .date(value) = value else { throw WiltedSyncError.invalidFieldType(n) }
        return value
    }
}
