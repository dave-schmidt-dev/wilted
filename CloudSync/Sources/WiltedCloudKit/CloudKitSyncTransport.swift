import CloudKit
import Foundation
import WiltedDomain
import WiltedSync

/// Actor-isolated CloudKit transport. The real engine and tests use the same event seam.
public actor CloudKitSyncTransport: SyncTransport {
    public nonisolated let statuses: AsyncStream<SyncStatus>
    public nonisolated let accountChanges: AsyncStream<CloudKitAccountChangeSignal>
    public nonisolated let role: SyncDeviceRole
    public nonisolated let mapper: CloudKitRecordMapper

    private let driver: any CloudKitEngineDriver
    private let pendingMapper: CloudKitPendingMapper
    private let accumulator: CloudKitChangeAccumulator
    private let statusContinuation: AsyncStream<SyncStatus>.Continuation
    private let accountContinuation: AsyncStream<CloudKitAccountChangeSignal>.Continuation
    private var stateData: Data?
    private var operationGenerationValue: UInt64 = 0
    private var generation = 0
    private var pendingChanges: [SyncPendingChange] = []
    private var quarantined = false
    private var fetchWaiters: [CheckedContinuation<SyncFetchBatch, Error>] = []
    private var sendWaiters: [CheckedContinuation<SyncSendResult, Error>] = []
    private var fetchInFlight = false
    private var sendInFlight = false
    private var sentRecords: [CKRecord] = []
    private var failedRecords: [CloudKitRecordFailure] = []
    private var deletedRecordIDs: [CKRecord.ID] = []
    private var failedDeleteErrors: [CKRecord.ID: CKError] = [:]
    private var sentEventReceived = false
    private var sendAcknowledgementSequence = 0
    private var sendStateSequence = 0
    private var sendZoneRecoveryAttempted = false
    private var sendRecoveryInFlight = false
    private var sendRecoveryCompletionPending = false
    private var sendRetryDispatched = false
    private var pendingZoneSaveIDs: Set<CKRecord.ID> = []
    private var pendingZoneDeleteIDs: Set<CKRecord.ID> = []
    /// The account token this device recorded, used to tell a first sign-in apart from
    /// a switch. Nil means no account has claimed the local work yet.
    private var knownOwnerToken: String?

    /// A corrupt nonempty state fails closed before any engine operation is attempted.
    public init(driver: any CloudKitEngineDriver, role: SyncDeviceRole, mapper: CloudKitRecordMapper,
                stateData: Data? = nil, pendingChanges: [SyncPendingChange] = [],
                knownOwnerToken: String? = nil) throws {
        if let stateData {
            guard !stateData.isEmpty, driver.isValidStateData(stateData) else { throw CloudKitSyncError.stateCorrupt }
            self.stateData = stateData
        } else {
            self.stateData = nil
        }
        self.driver = driver
        self.role = role
        self.mapper = mapper
        self.pendingMapper = CloudKitPendingMapper(mapper: mapper)
        self.accumulator = CloudKitChangeAccumulator(mapper: mapper)
        self.pendingChanges = pendingChanges
        self.knownOwnerToken = knownOwnerToken
        let (statusStream, statusContinuation) = AsyncStream<SyncStatus>.makeStream()
        self.statuses = statusStream
        self.statusContinuation = statusContinuation
        let (accountStream, accountContinuation) = AsyncStream<CloudKitAccountChangeSignal>.makeStream()
        self.accountChanges = accountStream
        self.accountContinuation = accountContinuation
        Task { [weak self, driver] in
            let events = await driver.events
            for await event in events { await self?.handleEngineEvent(event) }
        }
    }

    /// Sends changes and returns typed per-record acknowledgement/failure information.
    public func sendChanges(changes: [SyncPendingChange], role: SyncDeviceRole) async throws -> SyncSendResult {
        guard !quarantined else { throw CloudKitSyncError.quarantined }
        guard !sendInFlight, !fetchInFlight else { throw CloudKitSyncError.operationInProgress }
        guard role == self.role else { throw CloudKitSyncError.invalidRecordIdentity }
        if let stateData, !driver.isValidStateData(stateData) { throw CloudKitSyncError.stateCorrupt }
        if changes.isEmpty {
            emit(.init(phase: .completed, message: "No CloudKit changes to send"))
            return try SyncSendResult(engineState: stateData)
        }
        for change in changes {
            if let record = change.record { try validateOutgoing(record) }
        }
        let operations = try pendingMapper.pendingRecordZoneChanges(changes, scope: .all, role: role)
        sendInFlight = true
        emit(.init(phase: .staging, message: "Ensuring CloudKit custom zone exists"))
        do { try await driver.ensureZone() }
        catch {
            sendInFlight = false
            let mapped = quarantined ? .accountChanged : CloudKitSyncError.map(error)
            emit(.init(phase: .failed, message: mapped.localizedDescription))
            throw mapped
        }
        guard !quarantined else { throw CloudKitSyncError.accountChanged }
        pendingChanges = changes
        sentRecords = []; failedRecords = []; deletedRecordIDs = []; failedDeleteErrors = [:]; sentEventReceived = false
        sendAcknowledgementSequence = 0; sendStateSequence = 0
        sendZoneRecoveryAttempted = false; sendRecoveryInFlight = false; sendRecoveryCompletionPending = false; sendRetryDispatched = false
        pendingZoneSaveIDs = []; pendingZoneDeleteIDs = []
        await driver.addPendingRecordZoneChanges(operations)
        guard sendInFlight, !quarantined else {
            await driver.cancelOperations()
            throw quarantined ? CloudKitSyncError.accountChanged : CloudKitSyncError.cancelled
        }
        emit(.init(phase: .committing, message: "Sending CloudKit changes"))
        return try await withCheckedThrowingContinuation { continuation in
            sendWaiters.append(continuation)
            Task { [driver, operations] in
                do { try await driver.sendChanges() }
                catch let error as CKError where error.code == .zoneNotFound {
                    do { try await self.retrySendAfterZoneNotFound(operations) }
                    catch { self.failSend(error) }
                }
                catch { self.failSend(error) }
            }
        }
    }

    public func save(changes: [SyncPendingChange], role: SyncDeviceRole) async throws -> SyncSendResult {
        try await sendChanges(changes: changes, role: role)
    }

    public func fetchChanges() async throws -> SyncFetchBatch {
        guard !quarantined else { throw CloudKitSyncError.quarantined }
        guard !fetchInFlight, !sendInFlight else { throw CloudKitSyncError.operationInProgress }
        if let stateData, !driver.isValidStateData(stateData) { throw CloudKitSyncError.stateCorrupt }
        fetchInFlight = true
        emit(.init(phase: .staging, message: "Ensuring CloudKit custom zone exists"))
        do { try await driver.ensureZone() }
        catch {
            fetchInFlight = false
            let mapped = quarantined ? .accountChanged : CloudKitSyncError.map(error)
            emit(.init(phase: .failed, message: mapped.localizedDescription))
            throw mapped
        }
        guard !quarantined else { throw CloudKitSyncError.accountChanged }
        guard fetchInFlight else { throw CloudKitSyncError.cancelled }
        generation += 1
        await accumulator.begin()
        await accumulator.seedState(stateData)
        emit(.init(phase: .fetching, message: "Fetching CloudKit changes"))
        return try await withCheckedThrowingContinuation { continuation in
            fetchWaiters.append(continuation)
            Task { [driver] in
                do { try await driver.fetchChanges() }
                catch let error as CKError where error.code == .zoneNotFound {
                    do { try await self.retryFetchAfterZoneNotFound() }
                    catch { await self.failFetch(error) }
                }
                catch { await self.failFetch(error) }
            }
        }
    }

    /// Fetches only the selected revision's chunk records and reconstructs the
    /// original bytes after validating order, sizes, per-chunk hashes, and the
    /// whole-file hash. Metadata sync never calls this method.
    public func fetchAudioChunks(itemID: ItemID, revisionID: RevisionID,
                                 manifest: AudioChunkManifest) async throws -> Data {
        let operationGeneration = operationGenerationValue
        guard !quarantined else { throw CloudKitSyncError.quarantined }
        let ids = try manifest.chunks.map {
            CKRecord.ID(recordName: try WiltedRecordID.revisionChunk(itemID, revisionID, index: $0.index).recordName,
                        zoneID: mapper.zoneID)
        }
        emit(.init(phase: .fetching, message: "Fetching selected audio chunks"))
        do { try await driver.ensureZone() }
        catch {
            throw quarantined || operationGeneration != operationGenerationValue
                ? .accountChanged
                : CloudKitSyncError.map(error)
        }
        guard !quarantined, operationGeneration == operationGenerationValue else {
            throw CloudKitSyncError.accountChanged
        }
        let records: [CKRecord]
        do { records = try await driver.fetchRecords(ids) }
        catch {
            throw quarantined || operationGeneration != operationGenerationValue
                ? .accountChanged
                : CloudKitSyncError.map(error)
        }
        guard !quarantined, operationGeneration == operationGenerationValue else {
            throw CloudKitSyncError.accountChanged
        }
        var byID: [String: CKRecord] = [:]
        for record in records { byID[record.recordID.recordName] = record }
        var chunks: [Data] = []
        chunks.reserveCapacity(manifest.chunks.count)
        for descriptor in manifest.chunks {
            let id = try WiltedRecordID.revisionChunk(itemID, revisionID, index: descriptor.index).recordName
            guard let record = byID[id] else { throw CloudKitSyncError.missingField("chunk.\(descriptor.index)") }
            let decoded = try mapper.decodeChunk(record)
            guard decoded.descriptor == descriptor else { throw CloudKitSyncError.invalidField("chunk.\(descriptor.index).descriptor") }
            chunks.append(decoded.data)
        }
        do { return try AudioChunking.reconstruct(manifest: manifest, chunks: chunks) }
        catch let error as AudioChunkError { throw CloudKitSyncError.invalidField(error.localizedDescription) }
    }

    /// Reconstructs into a destination only after complete validation. The
    /// shared contract's atomic write prevents corrupt partial cache files.
    public func fetchAudioChunks(itemID: ItemID, revisionID: RevisionID,
                                 manifest: AudioChunkManifest, to destinationURL: URL) async throws {
        let data = try await fetchAudioChunks(itemID: itemID, revisionID: revisionID, manifest: manifest)
        do { try data.write(to: destinationURL, options: [.atomic]) }
        catch { throw CloudKitSyncError.assetCopyFailed(error.localizedDescription) }
    }

    public func cancel() async {
        await driver.cancelOperations()
        finishFetch(with: .failure(CloudKitSyncError.cancelled))
        finishSend(with: .failure(CloudKitSyncError.cancelled))
        await accumulator.cleanupStagedAssets()
        emit(.init(phase: .idle, message: "CloudKit sync cancelled"))
    }

    /// Re-enables operations after this driver's account-change event has been reviewed.
    ///
    /// CKSyncEngine automatically resets its own live state for the account event,
    /// so the same driver remains valid here. The zone bootstrap is invalidated
    /// so the next operation re-ensures the private zone for the new account.
    /// Full-state recovery, corruption recovery, and other app-initiated resets must
    /// discard this transport and construct a new driver and transport with `nil`
    /// serialization.
    public func resetAfterAccountChange() async {
        await driver.resetZoneBootstrap()
        quarantined = false
        stateData = nil
        pendingChanges = []
        // The review confirmed whichever account is signed in now, so the recorded owner
        // is dropped and the next sign-in adopts it. Keeping the old token would quarantine
        // again on the very next engine and make review unable to ever finish.
        knownOwnerToken = nil
    }

    public func isQuarantined() -> Bool { quarantined }

    public func operationGeneration() async -> UInt64 { operationGenerationValue }

    /// Returns staged asset locations owned by the most recently completed fetch.
    public func assetHandoff() async -> [WiltedRecordID: [String: URL]] {
        await accumulator.assetHandoff()
    }

    private func handleEngineEvent(_ event: CloudKitEngineEvent) async {
        switch event {
        case let .stateUpdated(data):
            guard !data.isEmpty, driver.isValidStateData(data) else { await failFetch(CloudKitSyncError.stateCorrupt); failSend(CloudKitSyncError.stateCorrupt); return }
            stateData = data
            await accumulator.updateState(data)
            if sendInFlight { sendStateSequence = sendAcknowledgementSequence }
        case .willFetch:
            emit(.init(phase: .fetching, message: "CloudKit fetch started"))
        case let .fetched(modifications, deletions):
            do {
                for record in modifications { try await accumulator.append(modified: record) }
                for deletion in deletions { try await accumulator.append(deleted: deletion.recordID, recordType: deletion.recordType) }
                emit(.init(phase: .staging, message: "Staged CloudKit record changes"))
            } catch { await failFetch(error) }
        case .didFetchRecordZoneChanges:
            emit(.init(phase: .staging, message: "CloudKit zone fetch completed"))
        case .fetchCompleted:
            do {
                let hasChanges = await accumulator.hasRemoteChanges()
                let batch = try await accumulator.finish(requireFreshState: hasChanges)
                finishFetch(with: .success(batch))
            } catch { await failFetch(error) }
        case .willSend:
            emit(.init(phase: .committing, message: "CloudKit send started"))
        case let .sent(saved, failed, deleted, failedDeletes):
            sentRecords.append(contentsOf: saved)
            deletedRecordIDs.append(contentsOf: deleted)
            let zoneSaveFailures = failed.filter { isZoneNotFound($0.error) }
            let zoneDeleteFailures = failedDeletes.filter { isZoneNotFound($0.value) }
            let hasZoneFailure = !zoneSaveFailures.isEmpty || !zoneDeleteFailures.isEmpty
            let terminalSaveFailures = failed.filter { !isZoneNotFound($0.error) }
            let terminalDeleteFailures = failedDeletes.filter { !isZoneNotFound($0.value) }
            if hasZoneFailure && sendRecoveryInFlight && !sendRetryDispatched {
                pendingZoneSaveIDs.formUnion(zoneSaveFailures.map { $0.record.recordID })
                pendingZoneDeleteIDs.formUnion(zoneDeleteFailures.map(\.key))
            }
            if hasZoneFailure && !sendZoneRecoveryAttempted {
                sendZoneRecoveryAttempted = true
                sendRecoveryInFlight = true
                sendRecoveryCompletionPending = true
                pendingZoneSaveIDs.formUnion(zoneSaveFailures.map { $0.record.recordID })
                pendingZoneDeleteIDs.formUnion(zoneDeleteFailures.map(\.key))
            }
            failedRecords.append(contentsOf: terminalSaveFailures)
            failedDeleteErrors.merge(terminalDeleteFailures) { _, new in new }
            if sendRetryDispatched {
                failedRecords.append(contentsOf: zoneSaveFailures)
                for (id, error) in zoneDeleteFailures { failedDeleteErrors[id] = error }
            }
            sentEventReceived = true
            sendAcknowledgementSequence += saved.count + deleted.count
            if hasZoneFailure && sendRecoveryInFlight { emit(.init(phase: .staging, message: "CloudKit zone failure detected; preparing retry")) }
            else if failed.isEmpty, failedDeletes.isEmpty { emit(.init(phase: .committing, message: "CloudKit records acknowledged")) }
            else { emit(.init(phase: .failed, message: "CloudKit send had per-record failures")) }
        case .sendCompleted:
            if sendRecoveryCompletionPending {
                sendRecoveryCompletionPending = false
                let saveIDs = pendingZoneSaveIDs
                let deleteIDs = pendingZoneDeleteIDs
                Task { await self.retryEventZoneFailures(saveIDs: saveIDs, deleteIDs: deleteIDs) }
                return
            }
            guard sentEventReceived else {
                failSend(CloudKitSyncError.cloudKit(code: -1, message: "CloudKit send completed without acknowledgement event"))
                return
            }
            guard sendAcknowledgementSequence == 0 || sendStateSequence >= sendAcknowledgementSequence else {
                failSend(CloudKitSyncError.stateCorrupt)
                return
            }
            guard let result = try? CloudKitSendMapper(mapper: mapper).result(engineState: stateData, pendingChanges: pendingChanges,
                saved: sentRecords, failed: failedRecords.map { ($0.record, $0.error) }, deleted: deletedRecordIDs, failedDeletes: failedDeleteErrors) else {
                failSend(CloudKitSyncError.stateCorrupt)
                return
            }
            if result.failures.isEmpty { emit(.init(phase: .completed, message: "CloudKit send completed")) }
            finishSend(with: .success(result))
        case let .accountChanged(changeType, identity):
            // A sync engine built without persisted serialization always reports a first
            // sign-in, so quarantining every sign-in deadlocked the first-ever sync: it
            // could never send, so it could never persist state, so the next engine
            // reported a first sign-in again. Classify instead of gating unconditionally.
            switch CloudKitAccountOwnership.resolve(changeType: changeType, identity: identity,
                                                    recordedOwnerToken: knownOwnerToken) {
            case let .adopt(token):
                knownOwnerToken = token
                accountContinuation.yield(.ownershipAdopted(token: token))
                emit(.init(phase: .staging, message: "iCloud account adopted for local sync"))
                return
            case .confirmed:
                accountContinuation.yield(.ownershipConfirmed)
                emit(.init(phase: .staging, message: "iCloud account confirmed for local sync"))
                return
            case .quarantine:
                break
            }
            operationGenerationValue &+= 1
            quarantined = true
            await driver.resetZoneBootstrap()
            pendingChanges = []
            stateData = nil
            await accumulator.cleanupStagedAssets()
            finishFetch(with: .failure(CloudKitSyncError.accountChanged))
            finishSend(with: .failure(CloudKitSyncError.accountChanged))
            accountContinuation.yield(.quarantineRequired(changeType))
            emit(.init(phase: .failed, message: "\(changeType.userFacingName) detected; sync quarantined for review"))
        case .ignored:
            emit(.init(phase: .idle, message: "Ignored unrelated CloudKit event"))
        }
    }

    private func validateOutgoing(_ envelope: WiltedRecordEnvelope) throws {
        switch envelope.id.recordType {
        case .item: _ = try WiltedRecordCodec().decodeArticleRecord(envelope)
        case .revision: _ = try WiltedRecordCodec().decodeRevisionRecord(envelope)
        case .revisionChunk: _ = try WiltedRecordCodec().decodeRevisionChunkRecord(envelope)
        case .transcript: _ = try WiltedRecordCodec().decodeTranscriptRecord(envelope)
        case .playbackState: _ = try WiltedRecordCodec().decodePlaybackRecord(envelope)
        }
    }

    private func retrySendAfterZoneNotFound(_ operations: [CKSyncEngine.PendingRecordZoneChange]) async throws {
        guard !quarantined, sendInFlight, !sendZoneRecoveryAttempted else { throw quarantined ? CloudKitSyncError.accountChanged : CloudKitSyncError.cancelled }
        sendZoneRecoveryAttempted = true
        emit(.init(phase: .staging, message: "CloudKit zone disappeared; recreating before retry"))
        await driver.resetZoneBootstrap()
        try await driver.ensureZone()
        guard !quarantined, sendInFlight else { throw quarantined ? CloudKitSyncError.accountChanged : CloudKitSyncError.cancelled }
        await driver.addPendingRecordZoneChanges(operations)
        guard !quarantined, sendInFlight else {
            await driver.cancelOperations()
            throw quarantined ? CloudKitSyncError.accountChanged : CloudKitSyncError.cancelled
        }
        emit(.init(phase: .committing, message: "Retrying CloudKit record-zone changes"))
        sendRetryDispatched = true
        try await driver.sendChanges()
    }

    private func retryEventZoneFailures(saveIDs: Set<CKRecord.ID>, deleteIDs: Set<CKRecord.ID>) async {
        do {
            guard !quarantined, sendInFlight else {
                throw quarantined ? CloudKitSyncError.accountChanged : CloudKitSyncError.cancelled
            }
            emit(.init(phase: .staging, message: "CloudKit zone disappeared; recreating before retry"))
            await driver.resetZoneBootstrap()
            try await driver.ensureZone()
            guard !quarantined, sendInFlight else {
                throw quarantined ? CloudKitSyncError.accountChanged : CloudKitSyncError.cancelled
            }
            let retryChanges = pendingChanges.filter { change in
                (change.operation == .delete && deleteIDs.contains(CKRecord.ID(recordName: change.recordID.recordName, zoneID: mapper.zoneID))) ||
                (change.operation != .delete && saveIDs.contains(CKRecord.ID(recordName: change.recordID.recordName, zoneID: mapper.zoneID)))
            }
            let operations = try pendingMapper.pendingRecordZoneChanges(retryChanges, scope: .all, role: role)
            await driver.addPendingRecordZoneChanges(operations)
            guard !quarantined, sendInFlight else {
                await driver.cancelOperations()
                throw quarantined ? CloudKitSyncError.accountChanged : CloudKitSyncError.cancelled
            }
            emit(.init(phase: .committing, message: "Retrying failed CloudKit record-zone changes"))
            // Keep the completion gate set until the first attempt's completion
            // event is consumed; event ordering then cleanly separates attempts.
            sendRetryDispatched = true
            try await driver.sendChanges()
        } catch {
            sendRecoveryInFlight = false
            sendRecoveryCompletionPending = false
            failSend(error)
        }
        sendRecoveryInFlight = false
    }

    private func retryFetchAfterZoneNotFound() async throws {
        guard !quarantined, fetchInFlight else { throw quarantined ? CloudKitSyncError.accountChanged : CloudKitSyncError.cancelled }
        emit(.init(phase: .staging, message: "CloudKit zone disappeared; recreating before retry"))
        await driver.resetZoneBootstrap()
        try await driver.ensureZone()
        guard !quarantined, fetchInFlight else { throw quarantined ? CloudKitSyncError.accountChanged : CloudKitSyncError.cancelled }
        await accumulator.begin()
        await accumulator.seedState(stateData)
        emit(.init(phase: .fetching, message: "Retrying CloudKit record-zone fetch"))
        try await driver.fetchChanges()
    }

    private func failFetch(_ error: Error) async {
        await accumulator.cleanupStagedAssets()
        finishFetch(with: .failure(quarantined ? .accountChanged : CloudKitSyncError.map(error)))
        emit(.init(phase: .failed, message: String(describing: error)))
    }

    private func failSend(_ error: Error) {
        sendRecoveryInFlight = false
        sendRecoveryCompletionPending = false
        finishSend(with: .failure(quarantined ? .accountChanged : CloudKitSyncError.map(error)))
        emit(.init(phase: .failed, message: String(describing: error)))
    }

    private func finishFetch(with result: Result<SyncFetchBatch, Error>) {
        fetchInFlight = false
        let waiters = fetchWaiters; fetchWaiters.removeAll()
        for waiter in waiters { waiter.resume(with: result) }
    }

    private func finishSend(with result: Result<SyncSendResult, Error>) {
        sendInFlight = false
        sendRecoveryInFlight = false
        sendRecoveryCompletionPending = false
        sendRetryDispatched = false
        pendingZoneSaveIDs = []; pendingZoneDeleteIDs = []
        let waiters = sendWaiters; sendWaiters.removeAll()
        for waiter in waiters { waiter.resume(with: result) }
    }

    private func isZoneNotFound(_ error: Error) -> Bool {
        (error as? CKError)?.code == .zoneNotFound
    }

    private func emit(_ status: SyncStatus) { statusContinuation.yield(status) }
}
