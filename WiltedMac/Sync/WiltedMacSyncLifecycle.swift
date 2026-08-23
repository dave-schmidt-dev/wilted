import Foundation
import Observation
import WiltedCloudKit
import WiltedDomain
import WiltedProducer
import WiltedSync

/// A transport together with the cancellation operation that interrupts its
/// underlying service request.
struct WiltedMacSyncTransportHandle: Sendable {
    let transport: any SyncTransport
    let cancel: @Sendable () async -> Void
    let reset: @Sendable () async -> Void
    /// Account signals the adapter has already classified.
    ///
    /// Carried here rather than read off a concrete transport type, so the account path is
    /// reachable in the unit gate. It previously required a live-only cast, which is how a
    /// first-sign-in deadlock reached a shipping build with every suite green.
    let accountSignals: AsyncStream<CloudKitAccountChangeSignal>

    init(transport: any SyncTransport, cancel: @escaping @Sendable () async -> Void = {},
         reset: @escaping @Sendable () async -> Void = {},
         accountSignals: AsyncStream<CloudKitAccountChangeSignal> = AsyncStream { $0.finish() }) {
        self.transport = transport
        self.cancel = cancel
        self.reset = reset
        self.accountSignals = accountSignals
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
    private var automaticUploadRequested = false

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

    /// Queues an immutable ready revision as a manifest plus independent byte chunks.
    ///
    /// The manifest is the catalog-facing record. Each chunk has its own stable record
    /// identity and asset descriptor, so retrying this method replaces the same durable
    /// queue entries instead of creating duplicate publications.
    func queueRevision(_ revision: AudioRevision, chunkedFile: AudioChunkedFile) async -> Result<Void, Error> {
        do {
            let manifest = try codec.encode(revision: revision, manifest: chunkedFile.manifest)
            for (descriptor, _) in zip(chunkedFile.manifest.chunks, chunkedFile.chunks) {
                let asset = try WiltedAsset(
                    assetID: descriptor.identity,
                    contentHash: "sha256:\(descriptor.sha256)"
                )
                let envelope = try codec.encode(
                    revisionChunk: revision.itemID,
                    revisionID: revision.revisionID,
                    descriptor: descriptor,
                    chunkAsset: asset
                )
                try await enqueue(envelope, operation: .create)
            }
            // Keep the discoverable ready manifest last even in the durable queue.
            // SyncCoordinator additionally enforces a separate acknowledged chunk phase.
            try await enqueue(manifest, operation: .create)
            return .success(())
        } catch {
            return .failure(error)
        }
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
            case let .success(sent):
                if !sent.failures.isEmpty {
                    setStatus(.init(phase: .failed,
                                    detail: SyncCoordinator.retryMessage(count: sent.failures.count),
                                    generationID: nil))
                    return .success(())
                }
                // A partly blocked send is still a success, so the count that moved and the
                // count still held both have to reach the surface; a bare "uploaded" here
                // reads as a drained queue when it is not.
                var held = 0
                if let repository = try? await openRepository() {
                    held = await repository.state().conflictBlockedChanges.count
                }
                setStatus(.init(phase: .completed,
                                detail: SyncCoordinator.acknowledgedMessage(sent: sent.acknowledgedRecordIDs.count, held: held),
                                generationID: nil))
                return .success(())
            case let .failure(error):
                setStatus(.init(phase: .failed, detail: Self.detail(for: error), generationID: nil))
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
            self?.finishStartedOperation()
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
            self?.finishStartedOperation()
        }
    }

