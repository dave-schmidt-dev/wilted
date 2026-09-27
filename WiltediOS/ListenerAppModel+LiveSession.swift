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
#if WILTED_CLOUDKIT_LIVE
    nonisolated static func makeLiveAssetLoader(
        transport: CloudKitSyncTransport,
        mapper: CloudKitRecordMapper
    ) -> ListenerAssetLoader {
        { recordID, asset in
            if let url = await transport.assetHandoff()[recordID]?["audioAsset"] { return url }
            if let url = mapper.resolvedAssetURL(for: asset) { return url }
            return try await transport.fetchLegacyRevisionAsset(
                recordID: recordID,
                expectedAsset: asset
            )
        }
    }

    static func makeLiveSession(root: URL, stateData: Data?, repository: any SyncRepository) async throws -> any ListenerSyncSession {
        let stager = try FileCloudKitAssetStager(rootURL: root.appendingPathComponent("CloudAssets", isDirectory: true))
        let mapper = try CloudKitRecordMapper(stager: stager)
        let container = CKContainer(identifier: "iCloud.com.zerodelta.wilted")
        let driverFactory = LiveCloudKitEngineDriver.makeFactory(
            database: container.privateCloudDatabase,
            automaticallySync: false,
            recordProvider: { recordID in
                let state = await repository.state()
                let change = state.pendingChanges.reversed().first { $0.recordID.recordName == recordID.recordName }
                    ?? state.pendingChanges.first { $0.recordID.recordName == recordID.recordName }
                guard let envelope = change?.record ?? state.records.first(where: { $0.id.recordName == recordID.recordName }) else { return nil }
                return try? mapper.encode(envelope)
            }
        )
        // Read once: the recorded owner is what lets the adapter tell a first sign-in apart
        // from an account switch that happened while engine state was missing.
        let repositoryState = await repository.state()
        let transport = try CloudKitSyncTransport(
            driver: try driverFactory(stateData), role: .iphone, mapper: mapper,
            stateData: stateData, pendingChanges: repositoryState.pendingChanges,
            knownOwnerToken: repositoryState.accountOwnerToken
        )
        return LiveListenerSyncSession(transport: transport, mapper: mapper)
    }

    private actor LiveListenerSyncSession: ListenerSyncSession {
        nonisolated let transport: any SyncTransport
        nonisolated let assetLoader: ListenerAssetLoader
        nonisolated let audioChunkLoader: ListenerAudioChunkLoader
        private let cloudTransport: CloudKitSyncTransport
        nonisolated let accountChanges: AsyncStream<ListenerAccountChange>
        private let accountContinuation: AsyncStream<ListenerAccountChange>.Continuation

        init(transport: CloudKitSyncTransport, mapper: CloudKitRecordMapper) {
            self.transport = transport
            self.cloudTransport = transport
            self.assetLoader = WiltedListenerAppModel.makeLiveAssetLoader(
                transport: transport,
                mapper: mapper
            )
            self.audioChunkLoader = { itemID, revisionID, manifest in
                try await transport.fetchAudioChunks(itemID: itemID, revisionID: revisionID, manifest: manifest)
            }
            let (stream, continuation) = AsyncStream<ListenerAccountChange>.makeStream()
            self.accountChanges = stream
            self.accountContinuation = continuation
            Task {
                for await signal in transport.accountChanges {
                    switch signal {
                    case let .quarantineRequired(changeType):
                        let type: ListenerAccountChangeType = switch changeType {
                        case .signIn: .signIn
                        case .signOut: .signOut
                        case .switchAccounts: .switchAccounts
                        }
                        continuation.yield(.quarantined(type))
                    case let .ownershipAdopted(token):
                        continuation.yield(.ownershipAdopted(token: token))
                    case .ownershipConfirmed:
                        continue
                    }
                }
            }
        }

        func cancel() async { await cloudTransport.cancel() }
        func resetAfterAccountChange() async { await cloudTransport.resetAfterAccountChange() }
    }
