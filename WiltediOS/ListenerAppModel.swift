import Foundation
import SwiftUI
import WiltedDomain
import WiltedListener
import WiltedSync

#if WILTED_CLOUDKIT_LIVE
import CloudKit
import WiltedCloudKit
#endif

public enum ListenerAppStatus: Equatable, Sendable {
    case idle
    case refreshing(String)
    case sending(String)
    case ready
    case offline(String)
    case playing
    case paused
    case deleted(String)
    case incompatible(String)
    case failed(String, retryable: Bool)

    public var message: String {
        switch self {
        case .idle: "Ready"
        case let .refreshing(message), let .sending(message), let .offline(message),
             let .deleted(message), let .incompatible(message): message
        case .ready: "Larder ready"
        case .playing: "Playing offline"
        case .paused: "Playback paused"
        case let .failed(message, _): message
        }
    }

    public var isBusy: Bool {
        switch self {
        case .refreshing, .sending: true
        default: false
        }
    }
}

public enum ListenerItemState: Equatable, Sendable {
    case downloaded
    case metadataOnly
    case deleted
    case incompatibleRevision
    case unavailable

    public var label: String {
        switch self {
        case .downloaded: "Downloaded"
        case .metadataOnly: "Metadata available; download required"
        case .deleted: "Deleted remotely"
        case .incompatibleRevision: "Incompatible revision"
        case .unavailable: "Audio unavailable offline"
        }
    }
}

/// The bounded, account-free states used by the shipping listener pixel tests.
/// They describe presentation only and never enable a transport, repository,
/// cache, or audio engine.
public enum ListenerPixelFixtureState: String, Sendable {
    case library
    case nowPlaying
    case emptyNowPlaying
    case terminalFailure
}

public struct ListenerLibraryItem: Identifiable, Equatable, Sendable {
    public let itemID: ItemID
    public let title: String
    public let source: String
    public let revisionID: RevisionID?
    public let durationSeconds: Double?
    public let asset: WiltedAsset?
    public let state: ListenerItemState

    public var id: ItemID { itemID }

    public init(itemID: ItemID, title: String, source: String, revisionID: RevisionID?,
                durationSeconds: Double?, asset: WiltedAsset?, state: ListenerItemState) {
        self.itemID = itemID
        self.title = title
        self.source = source
        self.revisionID = revisionID
        self.durationSeconds = durationSeconds
        self.asset = asset
        self.state = state
    }
}

public typealias ListenerAssetLoader = @Sendable (WiltedRecordID, WiltedAsset) async throws -> URL
public typealias ListenerAudioChunkLoader = @Sendable (ItemID, RevisionID, AudioChunkManifest) async throws -> Data

public enum ListenerAccountChangeType: String, Codable, Sendable {
    case signIn
    case signOut
    case switchAccounts

    var userFacingName: String {
        switch self {
        case .signIn: "iCloud sign-in"
        case .signOut: "iCloud sign-out"
        case .switchAccounts: "iCloud account switch"
        }
    }
}

public enum ListenerAccountChange: Sendable {
    case quarantined(ListenerAccountChangeType)
    /// A first sign-in on a device whose local work no account had claimed. Recorded and
    /// carried on, because there is no second account for the listener to review against.
    case ownershipAdopted(token: String)

    /// Compatibility spelling for callers that do not need the transition type.
    public static var quarantined: Self { .quarantined(.switchAccounts) }
}

public protocol ListenerSyncSession: Sendable {
    var transport: any SyncTransport { get }
    var assetLoader: ListenerAssetLoader { get }
    var audioChunkLoader: ListenerAudioChunkLoader { get }
    var accountChanges: AsyncStream<ListenerAccountChange> { get }
    func cancel() async
    func resetAfterAccountChange() async
}

public typealias ListenerSyncSessionFactory = @Sendable (Data?) async throws -> any ListenerSyncSession

enum ListenerDefaultSessionMode: Equatable {
    case localOnly
    case liveCloudKit
}

/// Main-actor presentation model for the iPhone listener.
///
/// The default initializer has no transport and therefore cannot construct or
/// contact CloudKit. A live transport and asset loader are supplied explicitly
/// by the attended live build composition.
@MainActor
public final class WiltedListenerAppModel: ObservableObject {
    /// Active background playback is durably checkpointed at this bounded cadence.
    /// The one-second UI readout remains memory-only.
    public static let durableBackgroundCheckpointInterval: Duration = .seconds(15)

    @Published public private(set) var items: [ListenerLibraryItem] = []
    @Published public private(set) var syncPhase: ListenerAppStatus = .idle
    @Published public private(set) var playbackPhase: ListenerAppStatus = .paused
    @Published public private(set) var selectedItemID: ItemID?
    @Published public private(set) var selectedPlayback: PlaybackState?
    @Published public private(set) var transcriptsByItem: [ItemID: Transcript] = [:]
    @Published public private(set) var downloadStatistics = ListenerDownloadStatistics()
    @Published public private(set) var syncObservability = ListenerSyncObservability()

