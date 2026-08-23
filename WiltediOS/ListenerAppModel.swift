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
        case .ready: "Library ready"
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

/// Main-actor presentation model for the iPhone listener.
///
/// The default initializer has no transport and therefore cannot construct or
/// contact CloudKit. A live transport and asset loader are supplied explicitly
/// by the attended live build composition.
@MainActor
public final class WiltedListenerAppModel: ObservableObject {
    @Published public private(set) var items: [ListenerLibraryItem] = []
    @Published public private(set) var status: ListenerAppStatus = .idle
    @Published public private(set) var selectedItemID: ItemID?
    @Published public private(set) var selectedPlayback: PlaybackState?

    private let repository: (any SyncRepository)?
    private var transport: (any SyncTransport)?
    private let cache: ListenerAudioCache?
    private let playback: ListenerPlaybackController?
    private var assetLoader: ListenerAssetLoader?
    private var audioChunkLoader: ListenerAudioChunkLoader?
    private let sessionFactory: ListenerSyncSessionFactory?
    private var session: (any ListenerSyncSession)?
    private var accountQuarantined = false
    private let metadataLoader: (@Sendable () async -> ListenerMetadata?)?
    private let metadataSaver: (@Sendable (ListenerMetadata?) async throws -> Void)?
    private var playbackByItem: [ItemID: PlaybackState] = [:]
    private var revisionByItem: [ItemID: AudioRevision] = [:]
    private var assetByItem: [ItemID: WiltedAsset] = [:]
    private var manifestByItem: [ItemID: AudioChunkManifest] = [:]
    private var operationInFlight = false
    /// Invalidates every suspended model operation when cancellation permits a retry.
    /// A Boolean alone cannot distinguish the cancelled operation from its successor.
    private var operationGeneration: UInt64 = 0
    private var didStart = false
    private var cancellationRequested = false
    private var statusTasks: [Task<Void, Never>] = []
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
        if let unavailableMessage { status = .failed(unavailableMessage, retryable: false) }
        if let repository { observe(repository.statuses) }
        if let transport { observe(transport.statuses) }
        if let cache { observe(cache.statuses) }
        // Playback commands set their final presentation state directly. Their status stream
        // is still consumed, but never used to overwrite those command results later.
        if let playback { observePlayback(playback.statuses) }
    }

    public static func makeDefault() -> WiltedListenerAppModel {
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Wilted", isDirectory: true)
        do {
            let repository = try ListenerRepository(directoryURL: root)
            let cache = try ListenerAudioCache(rootURL: root.appendingPathComponent("Audio", isDirectory: true))
            let playback = ListenerPlaybackController(cache: cache, engine: AVFoundationAudioEngine())
#if WILTED_CLOUDKIT_LIVE
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
#else
            return WiltedListenerAppModel(
                repository: repository,
                cache: cache,
                playback: playback,
                metadataLoader: { await repository.loadMetadata() },
                metadataSaver: { metadata in try await repository.saveMetadata(metadata) }
            )
#endif
        } catch {
            return WiltedListenerAppModel(unavailableMessage: "Local library unavailable: \(error.localizedDescription)")
        }
    }

    /// Deterministic shipping-view data for iOS pixel tests. This intentionally
    /// has no repository, transport, cache, or audio engine, so capturing the
    /// listener Library cannot touch an account or device media state.
    public static func makePixelFixture(
        state: ListenerPixelFixtureState = .library
    ) -> WiltedListenerAppModel {
        let model = WiltedListenerAppModel()
        guard let itemID = try? ItemID.derive(from: URL(string: "https://example.test/wilted-listener")!) else {
            return model
        }
        model.items = [
            ListenerLibraryItem(
                itemID: itemID,
                title: "A fixture article for listening",
                source: "Wilted Test Journal",
                revisionID: nil,
                durationSeconds: 120,
                asset: nil,
                state: .downloaded
            )
        ]
        switch state {
        case .library:
            model.status = .ready
        case .nowPlaying:
            guard let revisionID = try? RevisionID(rawValue: "revision-pixel-fixture"),
                  let playback = try? PlaybackState(
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
            model.status = .playing
            model.selectedPlayback = playback
        case .terminalFailure:
            model.status = .failed("iCloud account changed; sync is quarantined", retryable: false)
        }
        return model
    }

    /// Performs the initial metadata discovery once for the app lifetime.
    /// Foreground transitions use `resumeForeground()` so returning from the
    /// background still picks up producer changes without duplicate launch fetches.
    public func start() async {
        guard !didStart else { return }
        didStart = true
        await refresh()
    }

    public func refresh() async {
        guard let operation = beginOperation() else { return }
        defer { finishOperation(operation) }
        status = .refreshing("Refreshing library…")
        guard let repository else {
            status = .failed("Local library unavailable", retryable: false)
            return
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
                observe(createdSession.accountChanges)
            } catch {
                guard isCurrent(operation) else { return }
                status = .failed("Sync unavailable: \(error.localizedDescription)", retryable: true)
                return
            }
        }

        guard !accountQuarantined else {
            status = .failed("iCloud account changed; sync is quarantined", retryable: false)
            return
        }

        if let transport {
            do {
                let batch = try await transport.fetchChanges()
                guard isCurrent(operation) else { return }
                let staged = try await repository.stage(batch)
                guard isCurrent(operation) else { return }
                try await repository.commit(staged)
                guard isCurrent(operation) else { return }
                let state = await repository.state()
                guard isCurrent(operation) else { return }
                let previousAssets = assetByItem
                // Remote metadata is fetched first; audio is an explicit per-item download.
                rebuild(from: state)
                await removeOrphanedAssets(previousAssets)
                await restoreMetadata()
                await updateDownloadedStates()
                status = decodeHadErrors
                    ? .incompatible("Some listener records are incompatible")
                    : items.contains(where: { $0.state == .deleted })
                    ? .deleted("An item was deleted remotely")
                    : items.contains(where: { $0.state == .incompatibleRevision })
                    ? .incompatible("A library item has an incompatible revision") : .ready
                return
            } catch {
                guard isCurrent(operation) else { return }
                await loadLocal(repository: repository, fallback: error.localizedDescription)
                guard isCurrent(operation) else { return }
                if case .offline = status {
                    status = .failed("Refresh failed: \(error.localizedDescription)", retryable: true)
                }
                return
            }
        }

        await loadLocal(repository: repository, fallback: "Offline mode")
    }

    public func sendPending() async {
        guard let repository, let transport else {
            status = .offline("Offline: changes will send when connected")
            return
        }
        guard !accountQuarantined else {
            status = .failed("iCloud account changed; sync is quarantined", retryable: false)
            return
        }
        guard let operation = beginOperation() else { return }
        defer { finishOperation(operation) }
        status = .sending("Sending playback progress…")
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
                    status = .ready
                } else {
                    let subject = held.count == 1 ? "1 playback update is" : "\(held.count) playback updates are"
                    status = .failed("Nothing was sent. \(subject) held by unresolved conflicts.", retryable: true)
                }
                return
            }
            let result = try await transport.save(changes: sendableChanges, role: .iphone)
            guard isCurrent(operation) else { return }
            try await repository.acknowledge(result)
            guard isCurrent(operation) else { return }
            rebuild(from: await repository.state())
            guard isCurrent(operation) else { return }
            status = result.failures.isEmpty ? .ready : .failed("Some playback changes need retry", retryable: true)
        } catch {
            guard isCurrent(operation) else { return }
            status = .failed("Send failed: \(error.localizedDescription)", retryable: true)
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
        status = .refreshing("Downloading \(item.title)…")
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
            status = .ready
        } catch {
            guard isCurrent(operation) else { return }
            status = .failed("Download failed: \(error.localizedDescription)", retryable: true)
        }
    }

    public func removeDownload(itemID: ItemID) async {
        guard !operationInFlight, let cache, let asset = assetByItem[itemID],
              let index = items.firstIndex(where: { $0.itemID == itemID }) else { return }
        operationInFlight = true
        defer { operationInFlight = false }
        if selectedItemID == itemID { await pause() }
        try? await cache.remove(asset)
        let item = items[index]
        items[index] = ListenerLibraryItem(itemID: item.itemID, title: item.title, source: item.source,
                                           revisionID: item.revisionID, durationSeconds: item.durationSeconds,
                                           asset: item.asset, state: .metadataOnly)
        status = .ready
    }

    public func play(itemID: ItemID) async {
        guard let item = items.first(where: { $0.itemID == itemID }) else { return }
        guard item.state == .downloaded, let revision = revisionByItem[itemID], let asset = assetByItem[itemID], let playback else {
            status = item.state == .incompatibleRevision
                ? .incompatible("This item cannot play with its current revision")
                : .offline("Audio is not cached for offline playback")
            return
        }
        let state: PlaybackState
        if let existing = playbackByItem[itemID] {
            state = existing
        } else if let initial = makeInitialPlayback(for: item, revision: revision) {
            state = initial
        } else {
            status = .failed("Playback state could not be created", retryable: false)
            return
        }
        status = .refreshing("Preparing offline audio")
        do {
            let updated = try await playback.play(asset: asset, title: item.title, state: state)
            try await recordPlayback(updated)
            selectedItemID = itemID
            selectedPlayback = updated
            status = .playing
        } catch {
            status = .failed("Playback failed: \(error.localizedDescription)", retryable: true)
        }
    }

    public func pause() async {
        guard let playback else { return }
        do {
            if let updated = try await playback.pause() {
                try await recordPlayback(updated)
                selectedPlayback = updated
            }
            status = .paused
        } catch { status = .failed("Pause failed: \(error.localizedDescription)", retryable: true) }
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
        guard let playback else {
            await persistSelectedMetadata()
            return
        }
        do {
            if let updated = try await playback.enterBackground() {
                try await recordPlayback(updated)
                selectedPlayback = updated
            } else {
                await persistSelectedMetadata()
            }
        } catch {
            status = .failed("Background persistence failed: \(error.localizedDescription)", retryable: true)
        }
    }

    /// Refreshes the displayed position from the active engine without queuing a sync write.
    public func refreshNowPlayingReadout() async {
        guard case .playing = status, let playback else { return }
        do {
            guard let readout = try await playback.liveReadout() else { return }
            playbackByItem[readout.itemID] = readout
            selectedPlayback = readout
        } catch {
            status = .failed("Playback readout failed: \(error.localizedDescription)", retryable: true)
        }
    }

    public func resumeForeground() async {
        // Scene activation can race the view's initial task. Treat the first
        // foreground as launch so that pair produces one catalog fetch.
        if !didStart { await start() } else { await refresh() }
    }

    public func cancel() {
        invalidateCurrentOperation()
        status = .idle
        Task { await session?.cancel() }
    }

    private func invalidateCurrentOperation() {
        cancellationRequested = true
        operationGeneration &+= 1
        operationInFlight = false
    }

    private func beginOperation() -> UInt64? {
        guard !operationInFlight else { return nil }
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
        operationInFlight = false
    }

    public func resetAfterAccountChange() async {
        guard let session else { return }
        await session.resetAfterAccountChange()
        accountQuarantined = false
        status = .ready
    }