#endif

    func observe(_ stream: AsyncStream<SyncStatus>) {
        statusTasks.append(Task { [weak self] in
            for await event in stream { self?.receive(event) }
        })
    }

    /// Repository events without a generation are local bookkeeping (for example,
    /// durable playback enqueue) and must not replace the independently published
    /// sync result. Fetch stage/commit events retain their generation identifier.
    func observeRepository(_ stream: AsyncStream<SyncStatus>) {
        statusTasks.append(Task { [weak self] in
            for await event in stream where event.generationID != nil {
                self?.receive(event)
            }
        })
    }

    func observePlayback(_ stream: AsyncStream<SyncStatus>) {
        statusTasks.append(Task {
            for await _ in stream {}
        })
    }

    func observePlaybackCheckpoints(_ stream: AsyncStream<PlaybackState>) {
        statusTasks.append(Task { [weak self] in
            for await checkpoint in stream {
                guard let self else { return }
                do {
                    try await recordPlayback(checkpoint)
                    if selectedItemID == checkpoint.itemID {
                        selectedPlayback = checkpoint
                        if checkpoint.completed { playbackPhase = .paused }
                    }
                } catch {
                    playbackPhase = .failed("Playback persistence failed: \(error.localizedDescription)", retryable: true)
                }
            }
        })
    }

    func observeRemoteCommandResults(_ stream: AsyncStream<ListenerRemoteCommandResult>) {
        statusTasks.append(Task { [weak self] in
            for await result in stream {
                guard let self else { return }
                do {
                    try await recordPlayback(result.state)
                    guard let playback, await playback.current() == result.state else { continue }
                    selectedItemID = result.state.itemID
                    selectedPlayback = result.state
                    playbackPhase = result.isPlaying ? .playing : .paused
                    reconcileBackgroundCheckpointing(isPlaying: result.isPlaying)
                } catch {
                    playbackPhase = .failed("Remote playback persistence failed: \(error.localizedDescription)", retryable: true)
                }
            }
        })
    }

    private func reconcileBackgroundCheckpointing(isPlaying: Bool) {
        guard isBackgrounded else { return }
        if isPlaying {
            guard backgroundCheckpointTask == nil else { return }
            scheduleBackgroundCheckpoints(generation: backgroundCheckpointGeneration)
        } else {
            backgroundCheckpointTask?.cancel()
            backgroundCheckpointTask = nil
        }
    }

    func observeSession(_ stream: AsyncStream<ListenerAccountChange>) {
        sessionStatusTask?.cancel()
        sessionStatusTask = makeAccountObserver(stream)
    }

    private func makeAccountObserver(_ stream: AsyncStream<ListenerAccountChange>) -> Task<Void, Never> {
        Task { [weak self] in
            for await event in stream {
                guard let self else { return }
                switch event {
                case let .quarantined(type):
                    accountQuarantined = true
                    invalidateCurrentOperation()
                    syncPhase = .failed("\(type.userFacingName) detected; sync is quarantined", retryable: false)
                    await session?.cancel()
                    if let repository = repository as? ListenerRepository {
                        try? await repository.quarantineAfterAccountChange()
                    }
                case let .ownershipAdopted(token):
                    // Recorded before the sync it unblocks completes: a failure afterwards
                    // must not send the next launch back to an unreviewable first sign-in.
                    if let repository = repository as? ListenerRepository {
                        try? await repository.adoptAccountOwner(token)
                    }
                }
            }
        }
    }

    private func receive(_ event: SyncStatus) {
        switch event.phase {
        case .fetching, .staging: syncPhase = .refreshing(event.message)
        case .committing: syncPhase = .sending(event.message)
        case .failed:
            syncRetryOperation = .refresh
            syncPhase = .failed(event.message, retryable: true)
        case .completed: if !operationInFlight { syncPhase = .ready }
        case .idle: break
        }
    }
}
