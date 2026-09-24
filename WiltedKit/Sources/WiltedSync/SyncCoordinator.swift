import Foundation
import WiltedDomain

/// Coordinates fetch, staging, and atomic commit without inspecting opaque engine bytes.
public actor SyncCoordinator {
    /// Maximum stage/commit attempts for one fetched batch after local mutation races.
    public static let maximumStaleStageAttempts = 3

    private var transport: any SyncTransport
    private let transportFactory: (@Sendable (Data?) async throws -> any SyncTransport)?
    private let repository: any SyncRepository
    private var rebuildTransportBeforeNextSynchronization = false
    private var continuation: AsyncStream<SyncStatus>.Continuation?
    public let statuses: AsyncStream<SyncStatus>

    public init(
        transport: any SyncTransport,
        repository: any SyncRepository,
        transportFactory: (@Sendable (Data?) async throws -> any SyncTransport)? = nil
    ) {
        self.transport = transport
        self.transportFactory = transportFactory
        self.repository = repository
        let (stream, continuation) = AsyncStream<SyncStatus>.makeStream()
        statuses = stream
        self.continuation = continuation
    }

    /// Fetches and commits one complete generation; failures leave repository state unchanged.
    public func synchronize() async -> Result<SyncFetchBatch, Error> {
        emit(.init(phase: .fetching, message: "Fetching changes"))
        do {
            try await rebuildTransportIfNeeded()
            let operationGeneration = await transport.operationGeneration()
            let batch = try await transport.fetchChanges()
            for attempt in 1...Self.maximumStaleStageAttempts {
                emit(.init(phase: .staging, message: "Staging fetched changes", generationID: batch.generationID))
                let staged = try await repository.stage(batch)
                try await ensureCurrent(operationGeneration)
                emit(.init(phase: .committing, message: "Committing fetched changes", generationID: batch.generationID))
                do {
                    try await repository.commit(staged)
                    try await transport.commitFetchedState(batch.engineState)
                    emit(.init(phase: .completed, message: "Sync completed", generationID: batch.generationID))
                    return .success(batch)
                } catch let error as WiltedSyncError where error == .staleStagedBatch {
                    guard attempt < Self.maximumStaleStageAttempts else { throw error }
                }
            }
            throw WiltedSyncError.staleStagedBatch
        } catch {
            if transportFactory != nil {
                rebuildTransportBeforeNextSynchronization = true
            }
            emit(.init(phase: .failed, message: String(describing: error)))
            return .failure(error)
        }
    }

    /// Sends queued mutations and atomically applies the transport acknowledgement.
    public func sendPending(role: SyncDeviceRole) async -> Result<SyncSendResult, Error> {
        do {
            try await rebuildTransportIfNeeded()
            var state = await repository.state()
            var results: [SyncSendResult] = []

            // Chunks must precede only the manifest and item pointer for their own
            // revision. A stalled revision must not turn the durable queue into a
            // global barrier for another revision, item, or playback update.
            let chunks = state.sendableChanges.filter(isRevisionChunk)
            if !chunks.isEmpty {
                let chunkResult = try await sendAndAcknowledge(chunks, role: role)
                results.append(chunkResult)
                state = await repository.state()
            }

            let withheld = readyRecordsWithheldByPendingChunks(in: state)
            let remaining = state.sendableChanges.filter {
                !isRevisionChunk($0) && !withheld.contains($0.recordID)
            }
            if !remaining.isEmpty {
                results.append(try await sendAndAcknowledge(remaining, role: role))
            }
            if results.isEmpty {
                let blocked = state.conflictBlockedChanges
                if !blocked.isEmpty {
                    let reviewRequired = !state.accountQuarantinedRecordIDs.isEmpty
                    emit(.init(phase: .failed, message: Self.blockedMessage(count: blocked.count, accountReviewRequired: reviewRequired)))
                    return .failure(WiltedSyncError.sendBlockedByConflicts(count: blocked.count, accountReviewRequired: reviewRequired))
                }
                results.append(try await sendAndAcknowledge([], role: role))
            }
            let result = try combine(results)
            // Read after acknowledgement: this send can conflict records of its own, so
            // the pre-send count is not what is still held.
            let held = await repository.state().conflictBlockedChanges.count
            if result.failures.isEmpty {
                emit(.init(phase: .completed, message: Self.acknowledgedMessage(sent: result.acknowledgedRecordIDs.count, held: held)))
            } else {
                emit(.init(phase: .failed, message: Self.retryMessage(count: result.failures.count)))
            }
            return .success(result)
        } catch {
            rebuildTransportBeforeNextSynchronization = true
            emit(.init(phase: .failed, message: String(describing: error)))
            return .failure(error)
        }
    }

    /// The single wording for a send that moved something, shared by the status stream
    /// and by callers that set their own terminal status.
    ///
    /// Both must produce the identical string: a caller's `setStatus` and this stream
    /// event race, so any difference in wording surfaces as a nondeterministic panel.
    public static func acknowledgedMessage(sent: Int, held: Int) -> String {
        let uploaded = sent == 1 ? "Uploaded 1 change." : "Uploaded \(sent) changes."
        guard held > 0 else { return sent == 0 ? "No pending changes to upload." : uploaded }
        let holds = held == 1
            ? "1 change is held by unresolved conflicts."
            : "\(held) changes are held by unresolved conflicts."
        return sent == 0 ? "Nothing was sent. \(holds)" : "\(uploaded) \(holds)"
    }

    /// The single wording for a send that moved nothing, shared by the status stream
    /// and by callers that render the typed error.
    public static func blockedMessage(count: Int, accountReviewRequired: Bool) -> String {
        let subject = count == 1 ? "1 pending change is" : "\(count) pending changes are"
        return accountReviewRequired
            ? "Nothing was sent. \(subject) held until the current iCloud account is reviewed."
            : "Nothing was sent. \(subject) held by unresolved remote conflicts."
    }

    public static func retryMessage(count: Int) -> String {
        count == 1 ? "1 change needs retry." : "\(count) changes need retry."
    }

    public func finishStatusStream() { continuation?.finish(); continuation = nil }

    private func emit(_ status: SyncStatus) { continuation?.yield(status) }

    /// A failed fetch/stage/commit can leave an adapter holding provisional
    /// engine state. Rebuild it from the repository before any later operation.
    private func rebuildTransportIfNeeded() async throws {
        guard rebuildTransportBeforeNextSynchronization, let transportFactory else { return }
        let state = await repository.state()
        transport = try await transportFactory(state.engineState)
        rebuildTransportBeforeNextSynchronization = false
    }

    private func ensureCurrent(_ expected: UInt64) async throws {
        guard await transport.operationGeneration() == expected else {
            throw WiltedSyncError.transport("sync operation superseded by an account change")
        }
    }

    private func sendAndAcknowledge(_ changes: [SyncPendingChange], role: SyncDeviceRole) async throws -> SyncSendResult {
        let operationGeneration = await transport.operationGeneration()
        let result = try await transport.save(changes: changes, role: role)
        try await ensureCurrent(operationGeneration)
        try await repository.acknowledge(result, sent: changes)
        try await transport.commitSentState(result.engineState)
        return result
    }

    private func combine(_ results: [SyncSendResult]) throws -> SyncSendResult {
        try SyncSendResult(
            engineState: results.reversed().compactMap(\.engineState).first,
            acknowledgedRecordIDs: results.flatMap(\.acknowledgedRecordIDs),
            serverEnvelopes: results.flatMap(\.serverEnvelopes),
            failures: results.flatMap(\.failures)
        )
    }

    private struct RevisionKey: Hashable {
        let itemID: ItemID
        let revisionID: RevisionID
    }

    private func isRevisionChunk(_ change: SyncPendingChange) -> Bool {
        change.recordID.recordType == .revisionChunk
    }

    /// Returns the ready records that would expose an incomplete revision. The
    /// revision manifest is addressed by its identity, while an item record is
    /// addressed by its current-revision pointer.
    private func readyRecordsWithheldByPendingChunks(in state: SyncRepositoryState) -> Set<WiltedRecordID> {
        let pendingChunks = state.pendingChanges.filter(isRevisionChunk)
        guard !pendingChunks.isEmpty else { return [] }
        let pendingChunkKeys = pendingChunks.map(revisionKeyForChunk)
        let pendingRevisions = Set(pendingChunkKeys.compactMap { $0 })
        // An unidentified chunk could belong to any ready revision. Do not let an
        // ambiguous identity turn the per-revision barrier into a fail-open path.
        let hasUnidentifiedChunk = pendingChunkKeys.contains(nil)
        return Set(state.sendableChanges.compactMap { change in
            guard isReadyRecord(change) else { return nil }
            guard !hasUnidentifiedChunk,
                  let key = readyRevisionKey(for: change),
                  !pendingRevisions.contains(key) else { return change.recordID }
            return nil
        })
    }

    private func revisionKeyForChunk(_ change: SyncPendingChange) -> RevisionKey? {
        guard change.recordID.recordType == .revisionChunk else { return nil }
        return revisionKey(from: change.record)
    }

    private func readyRevisionKey(for change: SyncPendingChange) -> RevisionKey? {
        switch change.recordID.recordType {
        case .revision:
            guard change.record?.fields["audioManifest"] != nil else { return nil }
            return revisionKey(from: change.record)
        case .item:
            guard let envelope = change.record,
                  case let .string(itemValue)? = envelope.fields["itemID"],
                  case let .string(revisionValue)? = envelope.fields["currentRevisionID"],
                  let itemID = try? ItemID(rawValue: itemValue),
                  let revisionID = try? RevisionID(rawValue: revisionValue) else { return nil }
            return RevisionKey(itemID: itemID, revisionID: revisionID)
        default:
            return nil
        }
    }

    private func isReadyRecord(_ change: SyncPendingChange) -> Bool {
        switch change.recordID.recordType {
        case .revision:
            return change.record?.fields["audioManifest"] != nil
        case .item:
            return change.record?.fields["currentRevisionID"] != nil
        default:
            return false
        }
    }

    private func revisionKey(from record: WiltedRecordEnvelope?) -> RevisionKey? {
        guard let record,
              case let .string(itemValue)? = record.fields["itemID"],
              case let .string(revisionValue)? = record.fields["revisionID"],
              let itemID = try? ItemID(rawValue: itemValue),
              let revisionID = try? RevisionID(rawValue: revisionValue) else { return nil }
        return RevisionKey(itemID: itemID, revisionID: revisionID)
    }
}
