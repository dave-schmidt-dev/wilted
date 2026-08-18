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

    /// Compatibility spelling for callers that do not need the transition type.
    public static var quarantined: Self { .quarantined(.switchAccounts) }
}

public protocol ListenerSyncSession: Sendable {
    var transport: any SyncTransport { get }
    var assetLoader: ListenerAssetLoader { get }
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
    private let sessionFactory: ListenerSyncSessionFactory?
    private var session: (any ListenerSyncSession)?
    private var accountQuarantined = false
    private let metadataLoader: (@Sendable () async -> ListenerMetadata?)?
    private let metadataSaver: (@Sendable (ListenerMetadata?) async throws -> Void)?
    private var playbackByItem: [ItemID: PlaybackState] = [:]
    private var revisionByItem: [ItemID: AudioRevision] = [:]
    private var assetByItem: [ItemID: WiltedAsset] = [:]
    private var operationInFlight = false
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
        self.metadataLoader = metadataLoader
        self.metadataSaver = metadataSaver
        if let unavailableMessage { status = .failed(unavailableMessage, retryable: false) }
        if let repository { observe(repository.statuses) }
        if let transport { observe(transport.statuses) }
        if let cache { observe(cache.statuses) }
        if let playback { observe(playback.statuses) }
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

    public func refresh() async {
        guard !operationInFlight else { return }
        operationInFlight = true
        cancellationRequested = false
        defer { operationInFlight = false }
        status = .refreshing("Refreshing library…")
        guard let repository else {
            status = .failed("Local library unavailable", retryable: false)
            return
        }

        if transport == nil, let sessionFactory {
            do {
                let state = await repository.state()
                session = try await sessionFactory(state.engineState)
                transport = session?.transport
                assetLoader = session?.assetLoader
                if let session { observe(session.accountChanges) }
            } catch {
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
                let staged = try await repository.stage(batch)
                guard !cancellationRequested else { status = .idle; return }
                try await repository.commit(staged)
                let state = await repository.state()
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
                await loadLocal(repository: repository, fallback: error.localizedDescription)
                if case .offline = status {
                    status = .failed("Refresh failed: \(error.localizedDescription)", retryable: true)
                }
                return
            }
        }

        await loadLocal(repository: repository, fallback: "Offline mode")
    }

    public func sendPending() async {
        guard !operationInFlight else { return }
        guard let repository, let transport else {
            status = .offline("Offline: changes will send when connected")
            return
        }
        guard !accountQuarantined else {
            status = .failed("iCloud account changed; sync is quarantined", retryable: false)
            return
        }
        operationInFlight = true
        cancellationRequested = false
        defer { operationInFlight = false }
        status = .sending("Sending playback progress…")
        do {
            let state = await repository.state()
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
                status = .ready
                return
            }
            let result = try await transport.save(changes: sendableChanges, role: .iphone)
            guard !cancellationRequested else { status = .idle; return }
            try await repository.acknowledge(result)
            rebuild(from: await repository.state())
            status = result.failures.isEmpty ? .ready : .failed("Some playback changes need retry", retryable: true)
        } catch {
            status = .failed("Send failed: \(error.localizedDescription)", retryable: true)
        }
    }

    public func download(itemID: ItemID) async {
        guard !operationInFlight, let cache, let assetLoader,
              let item = items.first(where: { $0.itemID == itemID }),
              let revision = revisionByItem[itemID], let asset = assetByItem[itemID] else { return }
        guard item.state == .metadataOnly else { return }
        operationInFlight = true
        cancellationRequested = false
        defer { operationInFlight = false }
        status = .refreshing("Downloading \(item.title)…")
        do {
            let recordID = try WiltedRecordID.revision(itemID, revision.revisionID)
            let sourceURL = try await assetLoader(recordID, asset)
            _ = try await cache.store(fileURL: sourceURL, asset: asset)
            updateItemState(itemID: itemID, state: .downloaded)
            status = .ready
        } catch {
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
        await playback?.enterBackground()
        await persistSelectedMetadata()
    }

    public func resumeForeground() async { await refresh() }

    public func cancel() {
        cancellationRequested = true
        operationInFlight = false
        status = .idle
        Task { await session?.cancel() }
    }

    public func resetAfterAccountChange() async {
        guard let session else { return }
        await session.resetAfterAccountChange()
        accountQuarantined = false
        status = .ready
    }

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
        var revisions: [ItemID: (AudioRevision, WiltedAsset)] = [:]
        revisionByItem = [:]
        assetByItem = [:]
        playbackByItem = [:]
        for envelope in state.records {
            switch envelope.id.recordType {
            case .item:
                do { articles.append((try codec.decodeArticleRecord(envelope).value, envelope)) }
                catch { decodeHadErrors = true }
            case .revision:
                do {
                    let decoded = try codec.decodeRevisionRecord(envelope)
                    guard case let .asset(asset) = envelope.fields["audioAsset"] else { throw ListenerError.metadataCorrupt }
                    revisions[decoded.value.itemID] = (decoded.value, asset)
                    revisionByItem[decoded.value.itemID] = decoded.value
                    assetByItem[decoded.value.itemID] = asset
                } catch { decodeHadErrors = true }
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

    private func makeInitialPlayback(for item: ListenerLibraryItem, revision: AudioRevision) -> PlaybackState? {
        try? PlaybackState(itemID: item.itemID, revisionID: revision.revisionID, sessionID: UUID().uuidString,
                           sequence: 0, positionSeconds: 0, durationSeconds: revision.durationSeconds,
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
                          sequence: newSession ? 0 : current.sequence + 1,
                          positionSeconds: max(0, position), durationSeconds: current.durationSeconds,
                          completed: false, intent: intent, deviceID: current.deviceID,
                          encodedCloudKitRecordSystemFields: current.encodedCloudKitRecordSystemFields,
                          updatedAt: Timestamp(Date()))
    }

    private func recordPlayback(_ state: PlaybackState) async throws {
        guard let repository else { return }
        let envelope = try WiltedRecordCodec().encode(playback: state)
        let change = try SyncPendingChange(operation: .update, recordID: envelope.id, record: envelope)
        try await repository.enqueue(change)
        playbackByItem[state.itemID] = state
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
        let transport = try CloudKitSyncTransport(driver: driver, role: .iphone, mapper: mapper,
                                                  stateData: stateData,
                                                  pendingChanges: await repository.state().pendingChanges)
        return LiveListenerSyncSession(transport: transport, mapper: mapper)
    }

    private actor LiveListenerSyncSession: ListenerSyncSession {
        nonisolated let transport: any SyncTransport
        nonisolated let assetLoader: ListenerAssetLoader
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
            let (stream, continuation) = AsyncStream<ListenerAccountChange>.makeStream()
            self.accountChanges = stream
            self.accountContinuation = continuation
            Task {
                for await signal in transport.accountChanges {
                    let type: ListenerAccountChangeType = switch signal.changeType {
                    case .signIn: .signIn
                    case .signOut: .signOut
                    case .switchAccounts: .switchAccounts
                    }
                    continuation.yield(.quarantined(type))
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

    private func observe(_ stream: AsyncStream<ListenerAccountChange>) {
        statusTasks.append(Task { [weak self] in
            for await event in stream {
                guard let self else { return }
                if case let .quarantined(type) = event {
                    accountQuarantined = true
                    status = .failed("\(type.userFacingName) detected; sync is quarantined", retryable: false)
                    if let repository = repository as? ListenerRepository {
                        try? await repository.quarantineAfterAccountChange()
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