#if DEBUG
    /// Installs deterministic catalog state for the account-free UI fixture.
    /// This is internal to the app target so the production composition cannot
    /// accidentally use fixture data.
    func installMVPFixture(item: ListenerLibraryItem, revision: AudioRevision, asset: WiltedAsset) {
        items = [item]
        revisionByItem = [item.itemID: revision]
        assetByItem = [item.itemID: asset]
        manifestByItem = [:]
        playbackByItem = [:]
        status = .ready
    }

    /// Drives the recovery state exposed only by the account-free UI fixture.
    func quarantineForMVPFixture() {
        accountQuarantined = true
        invalidateCurrentOperation()
        status = .failed("iCloud account switch detected; sync is quarantined", retryable: false)
    }

    /// Recovers the account-free UI fixture after its simulated quarantine.
    func recoverMVPFixture() async {
        guard session == nil, accountQuarantined else { return }
        accountQuarantined = false
        await updateDownloadedStates()
        status = .ready
    }
#endif

    public func install(remoteCommands: any ListenerRemoteCommands) async {
        await playback?.install(remoteCommands: remoteCommands)
    }

    private func loadLocal(repository: any SyncRepository, fallback: String) async {
        let state = await repository.state()
        let previousAssets = assetByItem
        rebuild(from: state)
        await removeOrphanedAssets(previousAssets)
        await restoreMetadata()
        await updateDownloadedStates()
        if decodeHadErrors { status = .incompatible("Some listener records are incompatible") }
        else if items.contains(where: { $0.state == .deleted }) { status = .deleted("An item was deleted remotely") }
        else if items.isEmpty { status = .offline(fallback) }
        else if items.contains(where: { $0.state == .incompatibleRevision }) {
            status = .incompatible("A library item has an incompatible revision")
        } else { status = .offline(fallback) }
    }

    private func removeOrphanedAssets(_ previous: [ItemID: WiltedAsset]) async {
        guard let cache else { return }
        let currentIDs = Set(assetByItem.keys)
        for (itemID, asset) in previous where !currentIDs.contains(itemID) {
            try? await cache.remove(asset)
        }
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
    }

    private func rebuild(from state: SyncRepositoryState) {
        let codec = WiltedRecordCodec()
        decodeHadErrors = false
        let previousItems = Dictionary(uniqueKeysWithValues: items.map { ($0.itemID, $0) })
        var articles: [(Article, WiltedRecordEnvelope)] = []
        var revisions: [ItemID: (AudioRevision, WiltedAsset?, AudioChunkManifest?)] = [:]
        revisionByItem = [:]
        assetByItem = [:]
        manifestByItem = [:]
        playbackByItem = [:]
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
                    revisions[decoded.value.itemID] = (decoded.value, asset, manifest)
                    revisionByItem[decoded.value.itemID] = decoded.value
                    if let asset { assetByItem[decoded.value.itemID] = asset }
                    if let manifest { manifestByItem[decoded.value.itemID] = manifest }
                } catch { decodeHadErrors = true }
            case .revisionChunk:
                // Chunk records are fetched only after a user selects their revision;
                // they are transport rows, never standalone library entries.
                continue
            case .playbackState:
                do { let decoded = try codec.decodePlayback(envelope); playbackByItem[decoded.itemID] = decoded }
                catch { decodeHadErrors = true }
            }
        }
        var rebuilt = articles.map { article, envelope in
            let revisionID = (try? RevisionID(rawValue: envelope.fields["currentRevisionID"].flatMap { value in
                if case let .string(id) = value { return id }; return nil
            } ?? ""))
            let match = revisionID.flatMap { revisions[article.itemID]?.0.revisionID == $0 ? revisions[article.itemID] : nil }
            let state: ListenerItemState = article.isDeleted ? .deleted : match == nil ? .incompatibleRevision : .metadataOnly
            return ListenerLibraryItem(itemID: article.itemID, title: article.title, source: article.source,
                                       revisionID: match?.0.revisionID ?? revisionID, durationSeconds: match?.0.durationSeconds,
                                       asset: match?.1, state: state)
        }
        let rebuiltIDs = Set(rebuilt.map(\.itemID))
        rebuilt.append(contentsOf: previousItems.values.filter { !rebuiltIDs.contains($0.itemID) }.map {
            ListenerLibraryItem(itemID: $0.itemID, title: $0.title, source: $0.source,
                                revisionID: $0.revisionID, durationSeconds: $0.durationSeconds,
                                asset: nil, state: .deleted)
        })
        items = rebuilt.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        selectedPlayback = selectedItemID.flatMap { playbackByItem[$0] }
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
        status = .refreshing("Preparing offline audio")
        do {
            let updated = try await playback.play(asset: asset, title: item.title,
                                                  state: try nextPlayback(current, position: position,
                                                                           intent: intent, newSession: newSession))
            try await recordPlayback(updated)
            selectedPlayback = updated
            status = .playing
        } catch { status = .failed("Playback command failed: \(error.localizedDescription)", retryable: true) }
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
        let envelope = try WiltedRecordCodec().encode(playback: state)
        let change = try SyncPendingChange(operation: .update, recordID: envelope.id, record: envelope)
        try await repository.enqueue(change)
        try await metadataSaver?(ListenerMetadata(lastPlayedRecordID: envelope.id, lastPositionSeconds: state.positionSeconds))
    }

    private func persistSelectedMetadata() async {
        guard let state = selectedPlayback, let envelope = try? WiltedRecordCodec().encode(playback: state) else { return }
        try? await metadataSaver?(ListenerMetadata(lastPlayedRecordID: envelope.id, lastPositionSeconds: state.positionSeconds))
    }

    private func updateItemState(itemID: ItemID, state: ListenerItemState) {
        guard let index = items.firstIndex(where: { $0.itemID == itemID }) else { return }
        let item = items[index]
        items[index] = ListenerLibraryItem(itemID: item.itemID, title: item.title, source: item.source,
                                           revisionID: item.revisionID, durationSeconds: item.durationSeconds,
                                           asset: item.asset, state: state)
    }

