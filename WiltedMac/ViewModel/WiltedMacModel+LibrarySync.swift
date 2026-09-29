import Foundation
import Observation
import ObjectiveC
import OSLog
import WiltedCloudKit
import WiltedCloudKitLibrary
import WiltedDomain
import WiltedLibrary
#if WILTED_CLOUDKIT_LIVE
import CloudKit
#endif

#if canImport(WiltedProducer)
import WiltedProducer

private let librarySyncLog = Logger(subsystem: "com.zerodelta.wilted", category: "MacLibrarySync")

// MARK: - State source

/// What the model knows about playback that the store does not: the episode loaded in the
/// player, where it is, and whether it is playing.
struct WiltedMacPlaybackSample: Sendable, Equatable {
    var episodeID: ItemID
    var positionSeconds: Double
    var rate: Double
    var isPlaying: Bool
}

/// `LibraryStateSource` over `LocalLibraryStore`, through the existing one-read library
/// snapshot. It only reads: the producer store stays the single writer (W-INV-005).
struct WiltedMacLocalLibraryStateSource: LibraryStateSource {
    static let summaryLimit = 2_000

    let store: LocalLibraryStore
    let deviceID: String
    /// Main-actor playback readout; nil when nothing podcast is loaded.
    let playback: @Sendable () async -> WiltedMacPlaybackSample?

    func currentState() async throws -> LibraryStateSnapshot {
        let snapshot = try await store.podcastLibrarySnapshot()
        let queue = try await store.podcastQueueState()
        return try Self.state(from: snapshot, queue: queue.episodeIDs, playback: await playback(), deviceID: deviceID)
    }

    static func state(
        from snapshot: LocalLibraryStore.PodcastLibrarySnapshot, queue: [ItemID],
        playback: WiltedMacPlaybackSample?, deviceID: String
    ) throws -> LibraryStateSnapshot {
        let feeds = snapshot.feeds.values.sorted { $0.itemID.rawValue < $1.itemID.rawValue }.map { feed in
            LibrarySource(
                id: feed.itemID, kind: .podcastFeed, title: feed.title,
                locator: feed.canonicalURL.absoluteString, artworkRef: feed.artworkURL?.absoluteString
            )
        }
        var episodes: [LibraryEntry] = []
        for episode in snapshot.episodes {
            let feed = snapshot.feeds[episode.feedID]
            episodes.append(try LibraryEntry.podcastEpisode(
                id: episode.itemID, sourceID: episode.feedID, title: episode.title,
                summary: String((episode.notes ?? "").prefix(summaryLimit)),
                publishedAt: (episode.publishedTime ?? episode.createdAt).date,
                durationSeconds: episode.durationSeconds,
                artworkRef: (episode.artworkURL ?? feed?.artworkURL)?.absoluteString,
                removal: removal(of: episode.itemID, in: snapshot),
                removedAt: snapshot.retiredAtByEpisode[episode.itemID]?.date,
                payload: PodcastEpisodePayload(
                    enclosureURL: episode.enclosureURL, feedURL: episode.feedURL, rssGUID: episode.rssGUID
                )
            ))
        }
        let active = Set(episodes.filter { $0.removal == .none }.map(\.id))
        let known = Set(episodes.map(\.id))
        let listening = snapshot.listeningStates.values.filter { known.contains($0.episodeID) }
            .sorted { $0.episodeID.rawValue < $1.episodeID.rawValue }
            .map { ListeningRecord(itemID: $0.episodeID, completedAt: $0.completedAt?.date, updatedAt: $0.updatedAt.date, deviceID: deviceID) }
        return LibraryStateSnapshot(
            feeds: feeds, episodes: episodes, queue: queue.filter(active.contains), listening: listening,
            currentPlayback: try position(of: playback, in: snapshot, known: known, deviceID: deviceID)
        )
    }

    private static func removal(of id: ItemID, in snapshot: LocalLibraryStore.PodcastLibrarySnapshot) -> LibraryRemoval {
        guard snapshot.retiredAtByEpisode[id] != nil else { return .none }
        return snapshot.removalKindByEpisode[id] == .dismissed ? .dismissed : .retired
    }

    /// Needs a revision to name; an episode with no prepared audio has none to publish.
    private static func position(
        of sample: WiltedMacPlaybackSample?, in snapshot: LocalLibraryStore.PodcastLibrarySnapshot,
        known: Set<ItemID>, deviceID: String
    ) throws -> DevicePlaybackPosition? {
        guard let sample, known.contains(sample.episodeID),
              let revision = snapshot.readyRevisions[sample.episodeID]?.revisionID
                ?? snapshot.listeningStates[sample.episodeID]?.lastRevisionID else { return nil }
        return try DevicePlaybackPosition(
            deviceID: deviceID, entryID: sample.episodeID, revision: revision,
            positionSeconds: max(0, sample.positionSeconds), rate: sample.rate > 0 ? sample.rate : 1,
            isPlaying: sample.isPlaying, epoch: 0
        )
    }
}