    private let repository: (any SyncRepository)?
    private var transport: (any SyncTransport)?
    private let cache: ListenerAudioCache?
    private let playback: ListenerPlaybackController?
    private var installedRemoteCommands: (any ListenerRemoteCommands)?
    private var assetLoader: ListenerAssetLoader?
    private var audioChunkLoader: ListenerAudioChunkLoader?
    private let sessionFactory: ListenerSyncSessionFactory?
    private var session: (any ListenerSyncSession)?
    private var rebuildSessionBeforeNextRefresh = false
    /// Published so the listener can offer account review the way the producer
    /// does. While this was private the quarantined status was non-retryable
    /// and no control was drawn, which left the shipping listener with no way
    /// out of quarantine at all.
    @Published public private(set) var accountQuarantined = false
    private let metadataLoader: (@Sendable () async -> ListenerMetadata?)?
    private let metadataSaver: (@Sendable (ListenerMetadata?) async throws -> Void)?
    private var playbackByItem: [ItemID: PlaybackState] = [:]
    private var playbackChangeTagByItem: [ItemID: String] = [:]
    private var revisionByItem: [ItemID: AudioRevision] = [:]
    private var assetByItem: [ItemID: WiltedAsset] = [:]
    private var manifestByItem: [ItemID: AudioChunkManifest] = [:]
    private var operationInFlight = false
    private var operationHandoffReserved = false
    private var operationWaiters: [CheckedContinuation<Void, Never>] = []
    /// Invalidates every suspended model operation when cancellation permits a retry.
    /// A Boolean alone cannot distinguish the cancelled operation from its successor.
    private var operationGeneration: UInt64 = 0
    private var didStart = false
    private var cancellationRequested = false
    private var statusTasks: [Task<Void, Never>] = []
    private var sessionStatusTask: Task<Void, Never>?
    private var backgroundCheckpointTask: Task<Void, Never>?
    private var isBackgrounded = false
    private var backgroundCheckpointGeneration: UInt64 = 0
    private let backgroundCheckpointInterval: Duration
    private let backgroundSleeper: @Sendable (Duration) async throws -> Void
    private var decodeHadErrors = false

    public init(
        repository: (any SyncRepository)? = nil,
        transport: (any SyncTransport)? = nil,
        sessionFactory: ListenerSyncSessionFactory? = nil,
        cache: ListenerAudioCache? = nil,
        playback: ListenerPlaybackController? = nil,
        assetLoader: ListenerAssetLoader? = nil,
        audioChunkLoader: ListenerAudioChunkLoader? = nil,
        metadataLoader: (@Sendable () async -> ListenerMetadata?)? = nil,
        metadataSaver: (@Sendable (ListenerMetadata?) async throws -> Void)? = nil,
        backgroundCheckpointInterval: Duration = WiltedListenerAppModel.durableBackgroundCheckpointInterval,
        backgroundSleeper: @escaping @Sendable (Duration) async throws -> Void = { duration in
            try await Task.sleep(for: duration)
        },
        unavailableMessage: String? = nil
    ) {
        self.repository = repository
        self.transport = transport
        self.sessionFactory = sessionFactory
        self.cache = cache
        self.playback = playback
        self.assetLoader = assetLoader
        self.audioChunkLoader = audioChunkLoader
        self.metadataLoader = metadataLoader
        self.metadataSaver = metadataSaver
        self.backgroundCheckpointInterval = backgroundCheckpointInterval
        self.backgroundSleeper = backgroundSleeper
        if let unavailableMessage { syncPhase = .failed(unavailableMessage, retryable: false) }
        if let repository { observeRepository(repository.statuses) }
        if let transport { observe(transport.statuses) }
        if let cache { observe(cache.statuses) }
        // Playback commands set their final presentation state directly. Their status stream
        // is still consumed, but never used to overwrite those command results later.
        if let playback {
            observePlayback(playback.statuses)
            observePlaybackCheckpoints(playback.durableCheckpoints)
            observeRemoteCommandResults(playback.remoteCommandResults)
        }
    }

    public static func makeDefault() -> WiltedListenerAppModel {
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Wilted", isDirectory: true)
        do {
            let repository = try ListenerRepository(directoryURL: root)
            let cache = try ListenerAudioCache(rootURL: root.appendingPathComponent("Audio", isDirectory: true))
            let playback = ListenerPlaybackController(cache: cache, engine: AVFoundationAudioEngine())
#if WILTED_CLOUDKIT_LIVE
            if defaultSessionMode() == .liveCloudKit {
                return WiltedListenerAppModel(
                    repository: repository,
                    sessionFactory: { stateData in
                        try await Self.makeLiveSession(root: root, stateData: stateData, repository: repository)
                    },
                    cache: cache,
                    playback: playback,
                    metadataLoader: { await repository.loadMetadata() },
                    metadataSaver: { metadata in try await repository.saveMetadata(metadata) }
                )
            }
#endif
            return WiltedListenerAppModel(
                repository: repository,
                cache: cache,
                playback: playback,
                metadataLoader: { await repository.loadMetadata() },
                metadataSaver: { metadata in try await repository.saveMetadata(metadata) }
            )
        } catch {
            return WiltedListenerAppModel(unavailableMessage: "Local larder unavailable: \(error.localizedDescription)")
        }
    }

