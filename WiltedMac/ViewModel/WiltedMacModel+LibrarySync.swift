import Foundation
import Observation
import ObjectiveC
import OSLog
import WiltedCloudKit
import WiltedCloudKitLibrary
import WiltedDomain
import WiltedLibrary

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

/// Receives follower intents (`requestMedia`, `mediaCached`), records them, and routes each to
/// `consumer` (the ledger-guarded media service); without a consumer it only logs. Nothing here
/// writes producer state (W-INV-005).
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
            try await record(intent, describing: "requestMedia for \(entryID.rawValue)")
        case let .mediaCached(entryID, revisionID, deviceID):
            try await record(intent, describing: "mediaCached for \(entryID.rawValue) revision \(revisionID.rawValue) on \(deviceID)")
        case let .keep(entryID):
            try await record(intent, describing: "keep for \(entryID.rawValue)")
        case let .skip(entryID):
            try await record(intent, describing: "skip for \(entryID.rawValue)")
        case let .markDone(entryID):
            try await record(intent, describing: "markDone for \(entryID.rawValue)")
        case let .removeFromLarder(entryID):
            try await record(intent, describing: "removeFromLarder for \(entryID.rawValue)")
        case let .restore(entryID):
            try await record(intent, describing: "restore for \(entryID.rawValue)")
        case let .reorder(entryID, afterEntryID):
            try await record(intent, describing: "reorder of \(entryID.rawValue) after \(afterEntryID?.rawValue ?? "front")")
        }
    }

    private func record(_ intent: LibraryIntent, describing summary: String) async throws {
        recorded.append(intent)
        guard let consumer else {
            librarySyncLog.notice("\(summary, privacy: .public) recorded; no consumer, no-op")
            return
        }
        do { try await consumer(intent) } catch {
            seen.remove(intent.id)
            recorded.removeAll { $0.id == intent.id }
            throw error
        }
    }
}

// MARK: - Controller

/// Republishes when the queue or removals change: it watches the model with
/// `withObservationTracking`, coalesces bursts, and runs one publisher pass at a time. A user's
/// edit publishes its state at once (debounced); everything else, statistics and the playing
/// checkpoint included, waits for the next sync round (`tickRound`, 30 s), which is also what
/// retries a failed pass. Owned by the model through an associated object, so it ends with the model.
@MainActor
final class WiltedMacLibrarySyncController {
    let publisher: WiltedMacLibraryPublisher
    let sink: WiltedMacLibraryIntentSink
    private(set) var lastReport: LibraryPublishReport?
    private(set) var lastFailure: String?
    private(set) var passCount = 0
    /// The media service, inbound poller and intent ledger; stopped with the controller.
    var inbound: WiltedMacInboundRuntime?
    /// The only writer of the Mac's playback records; stopped with the controller.
    var handoff: WiltedMacHandoffController?
    /// The fresh read of the phone's position a Play press makes before the audio starts.
    var playRefresher: WiltedMacPlayPositionRefresher?
    /// The iCloud account binding that gates every server call; nil when unmanaged (Task 5.0).
    var account: WiltedMacLibraryAccountController?
    private weak var model: WiltedMacModel?
    private let triggers: AsyncStream<Void>.Continuation
    private var loop: Task<Void, Never>?
    private var offerReconcile: Task<Void, Never>?
    private var offerReconcileRequested = false
    private var passTail: Task<Bool, Never>?
    private var stopped = false
    /// Injected lifecycle observation for deterministic shutdown tests.
    var onShutdownDrain: (@MainActor () async -> Void)?

