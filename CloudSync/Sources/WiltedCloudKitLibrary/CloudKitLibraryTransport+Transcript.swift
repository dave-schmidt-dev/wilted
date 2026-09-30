import CloudKit
import Foundation
import WiltedCloudKit
import WiltedDomain
import WiltedLibrary

// MARK: - Transcripts (media zone, raw operations, read by name; no engine, no zone scan)

extension CloudKitLibraryTransport {
    /// Mac only. Uploads the transcript as one small asset record beside the audio. Replaces any
    /// earlier transcript for the entry, so a newer revision supersedes the older one.
    public func publishTranscript(_ transcript: LibraryTranscript) async throws {
        try requireTranscriptWriter()
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("wilted-transcript-upload-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        do {
            let data = try LibraryTranscriptRecord.encode(transcript)
            try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
            let file = scratch.appendingPathComponent("transcript.json")
            try data.write(to: file)
            let record = LibraryTranscriptRecord.record(transcript: transcript, byteCount: data.count, assetURL: file, zoneID: mapper.mediaZoneID)
            log.notice("Uploading \(data.count, privacy: .public) bytes of transcript for \(transcript.entryID.rawValue, privacy: .public)")
            try await driver.ensureZone(mapper.mediaZoneID)
            try await driver.saveRecordRaw(record) { _ in }
            log.notice("Uploaded transcript for \(transcript.entryID.rawValue, privacy: .public)")
        } catch { throw failure(error) }
    }

    /// The transcript for exactly this revision, or nil when none is published, it belongs to
    /// another revision, it was withdrawn while being fetched, or its bytes are undecodable. A cheap header read decides
    /// first, so a missing or stale record never downloads the asset.
    public func transcript(entryID: ItemID, revisionID: RevisionID) async throws -> LibraryTranscript? {
        guard !quarantined else { throw CloudKitSyncError.quarantined }
        let id = LibraryTranscriptRecord.recordID(entryID: entryID, zoneID: mapper.mediaZoneID)
        let destination = FileManager.default.temporaryDirectory.appendingPathComponent("wilted-transcript-\(UUID().uuidString).download")
        defer { try? FileManager.default.removeItem(at: destination) }
        do {
            let header = try await driver.fetchRecordsIfPresent([id], desiredKeys: LibraryTranscriptRecord.headerKeys)
            guard let found = header.first, LibraryTranscriptRecord.matches(found, entryID: entryID, revisionID: revisionID) else { return nil }
            let record: CKRecord
            do {
                record = try await driver.fetchAssetRecordRaw(id, assetField: LibraryTranscriptRecord.assetField, to: destination) { _ in }
            } catch CloudKitSyncError.assetUnavailable {
                return nil
            } catch let error as CKError where error.code == .unknownItem {
                return nil
            }
            // The record may have been replaced between the header read and the download.
            guard LibraryTranscriptRecord.matches(record, entryID: entryID, revisionID: revisionID) else { return nil }
            do {
                return try LibraryTranscriptRecord.decode(Data(contentsOf: destination), entryID: entryID, revisionID: revisionID)
            } catch {
                // A transcript is optional: an undecodable one reads as absent rather than failing every poll.
                log.error("Ignoring undecodable transcript for \(entryID.rawValue, privacy: .public): \(String(describing: error), privacy: .public)")
                return nil
            }
        } catch { throw failure(error) }
    }

    /// Mac only. Withdraws the transcript for `entryID`; absent is success.
    public func removeTranscript(entryID: ItemID) async throws {
        try requireTranscriptWriter()
        do {
            try await driver.deleteRecordsRaw([LibraryTranscriptRecord.recordID(entryID: entryID, zoneID: mapper.mediaZoneID)])
        } catch { throw failure(error) }
        log.notice("Removed transcript for \(entryID.rawValue, privacy: .public)")
    }

    private func requireTranscriptWriter() throws {
        guard isLibraryWriter else { throw LibraryTransportError.ownershipViolation("\(deviceID) may not publish transcripts") }
        guard !quarantined else { throw CloudKitSyncError.quarantined }
    }
}
