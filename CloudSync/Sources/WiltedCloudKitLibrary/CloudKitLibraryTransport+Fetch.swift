import CloudKit
import Foundation
import WiltedCloudKit
import WiltedLibrary

/// Engine fetch accumulation and complete-batch admission.
extension CloudKitLibraryTransport {
    public func fetchChanges(since token: LibraryChangeToken?) async throws -> LibraryChangeBatch {
        let wanted = try Self.stateData(token)
        await acquire()
        defer { release() }
        guard !quarantined else { throw CloudKitSyncError.quarantined }
        let generation = operationGenerationValue
        let admittedOwner = observedOwnerToken
        do {
            if needsFetchRebuild || wanted != enginePosition || (wanted == nil && !freshNilDriver) {
                try await replaceDriver(state: wanted)
                try verifyFetchContext(generation: generation, owner: admittedOwner)
            }
            try await observeCurrentOwner(generation: generation)
            let owner = observedOwnerToken
            var fullBootstrap = wanted == nil && freshNilDriver
            let acc: LibraryFetchAccumulator
            do { acc = try await runFetch(on: driver, epoch: mainEpoch) }
            catch where Self.isServerReset(error) {
                log.notice("Library zone or engine state missing on the server; discarding engine state")
                try await resetAfterServerReset()
                try verifyFetchContext(generation: generation, owner: owner)
                fullBootstrap = freshNilDriver
                acc = try await runFetch(on: driver, epoch: mainEpoch)
            }
            try await observeCurrentOwner(generation: generation)
            try verifyFetchContext(generation: generation, owner: owner)
            freshNilDriver = false
            if !acc.library.isEmpty, acc.state == nil { throw CloudKitSyncError.stateCorrupt }
            enginePosition = acc.state ?? enginePosition
            provisionalFetchToken = enginePosition.map(Self.token)
            return LibraryChangeBatch(
                generationID: "\(mapper.zoneID.zoneName):\(resetCount)",
                changes: acc.library.values.sorted { ($0.version, $0.change.key.description) < ($1.version, $1.change.key.description) },
                token: provisionalFetchToken ?? token,
                provenance: owner.map { .init(ownerToken: $0, operationGeneration: generation, isFullBootstrap: fullBootstrap) },
                observedPublication: acc.publication)
        } catch {
            needsFetchRebuild = true
            freshNilDriver = false
            throw failure(error)
        }
    }

    func runFetch(on target: any CloudKitEngineDriver, epoch: Int) async throws -> LibraryFetchAccumulator {
        let generation = operationGenerationValue
        let owner = observedOwnerToken
        try await target.ensureZone()
        try verifyFetchContext(generation: generation, owner: owner)
        fetchAcc = LibraryFetchAccumulator()
        operation = .fetch
        activeEpoch = epoch
        defer { operation = nil; activeEpoch = -1 }
        let zones: Set<CKRecordZone.ID> = [mapper.zoneID]
        try await wait { try await target.fetchChanges(zoneIDs: zones) }
        try verifyFetchContext(generation: generation, owner: owner)
        if let error = fetchAcc.error { throw error }
        return fetchAcc
    }

    func ingest(_ records: [CKRecord], _ deletions: [CloudKitRecordDeletion]) {
        guard fetchAcc.error == nil else { return }
        for record in records {
            let name = record.recordID.recordName
            do {
                switch try decodeTolerant(record) {
                case let .skipped(type):
                    log.notice("Skipping fetched record of unknown type \(type, privacy: .public)")
                case let .library(change):
                    guard let version = LibraryRecordMapper.version(of: record) else {
                        throw LibraryRecordMapperError.missingVersion
                    }
                    serverRecords[name] = record
                    if (fetchAcc.library[change.key]?.version ?? 0) < version {
                        fetchAcc.library[change.key] = VersionedLibraryChange(version: version, change: change)
                    }
                case let .playback(channel, value):
                    serverRecords[name] = record
                    fetchAcc.playback[name] = (channel, ObservedPlayback(record: value, serverModifiedAt: record.modificationDate ?? .distantPast))
                    peers.note(device: value.deviceID, entry: value.entryID)
                case let .intent(value):
                    serverRecords[name] = record
                    fetchAcc.intents[name] = value
                    intentCache[name] = value
                    peers.note(device: value.deviceID)
                case let .offer(offer):
                    serverRecords[name] = record
                    peers.note(entry: offer.entryID)
                case let .offerIndex(index):
                    serverRecords[name] = record
                    index.entryIDs.forEach { peers.note(entry: $0) }
                case let .intentIndex(index):
                    serverRecords[name] = record
                    peers.note(device: index.deviceID)
                case let .outcome(outcome):
                    serverRecords[name] = record
                    outcomeCache[name] = outcome
                    peers.note(device: outcome.deviceID)
                case let .outcomeIndex(index):
                    serverRecords[name] = record
                    peers.note(device: index.deviceID)
                case .stats:
                    serverRecords[name] = record
                case let .publication(value):
                    if fetchAcc.publication == nil || value.publishedAt > fetchAcc.publication!.publishedAt {
                        fetchAcc.publication = value
                    }
                }
            } catch {
                let libraryTypes: Set<LibraryRecordType> = [.entry, .source, .slot, .listening]
                if let type = LibraryRecordType(rawValue: record.recordType), libraryTypes.contains(type) {
                    fetchAcc.error = error
                    return
                }
                log.notice("Ignoring undecodable optional library metadata")
            }
        }
        for deletion in deletions {
            serverRecords[deletion.recordID.recordName] = nil
            if let change = mapper.deletion(recordID: deletion.recordID, recordType: deletion.recordType) {
                fetchAcc.library[change.key] = VersionedLibraryChange(version: deletionVersion(change.key, floor: 0), change: change)
            } else {
                log.notice("Ignoring deletion of \(deletion.recordType, privacy: .public)")
            }
        }
    }


    func verifyFetchContext(generation: UInt64, owner: String?) throws {
        guard !quarantined, generation == operationGenerationValue, owner == observedOwnerToken else {
            throw LibraryTransportError.superseded
        }
    }

    /// Checks the actual current account without discovering its name or exposing its record ID.
    /// A legacy driver leaves evidence unknown; failures never clear a held account.
    func observeCurrentOwner(generation: UInt64) async throws {
        guard !quarantined else { throw CloudKitSyncError.quarantined }
        let epoch = mainEpoch
        let priorOwner = observedOwnerToken
        let identity = try await driver.currentAccountIdentity()
        guard !quarantined, epoch == mainEpoch, generation == operationGenerationValue,
              priorOwner == observedOwnerToken else { throw LibraryTransportError.superseded }
        if let identity {
            await handleAccountChange(identity.currentOwnerToken == nil ? .signOut : .signIn, identity)
            guard !quarantined, generation == operationGenerationValue else { throw LibraryTransportError.superseded }
        }
    }
}
