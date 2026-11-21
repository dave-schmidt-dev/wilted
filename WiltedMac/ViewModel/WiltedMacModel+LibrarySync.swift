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

let librarySyncLog = Logger(subsystem: "com.zerodelta.wilted", category: "MacLibrarySync")

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
        case .subscribe, .addArticle:
            try await record(intent, describing: "add-flow intent for \(intent.action.entryID.rawValue)")
        case let .adFeedback(entryID, _, kind, _):
            try await record(intent, describing: "\(kind.rawValue) feedback for \(entryID.rawValue)")
        case .unsupported:
            try await record(intent, describing: "unsupported action")
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
        let source = WiltedMacLocalLibraryStateSource(store: store, deviceID: deviceID, playback: { [weak self] in
            await MainActor.run { self?.librarySyncPlaybackSample() }
        }, localRequests: { [weak self] in
            await MainActor.run {
                guard let self else { return [:] }
                var requests = self.preparationPublicationRequests
                for (id, sequence) in self.preparationRequestSequences {
                    if requests[id]?.requestSequence != sequence {
                        requests[id] = .init(requestSequence: sequence)
                    }
                }
                return requests
            }
        })
        let rawTransport = transport
            ?? WiltedMacLibraryTransports.production(deviceID: deviceID, hostsTests: librarySyncBuildFacts.hostsTests)
        libraryOperationCounters = (rawTransport as? CloudKitLibraryTransport)?.counters
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
            source: WiltedMacLibraryReadyAudioSource(store: store), transport: resolvedTransport,
            directory: syncDirectory, deviceID: deviceID, gate: gate, accountGate: accountGated.gate,
            preferences: WiltedMacLANPreferences(defaults: preferences),
            // The one whole-zone scan: it teaches the transport the peer and entry names to poll.
            discover: {
                try await gate.run {
                    try await accountGated.run { _ = try await (rawTransport as? CloudKitLibraryTransport)?.discoverPeers() }
                }
            },
            onDeviceRecords: { records in await importer.handle(records) }, maintenance: inboundMaintenance,
            beforePollerStart: { await previousShutdown?.value },
            onRoundFinished: { [weak self] error in await MainActor.run { self?.recordLibraryCheck(error) } },
            onDevicesChange: { [weak self] devices in await MainActor.run { self?.recordLinkedDevices(devices) } },
            preuploadLimit: WiltedMacMediaService.standardPreuploadLimit
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
            // A media request is queued, not awaited, so its upload never holds up the round.
            if intent.action.isDecision { try await applier.apply(intent) } else { await inbound.admit(intent) }
        })
        let publisher = WiltedMacLibraryPublisher(
            source: source, transport: resolvedTransport, sink: sink, isEnabled: true,
            statsProvider: { try? await store.lifetimeStatistics() },
            // The sync round reads intents once for everything; the publisher does not read them again.
            relaysIntents: false,
            publicationStore: account == nil ? nil : .store(store), deviceID: deviceID,
            approvedOwner: { [weak account] in await account?.approvedPublicationOwner }
        )
        let controller = WiltedMacLibrarySyncController(
            model: self, publisher: publisher, sink: sink, debounce: debounce
        )
        controller.inbound = inbound
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
            account.didClose = { [weak self, weak controller] in
                _ = inbound.stop(); controller?.publicationHydration?.cancel()
                self?.librarySyncActivity.publicationOwner = nil
            }
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
                model: self, audio: WiltedMacLibraryReadyAudioSource(store: store), adopted: { importer.adopted }),
            deviceID: deviceID,
            latestRecords: {
                guard let poller = await MainActor.run(body: { inbound.poller }) else { return nil }
                return await poller.latestDeviceRecords
            }
        )
        controller.handoff = handoff
        handoff.start()
        objc_setAssociatedObject(self, &librarySyncControllerKey, controller, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        controller.publicationHydration = Task { [weak self] in await self?.hydrateSavedLibraryPublication() }
        return true
    }

    func stopLibrarySync() {
        if let controller = librarySyncController {
            controller.publicationHydration?.cancel()
            controller.stop()
            let previous = librarySyncShutdown
            librarySyncShutdown = Task {
                await previous?.value
                await controller.close()
            }
        }
        objc_setAssociatedObject(self, &librarySyncControllerKey, nil, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        libraryOperationCounters = nil
        // A UI fixture's scripted state is not a running publisher's, so stopping keeps it.
        guard librarySyncFixture == nil else { return }
        libraryThrottle = nil
        libraryAccountStatus = nil
        librarySyncActivity = WiltedMacLibrarySyncActivity()
    }

    func waitForLibrarySyncShutdown() async { await librarySyncShutdown?.value }

    /// A normal quit's network step: cancel outstanding network generations,
    /// then close and join the library controllers. Pending library and
    /// playback work is already durable locally, so nothing here waits for
    /// cloud success, and the caller bounds the join. Task 5.0's publisher
    /// shutdown belongs here, between the cancel and the join.
    func closeLibraryControllersForTermination() async {
        stopLibrarySync()
        await waitForLibrarySyncShutdown()
    }

    func librarySyncPlaybackSample() -> WiltedMacPlaybackSample? {
        // An article or audiobook is what the player holds when it is not a podcast.
        let raw = isPodcastPlayback ? (playback?.itemID?.rawValue ?? currentPodcastEpisodeID) : playback?.itemID?.rawValue
        guard let raw, let id = try? ItemID(rawValue: raw) else { return nil }
        return WiltedMacPlaybackSample(
            episodeID: id, positionSeconds: playbackPositionSeconds, rate: playbackRate, isPlaying: isPlaying,
            revisionID: playback?.itemID == id ? playback?.revisionID : nil
        )
    }

    /// A random id created once per install, kept in preferences.
    func libraryDeviceID() -> String {
        if let existing = preferences.string(forKey: Self.libraryDeviceIDPreferenceKey), !existing.isEmpty { return existing }
        let created = "mac-\(UUID().uuidString)"
        preferences.set(created, forKey: Self.libraryDeviceIDPreferenceKey)
        return created
    }

    /// Re-reads ahead-of-time media upload activity and queued requests from the current runtime.
    func refreshMediaActivity() async {
        // A stopped runtime is never read, and a read that spans a stop or restart of the same
        // runtime (the account gate closing and reopening) is dropped.
        guard let inbound = librarySyncController?.inbound, inbound.poller != nil else { return }
        let lifecycle = inbound.lifecycle
        let snapshot = await inbound.mediaActivity()
        guard librarySyncController?.inbound === inbound, inbound.lifecycle == lifecycle,
              inbound.poller != nil else { return }
        if librarySyncActivity.media != snapshot {
            librarySyncActivity.media = snapshot
        }
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
            model.refreshLifetimeStatisticsAfterPlayback()
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
