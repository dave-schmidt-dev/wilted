import Foundation
import SwiftUI
import WiltedDomain
import WiltedListener
import WiltedSync

#if WILTED_CLOUDKIT_LIVE
import CloudKit
import WiltedCloudKit
#endif

@MainActor
public final class WiltedListenerAppModel: ObservableObject {
    /// Active background playback is durably checkpointed at this bounded cadence.
    /// The one-second UI readout remains memory-only.
    public static let durableBackgroundCheckpointInterval: Duration = .seconds(15)

    @Published public internal(set) var items: [ListenerLibraryItem] = []
    @Published public internal(set) var syncPhase: ListenerAppStatus = .idle
    @Published public internal(set) var playbackPhase: ListenerAppStatus = .paused
    @Published public internal(set) var selectedItemID: ItemID?
    @Published public internal(set) var selectedPlayback: PlaybackState?
    @Published public internal(set) var transcriptsByItem: [ItemID: Transcript] = [:]
    @Published public internal(set) var downloadStatistics = ListenerDownloadStatistics()
    @Published public internal(set) var syncObservability = ListenerSyncObservability()
    /// The listener never owns or merges the producer's device-local ledger.
    public let lifetimeStatisticsUnavailableReason = WiltedScreenCopy.lifetimeStatisticsUnavailableReason
    /// The item whose download currently owns the shared operation slot.
    @Published public internal(set) var downloadingItemID: ItemID?
    /// Short-lived feedback for a duplicate download request that arrives before its button disables.
    @Published public internal(set) var downloadRequestFeedback: String?

    let repository: (any SyncRepository)?
    var transport: (any SyncTransport)?
    let cache: ListenerAudioCache?
    let playback: ListenerPlaybackController?
    var installedRemoteCommands: (any ListenerRemoteCommands)?
    var assetLoader: ListenerAssetLoader?
    var audioChunkLoader: ListenerAudioChunkLoader?
    let sessionFactory: ListenerSyncSessionFactory?
    var session: (any ListenerSyncSession)?
    /// A transport that observed state which did not commit locally cannot be
    /// reused: CKSyncEngine serialization is process-local until promoted.
    var rebuildSessionBeforeNextTransportOperation = false
    /// Published so the listener can offer account review the way the producer
    /// does. While this was private the quarantined status was non-retryable
    /// and no control was drawn, which left the shipping listener with no way
    /// out of quarantine at all.
    @Published public internal(set) var accountQuarantined = false
    let metadataLoader: (@Sendable () async -> ListenerMetadata?)?
    let metadataSaver: (@Sendable (ListenerMetadata?) async throws -> Void)?
    var playbackByItem: [ItemID: PlaybackState] = [:]
    var playbackChangeTagByItem: [ItemID: String] = [:]
    var revisionByItem: [ItemID: AudioRevision] = [:]
    var assetByItem: [ItemID: WiltedAsset] = [:]
    var manifestByItem: [ItemID: AudioChunkManifest] = [:]
    enum SyncRetryOperation {
        case refresh
        case send
        case download(ItemID)
    }
    enum PlaybackRetryOperation {
        case play(ItemID)
        case pause
        case seek(Double)
    }
    var syncRetryOperation: SyncRetryOperation?
    var playbackRetryOperation: PlaybackRetryOperation?
    var operationInFlight = false
    var operationHandoffReserved = false
    var operationWaiters: [CheckedContinuation<Void, Never>] = []
    /// Invalidates every suspended model operation when cancellation permits a retry.
    /// A Boolean alone cannot distinguish the cancelled operation from its successor.
    var operationGeneration: UInt64 = 0
    var didStart = false
    var cancellationRequested = false
    var statusTasks: [Task<Void, Never>] = []
    var sessionStatusTask: Task<Void, Never>?
    var backgroundCheckpointTask: Task<Void, Never>?
    var isBackgrounded = false
    var backgroundCheckpointGeneration: UInt64 = 0
    let backgroundCheckpointInterval: Duration
    let backgroundSleeper: @Sendable (Duration) async throws -> Void
    var decodeHadErrors = false

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

}
