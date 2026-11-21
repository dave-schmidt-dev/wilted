import CloudKit
import Foundation
import WiltedCloudKit
import WiltedLibrary

// MARK: - The device handshake (named records, no engine, no zone scan)

extension CloudKitLibraryTransport {
    /// Follower only. Merges this device's announcement into a fresh read of the directory (other
    /// devices write it too, so a cached copy may be stale), and a conflict with a device announcing
    /// at the same moment is retried on the newer copy. Announcing is rare, so the read costs little.
    public func announceDevice(_ announcement: LibraryDeviceAnnouncement) async throws {
        try await CloudKitOperationContext.$caller.withValue(.deviceLink) {
            guard !isLibraryWriter, announcement.deviceID == deviceID else {
                throw LibraryTransportError.ownershipViolation("\(deviceID) may only announce itself, and only as a follower")
            }
            _ = try await fetchPresent([mapper.deviceDirectoryRecordID])
            try await write(name: mapper.deviceDirectoryRecordID.recordName, conflictIsSuccess: false) { base in
                var directory = LibraryDeviceDirectory()
                if let base, case let .deviceDirectory(server)? = try? self.mapper.decode(base) { directory = server }
                return try self.mapper.record(deviceDirectory: directory.merging(announcement), existing: base)
            }
        }
    }

    public func fetchDeviceDirectory() async throws -> LibraryDeviceDirectory? {
        try await CloudKitOperationContext.$caller.withValue(.deviceLink) {
            do {
                for record in try await fetchPresent([mapper.deviceDirectoryRecordID]) {
                    if case let .deviceDirectory(value)? = try? mapper.decode(record) {
                        consecutiveDirectoryFailures = 0
                        directoryRecordPresent = true
                        let now = clock()
                        for device in value.devices {
                            if now.timeIntervalSince(device.announcedAt) <= LibraryDeviceDirectory.announcementLifetime {
                                peers.note(device: device.deviceID, announcedAt: device.announcedAt)
                            } else {
                                peers.remove(device: device.deviceID)
                            }
                        }
                        return value
                    }
                }
                return nil
            } catch {
                consecutiveDirectoryFailures += 1
                throw error
            }
        }
    }

    /// Mac only. Merges `link` into the server copy, keeping the earlier `linkedAt` and the newer
    /// status of each request, so a restarted Mac never resets a device's handshake.
    public func publishDeviceLink(_ link: LibraryDeviceLink) async throws {
        try await CloudKitOperationContext.$caller.withValue(.deviceLink) {
            guard isLibraryWriter else { throw LibraryTransportError.ownershipViolation("\(deviceID) may not write device links") }
            let id = try mapper.recordID(deviceLinkFor: link.deviceID)
            let name = id.recordName
            try await loadBase(id)
            try await write(name: name, conflictIsSuccess: false) { base in
                var server: LibraryDeviceLink?
                if let base, case let .deviceLink(value)? = try? self.mapper.decode(base) { server = value }
                return try self.mapper.record(deviceLink: link.updating(nil, server: server, now: self.clock()), existing: base)
            }
            peers.note(device: link.deviceID)
        }
    }

    /// Mac only. Removes exactly the selected follower link record, leaving the directory and
    /// every library, request, playback and other device record untouched.
    public func deleteDeviceLink(deviceID: String) async throws {
        try await CloudKitOperationContext.$caller.withValue(.deviceLink) {
            await acquire()
            defer { release() }
            guard isLibraryWriter, deviceID != self.deviceID else {
                throw LibraryTransportError.ownershipViolation("\(self.deviceID) may only remove a follower device link")
            }
            guard !quarantined else { throw CloudKitSyncError.quarantined }
            let generation = operationGenerationValue
            try await observeCurrentOwner(generation: generation)
            let owner = observedOwnerToken
            try verifyFetchContext(generation: generation, owner: owner)
            let id = try mapper.recordID(deviceLinkFor: deviceID)
            do {
                try await driver.deleteRecordsRaw([id])
                try await observeCurrentOwner(generation: generation)
                try verifyFetchContext(generation: generation, owner: owner)
                serverRecords.removeValue(forKey: id.recordName)
                peers.remove(device: deviceID)
            } catch {
                throw failure(error)
            }
        }
    }

    /// Reads the server copy a merge builds on, once: only this Mac writes links, so later writes keep it current.
    private func loadBase(_ id: CKRecord.ID) async throws {
        if serverRecords[id.recordName] == nil { _ = try await fetchPresent([id]) }
    }

    public func fetchDeviceLink() async throws -> LibraryDeviceLink? {
        try await CloudKitOperationContext.$caller.withValue(.deviceLink) {
            for record in try await fetchPresent([mapper.recordID(deviceLinkFor: deviceID)]) {
                if case let .deviceLink(value)? = try? mapper.decode(record), value.deviceID == deviceID { return value }
            }
            return nil
        }
    }
}
