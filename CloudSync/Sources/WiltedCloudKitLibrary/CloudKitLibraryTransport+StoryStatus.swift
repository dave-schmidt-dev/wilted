import CloudKit
import Foundation
import WiltedLibrary

private enum StoryStatusRecord {
    static let type = "WiltedStoryStatus"
    static let field = "payload"

    static func id(device: String, request: String, zone: CKRecordZone.ID) throws -> CKRecord.ID {
        try LibraryStoryCloudRecordID.make(prefix: "story-status-", parts: [device, request], zone: zone)
    }

    static func needsUpdate(_ status: LibraryListenNextStatus, replacing record: CKRecord) throws -> Bool {
        let saved = try decode(record)
        guard saved.requestID == status.requestID, saved.requesterDeviceID == status.requesterDeviceID,
              saved.storyID == status.storyID else { throw LibraryTransportError.superseded }
        if saved.statusRevision == status.statusRevision && saved != status { throw LibraryTransportError.superseded }
        return saved.phase != .cancelled && saved.statusRevision < status.statusRevision
    }

    static func decode(_ record: CKRecord) throws -> LibraryListenNextStatus {
        guard record.recordType == type, let data = record[field] as? Data else {
            throw LibraryRecordMapperError.missingPayload(record.recordID.recordName)
        }
        return try JSONDecoder().decode(LibraryListenNextStatus.self, from: data)
    }
}

extension CloudKitLibraryTransport {
    public func publishListenNextStatus(_ status: LibraryListenNextStatus, expectedOwner: String) async throws {
        guard isLibraryWriter else { throw LibraryTransportError.ownershipViolation("Only the Mac can update reading progress.") }
        let generation = try await storyContext(expectedOwner)
        let id = try StoryStatusRecord.id(device: status.requesterDeviceID, request: status.requestID, zone: mapper.zoneID)
        // A restarted worker may replay the ready transition after the phone already received it.
        let current: CKRecord?
        if let cached = serverRecords[id.recordName] {
            current = cached
        } else {
            current = try await driver.fetchRecordsIfPresent([id], desiredKeys: nil).first
            try verifyFetchContext(generation: generation, owner: expectedOwner)
        }
        if let current, try !StoryStatusRecord.needsUpdate(status, replacing: current) { return }
        try await write(name: id.recordName, conflictIsSuccess: false, context: (generation, expectedOwner)) { base in
            if let base, try !StoryStatusRecord.needsUpdate(status, replacing: base) { return base }
            let record = base ?? CKRecord(recordType: StoryStatusRecord.type, recordID: id)
            record[StoryStatusRecord.field] = try JSONEncoder().encode(status) as CKRecordValue
            return record
        }
    }

    public func listenNextStatuses(requestIDs: Set<String>, expectedOwner: String) async throws -> [LibraryListenNextStatus] {
        guard !requestIDs.isEmpty else { return [] }
        let generation = try await storyContext(expectedOwner)
        let ids = try requestIDs.sorted().map {
            try StoryStatusRecord.id(device: deviceID, request: $0, zone: mapper.zoneID)
        }
        var statuses: [LibraryListenNextStatus] = []
        for start in stride(from: 0, to: ids.count, by: 100) {
            let page = Array(ids[start..<min(start + 100, ids.count)])
            let records = try await driver.fetchRecordsIfPresent(page, desiredKeys: [StoryStatusRecord.field])
            try verifyFetchContext(generation: generation, owner: expectedOwner)
            for record in records {
                let status = try StoryStatusRecord.decode(record)
                guard status.requesterDeviceID == deviceID, requestIDs.contains(status.requestID),
                      record.recordID == (try StoryStatusRecord.id(device: deviceID, request: status.requestID, zone: mapper.zoneID))
                else { throw LibraryTransportError.ownershipViolation("The reading status belongs to another request.") }
                statuses.append(status)
            }
        }
        return statuses.sorted { $0.requestID < $1.requestID }
    }
}