    /// Requests publication for durable changes produced by the Mac processor.
    /// Multiple completions coalesce into one follow-up send instead of starting
    /// concurrent CloudKit operations or surfacing an avoidable busy error.
    func startAutomaticUpload() {
        automaticUploadRequested = true
        scheduleAutomaticUploadIfNeeded()
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
            self.setStatus(.init(phase: .quarantined, detail: "Sync is quarantined until the current iCloud account is reviewed.", generationID: nil))
        }
    }

    /// Clears the local lifecycle quarantine after explicit account review.
    func resetAfterAccountChange() {
        guard quarantined else { return }
        setStatus(.init(phase: .staging, detail: "Resuming sync for the reviewed account.", generationID: nil))
        let reset = resetTransport
        let quarantine = quarantineTask
        Task { [weak self] in
            await quarantine?.value
            await reset?()
            guard let self else { return }
            do {
                // The quarantine conflicted every pending record, and conflicted records are
                // filtered out of every send. Without releasing them here, review resumes
                // syncing but strands the work it was protecting. Awaited before the flag
                // clears so the next upload cannot race it.
                try await self.openRepository().resumeAfterAccountReview()
            } catch {
                self.setStatus(.init(phase: .failed, detail: "Could not release quarantined sync work: \(error)", generationID: nil))
                return
            }
            // CKSyncEngine has already reset its own state for the account event.
            // Keep this transport/coordinator alive so the next operation uses the
            // reviewed engine rather than constructing another nil-state driver.
            self.cancelRequested = false
            self.quarantined = false
            self.setStatus(self.transportFactory == nil ? .disabled : Self.idleStatus)
            self.scheduleAutomaticUploadIfNeeded()
        }
    }

    /// Re-arms the account-review gate from durable state at launch.
    ///
    /// `quarantineAccount` only sets an in-memory flag, so a relaunch came back
    /// unquarantined while the persisted quarantine still conflicted every pending
    /// record. The review control renders only for `.quarantined`, so the release
    /// path was unreachable and the queue could never drain again. The persisted
    /// signature is recomputed rather than stored, so no state schema changes and
    /// existing blobs restore correctly.
    func restoreAccountQuarantine() {
        guard !quarantined, !running, operationTask == nil else { return }
        quarantineTask = Task { [weak self] in
            guard let self else { return }
            guard let repository = try? await self.openRepository() else { return }
            let held = await repository.state().accountQuarantinedRecordIDs
            guard !held.isEmpty, !self.quarantined, !self.running, self.operationTask == nil else { return }
            self.quarantined = true
            self.setStatus(.init(phase: .quarantined,
                                 detail: "Sync is quarantined until the current iCloud account is reviewed.",
                                 generationID: nil))
        }
    }

    private func enqueue(_ envelope: WiltedRecordEnvelope, operation: SyncOperation) async throws {
        guard !quarantined else { throw WiltedMacSyncLifecycleError.accountQuarantined }
        let recordType = envelope.id.recordType.rawValue
        setStatus(.init(phase: .staging, detail: "Queued \(recordType) publication.", generationID: nil))
        do {
            let repository = try await openRepository()
            try await repository.enqueue(try SyncPendingChange(operation: operation, recordID: envelope.id, record: envelope))
        } catch {
            // Callers discard this Result, so without a terminal status here a failed
            // enqueue leaves the surface parked on the staging string above and reads as
            // still working (W-INV-001 requires a bounded failure state).
            setStatus(.init(phase: .failed, detail: "Could not queue \(recordType) publication: \(error)", generationID: nil))
            throw error
        }
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
        accountTask = Task { [weak self, changes = handle.accountSignals] in
            for await signal in changes {
                guard let self else { return }
                await self.handleAccountSignal(signal)
            }
        }
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
            setStatus(.init(phase: .quarantined, detail: "Sync is quarantined until the current iCloud account is reviewed.", generationID: nil))
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
        if operationTask == nil {
            scheduleAutomaticUploadIfNeeded()
        }
    }

    private func finishStartedOperation() {
        operationTask = nil
        scheduleAutomaticUploadIfNeeded()
    }

    private func scheduleAutomaticUploadIfNeeded() {
        guard automaticUploadRequested,
              operationTask == nil,
              !running,
              !quarantined,
              transportFactory != nil else { return }
        operationTask = Task { [weak self] in
            // Keep the request latched while the task is merely queued. A second completion
            // can arrive before this task gets a turn on the main actor; consuming the latch
            // here makes that trigger coalesce with this send. Triggers after the send starts
            // remain latched and schedule the intended follow-up in finishStartedOperation().
            self?.automaticUploadRequested = false
            _ = await self?.uploadPending()
            self?.finishStartedOperation()
        }
    }

    private func cancelledResult() -> Result<Void, Error> {
        setStatus(.init(phase: .cancelled, detail: "Sync cancelled.", generationID: nil))
        return .failure(WiltedMacSyncLifecycleError.cancelled)
    }

    /// Applies an account signal that the adapter has already classified.
    ///
    /// Adoption is persisted immediately rather than after the send it unblocks: a send
    /// that fails first would otherwise leave no recorded owner, and the next launch would
    /// see another first sign-in with nothing for the owner to review.
    private func handleAccountSignal(_ signal: CloudKitAccountChangeSignal) async {
        switch signal {
        case let .quarantineRequired(changeType):
            await quarantineForAccountChange(changeType)
        case let .ownershipAdopted(token):
            do { try await openRepository().adoptAccountOwner(token) }
            catch { setStatus(.init(phase: .failed, detail: "Could not record the iCloud account for local sync: \(error)", generationID: nil)) }
        case .ownershipConfirmed:
            break
        }
    }

    private func quarantineForAccountChange(_ changeType: CloudKitAccountChangeType) async {
        guard !quarantined else { return }
        quarantined = true
        cancelRequested = true
        do {
            let repository = try await openRepository()
            try await repository.quarantineAfterAccountChange()
        } catch {
            setStatus(.init(phase: .failed, detail: "Could not quarantine local sync state: \(error)", generationID: nil))
            return
        }
        await cancelTransport?()
        setStatus(.init(phase: .quarantined, detail: quarantineDetail(for: changeType), generationID: nil))
    }

    private func quarantineDetail(for changeType: CloudKitAccountChangeType) -> String {
        switch changeType {
        case .signIn: "iCloud sign-in detected. Review local sync before continuing."
        case .signOut: "iCloud sign-out detected. Review local sync before continuing."
        case .switchAccounts: "iCloud account switch detected. Review local sync before continuing."
        }
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

    /// Renders a typed sync error for the panel. A blocked send is an expected,
    /// actionable outcome, so it must not surface as a raw enum description.
    private static func detail(for error: Error) -> String {
        guard case let .sendBlockedByConflicts(count, reviewRequired)? = error as? WiltedSyncError else {
            return String(describing: error)
        }
        return SyncCoordinator.blockedMessage(count: count, accountReviewRequired: reviewRequired)
    }

    private static let idleStatus = WiltedMacSyncStatus(phase: .idle, detail: "Sync is ready.", generationID: nil)
}

