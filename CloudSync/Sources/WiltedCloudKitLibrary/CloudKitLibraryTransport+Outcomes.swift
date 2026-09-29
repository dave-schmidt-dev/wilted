import CloudKit
import Foundation
import WiltedDomain
import WiltedLibrary

/// The intent ids the Mac has answered for one device. Only the library writer writes it.
public struct IntentOutcomeIndex: Codable, Sendable, Equatable {
    public let deviceID: String
    public let intentIDs: [String]
    public init(deviceID: String, intentIDs: [String]) {
        self.deviceID = deviceID
        self.intentIDs = intentIDs
    }
}

// MARK: - Intent outcomes (named records, no engine, no zone scan)

extension CloudKitLibraryTransport {
    /// Mac only. Saves the outcome, then adds it to the requesting device's index, so an index
    /// entry never points at a missing record. An outcome is immutable: republishing after a
    /// restart is a no-op.
    public func publishIntentOutcome(_ outcome: IntentOutcome) async throws {
        guard isLibraryWriter else { throw LibraryTransportError.ownershipViolation("\(deviceID) may not write intent outcomes") }
        let name = try mapper.recordID(outcome: outcome).recordName
        // An existing record is the first answer; it stays, and only the index below is repaired.
        if outcomeCache[name] == nil {
            let existing = try await fetchPresent([mapper.recordID(outcome: outcome)])
            if case let .outcome(first)? = existing.compactMap({ try? mapper.decode($0) }).first {
                outcomeCache[name] = first
            } else {
                try await write(name: name, conflictIsSuccess: true) { try self.mapper.record(outcome: outcome, existing: $0) }
                outcomeCache[name] = outcome
            }
        }
        peers.note(device: outcome.deviceID)
        let indexID = try mapper.recordID(outcomeIndexFor: outcome.deviceID)
        let device = outcome.deviceID
        try await write(name: indexID.recordName, conflictIsSuccess: false) { base in
            var merged: Set<String> = [outcome.intentID]
            if let base, case let .outcomeIndex(server)? = try? self.mapper.decode(base) { merged.formUnion(server.intentIDs) }
            return try self.mapper.record(outcomeIndex: IntentOutcomeIndex(deviceID: device, intentIDs: merged.sorted()), existing: base)
        }
    }

    /// Every outcome listed in the index of each device this transport knows, oldest first.
    public func intentOutcomes() async throws -> [IntentOutcome] {
        let devices = peers.devices.union([deviceID]).sorted()
        var wanted: [(name: String, deviceID: String, id: String)] = []
        for record in try await fetchPresent(devices.compactMap { try? mapper.recordID(outcomeIndexFor: $0) }) {
            guard case let .outcomeIndex(index)? = try? mapper.decode(record) else { continue }
            peers.note(device: index.deviceID)
            for id in index.intentIDs {
                guard let name = try? mapper.recordID(outcomeIntentID: id, deviceID: index.deviceID).recordName else { continue }
                wanted.append((name, index.deviceID, id))
            }
        }
        let missing = wanted.filter { outcomeCache[$0.name] == nil }
            .compactMap { try? mapper.recordID(outcomeIntentID: $0.id, deviceID: $0.deviceID) }
        for record in try await fetchPresent(missing) {
            if case let .outcome(value)? = try? mapper.decode(record) { outcomeCache[record.recordID.recordName] = value }
        }
        return wanted.compactMap { outcomeCache[$0.name] }.sorted { ($0.decidedAt, $0.intentID) < ($1.decidedAt, $1.intentID) }
    }
}
