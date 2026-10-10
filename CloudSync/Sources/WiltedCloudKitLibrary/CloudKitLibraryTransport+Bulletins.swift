import CloudKit
import Foundation
import WiltedLibrary

// MARK: - Bulletin channel (one named record, no engine, no zone scan)

extension CloudKitLibraryTransport {
    /// Mac only. Replaces the single bulletin record. Only the library writer writes it, so a
    /// conflict means this process lacked the server's change tag and retries against the server copy.
    public func publishBulletins(_ bulletins: LibraryBulletins) async throws {
        guard isLibraryWriter else { throw LibraryTransportError.ownershipViolation("\(deviceID) may not publish bulletins") }
        try await write(name: mapper.bulletinsRecordID.recordName, conflictIsSuccess: false) { base in
            try self.mapper.record(bulletins: bulletins, existing: base)
        }
    }

    /// The Mac's published bulletin channel, fetched by record name. Nil before the Mac has
    /// published, or when the record is not decodable by this client.
    public func fetchBulletins() async throws -> LibraryBulletins? {
        for record in try await fetchPresent([mapper.bulletinsRecordID]) {
            if case let .bulletins(value)? = try? mapper.decode(record) { return value }
        }
        return nil
    }
}
