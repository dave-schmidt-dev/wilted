import Foundation
import Observation
import WiltedDomain
import WiltedProducer
import WiltedSync

/// A transport together with the cancellation operation that interrupts its
/// underlying service request.
struct WiltedMacSyncTransportHandle: Sendable {
    let transport: any SyncTransport
    let cancel: @Sendable () async -> Void
    let reset: @Sendable () async -> Void

    init(transport: any SyncTransport, cancel: @escaping @Sendable () async -> Void = {},
         reset: @escaping @Sendable () async -> Void = {}) {
        self.transport = transport
        self.cancel = cancel
        self.reset = reset
    }
}

/// A caller-owned transport constructor. A nil result leaves sync disabled.
typealias WiltedMacSyncTransportFactory = @Sendable () async throws -> WiltedMacSyncTransportHandle?

enum WiltedMacSyncPhase: String, Sendable {
    case disabled
    case idle
    case staging
    case fetching
    case sending
    case completed
    case failed
    case cancelled
    case quarantined
}

struct WiltedMacSyncStatus: Equatable, Sendable {
    let phase: WiltedMacSyncPhase
    let detail: String
    let generationID: String?

    static let disabled = Self(phase: .disabled, detail: "Sync is not configured.", generationID: nil)
}

enum WiltedMacSyncLifecycleError: Error, Equatable, Sendable {
    case unavailable
    case operationInProgress
    case cancelled
    case accountQuarantined
}

/// Main-actor manual sync lifecycle for the Mac producer.
///
/// The transport is always injected. No default path constructs CloudKit or
/// contacts a service, including Debug builds.
@Observable
@MainActor
final class WiltedMacSyncLifecycle {
    private let store: LocalLibraryStore
    private let transportFactory: WiltedMacSyncTransportFactory?
    private let assetResolver: LocalLibraryAssetResolver
    private let codec = WiltedRecordCodec()
    private var repository: LocalLibrarySyncRepository?
    private var coordinator: SyncCoordinator?
    private var operationTask: Task<Void, Never>?
    private var statusTask: Task<Void, Never>?
    private var coordinatorStatusTask: Task<Void, Never>?
    private var accountTask: Task<Void, Never>?
    private var quarantineTask: Task<Void, Never>?
    private var cancelTransport: (@Sendable () async -> Void)?
    private var resetTransport: (@Sendable () async -> Void)?
    private var running = false
    private var cancelRequested = false
    private var quarantined = false

    private(set) var status: WiltedMacSyncStatus

    init(store: LocalLibraryStore,
         transportFactory: WiltedMacSyncTransportFactory? = nil,
         assetResolver: @escaping LocalLibraryAssetResolver = { _, _ in nil }) {
        self.store = store
        self.transportFactory = transportFactory
        self.assetResolver = assetResolver
        status = transportFactory == nil ? .disabled : Self.idleStatus
    }

    var isBusy: Bool { running }
    var isQuarantined: Bool { quarantined }

    /// Queues an item publication in the durable local repository.
    func queueItem(_ article: Article, currentRevisionID: RevisionID) async -> Result<Void, Error> {
        do {
            let envelope = try codec.encode(article: article, currentRevisionID: currentRevisionID)
            try await enqueue(envelope, operation: .create)
            return .success(())
        } catch { return .failure(error) }
    }

    /// Queues an immutable ready revision publication.
    func queueRevision(_ revision: AudioRevision, audioAsset: WiltedAsset) async -> Result<Void, Error> {
        do {
            let envelope = try codec.encode(revision: revision, audioAsset: audioAsset)
            try await enqueue(envelope, operation: .create)
            return .success(())
        } catch { return .failure(error) }
    }

    /// Queues a playback publication while preserving its opaque sidecar.
    func queuePlayback(_ state: PlaybackState, sidecar: WiltedOpaqueSidecar? = nil) async -> Result<Void, Error> {
        do {
            let envelope = try codec.encode(playback: state, sidecar: sidecar)
            try await enqueue(envelope, operation: .update)
            return .success(())
        } catch { return .failure(error) }
    }

