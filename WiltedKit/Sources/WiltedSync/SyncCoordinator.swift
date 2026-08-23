import Foundation

/// Coordinates fetch, staging, and atomic commit without inspecting opaque engine bytes.
public actor SyncCoordinator {
    private let transport: any SyncTransport
    private let repository: any SyncRepository
    private var continuation: AsyncStream<SyncStatus>.Continuation?
    public let statuses: AsyncStream<SyncStatus>

    public init(transport: any SyncTransport, repository: any SyncRepository) {
        self.transport = transport; self.repository = repository
        let (stream, continuation) = AsyncStream<SyncStatus>.makeStream()
        statuses = stream
        self.continuation = continuation
    }

    /// Fetches and commits one complete generation; failures leave repository state unchanged.
    public func synchronize() async -> Result<SyncFetchBatch, Error> {
        emit(.init(phase: .fetching, message: "Fetching changes"))
        do {
            let operationGeneration = await transport.operationGeneration()
            let batch = try await transport.fetchChanges()
            emit(.init(phase: .staging, message: "Staging fetched changes", generationID: batch.generationID))
            let staged = try await repository.stage(batch)
            try await ensureCurrent(operationGeneration)
            emit(.init(phase: .committing, message: "Committing fetched changes", generationID: batch.generationID))
            try await repository.commit(staged)
            emit(.init(phase: .completed, message: "Sync completed", generationID: batch.generationID))
            return .success(batch)
        } catch {
            emit(.init(phase: .failed, message: String(describing: error)))
            return .failure(error)
        }
    }

    /// Sends queued mutations and atomically applies the transport acknowledgement.
    public func sendPending(role: SyncDeviceRole) async -> Result<SyncSendResult, Error> {
        do {
            var state = await repository.state()
            let blocked = state.conflictBlockedChanges
            // A queue that is entirely conflicted sends an empty batch and returns a
            // clean result, so without this the surface reports a completed upload
            // while every queued change is still sitting on the device (W-INV-001).
            if state.sendableChanges.isEmpty, !blocked.isEmpty {
                let reviewRequired = !state.accountQuarantinedRecordIDs.isEmpty
                emit(.init(phase: .failed, message: Self.blockedMessage(count: blocked.count, accountReviewRequired: reviewRequired)))
                return .failure(WiltedSyncError.sendBlockedByConflicts(count: blocked.count, accountReviewRequired: reviewRequired))
            }

            var results: [SyncSendResult] = []
            let pendingChunks = state.pendingChanges.filter { $0.recordID.recordType == .revisionChunk }
            if !pendingChunks.isEmpty {
                // A ready revision manifest and its item pointer make the revision
                // discoverable. Never add either to CKSyncEngine until every chunk has
                // been acknowledged in a prior send. This remains fail-closed when a
                // chunk is retryable or conflicted.
                let chunks = state.sendableChanges.filter { $0.recordID.recordType == .revisionChunk }
                guard !chunks.isEmpty else {
                    let blockedChunks = state.conflictBlockedChanges.filter {
                        $0.recordID.recordType == .revisionChunk
                    }
                    let reviewRequired = !state.accountQuarantinedRecordIDs.intersection(
                        Set(blockedChunks.map(\.recordID))
                    ).isEmpty
                    emit(.init(phase: .failed, message: Self.blockedMessage(
                        count: blockedChunks.count,
                        accountReviewRequired: reviewRequired
                    )))
                    return .failure(WiltedSyncError.sendBlockedByConflicts(
                        count: blockedChunks.count,
                        accountReviewRequired: reviewRequired
                    ))
                }
                let chunkResult = try await sendAndAcknowledge(chunks, role: role)
                results.append(chunkResult)
                guard chunkResult.failures.isEmpty else {
                    let result = try combine(results)
                    emit(.init(phase: .failed, message: Self.retryMessage(count: result.failures.count)))
                    return .success(result)
                }
                state = await repository.state()
                guard !state.pendingChanges.contains(where: {
                    $0.recordID.recordType == .revisionChunk
                }) else {
                    let error = WiltedSyncError.transport(
                        "chunk publication incomplete; ready records were withheld"
                    )
                    emit(.init(phase: .failed, message: String(describing: error)))
                    return .failure(error)
                }
            }

            let remaining = state.sendableChanges
            if !remaining.isEmpty || results.isEmpty {
                results.append(try await sendAndAcknowledge(remaining, role: role))
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

    private func ensureCurrent(_ expected: UInt64) async throws {
        guard await transport.operationGeneration() == expected else {
            throw WiltedSyncError.transport("sync operation superseded by an account change")
        }
    }

    private func sendAndAcknowledge(_ changes: [SyncPendingChange], role: SyncDeviceRole) async throws -> SyncSendResult {
        let operationGeneration = await transport.operationGeneration()
        let result = try await transport.save(changes: changes, role: role)
        try await ensureCurrent(operationGeneration)
        try await repository.acknowledge(result)
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
}
