import CloudKit
import CryptoKit
import Foundation
import WiltedLibrary

/// A completed reading addressed to one request. No entry in the shared offer index is created.
enum LibraryStoryAudioRecord {
    static let recordType = "WiltedStoryAudio"
    static let offerField = "offer"

    static func id(for offer: LibraryStoryAudioOffer, in zone: CKRecordZone.ID) throws -> CKRecord.ID {
        // Encoding the parts separately avoids delimiter collisions in device and request IDs.
        let parts = [offer.requesterDeviceID, offer.requestID, offer.storyID, offer.voiceID,
                     offer.voiceRevision, offer.audioRevision.rawValue]
        return try LibraryStoryCloudRecordID.make(prefix: "story-audio-", parts: parts, zone: zone)
    }

    static func record(for offer: LibraryStoryAudioOffer, audio: URL, in zone: CKRecordZone.ID) throws -> CKRecord {
        let record = CKRecord(recordType: recordType, recordID: try id(for: offer, in: zone))
        record[offerField] = try JSONEncoder().encode(offer) as CKRecordValue
        record[LibraryMediaRecord.assetField] = CKAsset(fileURL: audio)
        return record
    }

    static func verify(_ record: CKRecord, expected: LibraryStoryAudioOffer, id: CKRecord.ID) throws {
        guard record.recordType == recordType, record.recordID == id,
              let encoded = record[offerField] as? Data,
              try JSONDecoder().decode(LibraryStoryAudioOffer.self, from: encoded) == expected else {
            throw LibraryTransportError.transport("The requested story audio changed.")
        }
    }

    static func verifySizeLimit(_ offer: LibraryStoryAudioOffer) throws {
        guard offer.byteCount > 0, offer.byteCount <= LibraryMediaRecord.maximumByteCount,
              MediaHash.isWellFormed(offer.contentHash) else {
            throw LibraryTransportError.transport("The story audio size or checksum is invalid.")
        }
    }

    static func verifyFile(_ url: URL, expected offer: LibraryStoryAudioOffer) throws {
        try verifySizeLimit(offer)
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard (attributes[.size] as? NSNumber)?.int64Value == offer.byteCount,
              try MediaHash.sha256(fileAt: url) == offer.contentHash else {
            throw LibraryTransportError.transport("The story audio does not match its checksum.")
        }
    }
}

enum LibraryStoryCloudRecordID {
    static func make(prefix: String, parts: [String], zone: CKRecordZone.ID) throws -> CKRecord.ID {
        let digest = SHA256.hash(data: try JSONEncoder().encode(parts))
        let suffix = digest.map { String(format: "%02x", $0) }.joined()
        return CKRecord.ID(recordName: prefix + suffix, zoneID: zone)
    }
}
