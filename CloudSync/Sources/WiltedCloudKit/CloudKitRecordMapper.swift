import CloudKit
import CryptoKit
import Foundation
import WiltedDomain
import WiltedSync

/// An app-owned destination for copying CloudKit assets before CloudKit releases them.
public protocol CloudKitAssetStaging: AnyObject {
    func stage(asset: CKAsset, assetID: String, contentHash: String) throws -> URL
    func commit(stagedURL: URL, assetID: String) throws -> CloudKitAssetCommit
    func removeStagedAsset(at url: URL)
    func resolve(assetID: String) -> URL?
}

public struct CloudKitAssetCommit: Sendable {
    public let url: URL
    public let created: Bool
    public init(url: URL, created: Bool) { self.url = url; self.created = created }
}

/// Copies assets into a directory owned by the app. Existing immutable files are preserved.
public final class FileCloudKitAssetStager: CloudKitAssetStaging, @unchecked Sendable {
    public let rootURL: URL
    private let fileManager: FileManager

    public init(rootURL: URL, fileManager: FileManager = .default) throws {
        self.rootURL = rootURL.standardizedFileURL
        self.fileManager = fileManager
        try fileManager.createDirectory(at: self.rootURL, withIntermediateDirectories: true)
    }

    public func stage(asset: CKAsset, assetID: String, contentHash: String) throws -> URL {
        guard let sourceURL = asset.fileURL else { throw CloudKitSyncError.assetUnavailable(assetID) }
        let temporary = rootURL.appendingPathComponent(".incoming-\(UUID().uuidString).tmp")
        do {
            try fileManager.copyItem(at: sourceURL, to: temporary)
            return temporary
        } catch {
            if fileManager.fileExists(atPath: temporary.path) { try? fileManager.removeItem(at: temporary) }
            throw CloudKitSyncError.assetCopyFailed(error.localizedDescription)
        }
    }

    public func commit(stagedURL: URL, assetID: String) throws -> CloudKitAssetCommit {
        let destination = rootURL.appendingPathComponent(Self.safeFilename(for: assetID), isDirectory: false)
        do {
            if fileManager.fileExists(atPath: destination.path) {
                try fileManager.removeItem(at: stagedURL)
                return CloudKitAssetCommit(url: destination, created: false)
            } else {
                try fileManager.moveItem(at: stagedURL, to: destination)
                return CloudKitAssetCommit(url: destination, created: true)
            }
        } catch {
            if fileManager.fileExists(atPath: stagedURL.path) { try? fileManager.removeItem(at: stagedURL) }
            throw CloudKitSyncError.assetCopyFailed(error.localizedDescription)
        }
    }

    public func removeStagedAsset(at url: URL) {
        try? fileManager.removeItem(at: url)
    }

    public func resolve(assetID: String) -> URL? {
        let destination = rootURL.appendingPathComponent(Self.safeFilename(for: assetID), isDirectory: false)
        return fileManager.fileExists(atPath: destination.path) ? destination : nil
    }

