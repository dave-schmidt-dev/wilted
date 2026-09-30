import CloudKit
import Foundation
import OSLog
import WiltedCloudKit
import WiltedDomain
import WiltedLibrary

/// `LibraryTransport` over one `CKSyncEngine` in `WiltedLibraryZone`.
///
/// The engine's serialized state is the change token: it is provisional until the caller
/// commits it after its store has applied the batch, and a token that differs from the live
/// engine's position rebuilds the engine from that token. When the server reports the zone
/// or the state missing (a Development reset) the state is discarded and the library is
/// refetched from nothing. Account changes are quarantined through `CloudKitAccountOwnership`.
public actor CloudKitLibraryTransport: LibraryTransport {
    public nonisolated let accountChanges: AsyncStream<CloudKitAccountChangeSignal>
    public nonisolated let deviceID: String
    public nonisolated let isLibraryWriter: Bool
    let mapper: LibraryRecordMapper

    private enum Operation { case fetch, send }
    private let driverFactory: CloudKitEngineDriverFactory
    private let outbox: CloudKitLibraryOutbox
    let log = Logger(subsystem: "com.zerodelta.wilted", category: "CloudKitLibraryTransport")
    var driver: any CloudKitEngineDriver
    private var mainEpoch = 0
    private var activeEpoch = -1
    private var consumer: Task<Void, Never>?
    /// Fetch position of the live engine; a differing `since` token rebuilds it.
    private var enginePosition: Data?
    private var resetCount = 0
    private var scanCount = 0
    private var operationGenerationValue: UInt64 = 0
    var quarantined = false
    private var knownOwnerToken: String?
    private var operation: Operation?
    private var waiter: CheckedContinuation<Void, Error>?
    private var fetchAcc = LibraryFetchAccumulator()
    private var sendAcc = LibrarySendAccumulator()
    var serverRecords: [String: CKRecord] = [:]
    private var busy = false
    /// Devices and entries learned from fetched records, so targeted fetches know which names to ask for.
    var peers = LibraryPeerDirectory()
    var intentCache: [String: LibraryIntent] = [:]
    /// Outcomes already fetched; an outcome is immutable, so a cached one never needs refreshing.
    var outcomeCache: [String: IntentOutcome] = [:]
    /// This device's own sent intent ids; nil until first loaded from its index record.
    var ownIntentIDs: Set<String>?
    /// Seconds without upload or download progress before a media transfer is abandoned.
    let mediaWatchdogInterval: TimeInterval
    private var gate: [CheckedContinuation<Void, Never>] = []
    private let accountContinuation: AsyncStream<CloudKitAccountChangeSignal>.Continuation
    public private(set) var provisionalFetchToken: LibraryChangeToken?
    public private(set) var committedFetchToken: LibraryChangeToken?
    public private(set) var committedSentToken: LibraryChangeToken?

    /// `driver` must have been built from `state`; `driverFactory` rebuilds it for a different token or a reset.
    public init(deviceID: String, isLibraryWriter: Bool, driver: any CloudKitEngineDriver,
                driverFactory: @escaping CloudKitEngineDriverFactory, outbox: CloudKitLibraryOutbox,
                state: LibraryChangeToken? = nil, knownOwnerToken: String? = nil,
                mapper: LibraryRecordMapper = LibraryRecordMapper(),
                mediaWatchdogInterval: TimeInterval = 300) throws {
        self.mediaWatchdogInterval = mediaWatchdogInterval
        self.deviceID = deviceID
        self.isLibraryWriter = isLibraryWriter
        self.driver = driver
        self.driverFactory = driverFactory
        self.outbox = outbox
        self.mapper = mapper
        self.knownOwnerToken = knownOwnerToken
        self.enginePosition = try Self.stateData(state)
        self.committedFetchToken = state
        (accountChanges, accountContinuation) = AsyncStream<CloudKitAccountChangeSignal>.makeStream()
        Task { [weak self] in await self?.startConsuming() }
    }

    /// Engine events are buffered by the driver, so starting after `init` loses none.
    private func startConsuming() {
        if consumer == nil { consumer = consume(driver, epoch: mainEpoch) }
    }

    // MARK: LibraryTransport

    public func operationGeneration() async -> UInt64 { operationGenerationValue }
    public func isQuarantined() -> Bool { quarantined }

    public func fetchChanges(since token: LibraryChangeToken?) async throws -> LibraryChangeBatch {
        let wanted = try Self.stateData(token)
        await acquire()
        defer { release() }
        guard !quarantined else { throw CloudKitSyncError.quarantined }
        do {
            if wanted != enginePosition { try await replaceDriver(state: wanted) }
            let acc: LibraryFetchAccumulator
            do { acc = try await runFetch(on: driver, epoch: mainEpoch) }
            catch where Self.isServerReset(error) {
                log.notice("Library zone or engine state missing on the server; discarding engine state")
                try await resetAfterServerReset()
                acc = try await runFetch(on: driver, epoch: mainEpoch)
            }
            if !acc.library.isEmpty, acc.state == nil { throw CloudKitSyncError.stateCorrupt }
            enginePosition = acc.state ?? enginePosition
            provisionalFetchToken = enginePosition.map(Self.token)
            return LibraryChangeBatch(
                generationID: "\(mapper.zoneID.zoneName):\(resetCount)",
                changes: acc.library.values.sorted { ($0.version, $0.change.key.description) < ($1.version, $1.change.key.description) },
                token: provisionalFetchToken ?? token)
        } catch { throw failure(error) }
    }

    public func push(changes: [PendingLibraryChange]) async throws -> LibraryPushResult {
        guard isLibraryWriter else { throw LibraryTransportError.ownershipViolation("\(deviceID) may not write library state") }
        await acquire()
        defer { release() }
        guard !quarantined else { throw CloudKitSyncError.quarantined }
        guard !changes.isEmpty else { return LibraryPushResult() }
        do {
            try await driver.ensureZone()
            let bases = try await baseRecords(for: changes)
            var saves: [CKRecord] = [], deletes: [CKRecord.ID] = []
            var sent: [PendingLibraryChange] = [], failures: [LibraryPushFailure] = []
            for pending in changes {
                let existing = bases[mapper.recordID(for: pending.key).recordName]
                if let server = existing, let version = LibraryRecordMapper.version(of: server), version > pending.baseVersion,
                   pending.baseVersion > 0 {
                    failures.append(conflict(pending.key, server))
                    continue
                }
                do {
                    switch try mapper.operation(for: pending.change, existing: existing) {
                    case let .save(record): saves.append(record)
                    case let .delete(id): deletes.append(id)
                    }
                    sent.append(pending)
                } catch {
                    failures.append(LibraryPushFailure(key: pending.key, disposition: .retryable))
                }
            }
            guard !sent.isEmpty else { return LibraryPushResult(failures: failures) }
            let acc = try await runSend(saves: saves, deletes: deletes)
            if acc.zoneMissing {
                return LibraryPushResult(failures: failures + sent.map { LibraryPushFailure(key: $0.key, disposition: .retryable) })
            }
            var acknowledged: [LibraryAcknowledgement] = []
            for pending in sent {
                let id = mapper.recordID(for: pending.key).recordName
                if let version = acc.saved[id] {
                    acknowledged.append(.init(key: pending.key, version: version))
                } else if acc.deleted.contains(id) {
                    acknowledged.append(.init(key: pending.key, version: deletionVersion(pending.key, floor: pending.baseVersion)))
                } else if let failed = acc.failed[id] {
                    if failed.disposition == .conflict, let server = failed.server { failures.append(conflict(pending.key, server)) }
                    else { failures.append(.init(key: pending.key, disposition: failed.disposition == .conflict ? .retryable : failed.disposition)) }
                } else {
                    failures.append(.init(key: pending.key, disposition: .retryable))
                }
            }
            return LibraryPushResult(token: acc.state.map(Self.token), acknowledged: acknowledged, failures: failures)
        } catch { throw failure(error) }
    }

    public func send(intent: LibraryIntent) async throws {
        guard intent.deviceID == deviceID else {
            throw LibraryTransportError.ownershipViolation("\(deviceID) may not write intents for \(intent.deviceID)")
        }
        let id = try mapper.recordID(intent: intent).recordName
        // An intent is immutable, so an existing record with this id is the same request.
        try await write(name: id, conflictIsSuccess: true) { try self.mapper.record(intent: intent, existing: $0) }
        // Second write: if it fails the caller retries `send`, and the immutable intent above is then a no-op.
        try await recordOwnIntent(intent.id)
    }

    public func publish(_ record: DevicePlaybackPosition, as channel: PlaybackChannel) async throws {
        guard record.deviceID == deviceID else {
            throw LibraryTransportError.ownershipViolation("\(deviceID) may not write records for \(record.deviceID)")
        }
        let id = try mapper.recordID(playback: record, channel: channel).recordName
        try await write(name: id, conflictIsSuccess: false) { try self.mapper.record(playback: record, channel: channel, existing: $0) }
    }

    public func commitFetchedState(_ token: LibraryChangeToken?) async throws {
        guard !quarantined else { throw CloudKitSyncError.quarantined }
        guard token == provisionalFetchToken || token == committedFetchToken else { throw CloudKitSyncError.stateCorrupt }
        committedFetchToken = token
    }

    public func commitSentState(_ token: LibraryChangeToken?) async throws {
        guard !quarantined else { throw CloudKitSyncError.quarantined }
        committedSentToken = token
    }

    /// Re-enables operations once the owner has reviewed an account change.
    public func resetAfterAccountChange() async {
        await driver.resetZoneBootstrap()
        quarantined = false
        knownOwnerToken = nil
        enginePosition = nil
        committedFetchToken = nil
        serverRecords = [:]
    }

    // MARK: Device records

    /// Every device record and intent, read by a throwaway engine with no state so it sees the
    /// whole zone. Only `discoverPeers()` uses it: polling reads named records instead.
    func scan() async throws -> LibraryFetchAccumulator {
        await acquire()
        defer { release() }
        guard !quarantined else { throw CloudKitSyncError.quarantined }
        do {
            let scanDriver = try driverFactory(nil)
            scanCount += 1
            let scanEpoch = -scanCount - 1
            let task = consume(scanDriver, epoch: scanEpoch)
            defer { task.cancel() }
            defer { Task { await scanDriver.cancelOperations() } }
            try await scanDriver.ensureZone()
            return try await runFetch(on: scanDriver, epoch: scanEpoch)
        } catch { throw failure(error) }
    }

    func write(name: String, conflictIsSuccess: Bool, build: (CKRecord?) throws -> CKRecord) async throws {
        await acquire()
        defer { release() }
        guard !quarantined else { throw CloudKitSyncError.quarantined }
        do {
            var base = serverRecords[name]
            for _ in 1...2 {
                try await driver.ensureZone()
                let acc = try await runSend(saves: [try build(base)], deletes: [])
                if acc.saved[name] != nil { return }
                if let failed = acc.failed[name] {
                    guard failed.disposition == .conflict else {
                        throw LibraryTransportError.transport("save failed: \(failed.disposition.rawValue)")
                    }
                    if conflictIsSuccess { return }
                    base = failed.server
                    continue
                }
                if acc.zoneMissing { base = nil }
            }
            throw LibraryTransportError.transport("record \(name) was not acknowledged")
        } catch { throw failure(error) }
    }

    // MARK: Engine plumbing

    func runFetch(on target: any CloudKitEngineDriver, epoch: Int) async throws -> LibraryFetchAccumulator {
        try await target.ensureZone()
        fetchAcc = LibraryFetchAccumulator()
        operation = .fetch
        activeEpoch = epoch
        defer { operation = nil; activeEpoch = -1 }
        let zones: Set<CKRecordZone.ID> = [mapper.zoneID]
        try await wait { try await target.fetchChanges(zoneIDs: zones) }
        return fetchAcc
    }

    func runSend(saves: [CKRecord], deletes: [CKRecord.ID]) async throws -> LibrarySendAccumulator {
        outbox.set(saves)
        defer { outbox.clear() }
        sendAcc = LibrarySendAccumulator()
        operation = .send
        activeEpoch = mainEpoch
        defer { operation = nil; activeEpoch = -1 }
        let target = driver
        await target.addPendingRecordZoneChanges(saves.map { .saveRecord($0.recordID) } + deletes.map { .deleteRecord($0) })
        do { try await wait { try await target.sendChanges() } }
        catch where Self.isServerReset(error) { sendAcc.zoneMissing = true }
        if sendAcc.zoneMissing {
            log.notice("Library zone missing while sending; discarding engine state")
            try await resetAfterServerReset()
        }
        return sendAcc
    }

    private func wait(_ body: @escaping @Sendable () async throws -> Void) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            waiter = continuation
            Task {
                do { try await body() } catch { self.finish(.failure(error)) }
            }
        }
    }

    private func finish(_ result: Result<Void, Error>) {
        guard let pending = waiter else { return }
        waiter = nil
        pending.resume(with: result)
    }

    private func replaceDriver(state: Data?) async throws {
        let replacement = try driverFactory(state)
        consumer?.cancel()
        await driver.cancelOperations()
        driver = replacement
        mainEpoch += 1
        enginePosition = state
        serverRecords = [:]
        consumer = consume(replacement, epoch: mainEpoch)
    }

    private func resetAfterServerReset() async throws {
        resetCount += 1
        try await replaceDriver(state: nil)
        await driver.resetZoneBootstrap()
        committedFetchToken = nil
        provisionalFetchToken = nil
    }

    private nonisolated func consume(_ target: any CloudKitEngineDriver, epoch: Int) -> Task<Void, Never> {
        Task { [weak self] in
            for await event in await target.events { await self?.handle(event, epoch: epoch) }
        }
    }

    func acquire() async {
        if !busy { busy = true; return }
        await withCheckedContinuation { gate.append($0) }
    }

    func release() {
        if gate.isEmpty { busy = false } else { gate.removeFirst().resume() }
    }

    func failure(_ error: Error) -> Error {
        if quarantined { return CloudKitSyncError.accountChanged }
        if error is LibraryTransportError || error is LibraryRecordMapperError { return error }
        return CloudKitSyncError.map(error)
    }

    // MARK: Events

    private func handle(_ event: CloudKitEngineEvent, epoch: Int) async {
        if case let .accountChanged(changeType, identity) = event {
            if epoch == mainEpoch { await handleAccountChange(changeType, identity) }
            return
        }
        guard epoch == activeEpoch, !quarantined else { return }
        switch event {
        case let .stateUpdated(data):
            guard !data.isEmpty else { return }
            if operation == .fetch { fetchAcc.state = data } else { sendAcc.state = data }
        case let .fetched(modifications, deletions):
            guard operation == .fetch else { return }
            ingest(modifications, deletions)
        case .fetchCompleted:
            if operation == .fetch { finish(.success(())) }
        case let .sent(saved, failed, deleted, failedDeletes):
            guard operation == .send else { return }
            recordSent(saved, failed.map { ($0.record.recordID, $0.error) }, deleted, failedDeletes)
        case .sendCompleted:
            if operation == .send { finish(.success(())) }
        default: break
        }
    }

    private func handleAccountChange(_ changeType: CloudKitAccountChangeType, _ identity: CloudKitAccountIdentity) async {
        switch CloudKitAccountOwnership.resolve(changeType: changeType, identity: identity, recordedOwnerToken: knownOwnerToken) {
        case let .adopt(token):
            knownOwnerToken = token
            accountContinuation.yield(.ownershipAdopted(token: token))
        case .confirmed:
            accountContinuation.yield(.ownershipConfirmed)
        case .quarantine:
            operationGenerationValue &+= 1
            quarantined = true
            await driver.resetZoneBootstrap()
            serverRecords = [:]
            enginePosition = nil
            finish(.failure(CloudKitSyncError.accountChanged))
            accountContinuation.yield(.quarantineRequired(changeType))
        }
    }

    private func ingest(_ records: [CKRecord], _ deletions: [CloudKitRecordDeletion]) {
        for record in records {
            let name = record.recordID.recordName
            do {
                switch try mapper.decode(record) {
                case let .skipped(type):
                    log.notice("Skipping fetched record of unknown type \(type, privacy: .public)")
                case let .library(change):
                    guard let version = LibraryRecordMapper.version(of: record) else {
                        log.error("Skipping record \(name, privacy: .public) without a modification date")
                        continue
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
                }
            } catch {
                log.error("Skipping undecodable record \(name, privacy: .public): \(String(describing: error), privacy: .public)")
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

    private func recordSent(_ saved: [CKRecord], _ failed: [(CKRecord.ID, Error)], _ deleted: [CKRecord.ID],
                            _ failedDeletes: [CKRecord.ID: CKError]) {
        for record in saved {
            serverRecords[record.recordID.recordName] = record
            sendAcc.saved[record.recordID.recordName] = LibraryRecordMapper.version(of: record) ?? Self.nowMicros
        }
        for id in deleted { sendAcc.deleted.insert(id.recordName); serverRecords[id.recordName] = nil }
        for (id, error) in failed + failedDeletes.map({ ($0.key, $0.value as Error) }) {
            let ckError = error as? CKError
            if ckError?.code == .unknownItem, failedDeletes[id] != nil { sendAcc.deleted.insert(id.recordName); continue }
            if Self.isServerReset(error) { sendAcc.zoneMissing = true; continue }
            if let server = ckError?.serverRecord, ckError?.code == .serverRecordChanged {
                serverRecords[id.recordName] = server
                sendAcc.failed[id.recordName] = (.conflict, server)
                continue
            }
            let retryable: Set<CKError.Code> = [.requestRateLimited, .serviceUnavailable, .networkFailure, .networkUnavailable,
                                                .zoneBusy, .batchRequestFailed, .operationCancelled]
            sendAcc.failed[id.recordName] = (ckError.map { retryable.contains($0.code) } == true ? .retryable : .terminal, nil)
        }
    }

    // MARK: Helpers

    private static var nowMicros: UInt64 { UInt64(Date().timeIntervalSince1970 * 1_000_000) }

    /// A deletion carries no server timestamp, so it is stamped with the local clock but never
    /// below what this transport has seen for the key, keeping versions increasing per key.
    private func deletionVersion(_ key: LibraryRecordKey, floor: UInt64) -> UInt64 {
        let seen = serverRecords[mapper.recordID(for: key).recordName].flatMap(LibraryRecordMapper.version(of:)) ?? 0
        return max(Self.nowMicros, seen + 1, floor + 1)
    }

    private func conflict(_ key: LibraryRecordKey, _ server: CKRecord) -> LibraryPushFailure {
        guard case let .library(change)? = try? mapper.decode(server), let version = LibraryRecordMapper.version(of: server) else {
            return LibraryPushFailure(key: key, disposition: .retryable)
        }
        serverRecords[server.recordID.recordName] = server
        return LibraryPushFailure(key: key, disposition: .conflict, server: VersionedLibraryChange(version: version, change: change))
    }

    /// The server's current record for every pending change that updates one, from the cache
    /// when it is still at the base version and from the server otherwise. A record the server
    /// no longer has (after a reset) is simply absent, so the change is written as new.
    private func baseRecords(for changes: [PendingLibraryChange]) async throws -> [String: CKRecord] {
        var found: [String: CKRecord] = [:]
        var missing: [CKRecord.ID] = []
        for pending in changes where pending.baseVersion > 0 {
            if case .slotRemoved = pending.change { continue }
            let id = mapper.recordID(for: pending.key)
            if let cached = serverRecords[id.recordName], LibraryRecordMapper.version(of: cached) == pending.baseVersion {
                found[id.recordName] = cached
            } else { missing.append(id) }
        }
        for id in missing {
            do { found[id.recordName] = try await driver.fetchRecords([id]).first { $0.recordID == id } }
            catch let error as CKError where error.code == .unknownItem { continue }
        }
        for (name, record) in found { serverRecords[name] = record }
        return found
    }
}
