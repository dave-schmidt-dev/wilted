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
            let batch = try await transport.fetchChanges()
            emit(.init(phase: .staging, message: "Staging fetched changes", generationID: batch.generationID))
            let staged = try await repository.stage(batch)
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
            let state = await repository.state()
            let changes = state.pendingChanges.filter { !state.conflictedRecordIDs.contains($0.recordID) }
            let result = try await transport.save(changes: changes, role: role)
            try await repository.acknowledge(result)
            emit(.init(phase: .completed, message: "Pending changes acknowledged"))
            return .success(result)
        } catch {
            emit(.init(phase: .failed, message: String(describing: error)))
            return .failure(error)
        }
    }

    public func finishStatusStream() { continuation?.finish(); continuation = nil }

    private func emit(_ status: SyncStatus) { continuation?.yield(status) }
}