    private static func safeFilename(for assetID: String) -> String {
        SHA256.hash(data: Data(assetID.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

/// A decoded neutral record and the app-owned locations of any staged assets.
public struct CloudKitDecodedRecord: Sendable {
    public let envelope: WiltedRecordEnvelope
    public let stagedAssets: [String: URL]
    public let ownedAssets: [URL]

    public init(envelope: WiltedRecordEnvelope, stagedAssets: [String: URL] = [:], ownedAssets: [URL] = []) {
        self.envelope = envelope
        self.stagedAssets = stagedAssets
        self.ownedAssets = ownedAssets
    }
}

/// A chunk after its CloudKit asset has been explicitly fetched and verified.
public struct CloudKitDecodedChunk: Sendable {
    public let id: WiltedRecordID
    public let descriptor: AudioChunkDescriptor
    public let data: Data

    public init(id: WiltedRecordID, descriptor: AudioChunkDescriptor, data: Data) {
        self.id = id
        self.descriptor = descriptor
        self.data = data
    }
}

/// Strictly translates CloudKit records to and from the CloudKit-neutral contract.
public final class CloudKitRecordMapper: @unchecked Sendable {
    public let zoneID: CKRecordZone.ID
    private let stager: CloudKitAssetStaging?

    public init(zoneName: String = WiltedRecordCodec.zoneName, ownerName: String = CKCurrentUserDefaultName,
                stager: CloudKitAssetStaging? = nil) throws {
        guard zoneName == WiltedRecordCodec.zoneName else { throw CloudKitSyncError.invalidZone(zoneName) }
        self.zoneID = CKRecordZone.ID(zoneName: zoneName, ownerName: ownerName)
        self.stager = stager
    }

    public func encode(_ envelope: WiltedRecordEnvelope, assetURLs: [String: URL] = [:]) throws -> CKRecord {
        guard envelope.id.zoneName == zoneID.zoneName else { throw CloudKitSyncError.invalidRecordIdentity }
        try validate(envelope)
        let record: CKRecord
        if let encodedSystemFields = envelope.sidecar?.encodedSystemFields {
            let restored = try decodeSystemFields(encodedSystemFields)
            guard restored.recordID.recordName == envelope.id.recordName,
                  restored.recordID.zoneID.zoneName == zoneID.zoneName,
                  restored.recordID.zoneID.ownerName == zoneID.ownerName,
                  restored.recordType == envelope.id.recordType.rawValue else {
                throw CloudKitSyncError.invalidRecordIdentity
            }
            record = restored
        } else {
            record = CKRecord(recordType: envelope.id.recordType.rawValue,
                              recordID: CKRecord.ID(recordName: envelope.id.recordName, zoneID: zoneID))
        }
        for (key, value) in envelope.fields {
            record[key] = try encode(value, field: key, assetURLs: assetURLs)
        }
        if let systemFields = envelope.sidecar?.encodedSystemFields, !systemFields.isEmpty {
            // System fields are used to preserve the server change tag for updates.
            // The caller supplies a record made by decodeSystemFields when needed.
            _ = systemFields
        }
        return record
    }

    /// Builds one deterministic revision-chunk record. The record is immutable
    /// by identity; retrying the same descriptor addresses the same CloudKit row.
    public func encodeChunk(_ envelope: WiltedRecordEnvelope, assetURL: URL) throws -> CKRecord {
        guard envelope.id.recordType == .revisionChunk else { throw CloudKitSyncError.invalidRecordIdentity }
        guard case let .asset(asset)? = envelope.fields["chunkAsset"] else { throw CloudKitSyncError.missingField("chunkAsset") }
        return try encode(envelope, assetURLs: [asset.assetID: assetURL])
    }

    /// Reads a chunk's CKAsset only when explicitly requested, then validates its
    /// declared length and digest before returning bytes to the app owner.
    public func decodeChunk(_ record: CKRecord) throws -> CloudKitDecodedChunk {
        guard record.recordType == WiltedRecordType.revisionChunk.rawValue else {
            throw CloudKitSyncError.invalidRecordIdentity
        }
        let decoded = try decodeMetadataOnly(record)
        let descriptor = try WiltedRecordCodec().decodeRevisionChunkRecord(decoded.envelope).value
        guard let asset = record["chunkAsset"] as? CKAsset, let url = asset.fileURL else {
            throw CloudKitSyncError.assetUnavailable("\(record.recordID.recordName)#chunkAsset")
        }
        let data: Data
        do { data = try Data(contentsOf: url) }
        catch { throw CloudKitSyncError.assetCopyFailed(error.localizedDescription) }
        guard Int64(data.count) == descriptor.byteCount else {
            throw CloudKitSyncError.invalidField("chunkAsset.byteCount")
        }
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        guard digest == descriptor.sha256 else { throw CloudKitSyncError.invalidField("chunkAsset.sha256") }
        return CloudKitDecodedChunk(id: decoded.envelope.id, descriptor: descriptor, data: data)
    }

    public func decode(_ record: CKRecord) throws -> CloudKitDecodedRecord {
        try decode(record, stageAssets: true)
    }

    /// Decodes record metadata while leaving every CKAsset at CloudKit's staged
    /// URL. Callers explicitly fetch and own audio bytes only after selection.
    public func decodeMetadataOnly(_ record: CKRecord) throws -> CloudKitDecodedRecord {
        try decode(record, stageAssets: false)
    }

    private func decode(_ record: CKRecord, stageAssets: Bool) throws -> CloudKitDecodedRecord {
        guard record.recordID.zoneID.zoneName == zoneID.zoneName,
              record.recordID.zoneID.ownerName == zoneID.ownerName else {
            throw CloudKitSyncError.invalidZone(record.recordID.zoneID.zoneName)
        }
        guard let type = WiltedRecordType(rawValue: record.recordType) else {
            throw CloudKitSyncError.unsupportedRecordType(record.recordType)
        }
        let id: WiltedRecordID
        do { id = try WiltedRecordID(recordType: type, recordName: record.recordID.recordName, zoneName: zoneID.zoneName) }
        catch { throw CloudKitSyncError.invalidRecordIdentity }
        var staged: [String: URL] = [:]
        do {
            var fields: [String: WiltedFieldValue] = [:]
            for key in record.allKeys() {
                guard let value = record[key] else { throw CloudKitSyncError.invalidField(key) }
                let decoded = try decode(value, field: key, assetID: "\(record.recordID.recordName)#\(key)", stageAsset: stageAssets,
                                         expectedHash: expectedHash(in: record, assetField: key))
                fields[key] = decoded.value
                if let url = decoded.assetURL { staged[key] = url }
            }
            if fields.values.contains(where: { if case .asset = $0 { return true }; return false }) {
                let contentHash: String
                if let value = fields["contentHash"].flatMap(Self.stringValue) {
                    contentHash = value
                } else if let value = fields["sha256"].flatMap(Self.stringValue) {
                    contentHash = "sha256:\(value)"
                } else {
                    throw CloudKitSyncError.missingField("contentHash")
                }
                guard contentHash.range(of: "^sha256:[0-9a-f]{64}$", options: .regularExpression) != nil else {
                    throw CloudKitSyncError.invalidField("contentHash")
                }
                for (key, value) in fields {
                    if case let .asset(asset) = value {
                        if stageAssets {
                            guard let url = staged[key], try sha256(url: url) == contentHash else {
                                throw CloudKitSyncError.invalidField("\(key).contentHash")
                            }
                        }
                        fields[key] = try .asset(WiltedAsset(assetID: asset.assetID, contentHash: contentHash))
                    }
                }
            }
            let envelope = try WiltedRecordEnvelope(
                id: id,
                schemaVersion: try schemaVersion(from: fields),
                fields: fields,
                sidecar: WiltedOpaqueSidecar(changeTag: record.recordChangeTag, encodedSystemFields: try encodeSystemFields(record))
            )
            try validate(envelope)
            return CloudKitDecodedRecord(envelope: envelope, stagedAssets: staged)
        } catch {
            for url in staged.values { stager?.removeStagedAsset(at: url) }
            throw error
        }
    }

    public func encodeSystemFields(_ record: CKRecord) throws -> Data {
        let archiver = NSKeyedArchiver(requiringSecureCoding: false)
        record.encodeSystemFields(with: archiver)
        archiver.finishEncoding()
        return archiver.encodedData
    }

    public func decodeSystemFields(_ data: Data) throws -> CKRecord {
        do {
            let unarchiver = try NSKeyedUnarchiver(forReadingFrom: data)
            unarchiver.requiresSecureCoding = false
            guard let record = CKRecord(coder: unarchiver) else { throw CloudKitSyncError.systemFieldsCorrupt }
            return record
        } catch {
            throw CloudKitSyncError.systemFieldsCorrupt
        }
    }

    public func removeStagedAsset(at url: URL) { stager?.removeStagedAsset(at: url) }

    /// Resolves a committed app-owned asset without exposing the stager's storage layout.
    public func resolvedAssetURL(for asset: WiltedAsset) -> URL? {
        stager?.resolve(assetID: "\(asset.assetID)#\(asset.contentHash.dropFirst(7))")
    }

    /// Carries the server's system fields onto the already-validated outbound envelope.
    /// This deliberately does not decode CloudKit values, so outbound asset URLs remain usable.
    public func envelope(_ envelope: WiltedRecordEnvelope, updatedFrom record: CKRecord) throws -> WiltedRecordEnvelope {
        guard envelope.id.recordName == record.recordID.recordName,
              envelope.id.recordType.rawValue == record.recordType,
              record.recordID.zoneID.zoneName == zoneID.zoneName,
              record.recordID.zoneID.ownerName == zoneID.ownerName else {
            throw CloudKitSyncError.invalidRecordIdentity
        }
        return try WiltedRecordEnvelope(
            id: envelope.id,
            schemaVersion: envelope.schemaVersion,
            fields: envelope.fields,
            sidecar: WiltedOpaqueSidecar(changeTag: record.recordChangeTag,
                                         encodedSystemFields: try encodeSystemFields(record)))
    }

    /// Publishes validated staged assets to immutable, content-addressed destinations.
    public func publish(_ decoded: CloudKitDecodedRecord) throws -> CloudKitDecodedRecord {
        guard let stager else { return decoded }
        var committed: [String: URL] = [:]
        var owned: [URL] = []
        do {
            for (key, url) in decoded.stagedAssets {
                guard case let .asset(asset)? = decoded.envelope.fields[key] else { throw CloudKitSyncError.invalidField(key) }
                let destinationID = "\(asset.assetID)#\(asset.contentHash.dropFirst(7))"
                let result = try stager.commit(stagedURL: url, assetID: destinationID)
                committed[key] = result.url
                if result.created { owned.append(result.url) }
            }
            return CloudKitDecodedRecord(envelope: decoded.envelope, stagedAssets: committed, ownedAssets: owned)
        } catch {
            for url in decoded.stagedAssets.values { stager.removeStagedAsset(at: url) }
            for url in owned { stager.removeStagedAsset(at: url) }
            throw error
        }
    }

    private func schemaVersion(from fields: [String: WiltedFieldValue]) throws -> Int {
        guard case let .int64(value)? = fields["schemaVersion"] else { throw CloudKitSyncError.missingField("schemaVersion") }
        guard value == Int64(WiltedRecordCodec.currentSchemaVersion) else {
            throw CloudKitSyncError.invalidField("schemaVersion")
        }
        return Int(value)
    }

    private func encode(_ value: WiltedFieldValue, field: String, assetURLs: [String: URL]) throws -> __CKRecordObjCValue {
        switch value {
        case let .string(value): return value as NSString
        case let .int64(value): return NSNumber(value: value)
        case let .double(value):
            guard value.isFinite else { throw CloudKitSyncError.invalidField(field) }
            return NSNumber(value: value)
        case let .date(value): return value.date as NSDate
        case let .bytes(value): return value as NSData
        case let .reference(reference):
            guard reference.recordID.zoneName == zoneID.zoneName else { throw CloudKitSyncError.invalidZone(reference.recordID.zoneName) }
            let id = CKRecord.ID(recordName: reference.recordID.recordName, zoneID: zoneID)
            return CKRecord.Reference(recordID: id, action: .none)
        case let .asset(asset):
            guard let url = assetURLs[asset.assetID], FileManager.default.fileExists(atPath: url.path) else {
                throw CloudKitSyncError.assetUnavailable(asset.assetID)
            }
            return CKAsset(fileURL: url)
        }
    }

    private struct DecodedField {
        let value: WiltedFieldValue
        let assetURL: URL?
    }

    private func decode(_ value: __CKRecordObjCValue, field: String, assetID: String,
                        stageAsset: Bool, expectedHash: String?) throws -> DecodedField {
        if let value = value as? NSString { return .init(value: .string(String(value)), assetURL: nil) }
        if let value = value as? NSDate { return .init(value: .date(Timestamp(value as Date)), assetURL: nil) }
        if let value = value as? NSData { return .init(value: .bytes(Data(value)), assetURL: nil) }
        if let value = value as? CKRecord.Reference {
            guard value.recordID.zoneID.zoneName == zoneID.zoneName,
                  value.recordID.zoneID.ownerName == zoneID.ownerName else { throw CloudKitSyncError.invalidZone(value.recordID.zoneID.zoneName) }
            let type = try typeFromRecordName(value.recordID.recordName)
            let id: WiltedRecordID
            do { id = try WiltedRecordID(recordType: type, recordName: value.recordID.recordName, zoneName: zoneID.zoneName) }
            catch { throw CloudKitSyncError.invalidRecordIdentity }
            return .init(value: .reference(WiltedRecordReference(recordID: id)), assetURL: nil)
        }
        if let value = value as? CKAsset {
            let hash = expectedHash ?? ("sha256:" + String(repeating: "0", count: 64))
            guard hash.range(of: "^sha256:[0-9a-f]{64}$", options: .regularExpression) != nil else {
                throw CloudKitSyncError.invalidField(field)
            }
            if !stageAsset {
                return .init(value: .asset(try WiltedAsset(assetID: assetID, contentHash: hash)), assetURL: nil)
            }
            guard let stager else { throw CloudKitSyncError.assetUnavailable(assetID) }
            let url: URL
            do { url = try stager.stage(asset: value, assetID: assetID, contentHash: hash) }
            catch let error as CloudKitSyncError { throw error }
            catch { throw CloudKitSyncError.map(error) }
            return .init(value: .asset(try WiltedAsset(assetID: assetID, contentHash: hash)), assetURL: url)
        }
        if let value = value as? NSNumber {
            let type = String(cString: value.objCType)
            if type == "d" || type == "f" { return .init(value: .double(value.doubleValue), assetURL: nil) }
            return .init(value: .int64(value.int64Value), assetURL: nil)
        }
        throw CloudKitSyncError.invalidField(field)
    }

    private func validate(_ envelope: WiltedRecordEnvelope) throws {
        let codec = WiltedRecordCodec()
        switch envelope.id.recordType {
        case .item: _ = try codec.decodeArticleRecord(envelope)
        case .revision: _ = try codec.decodeRevisionRecord(envelope)
        case .revisionChunk: _ = try codec.decodeRevisionChunkRecord(envelope)
        case .transcript: _ = try codec.decodeTranscriptRecord(envelope)
        case .playbackState: _ = try codec.decodePlaybackRecord(envelope)
        }
    }

    private func expectedHash(in record: CKRecord, assetField: String) -> String? {
        if assetField == "audioAsset", let value = record["contentHash"] as? NSString { return String(value) }
        if assetField == "chunkAsset", let value = record["sha256"] as? NSString { return "sha256:\(value)" }
        return nil
    }

    private static func stringValue(_ value: WiltedFieldValue) -> String? {
        guard case let .string(value) = value else { return nil }
        return value
    }

    private func sha256(url: URL) throws -> String {
        let digest = SHA256.hash(data: try Data(contentsOf: url))
        return "sha256:" + digest.map { String(format: "%02x", $0) }.joined()
    }

    private func typeFromRecordName(_ name: String) throws -> WiltedRecordType {
        if name.hasPrefix("item:") { return .item }
        if name.hasPrefix("revision:") { return .revision }
        if name.hasPrefix("transcript:") { return .transcript }
        if name.hasPrefix("playback:") { return .playbackState }
        throw CloudKitSyncError.invalidRecordIdentity
    }
}