    static func defaultSessionMode(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> ListenerDefaultSessionMode {
#if WILTED_CLOUDKIT_LIVE
        environment["XCTestConfigurationFilePath"] == nil ? .liveCloudKit : .localOnly
#else
        .localOnly
#endif
    }

    /// Deterministic shipping-view data for iOS pixel tests. This intentionally
    /// has no repository, transport, cache, or audio engine, so capturing the
    /// listener Library cannot touch an account or device media state.
    public static func makePixelFixture(
        state: ListenerPixelFixtureState = .library
    ) -> WiltedListenerAppModel {
        let model = WiltedListenerAppModel()
        if state == .emptyNowPlaying {
            model.syncPhase = .ready
            return model
        }
        guard let itemID = try? ItemID.derive(from: URL(string: "https://example.test/wilted-listener")!) else {
            return model
        }
        guard let revisionID = try? RevisionID(rawValue: "revision-pixel-fixture") else { return model }
        model.items = [
            ListenerLibraryItem(
                itemID: itemID,
                title: "A fixture article for listening",
                source: "Wilted Test Journal",
                revisionID: revisionID,
                durationSeconds: 120,
                asset: nil,
                state: .downloaded
            )
        ]
        model.transcriptsByItem[itemID] = try? Transcript(
            itemID: itemID,
            revisionID: revisionID,
            availability: .available,
            text: "This fixture transcript proves saved article text remains available while listening.",
            languageCode: "en",
            updatedAt: Timestamp(Date(timeIntervalSince1970: 1_787_515_200))
        )
        model.downloadStatistics = ListenerDownloadStatistics(fileCount: 1, byteCount: 1_245_184)
        model.syncObservability = ListenerSyncObservability(
            lastSuccessfulFetchAt: Date(timeIntervalSince1970: 1_787_515_200)
        )
        switch state {
        case .library, .emptyNowPlaying:
            model.syncPhase = .ready
        case .nowPlaying:
            guard let playback = try? PlaybackState(
                      itemID: itemID,
                      revisionID: revisionID,
                      sessionID: "pixel-fixture",
                      sequence: 1,
                      positionSeconds: 31,
                      durationSeconds: 120,
                      completed: false,
                      intent: .progress,
                      deviceID: "pixel-fixture-device",
                      updatedAt: Timestamp(Date(timeIntervalSince1970: 0))
                  ) else {
                return model
            }
            model.syncPhase = .ready
            model.playbackPhase = .playing
            model.selectedPlayback = playback
        case .terminalFailure:
            // The quarantine flag, not just its message. Setting only the
            // status reproduced the *appearance* of a quarantined listener
            // without the condition, so the baseline recorded a screen with no
            // recovery control and nothing flagged it as a dead end.
            model.accountQuarantined = true
            model.syncPhase = .failed("iCloud account changed; sync is quarantined", retryable: false)
        }
        return model
    }

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
        guard let operation = beginOperation() else { return }
        defer { finishOperation(operation) }
        syncPhase = .refreshing("Refreshing larder…")
        guard let repository else {
            syncPhase = .failed("Local larder unavailable", retryable: false)
            return
        }

        if rebuildSessionBeforeNextRefresh {
            await session?.cancel()
            guard isCurrent(operation) else { return }
            session = nil
            transport = nil
            assetLoader = nil
            audioChunkLoader = nil
            sessionStatusTask?.cancel()
            sessionStatusTask = nil
            rebuildSessionBeforeNextRefresh = false
        }

        if transport == nil, let sessionFactory {
            do {
                let state = await repository.state()
                let createdSession = try await sessionFactory(state.engineState)
                guard isCurrent(operation) else { return }
                session = createdSession
                transport = createdSession.transport
                assetLoader = createdSession.assetLoader
                audioChunkLoader = createdSession.audioChunkLoader
                observeSession(createdSession.accountChanges)
            } catch {
                guard isCurrent(operation) else { return }
                rebuildSessionBeforeNextRefresh = true
                if let listenerRepository = repository as? ListenerRepository {
                    try? await listenerRepository.recordFetchFailure(error.localizedDescription)
                }
                await refreshSyncObservability()
                guard isCurrent(operation) else { return }
                await loadLocal(repository: repository, fallback: error.localizedDescription, operation: operation)
                guard isCurrent(operation) else { return }
                if case .offline = syncPhase {
                    syncPhase = .failed("Sync unavailable: \(error.localizedDescription)", retryable: true)
                }
                return
            }
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
                    rebuildSessionBeforeNextRefresh = true
                }
                if let listenerRepository = repository as? ListenerRepository {
                    try? await listenerRepository.recordFetchFailure(error.localizedDescription)
                }
                await refreshSyncObservability()
                guard isCurrent(operation) else { return }
                await loadLocal(repository: repository, fallback: error.localizedDescription, operation: operation)
                guard isCurrent(operation) else { return }
                if case .offline = syncPhase {
                    syncPhase = .failed("Refresh failed: \(error.localizedDescription)", retryable: true)
                }
                return
            }
        }

        guard isCurrent(operation) else { return }
        await loadLocal(repository: repository, fallback: "Offline mode", operation: operation)
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
        let operation = await beginQueuedOperation()
        defer { finishOperation(operation) }
        guard let repository, let transport else {
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
                    syncPhase = .failed("Nothing was sent. \(subject) held by unresolved conflicts.", retryable: true)
                }
                return
            }
            let result = try await transport.save(changes: sendableChanges, role: .iphone)
            guard isCurrent(operation) else { return }
            try await repository.acknowledge(result, sent: sendableChanges)
            guard isCurrent(operation) else { return }
            rebuild(from: await repository.state())
            guard isCurrent(operation) else { return }
            await updateDownloadedStates()
            guard isCurrent(operation) else { return }
            syncPhase = result.failures.isEmpty ? .ready : .failed("Some playback changes need retry", retryable: true)
        } catch {
            guard isCurrent(operation) else { return }
            syncPhase = .failed("Send failed: \(error.localizedDescription)", retryable: true)
        }
    }

    public func download(itemID: ItemID) async {
        guard !accountQuarantined else { return }
        guard let cache,
              let item = items.first(where: { $0.itemID == itemID }),
              let revision = revisionByItem[itemID], let asset = assetByItem[itemID] else { return }
        guard item.state == .metadataOnly else { return }
        guard let operation = beginOperation() else { return }
        defer { finishOperation(operation) }
        syncPhase = .refreshing("Downloading \(item.title)…")
        do {
            if let manifest = manifestByItem[itemID] {
                guard let audioChunkLoader else {
                    throw ListenerError.cacheUnavailable(asset.assetID)
                }
                let data = try await audioChunkLoader(itemID, revision.revisionID, manifest)
                guard isCurrent(operation) else { return }
                _ = try await cache.store(data: data, asset: asset)
            } else {
                guard let assetLoader else {
                    throw ListenerError.cacheUnavailable(asset.assetID)
                }
                let recordID = try WiltedRecordID.revision(itemID, revision.revisionID)
                let sourceURL = try await assetLoader(recordID, asset)
                guard isCurrent(operation) else { return }
                _ = try await cache.store(fileURL: sourceURL, asset: asset)
            }
            guard isCurrent(operation) else { return }
            updateItemState(itemID: itemID, state: .downloaded)
            await refreshDownloadStatistics()
            syncPhase = .ready
        } catch {
            guard isCurrent(operation) else { return }
            syncPhase = .failed("Download failed: \(error.localizedDescription)", retryable: true)
        }
    }

    public func removeDownload(itemID: ItemID) async {
        guard !accountQuarantined,
              let cache, assetByItem[itemID] != nil,
              items.contains(where: { $0.itemID == itemID }) else { return }
        guard let operation = beginOperation() else { return }
        defer { finishOperation(operation) }
        if selectedItemID == itemID { await pause() }
        guard isCurrent(operation), !accountQuarantined else { return }
        let retainedAssets = assetByItem.compactMap { $0.key == itemID ? nil : $0.value }
        await cache.reconcile(retaining: retainedAssets)
        guard isCurrent(operation), !accountQuarantined else { return }
        await updateDownloadedStates()
        guard isCurrent(operation), !accountQuarantined else { return }
        syncPhase = .ready
    }

    public func play(itemID: ItemID) async {
        guard let item = items.first(where: { $0.itemID == itemID }) else { return }
        guard item.state == .downloaded, let revision = revisionByItem[itemID], let asset = assetByItem[itemID], let playback else {
            playbackPhase = item.state == .incompatibleRevision
                ? .incompatible("This item cannot play with its current revision")
                : .offline("Audio is not cached for offline playback")
            return
        }
        let state: PlaybackState
        if let existing = playbackByItem[itemID], existing.revisionID == revision.revisionID {
            state = existing
        } else if let initial = makeInitialPlayback(for: item, revision: revision) {
            state = initial
        } else {
            playbackPhase = .failed("Playback state could not be created", retryable: false)
            return
        }
        playbackPhase = .refreshing("Preparing offline audio")
        do {
            if selectedItemID != nil, selectedItemID != itemID,
               let outgoing = try await playback.liveCheckpoint() {
                try await recordPlayback(outgoing)
                selectedPlayback = outgoing
            }
            let updated = try await playback.play(asset: asset, title: item.title, state: state)
            try await recordPlayback(updated)
            selectedItemID = itemID
            selectedPlayback = updated
            playbackPhase = .playing
        } catch {
            playbackPhase = .failed("Playback failed: \(error.localizedDescription)", retryable: true)
        }
    }

    public func pause() async {
        guard let playback else { return }
        do {
            if let updated = try await playback.pause() {
                try await recordPlayback(updated)
                selectedPlayback = updated
            }
            playbackPhase = .paused
        } catch { playbackPhase = .failed("Pause failed: \(error.localizedDescription)", retryable: true) }
    }

    public func seek(to position: Double) async {
        guard let itemID = selectedItemID, let item = items.first(where: { $0.itemID == itemID }),
              let revision = revisionByItem[itemID], let asset = assetByItem[itemID], let current = playbackByItem[itemID],
              let playback else { return }
        let bounded = max(0, min(position, revision.durationSeconds))
        await positionChange(item: item, asset: asset, playback: playback, current: current,
                             position: bounded, intent: bounded < current.positionSeconds ? .rewind : .progress,
                             newSession: bounded < current.positionSeconds)
    }

    public func seekForward(by seconds: Double = 30) async {
        guard seconds.isFinite, seconds >= 0 else { return }
        await seek(to: (selectedPlayback?.positionSeconds ?? 0) + seconds)
    }

    public func seekBackward(by seconds: Double = 15) async {
        guard seconds.isFinite, seconds >= 0 else { return }
        await seek(to: max(0, (selectedPlayback?.positionSeconds ?? 0) - seconds))
    }

    public func rewind() async {
        await explicitPositionChange(intent: .rewind, position: max(0, (selectedPlayback?.positionSeconds ?? 0) - 15))
    }

    public func restart() async {
        await explicitPositionChange(intent: .restart, position: 0)
    }

    public func enterBackground() async {
        isBackgrounded = true
        backgroundCheckpointGeneration &+= 1
        let generation = backgroundCheckpointGeneration
        backgroundCheckpointTask?.cancel()
        guard let playback else {
            return
        }
        do {
            if let updated = try await playback.enterBackground() {
                guard isBackgrounded, backgroundCheckpointGeneration == generation else { return }
                try await recordPlayback(updated)
                guard isBackgrounded, backgroundCheckpointGeneration == generation else { return }
                selectedPlayback = updated
                scheduleBackgroundCheckpoints(generation: generation)
            }
        } catch {
            playbackPhase = .failed("Background persistence failed: \(error.localizedDescription)", retryable: true)
        }
    }

    /// Refreshes the displayed position from the active engine without queuing a sync write.
    public func refreshNowPlayingReadout() async {
        guard case .playing = playbackPhase, let playback else { return }
        do {
            guard let readout = try await playback.liveReadout() else { return }
            playbackByItem[readout.itemID] = readout
            selectedPlayback = readout
        } catch {
            playbackPhase = .failed("Playback readout failed: \(error.localizedDescription)", retryable: true)
        }
    }

    public func resumeForeground() async {
        let shouldPersistActivePosition = isBackgrounded
        isBackgrounded = false
        backgroundCheckpointGeneration &+= 1
        let cancelledCheckpointTask = backgroundCheckpointTask
        cancelledCheckpointTask?.cancel()
        backgroundCheckpointTask = nil
        await cancelledCheckpointTask?.value
        if shouldPersistActivePosition { await persistActivePlaybackCheckpoint() }
        // Scene activation can race the view's initial task. Treat the first
        // foreground as launch so that pair produces one catalog fetch.
        if !didStart { await start() } else { await refresh() }
    }

    public func cancel() {
        invalidateCurrentOperation()
        syncPhase = .idle
        Task { await session?.cancel() }
    }

    private func invalidateCurrentOperation() {
        cancellationRequested = true
        operationGeneration &+= 1
        guard operationInFlight else { return }
        releaseOperationSlot()
    }

    private func beginOperation() -> UInt64? {
        guard !operationInFlight, !operationHandoffReserved else { return nil }
        return claimOperationSlot()
    }

    private func beginQueuedOperation() async -> UInt64 {
        if operationInFlight || operationHandoffReserved {
            await withCheckedContinuation { operationWaiters.append($0) }
            operationHandoffReserved = false
        }
        return claimOperationSlot()
    }

    private func claimOperationSlot() -> UInt64 {
        operationGeneration &+= 1
        operationInFlight = true
        cancellationRequested = false
        return operationGeneration
    }

    private func isCurrent(_ operation: UInt64) -> Bool {
        operationGeneration == operation && !cancellationRequested
    }

    private func finishOperation(_ operation: UInt64) {
        guard operationGeneration == operation else { return }
        releaseOperationSlot()
    }

    private func releaseOperationSlot() {
        operationInFlight = false
        guard !operationWaiters.isEmpty else {
            operationHandoffReserved = false
            return
        }
        operationHandoffReserved = true
        operationWaiters.removeFirst().resume()
    }

    public func resetAfterAccountChange() async {
        guard let session else { return }
        await session.resetAfterAccountChange()
        accountQuarantined = false
        syncPhase = .ready
    }

    /// The single account-review entry point the listener UI calls.
    ///
    /// `resetAfterAccountChange()` only recovers when a live sync session
    /// exists. A listener can also be quarantined before one is established —
    /// and the account-free fixture never has one — so this covers both rather
    /// than leaving the control inert in exactly the states it is needed.
    public func recoverFromAccountChange() async {
        guard accountQuarantined else { return }
        if session != nil {
            await resetAfterAccountChange()
            return
        }
        accountQuarantined = false
        await updateDownloadedStates()
        syncPhase = .ready
    }

