import CloudKit
import Foundation
import WiltedLibrary

// MARK: - Lifetime statistics (one named record, no engine, no zone scan)

extension CloudKitLibraryTransport {
    /// Mac only. Replaces the single statistics record. Only the library writer writes it, so a
    /// conflict means this process lacked the server's change tag and retries against the server copy.
    public func publishStats(_ stats: LibraryStats) async throws {
        guard isLibraryWriter else { throw LibraryTransportError.ownershipViolation("\(deviceID) may not publish statistics") }
        try await write(name: mapper.statsRecordID.recordName, conflictIsSuccess: false) { base in
            try self.mapper.record(stats: stats, existing: base)
        }
    }

    /// The Mac's published statistics, fetched by record name. Nil before the Mac has published,
    /// or when the record is not decodable by this client.
    public func readStats() async throws -> LibraryStats? {
        for record in try await fetchPresent([mapper.statsRecordID]) {
            if case let .stats(value)? = try? mapper.decode(record) { return value }
        }
        return nil
    }
}
