import CloudKit
import Foundation
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

    /// A corrupt nonempty state fails closed before any engine operation is attempted.
    public init(driver: any CloudKitEngineDriver, role: SyncDeviceRole, mapper: CloudKitRecordMapper,
                stateData: Data? = nil, pendingChanges: [SyncPendingChange] = []) throws {
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
        pendingChanges = changes
        sentRecords = []; failedRecords = []; deletedRecordIDs = []; failedDeleteErrors = [:]; sentEventReceived = false
        sendAcknowledgementSequence = 0; sendStateSequence = 0
        sendInFlight = true
        await driver.addPendingRecordZoneChanges(operations)
        emit(.init(phase: .committing, message: "Sending CloudKit changes"))
        return try await withCheckedThrowingContinuation { continuation in
            sendWaiters.append(continuation)
            Task { [driver] in
                do { try await driver.sendChanges() }
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
        generation += 1
        await accumulator.begin()
        await accumulator.seedState(stateData)
        emit(.init(phase: .fetching, message: "Fetching CloudKit changes"))
        return try await withCheckedThrowingContinuation { continuation in
            fetchWaiters.append(continuation)
            Task { [driver] in
                do { try await driver.fetchChanges() }
                catch { await self.failFetch(error) }
            }
        }
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
    /// so the same driver remains valid here. This method does not reset CKSyncEngine.
    /// Full-state recovery, corruption recovery, and other app-initiated resets must
    /// discard this transport and construct a new driver and transport with `nil`
    /// serialization.
    public func resetAfterAccountChange() {
        quarantined = false
        stateData = nil
        pendingChanges = []
    }

    public func isQuarantined() -> Bool { quarantined }

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
            failedRecords.append(contentsOf: failed)
            deletedRecordIDs.append(contentsOf: deleted)
            failedDeleteErrors.merge(failedDeletes) { _, new in new }
            sentEventReceived = true
            sendAcknowledgementSequence += saved.count + deleted.count
            if failed.isEmpty, failedDeletes.isEmpty { emit(.init(phase: .committing, message: "CloudKit records acknowledged")) }
            else { emit(.init(phase: .failed, message: "CloudKit send had per-record failures")) }
        case .sendCompleted:
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
        case .accountChanged:
            quarantined = true
            pendingChanges = []
            stateData = nil
            await accumulator.cleanupStagedAssets()
            finishFetch(with: .failure(CloudKitSyncError.accountChanged))
            finishSend(with: .failure(CloudKitSyncError.accountChanged))
            accountContinuation.yield(.quarantineRequired)
            emit(.init(phase: .failed, message: "iCloud account changed; sync quarantined"))
        case .ignored:
            emit(.init(phase: .idle, message: "Ignored unrelated CloudKit event"))
        }
    }

    private func validateOutgoing(_ envelope: WiltedRecordEnvelope) throws {
        switch envelope.id.recordType {
        case .item: _ = try WiltedRecordCodec().decodeArticleRecord(envelope)
        case .revision: _ = try WiltedRecordCodec().decodeRevisionRecord(envelope)
        case .playbackState: _ = try WiltedRecordCodec().decodePlaybackRecord(envelope)
        }
    }

    private func failFetch(_ error: Error) async {
        await accumulator.cleanupStagedAssets()
        finishFetch(with: .failure(CloudKitSyncError.map(error)))
        emit(.init(phase: .failed, message: String(describing: error)))
    }

    private func failSend(_ error: Error) {
        finishSend(with: .failure(CloudKitSyncError.map(error)))
        emit(.init(phase: .failed, message: String(describing: error)))
    }

    private func finishFetch(with result: Result<SyncFetchBatch, Error>) {
        fetchInFlight = false
        let waiters = fetchWaiters; fetchWaiters.removeAll()
        for waiter in waiters { waiter.resume(with: result) }
    }

    private func finishSend(with result: Result<SyncSendResult, Error>) {
        sendInFlight = false
        let waiters = sendWaiters; sendWaiters.removeAll()
        for waiter in waiters { waiter.resume(with: result) }
    }

    private func emit(_ status: SyncStatus) { statusContinuation.yield(status) }
}