#if DEBUG
    /// Installs deterministic catalog state for the account-free UI fixture.
    /// This is internal to the app target so the production composition cannot
    /// accidentally use fixture data.
    func installMVPFixture(item: ListenerLibraryItem, revision: AudioRevision, asset: WiltedAsset,
                           transcript: Transcript? = nil) {
        items = [item]
        revisionByItem = [item.itemID: revision]
        assetByItem = [item.itemID: asset]
        manifestByItem = [:]
        playbackByItem = [:]
        playbackChangeTagByItem = [:]
        transcriptsByItem = transcript.map { [item.itemID: $0] } ?? [:]
        downloadStatistics = ListenerDownloadStatistics()
        syncPhase = .ready
    }

    /// Drives the recovery state exposed only by the account-free UI fixture.
    func quarantineForMVPFixture() {
        accountQuarantined = true
        invalidateCurrentOperation()
        syncPhase = .failed("iCloud account switch detected; sync is quarantined", retryable: false)
    }

    /// Recovers the account-free UI fixture after its simulated quarantine.
    func recoverMVPFixture() async {
        guard session == nil, accountQuarantined else { return }
        accountQuarantined = false
        await updateDownloadedStates()
        syncPhase = .ready
    }
#endif

    public func install(remoteCommands: any ListenerRemoteCommands) async {
        installedRemoteCommands = remoteCommands
        await playback?.install(remoteCommands: remoteCommands)
    }

    public func installSystemRemoteCommands() async {
        if installedRemoteCommands is MediaPlayerRemoteCommands { return }
        let remoteCommands = MediaPlayerRemoteCommands()
        installedRemoteCommands = remoteCommands
        await playback?.install(remoteCommands: remoteCommands)
    }