// MARK: - Inbound intents

/// Receives follower intents. Phase 2 has no consumer for `requestMedia`, so each one is
/// recorded and logged and nothing is written; a producer-service consumer plugs in through
/// `consumer` without the model or any view writing producer state (W-INV-005).
actor WiltedMacLibraryIntentSink: LibraryIntentSink {
    typealias Consumer = @Sendable (LibraryIntent) async throws -> Void

    private let consumer: Consumer?
    private var seen = Set<String>()
    private(set) var recorded: [LibraryIntent] = []

    init(consumer: Consumer? = nil) { self.consumer = consumer }

    func receive(_ intent: LibraryIntent) async throws {
        guard seen.insert(intent.id).inserted else { return }
        switch intent.action {
        case let .requestMedia(entryID):
            recorded.append(intent)
            guard let consumer else {
                librarySyncLog.notice("requestMedia for \(entryID.rawValue, privacy: .public) recorded; no Phase 2 consumer, no-op")
                return
            }
            do { try await consumer(intent) } catch {
                seen.remove(intent.id)
                recorded.removeAll { $0.id == intent.id }
                throw error
            }
        }
    }
}

// MARK: - Transport

/// Stands in when this build or process may not reach CloudKit. Every operation fails, so a
/// unit-test host or a non-live build never touches an iCloud account.
struct WiltedMacUnavailableLibraryTransport: LibraryTransport {
    let reason: String
    private var failure: LibraryTransportError { .transport(reason) }

    func fetchChanges(since token: LibraryChangeToken?) async throws -> LibraryChangeBatch { throw failure }
    func push(changes: [PendingLibraryChange]) async throws -> LibraryPushResult { throw failure }
    func send(intent: LibraryIntent) async throws { throw failure }
    func listIntents() async throws -> [LibraryIntent] { throw failure }
    func publish(_ record: DevicePlaybackPosition, as channel: PlaybackChannel) async throws { throw failure }
    func fetchDeviceRecords() async throws -> LibraryDeviceRecords { throw failure }
}

enum WiltedMacLibraryTransports {
    static let containerIdentifier = "iCloud.com.zerodelta.wilted"

    /// `CloudKitLibraryTransport` as the library writer on `WiltedLibraryZone`, or the
    /// unavailable stand-in without `WILTED_CLOUDKIT_LIVE` or under XCTest.
    static func production(deviceID: String, hostsTests: Bool) -> any LibraryTransport {
#if WILTED_CLOUDKIT_LIVE
        guard !hostsTests else { return WiltedMacUnavailableLibraryTransport(reason: "iCloud sync is off in tests.") }
        do {
            let outbox = CloudKitLibraryOutbox()
            let factory = driverFactory(outbox: outbox)
            return try CloudKitLibraryTransport(
                deviceID: deviceID, isLibraryWriter: true, driver: try factory(nil), driverFactory: factory, outbox: outbox
            )
        } catch {
            return WiltedMacUnavailableLibraryTransport(reason: "iCloud library sync could not start.")
        }
#else
        _ = (deviceID, hostsTests)
        return WiltedMacUnavailableLibraryTransport(reason: "iCloud sync is not enabled in this build.")
#endif
    }

#if WILTED_CLOUDKIT_LIVE
    private static func driverFactory(outbox: CloudKitLibraryOutbox) -> CloudKitEngineDriverFactory {
        let database = CKContainer(identifier: containerIdentifier).privateCloudDatabase
        let zoneID = LibraryRecordMapper().zoneID
        return { stateData in
            let serialization = try stateData.map { data -> CKSyncEngine.State.Serialization in
                guard let decoded = try? JSONDecoder().decode(CKSyncEngine.State.Serialization.self, from: data) else {
                    throw CloudKitSyncError.stateCorrupt
                }
                return decoded
            }
            return LiveCloudKitEngineDriver(
                database: database, stateSerialization: serialization,
                zoneBootstrap: LiveCloudKitZoneBootstrap(database: database, zoneID: zoneID),
                recordProvider: { outbox.record(for: $0) })
        }
    }
#endif
}

// MARK: - Controller

/// Republishes when the queue, removals or playback change: it watches the model with
/// `withObservationTracking`, coalesces bursts, and runs one publisher pass at a time. A
/// failed pass retries after `retryDelay`. Owned by the model through an associated object,
/// so it ends with the model.
@MainActor
final class WiltedMacLibrarySyncController {
    let publisher: WiltedMacLibraryPublisher
    let sink: WiltedMacLibraryIntentSink
    private(set) var lastReport: LibraryPublishReport?
    private(set) var lastFailure: String?
    private(set) var passCount = 0
    private weak var model: WiltedMacModel?
    private let triggers: AsyncStream<Void>.Continuation
    private var loop: Task<Void, Never>?
    private var stopped = false