/// Normalizes the persisted CloudKit engine-state blob before it is decoded.
///
/// `LocalLibraryStore` mirrors the engine bytes into a non-optional SwiftData column and
/// collapses "no state yet" to zero bytes, so a fresh install reads back an empty
/// non-nil `Data` rather than nil. Zero bytes are not a decodable
/// `CKSyncEngine.State.Serialization`, and treating them as one reports a corrupt state
/// on the first sync of every fresh install and after every account reset. Empty is
/// absent: `SyncContracts` already rejects an empty `engineState` as `invalidValue`, so
/// no valid state can be zero-length, and the lossless copy lives in
/// `syncRepositoryState()`.
///
/// This is deliberately outside the live build flag so the Debug gate can cover it.
enum WiltedMacSyncEngineState {
    static func normalized(_ data: Data?) -> Data? {
        guard let data, !data.isEmpty else { return nil }
        return data
    }
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
        guard !explicitlyReset else { return nil }
        return WiltedMacSyncEngineState.normalized(data ?? defaultData)
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
                if case let .asset(asset)? = envelope.fields["chunkAsset"],
                   let chunk = try? WiltedRecordCodec().decodeRevisionChunkRecord(envelope).value,
                   let itemID = try? ItemID(rawValue: envelope.fields["itemID"].flatMap {
                       guard case let .string(value) = $0 else { return nil }
                       return value
                   } ?? ""),
                   let revisionID = try? RevisionID(rawValue: envelope.fields["revisionID"].flatMap {
                       guard case let .string(value) = $0 else { return nil }
                       return value
                   } ?? ""),
                   let stored = try? await configuration.store.readyRevision(for: itemID),
                   stored.revision.revisionID == revisionID {
                    if let url = try? configuration.assetResolver(
                        asset, stored.revision
                    ) {
                        assets[asset.assetID] = url
                    } else if let url = try? materializedChunkURL(
                        descriptor: chunk,
                        revision: stored.revision,
                        sourceURL: stored.mediaURL,
                        rootURL: configuration.assetRootURL
                    ) {
                        assets[asset.assetID] = url
                    } else {
                        return nil
                    }
                }
                return try? mapper.encode(envelope, assetURLs: assets)
            }
        )
        // Read once: the recorded owner is what lets the adapter tell a first sign-in
        // apart from an account switch that happened while engine state was missing.
        let repositoryState = try? await configuration.store.syncRepositoryState()
        let transport = try CloudKitSyncTransport(
            driver: driver, role: .mac, mapper: mapper, stateData: stateData,
            pendingChanges: repositoryState?.pendingChanges ?? [],
            knownOwnerToken: repositoryState?.accountOwnerToken
        )
        return WiltedMacSyncTransportHandle(transport: transport,
                                            cancel: { await transport.cancel() },
                                            reset: { await transport.resetAfterAccountChange() },
                                            accountSignals: transport.accountChanges)
    }

}

/// Materializes the requested opaque byte range into a deterministic local file for
/// `CKAsset`. The source remains the prepared M4A; no re-encoding or remuxing occurs.
private func materializedChunkURL(
    descriptor: AudioChunkDescriptor,
    revision: AudioRevision,
    sourceURL: URL,
    rootURL: URL
) throws -> URL {
    let bytes = try Data(contentsOf: sourceURL)
    let chunked = try AudioChunking.chunk(bytes)
    guard chunked.manifest.chunks.indices.contains(descriptor.index),
          chunked.manifest.chunks[descriptor.index] == descriptor,
          chunked.chunks.indices.contains(descriptor.index) else {
        throw WiltedSyncError.invalidValue(field: "chunkAsset")
    }
    let chunk = chunked.chunks[descriptor.index]
    let directory = rootURL.appendingPathComponent(".wilted-upload-chunks", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let destination = directory.appendingPathComponent(
        "\(revision.itemID.rawValue)-\(revision.revisionID.rawValue)-\(descriptor.index).chunk"
    )
    try chunk.write(to: destination, options: [.atomic])
    return destination
}
#endif