    init(
        model: WiltedMacModel, publisher: WiltedMacLibraryPublisher, sink: WiltedMacLibraryIntentSink,
        debounce: Duration
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
                // A failed edit waits for the next sync round instead of running its own retry timer.
                _ = await self.runPass(includesStats: false)
            }
        }
        continuation.yield()
        observe()
    }

    /// Asks for a publisher pass now (still coalesced and debounced), e.g. after a phone decision.
    func requestPublish() { triggers.yield() }

    /// The Mac's own work in one sync round, after the round's reads: the library state and
    /// statistics (a request only when one changed), then the playing checkpoint and the stored positions.
    func tickRound() async {
        guard !stopped else { return }
        _ = await runPass(includesStats: true)
        await handoff?.tickRound()
    }

    func stop() {
        stopped = true
        account?.stop()
        inbound?.stop()
        handoff?.stop()
        loop?.cancel()
        offerReconcile?.cancel()
        triggers.finish()
    }

    /// Stops accepting work and drains finite writers before their directory can go away.
    func close() async {
        stop()
        await onShutdownDrain?()
        await account?.close()
        await inbound?.close()
        await loop?.value
        await offerReconcile?.value
        _ = await passTail?.value
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

    /// Publishes `available` offers, one run at a time; a request that arrives during a run makes
    /// it repeat, so bursts coalesce. A run that could not publish everything is repeated by the
    /// next sync round.
    private func scheduleOfferReconcile() {
        guard !stopped, let service = inbound?.service else { return }
        guard offerReconcile == nil else {
            offerReconcileRequested = true
            return
        }
        offerReconcile = Task { [weak self] in
            repeat {
                self?.offerReconcileRequested = false
                _ = await service.reconcileAvailable()
            } while self?.offerReconcileRequested == true && !Task.isCancelled
            self?.offerReconcile = nil
        }
    }

    /// One pass at a time: an edit and a sync round never publish the same diff twice.
    private func runPass(includesStats: Bool) async -> Bool {
        guard !stopped else { return true }
        let previous = passTail
        let task = Task { @MainActor [weak self] in
            _ = await previous?.value
            return await self?.performPass(includesStats: includesStats) ?? true
        }
        passTail = task
        return await task.value
    }

    private func performPass(includesStats: Bool) async -> Bool {
        guard !stopped, let model, !model.isClosingTemporaryState else { return true }
        // Paused for the account: nothing to send, and nothing to report as a failure.
        if let account, !account.gate.isOpen { return true }
        do {
            lastReport = try await publisher.sync(includesStats: includesStats)
            // Offers follow the same triggers as state (the queue and the prepared set) but run on
            // their own task: the media service serializes behind an upload in flight, and a long
            // upload must not hold up state publishing.
            scheduleOfferReconcile()
            lastFailure = nil
            passCount += 1
            return true
        } catch {
            lastFailure = String(describing: error)
            // A closed gate reports itself (the Sync card); only a new kind of failure is an error.
            if !(error is TransportThrottled), !Self.isAccountPause(error) {
                librarySyncLog.error("Library publish failed: \(String(describing: error), privacy: .public)")
            }
            return false
        }
    }

    /// A call refused or superseded by the account gate; the account status reports it.
    static func isAccountPause(_ error: any Error) -> Bool {
        error is WiltedMacLibraryAccountError || (error as? LibraryTransportError) == .superseded
    }
}

// MARK: - Model integration

private nonisolated(unsafe) var librarySyncControllerKey: UInt8 = 0
private nonisolated(unsafe) var librarySyncShutdownKey: UInt8 = 0

extension WiltedMacModel {
    static let libraryDeviceIDPreferenceKey = "wilted.library.deviceID"

    /// The running publisher owner, kept alive by the model without a stored property.
    var librarySyncController: WiltedMacLibrarySyncController? {
        objc_getAssociatedObject(self, &librarySyncControllerKey) as? WiltedMacLibrarySyncController
    }

    /// Retains a draining owner after synchronous stop clears its visible association.
    private var librarySyncShutdown: Task<Void, Never>? {
        get { objc_getAssociatedObject(self, &librarySyncShutdownKey) as? Task<Void, Never> }
        set { objc_setAssociatedObject(self, &librarySyncShutdownKey, newValue, .OBJC_ASSOCIATION_RETAIN_NONATOMIC) }
    }

