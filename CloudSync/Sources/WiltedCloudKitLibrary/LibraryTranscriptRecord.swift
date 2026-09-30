import CloudKit
import Foundation
import WiltedDomain
import WiltedLibrary

/// The `WiltedTranscript` record: the JSON of one `LibraryTranscript` as a `CKAsset`, plus the
/// identifying fields, in `WiltedMediaZone` beside the audio.
///
/// It sits in the media zone, not the library zone, on purpose. `CKSyncEngine` eagerly fetches
/// asset bytes and every record in the library zone, and a transcript (up to 512 KB) is far
/// over the library zone's 256 KB payload limit; here it moves only through the raw operations,
/// by record name, so no engine fetch and no zone scan ever stages it. An older reader never
/// asks for this record type, so it ignores the record entirely. The Mac is the only writer.
public enum LibraryTranscriptRecord {
    public static let recordType = "WiltedTranscript"
    public static let namePrefix = "transcript:"
    public static let assetField = LibraryMediaRecord.assetField
    /// The small fields read first, so a missing or stale record costs no asset download.
    public static let headerKeys: [CKRecord.FieldKey] = ["entryID", "revisionID", "byteCount"]

    public static func recordID(entryID: ItemID, zoneID: CKRecordZone.ID) -> CKRecord.ID {
        CKRecord.ID(recordName: namePrefix + entryID.rawValue, zoneID: zoneID)
    }

    /// The encoded JSON for `transcript`, refused when it exceeds `LibraryTranscript.maximumEncodedBytes`.
    public static func encode(_ transcript: LibraryTranscript) throws -> Data {
        let data = try JSONEncoder().encode(transcript)
        guard data.count <= LibraryTranscript.maximumEncodedBytes else {
            throw LibraryTransportError.transport("transcript for \(transcript.entryID.rawValue) exceeds the \(LibraryTranscript.maximumEncodedBytes) byte cap")
        }
        return data
    }

    /// Builds the record; `assetURL` must be a file holding `encode(transcript)` that the caller no longer needs.
    public static func record(transcript: LibraryTranscript, byteCount: Int, assetURL: URL, zoneID: CKRecordZone.ID) -> CKRecord {
        let record = CKRecord(recordType: recordType, recordID: recordID(entryID: transcript.entryID, zoneID: zoneID))
        record["entryID"] = transcript.entryID.rawValue as CKRecordValue
        record["revisionID"] = transcript.revisionID.rawValue as CKRecordValue
        record["byteCount"] = NSNumber(value: byteCount)
        record[assetField] = CKAsset(fileURL: assetURL)
        return record
    }

    /// Whether a fetched header (or full) record is the transcript for exactly this entry and revision.
    public static func matches(_ record: CKRecord, entryID: ItemID, revisionID: RevisionID) -> Bool {
        record.recordType == recordType && record["entryID"] as? String == entryID.rawValue
            && record["revisionID"] as? String == revisionID.rawValue
    }

    /// Decodes downloaded asset bytes, verifying the size cap and that they describe the requested transcript.
    public static func decode(_ data: Data, entryID: ItemID, revisionID: RevisionID) throws -> LibraryTranscript {
        guard data.count <= LibraryTranscript.maximumEncodedBytes else {
            throw LibraryTransportError.transport("transcript for \(entryID.rawValue) exceeds the size cap")
        }
        let value = try JSONDecoder().decode(LibraryTranscript.self, from: data)
        guard value.entryID == entryID, value.revisionID == revisionID else {
            throw LibraryTransportError.transport("transcript for \(entryID.rawValue) does not match its record")
        }
        return value
    }
}
