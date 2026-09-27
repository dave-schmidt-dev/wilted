import Foundation
import SwiftUI
import WiltedDomain
import WiltedListener
import WiltedSync

#if WILTED_CLOUDKIT_LIVE
import CloudKit
import WiltedCloudKit
#endif

extension WiltedListenerAppModel {
    /// Performs the initial metadata discovery once for the app lifetime.
    /// Foreground transitions use `resumeForeground()` so returning from the
    /// background still picks up producer changes without duplicate launch fetches.
    public func start() async {
        guard !didStart else { return }
        didStart = true
        await refreshPresentationFacts()
        await refresh()
    }

    public func refresh() async {
        syncRetryOperation = nil
        guard let operation = beginOperation() else { return }
        defer { finishOperation(operation) }
        syncPhase = .refreshing("Refreshing larder…")
        guard let repository else {
            syncPhase = .failed("Local larder unavailable", retryable: false)
            return
        }

        do {
            guard try await prepareTransport(repository: repository, operation: operation) else { return }
        } catch {
            guard isCurrent(operation) else { return }
            rebuildSessionBeforeNextTransportOperation = true
            if let listenerRepository = repository as? ListenerRepository {
                try? await listenerRepository.recordFetchFailure(error.localizedDescription)
            }
            await refreshSyncObservability()
            guard isCurrent(operation) else { return }
            await loadLocal(repository: repository, fallback: error.localizedDescription, operation: operation)
            guard isCurrent(operation) else { return }
            if case .offline = syncPhase {
                syncRetryOperation = .refresh
                syncPhase = .failed("Sync unavailable: \(error.localizedDescription)", retryable: true)
            }
            return
        }

        guard !accountQuarantined else {
            syncPhase = .failed("iCloud account changed; sync is quarantined", retryable: false)
            return
        }

        if let transport {
            do {
                let batch = try await transport.fetchChanges()
                guard isCurrent(operation) else { return }
                guard try await stageAndCommit(batch, repository: repository, operation: operation) else { return }
                guard isCurrent(operation) else { return }
                try await transport.commitFetchedState(batch.engineState)
                guard isCurrent(operation) else { return }
                if let listenerRepository = repository as? ListenerRepository {
                    try? await listenerRepository.recordSuccessfulFetch()
                }
                await refreshSyncObservability()
                let state = await repository.state()
                guard isCurrent(operation) else { return }
                let previousAssets = assetByItem
                // Remote metadata is fetched first; audio is an explicit per-item download.
                rebuild(from: state)
                await reconcileCachedAssets(previousAssets)
                guard isCurrent(operation) else { return }
                await restoreMetadata()
                guard isCurrent(operation) else { return }
                await updateDownloadedStates()
                guard isCurrent(operation) else { return }
                syncPhase = decodeHadErrors
                    ? .incompatible("Some listener records are incompatible")
                    : items.contains(where: { $0.state == .deleted })
                    ? .deleted("An item was deleted remotely")
                    : items.contains(where: { $0.state == .incompatibleRevision })
                    ? .incompatible("A larder item has an incompatible revision") : .ready
                return
            } catch {
                guard isCurrent(operation) else { return }
                if sessionFactory != nil {
                    rebuildSessionBeforeNextTransportOperation = true
                }
                if let listenerRepository = repository as? ListenerRepository {
                    try? await listenerRepository.recordFetchFailure(error.localizedDescription)
                }
                await refreshSyncObservability()
                guard isCurrent(operation) else { return }
                await loadLocal(repository: repository, fallback: error.localizedDescription, operation: operation)
                guard isCurrent(operation) else { return }
                if case .offline = syncPhase {
                    syncRetryOperation = .refresh
                    syncPhase = .failed("Refresh failed: \(error.localizedDescription)", retryable: true)
                }
                return
            }
        }

        guard isCurrent(operation) else { return }
        await loadLocal(repository: repository, fallback: "Offline mode", operation: operation)
    }

    /// Reconstructs a session only from repository-persisted engine state.
    /// A failed fetch or local commit may leave the prior transport carrying
    /// provisional CKSyncEngine state, so it must not perform a later send.
    private func prepareTransport(
        repository: any SyncRepository,
        operation: UInt64
    ) async throws -> Bool {
        if rebuildSessionBeforeNextTransportOperation {
            await session?.cancel()
            guard isCurrent(operation) else { return false }
            session = nil
            transport = nil
            assetLoader = nil
            audioChunkLoader = nil
            sessionStatusTask?.cancel()
            sessionStatusTask = nil
            rebuildSessionBeforeNextTransportOperation = false
        }

        guard transport == nil, let sessionFactory else { return true }
        let state = await repository.state()
        guard isCurrent(operation) else { return false }
        let createdSession = try await sessionFactory(state.engineState)
        guard isCurrent(operation) else { return false }
        session = createdSession
        transport = createdSession.transport
        assetLoader = createdSession.assetLoader
        audioChunkLoader = createdSession.audioChunkLoader
        observeSession(createdSession.accountChanges)
        return true
    }