    /// Manually fetches and commits one remote generation.
    @discardableResult
    func refresh() async -> Result<Void, Error> {
        if let error = begin(.fetching, detail: "Fetching changes") { return .failure(error) }
        defer { finishOperation() }
        do {
            let coordinator = try await openCoordinator()
            let result = await coordinator.synchronize()
            if cancelRequested { return cancelledResult() }
            switch result {
            case let .success(batch):
                setStatus(.init(phase: .completed, detail: "Sync completed.", generationID: batch.generationID))
                return .success(())
            case let .failure(error):
                setStatus(.init(phase: .failed, detail: String(describing: error), generationID: nil))
                return .failure(error)
            }
        } catch {
            if cancelRequested { return cancelledResult() }
            setStatus(.init(phase: .failed, detail: String(describing: error), generationID: nil))
            return .failure(error)
        }
    }

    /// Manually sends all durable pending mutations as the Mac role.
    @discardableResult
    func uploadPending() async -> Result<Void, Error> {
        if let error = begin(.sending, detail: "Uploading pending changes") { return .failure(error) }
        defer { finishOperation() }
        do {
            let coordinator = try await openCoordinator()
            let result = await coordinator.sendPending(role: .mac)
            if cancelRequested { return cancelledResult() }
            switch result {
            case .success:
                setStatus(.init(phase: .completed, detail: "Pending changes uploaded.", generationID: nil))
                return .success(())
            case let .failure(error):
                setStatus(.init(phase: .failed, detail: String(describing: error), generationID: nil))
                return .failure(error)
            }
        } catch {
            if cancelRequested { return cancelledResult() }
            setStatus(.init(phase: .failed, detail: String(describing: error), generationID: nil))
            return .failure(error)
        }
    }

    /// Starts the manual refresh action without blocking a UI event handler.
    func startRefresh() {
        guard operationTask == nil else {
            setStatus(.init(phase: .failed, detail: "A sync operation is already running.", generationID: nil))
            return
        }
        operationTask = Task { [weak self] in
            _ = await self?.refresh()
            self?.operationTask = nil
        }
    }

    /// Starts the manual upload action without blocking a UI event handler.
    func startUpload() {
        guard operationTask == nil else {
            setStatus(.init(phase: .failed, detail: "A sync operation is already running.", generationID: nil))
            return
        }
        operationTask = Task { [weak self] in
            _ = await self?.uploadPending()
            self?.operationTask = nil
        }
    }

    /// Cancels the bounded lifecycle and prevents a late result from becoming success.
    func cancel() {
        guard running else { return }
        cancelRequested = true
        setStatus(.init(phase: .cancelled, detail: "Sync cancelled.", generationID: nil))
        let cancelTransport = self.cancelTransport
        Task { await cancelTransport?() }
        operationTask?.cancel()
    }

    /// Quarantines operations after an account-owner change until explicitly reset.
    func quarantineAccount() {
        cancel()
        quarantined = true
        quarantineTask = Task { [weak self] in
            guard let self else { return }
            do {
                let repository = try await self.openRepository()
                try await repository.quarantineAfterAccountChange()
            } catch {
                self.setStatus(.init(phase: .failed, detail: "Could not quarantine local sync state: \(error)", generationID: nil))
                return
            }
            self.setStatus(.init(phase: .quarantined, detail: "Sync is quarantined until the account is reviewed.", generationID: nil))
        }
    }

    /// Clears the local lifecycle quarantine; durable repository state remains intact.
    func resetAfterAccountChange() {
        guard quarantined else { return }
        setStatus(.init(phase: .staging, detail: "Rebuilding sync for the reviewed account.", generationID: nil))
        let reset = resetTransport
        let quarantine = quarantineTask
        Task { [weak self] in
            await quarantine?.value
            await reset?()
            guard let self else { return }
            self.coordinator = nil
            self.repository = nil
            self.statusTask?.cancel(); self.coordinatorStatusTask?.cancel(); self.accountTask?.cancel()
            self.quarantined = false
            self.setStatus(self.transportFactory == nil ? .disabled : Self.idleStatus)
        }
    }