    init(
        model: WiltedMacModel, publisher: WiltedMacLibraryPublisher, sink: WiltedMacLibraryIntentSink,
        debounce: Duration, retryDelay: Duration
    ) {
        self.model = model
        self.publisher = publisher
        self.sink = sink
        let (stream, continuation) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        triggers = continuation
        loop = Task { [weak self] in
            for await _ in stream {
                try? await Task.sleep(for: debounce)
                guard !Task.isCancelled, let self else { return }
                if await self.runPass() == false {
                    try? await Task.sleep(for: retryDelay)
                    continuation.yield()
                }
            }
        }
        continuation.yield()
        observe()
    }

    func stop() {
        stopped = true
        loop?.cancel()
        triggers.finish()
    }

    isolated deinit { stop() }

    private func observe() {
        guard !stopped, let model else { return }
        withObservationTracking {
            model.librarySyncObservedInputs()
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                self?.triggers.yield()
                self?.observe()
            }
        }
    }

    private func runPass() async -> Bool {
        guard let model, !model.isClosingTemporaryState else { return true }
        do {
            lastReport = try await publisher.sync()
            lastFailure = nil
            passCount += 1
            return true
        } catch {
            lastFailure = String(describing: error)
            librarySyncLog.error("Library publish failed: \(String(describing: error), privacy: .public)")
            return false
        }
    }
}

// MARK: - Model integration

private nonisolated(unsafe) var librarySyncControllerKey: UInt8 = 0

extension WiltedMacModel {
    static let libraryDeviceIDPreferenceKey = "wilted.library.deviceID"

    /// The running publisher owner, kept alive by the model without a stored property.
    var librarySyncController: WiltedMacLibrarySyncController? {
        objc_getAssociatedObject(self, &librarySyncControllerKey) as? WiltedMacLibrarySyncController
    }

    /// Starts the library publisher when `WILTED_LIBRARY_SYNC=1` and a store is open;
    /// otherwise stops any running one. Returns whether a publisher is running.
    @discardableResult
    func startLibrarySyncIfEnabled(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        transport: (any LibraryTransport)? = nil,
        mediaRequestConsumer: WiltedMacLibraryIntentSink.Consumer? = nil,
        debounce: Duration = .seconds(2),
        retryDelay: Duration = .seconds(60)
    ) -> Bool {
        stopLibrarySync()
        guard WiltedMacLibraryPublisher.isEnabled(in: environment), !fixtureMode, let store else { return false }
        let deviceID = libraryDeviceID()
        let source = WiltedMacLocalLibraryStateSource(store: store, deviceID: deviceID) { [weak self] in
            await MainActor.run { self?.librarySyncPlaybackSample() }
        }
        let sink = WiltedMacLibraryIntentSink(consumer: mediaRequestConsumer)
        let publisher = WiltedMacLibraryPublisher(
            source: source,
            transport: transport ?? WiltedMacLibraryTransports.production(deviceID: deviceID, hostsTests: Self.hostsTests),
            sink: sink, isEnabled: true
        )
        let controller = WiltedMacLibrarySyncController(
            model: self, publisher: publisher, sink: sink, debounce: debounce, retryDelay: retryDelay
        )
        objc_setAssociatedObject(self, &librarySyncControllerKey, controller, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        return true
    }

    func stopLibrarySync() {
        librarySyncController?.stop()
        objc_setAssociatedObject(self, &librarySyncControllerKey, nil, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
    }

    /// Everything whose change should republish. Position ticks are deliberately absent:
    /// the position rides along with the next queue, removal or play/pause change.
    func librarySyncObservedInputs() {
        _ = podcastQueueIDs
        _ = episodes
        _ = dismissedEpisodes
        _ = currentPodcastEpisodeID
        _ = isPodcastPlayback
        _ = isPlaying
    }

    func librarySyncPlaybackSample() -> WiltedMacPlaybackSample? {
        guard isPodcastPlayback, let raw = currentPodcastEpisodeID, let id = try? ItemID(rawValue: raw) else { return nil }
        return WiltedMacPlaybackSample(
            episodeID: id, positionSeconds: playbackPositionSeconds, rate: playbackRate, isPlaying: isPlaying
        )
    }

    /// A random id created once per install, kept in preferences.
    func libraryDeviceID() -> String {
        if let existing = preferences.string(forKey: Self.libraryDeviceIDPreferenceKey), !existing.isEmpty { return existing }
        let created = "mac-\(UUID().uuidString)"
        preferences.set(created, forKey: Self.libraryDeviceIDPreferenceKey)
        return created
    }
}
#endif