#if WILTED_CLOUDKIT_LIVE
    private static func makeLiveSession(root: URL, stateData: Data?, repository: any SyncRepository) async throws -> any ListenerSyncSession {
        let stager = try FileCloudKitAssetStager(rootURL: root.appendingPathComponent("CloudAssets", isDirectory: true))
        let mapper = try CloudKitRecordMapper(stager: stager)
        let stateSerialization = try stateData.map { try JSONDecoder().decode(CKSyncEngine.State.Serialization.self, from: $0) }
        let container = CKContainer(identifier: "iCloud.com.zerodelta.wilted")
        let driver = LiveCloudKitEngineDriver(
            database: container.privateCloudDatabase,
            stateSerialization: stateSerialization,
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
        let transport = try CloudKitSyncTransport(driver: driver, role: .iphone, mapper: mapper,
                                                  stateData: stateData,
                                                  pendingChanges: repositoryState.pendingChanges,
                                                  knownOwnerToken: repositoryState.accountOwnerToken)
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
            self.assetLoader = { recordID, asset in
                if let url = await transport.assetHandoff()[recordID]?.first?.value { return url }
                if let url = mapper.resolvedAssetURL(for: asset) { return url }
                throw ListenerError.cacheUnavailable(asset.assetID)
            }
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

    private func observePlayback(_ stream: AsyncStream<SyncStatus>) {
        statusTasks.append(Task {
            for await _ in stream {}
        })
    }

    private func observe(_ stream: AsyncStream<ListenerAccountChange>) {
        statusTasks.append(Task { [weak self] in
            for await event in stream {
                guard let self else { return }
                switch event {
                case let .quarantined(type):
                    accountQuarantined = true
                    invalidateCurrentOperation()
                    status = .failed("\(type.userFacingName) detected; sync is quarantined", retryable: false)
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
        })
    }

    private func receive(_ event: SyncStatus) {
        switch event.phase {
        case .fetching, .staging: status = .refreshing(event.message)
        case .committing: status = .sending(event.message)
        case .failed: status = .failed(event.message, retryable: true)
        case .completed: if !operationInFlight { status = .ready }
        case .idle: break
        }
    }
}