    private func enqueue(_ envelope: WiltedRecordEnvelope, operation: SyncOperation) async throws {
        guard !quarantined else { throw WiltedMacSyncLifecycleError.accountQuarantined }
        setStatus(.init(phase: .staging, detail: "Queued \(envelope.id.recordType.rawValue) publication.", generationID: nil))
        let repository = try await openRepository()
        try await repository.enqueue(try SyncPendingChange(operation: operation, recordID: envelope.id, record: envelope))
        setStatus(.init(phase: .completed, detail: "Publication queued.", generationID: nil))
    }

    private func openCoordinator() async throws -> SyncCoordinator {
        guard !quarantined else { throw WiltedMacSyncLifecycleError.accountQuarantined }
        if let coordinator { return coordinator }
        guard let transportFactory, let handle = try await transportFactory() else {
            throw WiltedMacSyncLifecycleError.unavailable
        }
        let repository = try await openRepository()
        let coordinator = SyncCoordinator(transport: handle.transport, repository: repository)
        self.coordinator = coordinator
        cancelTransport = handle.cancel
        resetTransport = handle.reset
        statusTask = Task { [weak self, statuses = handle.transport.statuses] in
            for await event in statuses {
                guard let self else { return }
                self.apply(event)
            }
        }
        let coordinatorStatuses = await coordinator.statuses
        coordinatorStatusTask = Task { [weak self, statuses = coordinatorStatuses] in
            for await event in statuses {
                guard let self else { return }
                self.apply(event)
            }
        }
#if WILTED_CLOUDKIT_LIVE
        if let cloudTransport = handle.transport as? CloudKitSyncTransport {
            accountTask = Task { [weak self, changes = cloudTransport.accountChanges] in
                for await signal in changes where signal == .quarantineRequired {
                    guard let self else { return }
                    await self.quarantineForAccountChange()
                }
            }
        }
#endif
        return coordinator
    }

    private func openRepository() async throws -> LocalLibrarySyncRepository {
        if let repository { return repository }
        let repository = try await LocalLibrarySyncRepository(store: store, assetResolver: assetResolver)
        self.repository = repository
        return repository
    }

    private func begin(_ phase: WiltedMacSyncPhase, detail: String) -> Error? {
        guard !running else { return WiltedMacSyncLifecycleError.operationInProgress }
        guard !quarantined else {
            setStatus(.init(phase: .quarantined, detail: "Sync is quarantined until the account is reviewed.", generationID: nil))
            return WiltedMacSyncLifecycleError.accountQuarantined
        }
        guard transportFactory != nil else {
            setStatus(.disabled)
            return WiltedMacSyncLifecycleError.unavailable
        }
        running = true
        cancelRequested = false
        setStatus(.init(phase: phase, detail: detail, generationID: nil))
        return nil
    }

    private func finishOperation() {
        // Keep the cancellation marker through the terminal result so a
        // transport's late failure cannot replace the visible cancelled state.
        running = false
    }

    private func cancelledResult() -> Result<Void, Error> {
        setStatus(.init(phase: .cancelled, detail: "Sync cancelled.", generationID: nil))
        return .failure(WiltedMacSyncLifecycleError.cancelled)
    }

    private func quarantineForAccountChange() async {
        guard !quarantined else { return }
        quarantined = true
        cancelRequested = true
        do {
            try await repository?.quarantineAfterAccountChange()
        } catch {
            setStatus(.init(phase: .failed, detail: "Could not quarantine local sync state: \(error)", generationID: nil))
            return
        }
        await cancelTransport?()
        setStatus(.init(phase: .quarantined, detail: "Sync is quarantined until the account is reviewed.", generationID: nil))
    }

    private func setStatus(_ value: WiltedMacSyncStatus) { status = value }