    /// Re-stages one fetched batch when a concurrent local enqueue invalidates its snapshot.
    private func stageAndCommit(
        _ batch: SyncFetchBatch,
        repository: any SyncRepository,
        operation: UInt64
    ) async throws -> Bool {
        for attempt in 1...SyncCoordinator.maximumStaleStageAttempts {
            let staged = try await repository.stage(batch)
            guard isCurrent(operation) else { return false }
            do {
                try await repository.commit(staged)
                return isCurrent(operation)
            } catch let error as ListenerError where error == .staleStage {
                guard attempt < SyncCoordinator.maximumStaleStageAttempts else { throw error }
            }
        }
        throw ListenerError.staleStage
    }

    public func sendPending() async {
        syncRetryOperation = nil
        let operation = await beginQueuedOperation()
        defer { finishOperation(operation) }
        guard let repository else {
            syncPhase = .offline("Offline: changes will send when connected")
            return
        }
        guard transport != nil || sessionFactory != nil else {
            syncPhase = .offline("Offline: changes will send when connected")
            return
        }
        guard !accountQuarantined else {
            syncPhase = .failed("iCloud account changed; sync is quarantined", retryable: false)
            return
        }
        syncPhase = .sending("Sending playback progress…")
        do {
            let state = await repository.state()
            guard isCurrent(operation) else { return }
            let liveItemIDs = Set(items.filter { $0.state != .deleted }.map(\.itemID))
            let sendableChanges = state.pendingChanges.filter { change in
                guard change.recordID.recordType == .playbackState,
                      let record = change.record,
                      case let .string(rawItemID) = record.fields["itemID"],
                      let itemID = try? ItemID(rawValue: rawItemID) else { return false }
                return liveItemIDs.contains(itemID)
                    && !state.conflictedRecordIDs.contains(change.recordID)
            }
            guard !sendableChanges.isEmpty else {
                // An entirely conflicted queue sends nothing and used to report ready, which
                // is indistinguishable from having nothing to send. Name the held work so a
                // stranded queue cannot present as a completed send.
                let held = state.conflictBlockedChanges.filter { $0.recordID.recordType == .playbackState }
                if held.isEmpty {
                    syncPhase = .ready
                } else {
                    let subject = held.count == 1 ? "1 playback update is" : "\(held.count) playback updates are"
                    syncRetryOperation = .send
                    syncPhase = .failed("Nothing was sent. \(subject) held by unresolved conflicts.", retryable: true)
                }
                return
            }
            guard try await prepareTransport(repository: repository, operation: operation) else { return }
            guard let transport else {
                syncPhase = .offline("Offline: changes will send when connected")
                return
            }
            var changes = sendableChanges
            var rebaseSendsRemaining = 1
            while true {
                let result = try await transport.save(changes: changes, role: .iphone)
                guard isCurrent(operation) else { return }
                try await repository.acknowledge(result, sent: changes)
                guard isCurrent(operation) else { return }
                try await transport.commitSentState(result.engineState)
                guard isCurrent(operation) else { return }
                let acknowledgedState = await repository.state()
                rebuild(from: acknowledgedState)
                guard isCurrent(operation) else { return }
                await updateDownloadedStates()
                guard isCurrent(operation) else { return }
                if result.failures.isEmpty {
                    syncPhase = .ready
                    return
                }

                let rebasedChanges = acknowledgedState.pendingChanges.filter { change in
                    guard change.recordID.recordType == .playbackState,
                          let record = change.record,
                          case let .string(rawItemID) = record.fields["itemID"],
                          let itemID = try? ItemID(rawValue: rawItemID) else { return false }
                    return liveItemIDs.contains(itemID)
                        && !acknowledgedState.conflictedRecordIDs.contains(change.recordID)
                }
                let receivedPlaybackConflict = result.failures.contains {
                    $0.disposition == .conflict && $0.recordID.recordType == .playbackState
                }
                guard receivedPlaybackConflict, rebaseSendsRemaining > 0, !rebasedChanges.isEmpty else {
                    syncRetryOperation = .send
                    syncPhase = .failed("Some playback changes need retry", retryable: true)
                    return
                }
                rebaseSendsRemaining -= 1
                changes = rebasedChanges
                syncPhase = .sending("Sending rebased playback progress…")
            }
        } catch {
            guard isCurrent(operation) else { return }
            if sessionFactory != nil {
                rebuildSessionBeforeNextTransportOperation = true
            }
            syncRetryOperation = .send
            syncPhase = .failed("Send failed: \(error.localizedDescription)", retryable: true)
        }
    }

}