    /// Starts the library publisher when the runtime selection names it (the live-build default,
    /// or `WILTED_LIBRARY_SYNC=1`) and a store is open; otherwise stops any running one. The
    /// default starts only on a transport that reports account changes. Returns whether a
    /// publisher is running.
    @discardableResult
    func startLibrarySyncIfEnabled(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        transport: (any LibraryTransport)? = nil,
        mediaRequestConsumer: WiltedMacLibraryIntentSink.Consumer? = nil,
        inboundMaintenance: (@Sendable () async -> Void)? = nil,
        debounce: Duration = .seconds(2),
        account accountSource: WiltedMacLibraryAccountSource? = nil
    ) -> Bool {
        stopLibrarySync()
        let selection = libraryRuntimeSelection(environment: environment)
        guard !isClosingTemporaryState, selection.engine == .libraryPublisher, !fixtureMode, let store else { return false }
        let previousShutdown = librarySyncShutdown
        let deviceID = libraryDeviceID()
        let source = WiltedMacLocalLibraryStateSource(store: store, deviceID: deviceID) { [weak self] in
            await MainActor.run { self?.librarySyncPlaybackSample() }
        }
        let rawTransport = transport
            ?? WiltedMacLibraryTransports.production(deviceID: deviceID, hostsTests: librarySyncBuildFacts.hostsTests)
        let accountSource = accountSource
            ?? WiltedMacLibraryAccountSource.transport(rawTransport, probe: WiltedMacLibraryTransports.accountProbe())
        guard selection.admits(managedTransport: accountSource != nil) else {
            librarySyncLog.error("Library sync default refused: the transport reports no account changes")
            libraryAccountStatus = .transportUnavailable
            return false
        }
        // One gate for every server call this device makes (poller, handoff, publisher, intents,
        // media): a rate limit anywhere pauses all of them together and the Sync card says so.
        let gate = TransportGate(onChange: { [weak self] state in
            Task { @MainActor in self?.libraryThrottleChanged(state) }
        })
        // The account gate sits inside the throttle, so a call is admitted when it actually runs.
        let account = accountSource.map { signals in
            WiltedMacLibraryAccountController(
                source: signals, persistence: .store(store),
                isLibraryEmpty: { (try? await source.currentState())?.isEmptyLibrary ?? false })
        }
        let accountGated = WiltedMacAccountGatedLibraryTransport(
            inner: rawTransport, gate: account?.gate ?? WiltedMacLibraryAccountGate(open: true))
        let resolvedTransport = ThrottledLibraryTransport(wrapping: accountGated, gate: gate)
        let syncDirectory = libraryURL.deletingLastPathComponent().appendingPathComponent("library-sync", isDirectory: true)
        // The phone's positions become the Mac's stored positions (see WiltedMacPositionImporter).
        let importer = WiltedMacPositionImporter(host: WiltedMacModelPositionImportHost(model: self), deviceID: deviceID)
        let inbound = WiltedMacInboundRuntime(
            source: WiltedMacLocalReadyAudioSource(store: store), transport: resolvedTransport,
            directory: syncDirectory, deviceID: deviceID, gate: gate,
            // The one whole-zone scan: it teaches the transport the peer and entry names to poll.
            discover: {
                try await gate.run {
                    try await accountGated.run { _ = try await (rawTransport as? CloudKitLibraryTransport)?.discoverPeers() }
                }
            },
            onDeviceRecords: { [weak self] records in
                await importer.handle(records)
                await MainActor.run { self?.updatePhonePositions(from: records) }
            }, maintenance: inboundMaintenance,
            beforePollerStart: { await previousShutdown?.value }
        )
        // Decision intents (keep, skip, mark done, remove from Larder, restore, reorder) go to the applier, which shares
        // the media service's ledger; media intents keep their existing route.
        let applier = WiltedMacIntentApplier(
            host: self, ledger: inbound.ledger,
            book: WiltedMacIntentOutcomeBook(fileURL: syncDirectory.appendingPathComponent("intent-outcomes.json")),
            transport: resolvedTransport,
            onApplied: { [weak self] in self?.librarySyncController?.requestPublish() }
        )
        let sink = WiltedMacLibraryIntentSink(consumer: mediaRequestConsumer ?? { intent in
            if intent.action.isDecision { try await applier.apply(intent) } else { await inbound.consume(intent) }
        })
        let publisher = WiltedMacLibraryPublisher(
            source: source, transport: resolvedTransport, sink: sink, isEnabled: true,
            statsProvider: { try? await store.lifetimeStatistics() },
            // The sync round reads intents once for everything; the publisher does not read them again.
            relaysIntents: false
        )
        let controller = WiltedMacLibrarySyncController(
            model: self, publisher: publisher, sink: sink, debounce: debounce
        )
        controller.inbound = inbound
        // Play reads the phone's position itself (one bounded fetch) instead of waiting for a poll.
        controller.playRefresher = WiltedMacPlayPositionRefresher(
            fetch: { try await resolvedTransport.fetchDeviceRecords() }, importer: importer,
            onRecords: { [weak self] records in self?.updatePhonePositions(from: records) })
        // The Mac's one 30 s sync round: reads, then its own writes (state, statistics, checkpoint).
        let startPolling = { [weak controller] in
            _ = inbound.start(sink: sink, publishRound: { [weak controller] in await controller?.tickRound() })
        }
        if let account {
            controller.account = account
            account.willOpen = { await publisher.resetForAccount() }
            account.didOpen = { [weak controller] in
                startPolling()
                controller?.requestPublish()
            }
            account.didClose = { _ = inbound.stop() }
            account.onStatus = { [weak self] status in self?.libraryAccountStatus = status }
            libraryAccountStatus = account.status
            account.start()
        } else {
            libraryAccountStatus = .unmanaged
            startPolling()
        }
        let handoff = WiltedMacHandoffController(
            coordinator: HandoffCoordinator(transport: resolvedTransport, deviceID: deviceID),
            player: WiltedMacModelHandoffPlayer(
                model: self, audio: WiltedMacLocalReadyAudioSource(store: store), adopted: { importer.adopted }),
            deviceID: deviceID,
            latestRecords: {
                guard let poller = await MainActor.run(body: { inbound.poller }) else { return nil }
                return await poller.latestDeviceRecords
            }
        )
        controller.handoff = handoff
        handoff.start()
        objc_setAssociatedObject(self, &librarySyncControllerKey, controller, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        return true
    }

    func stopLibrarySync() {
        if let controller = librarySyncController {
            controller.stop()
            let previous = librarySyncShutdown
            librarySyncShutdown = Task {
                await previous?.value
                await controller.close()
            }
        }
        objc_setAssociatedObject(self, &librarySyncControllerKey, nil, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        libraryThrottle = nil
        libraryAccountStatus = nil
        phonePositions = [:]
    }

    func waitForLibrarySyncShutdown() async { await librarySyncShutdown?.value }

    /// Everything whose change should republish at once: the queue and removals. Playback is
    /// published by the handoff controller and statistics by the sync round, so neither a position
    /// checkpoint nor the listening clock wakes the publisher.
    func librarySyncObservedInputs() {
        _ = podcastQueueIDs
        _ = episodes
        _ = dismissedEpisodes
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

// MARK: - Handoff player

/// `WiltedMacHandoffPlayer` over the model's playback path: it reads the live engine, and pauses
/// exactly as the transport toggle does, including the durable checkpoint.
@MainActor
final class WiltedMacModelHandoffPlayer: WiltedMacHandoffPlayer {
    weak var model: WiltedMacModel?
    private let audio: any WiltedMacReadyAudioSource

    /// Positions the Mac stored from the phone, which it does not publish back as its own.
    private let adopted: @MainActor () -> [ItemID: WiltedMacPositionImporter.Adoption]

    init(
        model: WiltedMacModel, audio: any WiltedMacReadyAudioSource,
        adopted: @escaping @MainActor () -> [ItemID: WiltedMacPositionImporter.Adoption] = { [:] }
    ) {
        self.model = model
        self.audio = audio
        self.adopted = adopted
    }

    func adoptedPositions() -> [ItemID: WiltedMacPositionImporter.Adoption] { adopted() }

    func handoffSample() -> WiltedMacPlaybackSample? {
        guard let model, var sample = model.librarySyncPlaybackSample() else { return nil }
        if let playback = model.playback {
            sample.positionSeconds = max(0, playback.livePositionSeconds)
            sample.isPlaying = playback.liveIsPlaying
            sample.rate = Double(playback.playbackRate)
        }
        return sample
    }

    func handoffRevision(for entryID: ItemID) async -> RevisionID? {
        if let playback = model?.playback, playback.itemID == entryID, let loaded = playback.revisionID { return loaded }
        return try? await audio.readyAudio(for: entryID)?.revisionID
    }

    func pauseAndCheckpoint() async {
        guard let model, let playback = model.playback else { return }
        do {
            try await playback.pauseAndCheckpoint()
            model.isPlaying = playback.isPlaying
            model.refreshPlaybackReadout()
            await model.queueCurrentPlaybackCheckpoint()
        } catch {
            librarySyncLog.error("Handoff pause failed: \(String(describing: error), privacy: .public)")
        }
    }

    func trackPlayback(onChange: @escaping @MainActor () -> Void) {
        guard let model else { return }
        withObservationTracking {
            _ = model.isPlaying
            _ = model.currentPodcastEpisodeID
            _ = model.isPodcastPlayback
        } onChange: {
            Task { @MainActor in onChange() }
        }
    }
}
#endif