    private func apply(_ event: SyncStatus) {
        if cancelRequested { return }
        let phase: WiltedMacSyncPhase
        switch event.phase {
        case .idle: phase = .idle
        case .fetching: phase = .fetching
        case .staging, .committing: phase = .staging
        case .completed: phase = .completed
        case .failed: phase = .failed
        }
        setStatus(.init(phase: phase, detail: event.message, generationID: event.generationID))
    }

    private static let idleStatus = WiltedMacSyncStatus(phase: .idle, detail: "Sync is ready.", generationID: nil)
}

#if WILTED_CLOUDKIT_LIVE
import CloudKit
import WiltedCloudKit

/// Explicit live configuration. Construction is unavailable in Debug because
/// the implementation is compiled only when the live build flag is present.
struct WiltedMacLiveSyncConfiguration {
    let database: CKDatabase
    let assetRootURL: URL
    let store: LocalLibraryStore
    let assetResolver: LocalLibraryAssetResolver
    let stateData: Data?

    init(database: CKDatabase, assetRootURL: URL, store: LocalLibraryStore,
         assetResolver: @escaping LocalLibraryAssetResolver, stateData: Data? = nil) {
        self.database = database
        self.assetRootURL = assetRootURL
        self.store = store
        self.assetResolver = assetResolver
        self.stateData = stateData
    }
}

private actor WiltedMacLiveStateBox {
    private var data: Data?
    private var explicitlyReset = false

    init(_ data: Data?) { self.data = data }

    func take(defaultData: Data?) -> Data? {
        explicitlyReset ? nil : (data ?? defaultData)
    }

    func clear() { data = nil; explicitlyReset = true }
}

/// Creates the opted-in Development/Release transport and maps pending record
/// assets through the local repository before CKSyncEngine asks for records.
func makeWiltedMacLiveSyncTransportFactory(
    configuration: WiltedMacLiveSyncConfiguration
) -> WiltedMacSyncTransportFactory {
    let stateBox = WiltedMacLiveStateBox(configuration.stateData)
    return {
        let persistedState = try? await configuration.store.syncState(for: "private-zone")
        let stateData = await stateBox.take(defaultData: persistedState?.engineState)
        let stager = try FileCloudKitAssetStager(rootURL: configuration.assetRootURL)
        let mapper = try CloudKitRecordMapper(stager: stager)
        let serialization: CKSyncEngine.State.Serialization?
        if let stateData {
            guard let decoded = try? JSONDecoder().decode(CKSyncEngine.State.Serialization.self, from: stateData) else {
                throw CloudKitSyncError.stateCorrupt
            }
            serialization = decoded
        } else {
            serialization = nil
        }
        let driver = LiveCloudKitEngineDriver(
            database: configuration.database,
            stateSerialization: serialization,
            automaticallySync: false,
            recordProvider: { recordID in
                let currentState = try? await configuration.store.syncRepositoryState()
                let pending = currentState?.pendingChanges.first {
                    $0.recordID.recordName == recordID.recordName
                }
                guard let envelope = pending?.record else { return nil }
                var assets: [String: URL] = [:]
                if case let .asset(asset)? = envelope.fields["audioAsset"] {
                    guard let revision = try? WiltedRecordCodec().decodeRevision(envelope) else { return nil }
                    if let url = try? configuration.assetResolver(asset, revision) {
                        assets[asset.assetID] = url
                    } else if let stored = try? await configuration.store.readyRevision(for: revision.itemID),
                              stored.revision.revisionID == revision.revisionID,
                              stored.revision.contentHash == revision.contentHash {
                        assets[asset.assetID] = stored.mediaURL
                    } else {
                        return nil
                    }
                }
                return try? mapper.encode(envelope, assetURLs: assets)
            }
        )
        let transport = try CloudKitSyncTransport(
            driver: driver, role: .mac, mapper: mapper, stateData: stateData,
            pendingChanges: (try? await configuration.store.syncRepositoryState())?.pendingChanges ?? []
        )
        return WiltedMacSyncTransportHandle(transport: transport,
                                            cancel: { await transport.cancel() },
                                            reset: { await stateBox.clear() })
    }
}
#endif