#if DEBUG
    var installedSystemRemoteCommandsForTesting: MediaPlayerRemoteCommands? {
        installedRemoteCommands as? MediaPlayerRemoteCommands
    }
#endif

    private func loadLocal(
        repository: any SyncRepository,
        fallback: String,
        operation: UInt64? = nil
    ) async {
        let state = await repository.state()
        guard operation.map(isCurrent) ?? true else { return }
        let previousAssets = assetByItem
        rebuild(from: state)
        await reconcileCachedAssets(previousAssets)
        guard operation.map(isCurrent) ?? true else { return }
        await restoreMetadata()
        guard operation.map(isCurrent) ?? true else { return }
        await updateDownloadedStates()
        guard operation.map(isCurrent) ?? true else { return }
        if decodeHadErrors { syncPhase = .incompatible("Some listener records are incompatible") }
        else if items.contains(where: { $0.state == .deleted }) { syncPhase = .deleted("An item was deleted remotely") }
        else if items.isEmpty { syncPhase = .offline(fallback) }
        else if items.contains(where: { $0.state == .incompatibleRevision }) {
            syncPhase = .incompatible("A larder item has an incompatible revision")
        } else { syncPhase = .offline(fallback) }
    }

    private func reconcileCachedAssets(_ previousAssets: [ItemID: WiltedAsset]) async {
        guard let cache, !assetByItem.isEmpty || !previousAssets.isEmpty else { return }
        await cache.reconcile(retaining: Array(assetByItem.values))
    }

    private func updateDownloadedStates() async {
        guard let cache else { return }
        var updated: [ListenerLibraryItem] = []
        for item in items {
            guard item.state == .metadataOnly || item.state == .downloaded, let asset = item.asset else {
                updated.append(item)
                continue
            }
            let downloaded = await cache.url(for: asset) != nil
            updated.append(ListenerLibraryItem(itemID: item.itemID, title: item.title, source: item.source,
                                               revisionID: item.revisionID, durationSeconds: item.durationSeconds,
                                               asset: item.asset, state: downloaded ? .downloaded : .metadataOnly))
        }
        items = updated
        await refreshDownloadStatistics()
    }

    private func rebuild(from state: SyncRepositoryState) {
        let codec = WiltedRecordCodec()
        decodeHadErrors = false
        let activePlaybackPresentation: PlaybackState? = if case .playing = playbackPhase {
            selectedPlayback
        } else {
            nil
        }
        let previousItems = Dictionary(uniqueKeysWithValues: items.map { ($0.itemID, $0) })
        var articles: [(Article, WiltedRecordEnvelope)] = []
        var revisions: [ItemID: [RevisionID: (AudioRevision, WiltedAsset?, AudioChunkManifest?)]] = [:]
        revisionByItem = [:]
        assetByItem = [:]
        manifestByItem = [:]
        playbackByItem = [:]
        playbackChangeTagByItem = [:]
        var playbackCandidates: [ItemID: [PlaybackCandidate]] = [:]
        var transcriptRecords: [WiltedRecordID: Transcript] = [:]
        for envelope in state.records {
            switch envelope.id.recordType {
            case .item:
                do { articles.append((try codec.decodeArticleRecord(envelope).value, envelope)) }
                catch { decodeHadErrors = true }
            case .revision:
                do {
                    let decoded = try codec.decodeRevisionRecord(envelope)
                    let legacyAsset: WiltedAsset?
                    if case let .asset(asset) = envelope.fields["audioAsset"] {
                        legacyAsset = asset
                    } else {
                        legacyAsset = nil
                    }
                    let manifest: AudioChunkManifest?
                    if case let .bytes(data) = envelope.fields["audioManifest"] {
                        manifest = try JSONDecoder().decode(AudioChunkManifest.self, from: data)
                    } else {
                        manifest = nil
                    }
                    guard legacyAsset != nil || manifest != nil else { throw ListenerError.metadataCorrupt }
                    let asset = legacyAsset ?? (try? WiltedAsset(
                        assetID: "audio:\(decoded.value.revisionID.rawValue)",
                        contentHash: decoded.value.contentHash
                    ))
                    revisions[decoded.value.itemID, default: [:]][decoded.value.revisionID] =
                        (decoded.value, asset, manifest)
                } catch { decodeHadErrors = true }
            case .revisionChunk:
                // Chunk records are fetched only after a user selects their revision;
                // they are transport rows, never standalone library entries.
                continue
            case .transcript:
                do { transcriptRecords[envelope.id] = try codec.decodeTranscript(envelope) }
                catch { decodeHadErrors = true }
            case .playbackState:
                do {
                    let decoded = try codec.decodePlaybackRecord(envelope)
                    playbackCandidates[decoded.value.itemID, default: []].append(
                        PlaybackCandidate(state: decoded.value, changeTag: envelope.sidecar?.changeTag)
                    )
                }
                catch { decodeHadErrors = true }
            }
        }
        var rebuilt: [ListenerLibraryItem] = []
        for (article, envelope) in articles {
            let revisionID = (try? RevisionID(rawValue: envelope.fields["currentRevisionID"].flatMap { value in
                if case let .string(id) = value { return id }; return nil
            } ?? ""))
            let match: (AudioRevision, WiltedAsset?, AudioChunkManifest?)?
            if let revisionID, let itemRevisions = revisions[article.itemID] {
                match = itemRevisions[revisionID]
            } else {
                match = nil
            }
            if let match {
                revisionByItem[article.itemID] = match.0
                if let asset = match.1 { assetByItem[article.itemID] = asset }
                if let manifest = match.2 { manifestByItem[article.itemID] = manifest }
            }
            let state: ListenerItemState = article.isDeleted ? .deleted : match == nil ? .incompatibleRevision : .metadataOnly
            rebuilt.append(ListenerLibraryItem(itemID: article.itemID, title: article.title, source: article.source,
                                                revisionID: match?.0.revisionID ?? revisionID, durationSeconds: match?.0.durationSeconds,
                                                asset: match?.1, state: state))
            guard !article.isDeleted, let selectedRevisionID = match?.0.revisionID,
                  let selected = latestPlayback(
                      playbackCandidates[article.itemID, default: []].filter {
                          $0.state.revisionID == selectedRevisionID
                      }
                  ) else { continue }
            playbackByItem[article.itemID] = selected.state
            if let changeTag = selected.changeTag {
                playbackChangeTagByItem[article.itemID] = changeTag
            }
        }
        let rebuiltIDs = Set(rebuilt.map(\.itemID))
        rebuilt.append(contentsOf: previousItems.values.filter { !rebuiltIDs.contains($0.itemID) }.map {
            ListenerLibraryItem(itemID: $0.itemID, title: $0.title, source: $0.source,
                                revisionID: $0.revisionID, durationSeconds: $0.durationSeconds,
                                asset: nil, state: .deleted)
        })
        items = rebuilt.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        if let activePlaybackPresentation,
           revisionByItem[activePlaybackPresentation.itemID]?.revisionID == activePlaybackPresentation.revisionID {
            playbackByItem[activePlaybackPresentation.itemID] = activePlaybackPresentation
        }
        transcriptsByItem = Dictionary(uniqueKeysWithValues: rebuilt.compactMap { item in
            guard let revisionID = item.revisionID,
                  let recordID = try? WiltedRecordID.transcript(item.itemID, revisionID),
                  let transcript = transcriptRecords[recordID] else { return nil }
            return (item.itemID, transcript)
        })
        selectedPlayback = selectedItemID.flatMap { playbackByItem[$0] }
    }

    private struct PlaybackCandidate: Equatable, Sendable {
        let state: PlaybackState
        let changeTag: String?
    }

    /// Chooses a unique causally latest candidate. An incomparable set is rejected rather
    /// than resolved by record identity or the order in which records happened to arrive.
    private func latestPlayback(_ candidates: [PlaybackCandidate]) -> PlaybackCandidate? {
        var unique: [PlaybackCandidate] = []
        for candidate in candidates where !unique.contains(candidate) {
            unique.append(candidate)
        }
        guard !unique.isEmpty else { return nil }
        let maximal = unique.filter { candidate in
            !unique.contains { other in
                guard candidate != other else { return false }
                let result = mergePlayback(
                    current: candidate.state,
                    incoming: other.state,
                    changeTagMatches: candidate.changeTag == other.changeTag
                )
                return result.acceptedStateIsIncoming
            }
        }
        guard !maximal.isEmpty else { return nil }
        let ranked = maximal.map { candidate in
            let wins = unique.reduce(into: 0) { count, other in
                guard candidate != other else { return }
                let result = mergePlayback(
                    current: other.state,
                    incoming: candidate.state,
                    changeTagMatches: other.changeTag == candidate.changeTag
                )
                if result.acceptedStateIsIncoming { count += 1 }
            }
            return (candidate, wins)
        }
        let highest = ranked.map { $0.1 }.max() ?? 0
        let winners = ranked.filter { $0.1 == highest }
        guard winners.count == 1 else { return nil }
        return winners[0].0
    }

    private func refreshPresentationFacts() async {
        await refreshDownloadStatistics()
        await refreshSyncObservability()
    }

    private func refreshDownloadStatistics() async {
        guard let cache else {
            downloadStatistics = ListenerDownloadStatistics()
            return
        }
        downloadStatistics = (try? await cache.statistics()) ?? ListenerDownloadStatistics()
    }

    private func refreshSyncObservability() async {
        guard let listenerRepository = repository as? ListenerRepository else {
            syncObservability = ListenerSyncObservability()
            return
        }
        syncObservability = await listenerRepository.loadObservability() ?? ListenerSyncObservability()
    }

    /// Builds the playback state for an item that has never been played.
    ///
    /// `sequence` starts at one because `PlaybackState` rejects anything lower, and a
    /// state that cannot be constructed leaves the item permanently unplayable: `play`
    /// has no other way to begin. A new session restarts the numbering at the same floor.
    private func makeInitialPlayback(for item: ListenerLibraryItem, revision: AudioRevision) -> PlaybackState? {
        try? PlaybackState(itemID: item.itemID, revisionID: revision.revisionID, sessionID: UUID().uuidString,
                           sequence: 1, positionSeconds: 0, durationSeconds: revision.durationSeconds,
                           completed: false, intent: .progress, deviceID: "iphone", updatedAt: Timestamp(Date()))
    }

    private func restoreMetadata() async {
        guard selectedItemID == nil, let metadata = await metadataLoader?(), let recordID = metadata.lastPlayedRecordID else { return }
        for (itemID, state) in playbackByItem {
            if (try? WiltedRecordID.playback(itemID, state.revisionID)) == recordID {
                selectedItemID = itemID
                selectedPlayback = state
                return
            }
        }
    }

    private func explicitPositionChange(intent: PlaybackIntent, position: Double) async {
        guard let itemID = selectedItemID, let item = items.first(where: { $0.itemID == itemID }),
              let revision = revisionByItem[itemID], let asset = assetByItem[itemID], let current = playbackByItem[itemID],
              let playback else { return }
        await positionChange(item: item, asset: asset, playback: playback, current: current,
                             position: position, intent: intent, newSession: true)
        _ = revision
    }

    private func positionChange(item: ListenerLibraryItem, asset: WiltedAsset,
                                playback: ListenerPlaybackController, current: PlaybackState,
                                position: Double, intent: PlaybackIntent, newSession: Bool) async {
        playbackPhase = .refreshing("Preparing offline audio")
        do {
            let updated = try await playback.play(asset: asset, title: item.title,
                                                  state: try nextPlayback(current, position: position,
                                                                           intent: intent, newSession: newSession))
            try await recordPlayback(updated)
            selectedPlayback = updated
            playbackPhase = .playing
        } catch { playbackPhase = .failed("Playback command failed: \(error.localizedDescription)", retryable: true) }
    }

    private func nextPlayback(_ current: PlaybackState, position: Double, intent: PlaybackIntent, newSession: Bool) throws -> PlaybackState {
        try PlaybackState(itemID: current.itemID, revisionID: current.revisionID,
                          sessionID: newSession ? UUID().uuidString : current.sessionID,
                          sequence: newSession ? 1 : current.sequence + 1,
                          positionSeconds: max(0, position), durationSeconds: current.durationSeconds,
                          completed: false, intent: intent, deviceID: current.deviceID,
                          encodedCloudKitRecordSystemFields: current.encodedCloudKitRecordSystemFields,
                          updatedAt: Timestamp(Date()))
    }

    private func recordPlayback(_ state: PlaybackState) async throws {
        // Keep the local playback projection current even when a deliberately
        // account-free composition has no sync repository. Production still
        // enqueues the same durable change immediately below.
        playbackByItem[state.itemID] = state
        guard let repository else { return }
        let sidecar = WiltedOpaqueSidecar(
            changeTag: playbackChangeTagByItem[state.itemID],
            encodedSystemFields: state.encodedCloudKitRecordSystemFields
        )
        let envelope = try WiltedRecordCodec().encode(playback: state, sidecar: sidecar)
        let change = try SyncPendingChange(operation: .update, recordID: envelope.id, record: envelope)
        try await repository.enqueue(change)
        try await metadataSaver?(ListenerMetadata(lastPlayedRecordID: envelope.id, lastPositionSeconds: state.positionSeconds))
    }

    private func scheduleBackgroundCheckpoints(generation: UInt64) {
        let interval = backgroundCheckpointInterval
        let sleeper = backgroundSleeper
        backgroundCheckpointTask = Task { [weak self] in
            while !Task.isCancelled {
                do { try await sleeper(interval) }
                catch { return }
                guard let self, self.isBackgrounded,
                      self.backgroundCheckpointGeneration == generation,
                      !Task.isCancelled else { return }
                guard await self.persistBoundedBackgroundCheckpoint(generation: generation) else {
                    if self.backgroundCheckpointGeneration == generation {
                        self.backgroundCheckpointTask = nil
                    }
                    return
                }
            }
        }
    }

    private func persistBoundedBackgroundCheckpoint(generation: UInt64) async -> Bool {
        guard isBackgrounded, backgroundCheckpointGeneration == generation,
              let playback else { return false }
        do {
            guard let updated = try await playback.liveCheckpoint() else { return false }
            guard isBackgrounded, backgroundCheckpointGeneration == generation,
                  !Task.isCancelled else { return false }
            try await recordPlayback(updated)
            if selectedItemID == updated.itemID { selectedPlayback = updated }
            return true
        } catch {
            playbackPhase = .failed("Background persistence failed: \(error.localizedDescription)", retryable: true)
            return false
        }
    }

    private func persistActivePlaybackCheckpoint() async {
        guard let playback else { return }
        do {
            if let readout = try await playback.liveReadout(),
               let persisted = playbackByItem[readout.itemID],
               persisted.revisionID == readout.revisionID,
               persisted.sessionID == readout.sessionID,
               persisted.positionSeconds == readout.positionSeconds,
               persisted.completed == readout.completed {
                return
            }
            guard let updated = try await playback.liveCheckpoint() else { return }
            try await recordPlayback(updated)
            if selectedItemID == updated.itemID { selectedPlayback = updated }
        } catch {
            playbackPhase = .failed("Background persistence failed: \(error.localizedDescription)", retryable: true)
        }
    }

    private func updateItemState(itemID: ItemID, state: ListenerItemState) {
        guard let index = items.firstIndex(where: { $0.itemID == itemID }) else { return }
        let item = items[index]
        items[index] = ListenerLibraryItem(itemID: item.itemID, title: item.title, source: item.source,
                                           revisionID: item.revisionID, durationSeconds: item.durationSeconds,
                                           asset: item.asset, state: state)
    }

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

    private static func makeLiveSession(root: URL, stateData: Data?, repository: any SyncRepository) async throws -> any ListenerSyncSession {
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

    private func observe(_ stream: AsyncStream<SyncStatus>) {
        statusTasks.append(Task { [weak self] in
            for await event in stream { self?.receive(event) }
        })
    }

    /// Repository events without a generation are local bookkeeping (for example,
    /// durable playback enqueue) and must not replace the independently published
    /// sync result. Fetch stage/commit events retain their generation identifier.
    private func observeRepository(_ stream: AsyncStream<SyncStatus>) {
        statusTasks.append(Task { [weak self] in
            for await event in stream where event.generationID != nil {
                self?.receive(event)
            }
        })
    }

    private func observePlayback(_ stream: AsyncStream<SyncStatus>) {
        statusTasks.append(Task {
            for await _ in stream {}
        })
    }

    private func observePlaybackCheckpoints(_ stream: AsyncStream<PlaybackState>) {
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

    private func observeRemoteCommandResults(_ stream: AsyncStream<ListenerRemoteCommandResult>) {
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

    private func observeSession(_ stream: AsyncStream<ListenerAccountChange>) {
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
        case .failed: syncPhase = .failed(event.message, retryable: true)
        case .completed: if !operationInFlight { syncPhase = .ready }
        case .idle: break
        }
    }
}
