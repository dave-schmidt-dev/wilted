import Foundation
import Observation

#if canImport(WiltedProducer)
import WiltedDomain
import WiltedProducer
import WiltedSync
#endif

#if WILTED_CLOUDKIT_LIVE
import CloudKit
#endif

struct WiltedMacArticle: Identifiable, Hashable, Sendable {
    let id: String
    let title: String
    let source: String
    let url: URL
    let isReady: Bool
    /// Present once audio exists. The library row states how long an article
    /// takes to listen to, which is the one fact that decides whether to
    /// start it now, and it was the only list in the app that withheld it.
    let durationSeconds: TimeInterval?
}

/// Presentation view of one recorded preparation attempt.
///
/// The producer runs one preparation at a time and keeps a journal of every
/// status each attempt emitted. Nothing surfaced that journal, so a run that
/// failed overnight left no trace a reader could find. This is the row shape
/// the Processor destination lists.
struct WiltedMacProcessorRun: Identifiable, Equatable, Sendable {
    enum Outcome: String, Sendable {
        case running, succeeded, failed, cancelled
    }

    let id: String
    let title: String
    let source: String
    let stage: String
    let detail: String
    let fraction: Double?
    let outcome: Outcome
    let updatedAt: Date

    /// Colour is emphasis only; `outcomeLabel` always states the outcome.
    var tone: WiltedStatusTone {
        switch outcome {
        case .running: .active
        case .succeeded: .positive
        case .cancelled: .neutral
        case .failed: .failure
        }
    }

    var outcomeLabel: String {
        switch outcome {
        case .running: "Running"
        case .succeeded: "Succeeded"
        case .failed: "Failed"
        case .cancelled: "Cancelled"
        }
    }
}

/// Presentation view of a stored transcript.
///
/// The domain `Transcript` lives behind `canImport(WiltedProducer)`, so the
/// producer keeps a local shape here for the same reason `WiltedMacArticle`
/// exists: the views stay compilable without the producer package, and UI code
/// never handles a domain type directly.
struct WiltedMacTranscript: Equatable, Sendable {
    enum Availability: String, Sendable {
        case available
        case stale
        case oversized
        case malformed
        case absent
    }

    let availability: Availability
    let text: String?

    var isReadable: Bool {
        (availability == .available || availability == .stale) && !(text ?? "").isEmpty
    }

    /// Says why text is missing instead of silently showing nothing. The
    /// listener already did this; the producer showed no transcript at all.
    var unavailableLabel: String {
        switch availability {
        case .oversized: "Transcript unavailable: article text is too large"
        case .malformed: "Transcript unavailable: article text could not be read"
        case .absent, .available, .stale: "Transcript unavailable"
        }
    }

    var disclosureTitle: String {
        availability == .stale ? "Transcript (may be outdated)" : "Transcript"
    }

    /// The listener always shows this row and explains why text is missing.
    /// The producer rendered nothing at all when it had no transcript loaded,
    /// so this is what a missing one resolves to.
    static let unavailable = WiltedMacTranscript(availability: .absent, text: nil)
}

struct WiltedMacPreparation: Equatable, Sendable {
    enum Phase: String, Sendable {
        case preparing
        case extracting
        case synthesizing
        case assembling
        case saving
        case cancelling
        case completed
        case cancelled
        case failed

        var title: String {
            switch self {
            case .preparing: "Preparing article"
            case .extracting: "Extracting article"
            case .synthesizing: "Generating speech"
            case .assembling: "Assembling audio"
            case .saving: "Saving revision"
            case .cancelling: "Cancelling preparation"
            case .completed: "Ready to play"
            case .cancelled: "Preparation cancelled"
            case .failed: "Preparation failed"
            }
        }

        /// A finished run. The Processor destination shows the active card
        /// only while work is genuinely in flight.
        var isTerminal: Bool {
            switch self {
            case .completed, .cancelled, .failed: true
            default: false
            }
        }
    }

    let phase: Phase
    let detail: String
    let fraction: Double?
    let cancellable: Bool
}

/// The producer's permanent destinations.
///
/// These mirror the listener's tabs minus Downloads, which is listener-only:
/// Mac audio is local the moment it is produced. Exactly one destination fills
/// the detail region at a time — an earlier composition rendered Library
/// unconditionally and merely appended a player, so selecting a destination
/// changed nothing and the window read as three competing regions.
enum WiltedMacNavigation: String, CaseIterable, Hashable, Identifiable, Sendable {
    case library
    case nowPlaying
    case processor
    case settings

    var id: Self { self }

    var title: String {
        switch self {
        case .library: WiltedScreenCopy.library
        case .nowPlaying: WiltedScreenCopy.nowPlaying
        case .processor: WiltedScreenCopy.processor
        case .settings: WiltedScreenCopy.settings
        }
    }

    var symbolName: String {
        switch self {
        case .library: "books.vertical"
        case .nowPlaying: "waveform"
        case .processor: "gearshape.2"
        case .settings: "gearshape"
        }
    }
}

/// Main-actor presentation state for the local Mac producer.
@Observable
@MainActor
final class WiltedMacModel {
    var urlDraft = ""
    var selectedNavigation: WiltedMacNavigation = .library
    private(set) var articles: [WiltedMacArticle] = []
    private(set) var preparation: WiltedMacPreparation?
    private(set) var selectedArticleID: String?
    private(set) var isNowPlaying = false
    private(set) var isPlaying = false
    private(set) var playbackError: String?
    /// Readout state the listener already published. The producer's player
    /// showed transports and nothing else, so the Mac could not answer "how
    /// far in am I?" — a question the same audio answers on iPhone.
    private(set) var playbackPositionSeconds: TimeInterval = 0
    private(set) var playbackDurationSeconds: TimeInterval = 0
    /// Every recorded preparation attempt, newest first.
    private(set) var processorRuns: [WiltedMacProcessorRun] = []
    /// Progress for an in-flight transcript backfill (W-INV-001: a network
    /// fetch never runs without the surface saying so).
    private(set) var transcriptBackfillStatus: String?
    private(set) var isBackfillingTranscript = false
    private(set) var currentTranscript: WiltedMacTranscript?
    /// Set only when a route operation actually failed. The recovery control
    /// is gated on this so it does not advertise a fix for a fault that has
    /// not happened, matching how every other recovery control here behaves.
    private(set) var audioRouteFault = false

    let fixtureMode: Bool

#if canImport(WiltedProducer)
    private let store: LocalLibraryStore?
    private let coordinator: PreparationCoordinator?
    private let playback: PlaybackController?
    private let syncLifecycle: WiltedMacSyncLifecycle?
    private var preparationRun: PreparationRun?
    private var preparationTask: Task<Void, Never>?
    private var syncReconciliationTask: Task<Void, Never>?
    private var fixtureRevision: StoredAudioRevision?
#endif

    init(arguments: [String] = ProcessInfo.processInfo.arguments,
         syncTransportFactory: WiltedMacSyncTransportFactory? = nil,
         assetResolver: @escaping LocalLibraryAssetResolver = { _, _ in nil },
         stateDirectoryOverride: URL? = nil) {
        let usesFixtureMode = arguments.contains("--wilted-ui-fixture-article-flow")
            || arguments.contains("--wilted-ui-fixture-quarantined")
            || arguments.contains("--wilted-ui-smoke")
            || arguments.contains("--wilted-ui-fixture-ready")
            || arguments.contains("--wilted-ui-fixture-playing")
            || arguments.contains("--wilted-ui-fixture-preparing")
        fixtureMode = usesFixtureMode

#if canImport(WiltedProducer)
        let stateDirectory = stateDirectoryOverride ?? Self.stateDirectory(fixtureMode: usesFixtureMode)
        let libraryURL = stateDirectory.appendingPathComponent("library.sqlite")
        let mediaDirectory = stateDirectory.appendingPathComponent("media", isDirectory: true)
        let configuredStore = try? LocalLibraryStore(url: libraryURL)
        store = configuredStore
        coordinator = configuredStore.map {
            PreparationCoordinator(store: $0, mediaDirectory: mediaDirectory)
        }
        playback = configuredStore.map {
            PlaybackController(
                store: $0,
                backend: usesFixtureMode ? WiltedFixturePlaybackBackend() : AVAudioPlayerBackend(),
                deviceID: "mac"
            )
        }
        var selectedSyncFactory = syncTransportFactory
#if WILTED_CLOUDKIT_LIVE
        if !usesFixtureMode, selectedSyncFactory == nil, let configuredStore {
            let liveConfiguration = WiltedMacLiveSyncConfiguration(
                database: CKContainer(identifier: "iCloud.com.zerodelta.wilted").privateCloudDatabase,
                assetRootURL: mediaDirectory,
                store: configuredStore,
                assetResolver: assetResolver
            )
            selectedSyncFactory = makeWiltedMacLiveSyncTransportFactory(configuration: liveConfiguration)
        }
#endif
        syncLifecycle = configuredStore.map {
            WiltedMacSyncLifecycle(
                store: $0,
                transportFactory: usesFixtureMode ? nil : selectedSyncFactory,
                assetResolver: assetResolver
            )
        }

        if usesFixtureMode {
            installFixture(
                ready: arguments.contains("--wilted-ui-fixture-ready") || arguments.contains("--wilted-ui-fixture-playing"),
                preparing: arguments.contains("--wilted-ui-fixture-preparing")
            )
            if arguments.contains("--wilted-ui-fixture-quarantined") {
                syncLifecycle?.quarantineAccount()
            }
            if arguments.contains("--wilted-ui-fixture-playing"), let firstArticle = articles.first(where: { $0.isReady }) {
                openNowPlaying(for: firstArticle)
                togglePlayback()
            }
        } else {
            // The account-review gate is durable state, so it has to be restored before
            // the panel decides whether to show the review control.
            syncLifecycle?.restoreAccountQuarantine()
            refresh()
        }
#else
        _ = arguments
#endif
    }

    var syncStatus: WiltedMacSyncStatus {
#if canImport(WiltedProducer)
        syncLifecycle?.status ?? .disabled
#else
        .disabled
#endif
    }

    var syncObservability: WiltedMacObservability {
#if canImport(WiltedProducer)
        syncLifecycle?.observability ?? .unavailable
#else
        .unavailable
#endif
    }

    /// Starts the explicit manual refresh action.
    func refreshSync() {
#if canImport(WiltedProducer)
        syncLifecycle?.startRefresh()
#endif
    }

    /// Starts the explicit manual upload action.
    func uploadPendingSync() {
#if canImport(WiltedProducer)
        Task { [weak self] in
            _ = await self?.queueUnpublishedReadyRevisions()
            self?.syncLifecycle?.startUpload()
        }
#endif
    }

    /// Reconciles durable ready revisions when the producer launches or returns to the
    /// foreground. The task guard makes repeated scene callbacks harmless while the
    /// existing lifecycle coalesces any automatic send requested by the reconciliation.
    func reconcileSyncOnLaunchOrForeground() {
#if canImport(WiltedProducer)
        guard !fixtureMode,
              let syncLifecycle,
              syncLifecycle.status.phase != .disabled,
              syncReconciliationTask == nil else { return }
        syncReconciliationTask = Task { [weak self] in
            guard let self else { return }
            let queued = await self.queueUnpublishedReadyRevisions()
            if queued {
                self.syncLifecycle?.startAutomaticUpload()
            }
            self.syncReconciliationTask = nil
        }
#endif
    }

    /// Cancels the current bounded sync action.
    func cancelSync() {
#if canImport(WiltedProducer)
        syncLifecycle?.cancel()
#endif
    }

    /// Quarantines sync after an account-owner change.
    func quarantineSyncAccount() {
#if canImport(WiltedProducer)
        syncLifecycle?.quarantineAccount()
#endif
    }

    /// Clears the explicit account quarantine after review.
    func resetSyncAccount() {
#if canImport(WiltedProducer)
        syncLifecycle?.resetAfterAccountChange()
#endif
    }

    var currentArticle: WiltedMacArticle? {
        guard let selectedArticleID else { return nil }
        return articles.first(where: { $0.id == selectedArticleID })
    }

    var canCancelPreparation: Bool { preparation?.cancellable == true }

    /// The player's one-line status, matching the listener's status channel so
    /// the same condition reads the same way on both platforms. Never color
    /// alone: the tone accompanies this text rather than replacing it.
    var playbackStatusMessage: String {
        if let playbackError { return playbackError }
        if isPlaying { return "Playing" }
        if isNowPlaying { return "Paused" }
        return "Ready"
    }

    var playbackStatusTone: WiltedStatusTone {
        if playbackError != nil { return .failure }
        if isPlaying { return .active }
        return .neutral
    }

    /// Elapsed and total, in the listener's wording.
    var playbackProgressLabel: String {
        WiltedDuration.progress(position: playbackPositionSeconds, duration: playbackDurationSeconds)
    }

    /// The spoken form of the same readout.
    var playbackProgressSpokenLabel: String {
        WiltedDuration.spokenProgress(position: playbackPositionSeconds, duration: playbackDurationSeconds)
    }

    func addArticle() {
        guard let url = URL(string: urlDraft.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            preparation = WiltedMacPreparation(
                phase: .failed, detail: "Enter a complete HTTPS article URL.", fraction: nil, cancellable: false
            )
            return
        }
        guard url.scheme?.lowercased() == "https", url.host != nil else {
            preparation = WiltedMacPreparation(
                phase: .failed, detail: "Enter a complete HTTPS article URL.", fraction: nil, cancellable: false
            )
            return
        }
        guard let preparedItemID = try? ItemID.derive(from: url) else { return }

        if fixtureMode {
            preparation = WiltedMacPreparation(
                phase: .preparing, detail: "Validating article URL", fraction: 0, cancellable: true
            )
            return
        }

#if canImport(WiltedProducer)
        guard let coordinator else {
            preparation = WiltedMacPreparation(
                phase: .failed, detail: "The local library is unavailable.", fraction: nil, cancellable: false
            )
            return
        }
        preparationTask?.cancel()
        preparation = WiltedMacPreparation(
            phase: .preparing, detail: "Validating article URL", fraction: 0, cancellable: true
        )
        preparationTask = Task { [weak self] in
            let run = await coordinator.start(url: url)
            guard let self else { await run.cancel(); return }
            self.preparationRun = run
            for await status in run.statuses {
                guard !Task.isCancelled else { await run.cancel(); return }
                self.update(status)
                if status.terminal { break }
            }
            if self.preparation?.phase == .completed {
                if await self.queuePreparedPublication(itemID: preparedItemID) {
                    self.syncLifecycle?.startAutomaticUpload()
                }
            }
            self.preparationRun = nil
            self.refresh()
        }
#endif
    }

    func cancelPreparation() {
        guard canCancelPreparation else { return }
        preparation = WiltedMacPreparation(
            phase: .cancelling, detail: "The current work will stop without replacing saved audio.",
            fraction: preparation?.fraction, cancellable: false
        )
        if fixtureMode { return }
#if canImport(WiltedProducer)
        let run = preparationRun
        Task { await run?.cancel() }
#endif
    }

    func openNowPlaying(for article: WiltedMacArticle) {
        guard article.isReady else { return }
        selectedArticleID = article.id
        isNowPlaying = true
        selectedNavigation = .nowPlaying
        playbackError = nil
        currentTranscript = nil
        playbackPositionSeconds = 0
        playbackDurationSeconds = 0
#if canImport(WiltedProducer)
        guard let playback else { return }
        guard let fixtureRevision else {
            if fixtureMode { return }
            Task { [weak self] in
                guard let self, let store = self.store,
                      let itemID = try? ItemID(rawValue: article.id),
                      let revision = try? await store.readyRevision(for: itemID) else { return }
                do {
                    try await playback.load(revision)
                    self.isPlaying = playback.isPlaying
                    self.refreshPlaybackReadout()
                    await self.loadTranscript(itemID: itemID, revisionID: revision.revision.revisionID)
                } catch { self.playbackError = "Audio could not be loaded." }
            }
            return
        }
        Task { [weak self] in
            guard let self else { return }
            do {
                try await playback.load(fixtureRevision)
                self.isPlaying = playback.isPlaying
                self.refreshPlaybackReadout()
                if let itemID = try? ItemID(rawValue: article.id) {
                    await self.loadTranscript(
                        itemID: itemID,
                        revisionID: fixtureRevision.revision.revisionID
                    )
                }
            } catch { self.playbackError = "Audio could not be loaded." }
        }
#endif
    }

    /// Republishes elapsed/total from the controller.
    ///
    /// `PlaybackController` advances its own position, but nothing observed it
    /// while audio ran, so the producer's readout would freeze at the loaded
    /// value. The player view drives this on a one-second cadence, matching
    /// the listener's `refreshNowPlayingReadout`.
    func refreshPlaybackReadout() {
#if canImport(WiltedProducer)
        guard let playback else { return }
        playbackDurationSeconds = playback.durationSeconds
        // The live engine read, not the checkpointed one. `positionSeconds`
        // only moves on load, seek, and checkpoint, so polling it left the
        // readout frozen between transport presses.
        playbackPositionSeconds = min(max(0, playback.livePositionSeconds), max(0, playback.durationSeconds))
        isPlaying = playback.liveIsPlaying
#endif
    }

#if canImport(WiltedProducer)
    private func loadTranscript(itemID: ItemID, revisionID: RevisionID) async {
        guard let store else { return }
        guard let stored = try? await store.transcript(for: itemID, revisionID: revisionID) else {
            currentTranscript = WiltedMacTranscript(availability: .absent, text: nil)
            return
        }
        let availability: WiltedMacTranscript.Availability = switch stored.availability {
        case .available: .available
        case .stale: .stale
        case .oversized: .oversized
        case .malformed: .malformed
        case .absent: .absent
        }
        currentTranscript = WiltedMacTranscript(availability: availability, text: stored.text)
    }
#endif

    func togglePlayback() {
#if canImport(WiltedProducer)
        guard let playback else { return }
        Task { [weak self] in
            guard let self else { return }
            do {
                try await playback.toggle()
                self.isPlaying = playback.isPlaying
                self.refreshPlaybackReadout()
                await self.queueCurrentPlaybackCheckpoint()
            } catch { self.reportAudioRouteFault("Playback is unavailable.") }
        }
#else
        isPlaying.toggle()
#endif
    }

    /// Returns to Library without changing playback state.
    ///
    /// The player no longer draws its own back button — the sidebar is
    /// permanent, so a second way back was redundant and the listener has no
    /// equivalent — but menu and keyboard paths still need the operation.
    func returnToLibrary() {
        selectedNavigation = .library
    }

    func rewind() { seek(by: -15) }
    func forward() { seek(by: 30) }

    /// Starts a new playback session and publishes its durable checkpoint.
    func restartPlayback() {
#if canImport(WiltedProducer)
        guard let playback else { return }
        Task { [weak self] in
            guard let self else { return }
            do {
                try await playback.restart()
                self.refreshPlaybackReadout()
                await self.queueCurrentPlaybackCheckpoint()
            } catch { self.playbackError = "Playback restart is unavailable." }
        }
#endif
    }

    /// Records a playback fault that a route recovery can plausibly clear, so
    /// the recovery control appears only when it has something to act on.
    func reportAudioRouteFault(_ message: String) {
        playbackError = message
        audioRouteFault = true
    }

    func recoverAudioRoute() {
#if canImport(WiltedProducer)
        guard let playback else { return }
        Task { [weak self] in
            guard let self else { return }
            do {
                try await playback.recoverFromRouteChange()
                self.audioRouteFault = false
                self.playbackError = nil
                self.refreshPlaybackReadout()
            } catch {
                self.playbackError = "Audio route recovery failed."
            }
        }
#else
        audioRouteFault = false
        playbackError = nil
#endif
    }

    func checkpointForQuit() {
#if canImport(WiltedProducer)
        guard let playback else { return }
        Task { [weak self] in
            guard let self else { return }
            try? await playback.handlePauseOrQuit()
            await self.queueCurrentPlaybackCheckpoint()
        }
#endif
    }

#if canImport(WiltedProducer)
    private func update(_ status: PreparationStatus) {
        let phase: WiltedMacPreparation.Phase
        switch status.stage {
        case .preparing: phase = .preparing
        case .fetching: phase = .preparing
        case .extracting: phase = .extracting
        case .synthesizing: phase = .synthesizing
        case .assembling: phase = .assembling
        case .saving: phase = .saving
        case .completed: phase = .completed
        case .cancelled: phase = .cancelled
        case .failed: phase = .failed
        }
        preparation = WiltedMacPreparation(
            phase: phase, detail: status.detail, fraction: status.fraction, cancellable: status.cancellable
        )
    }

    @discardableResult
    private func queuePreparedPublication(itemID: ItemID, chunkedFile: AudioChunkedFile? = nil) async -> Bool {
        guard let store, let syncLifecycle,
              let article = try? await store.article(for: itemID),
              let stored = try? await store.readyRevision(for: itemID),
              let bytes = try? Data(contentsOf: stored.mediaURL),
              let chunkedFile = chunkedFile ?? (try? AudioChunking.chunk(bytes)) else { return false }
        let revisionResult = await syncLifecycle.queueRevision(stored.revision, chunkedFile: chunkedFile)
        let itemResult = await syncLifecycle.queueItem(article, currentRevisionID: stored.revision.revisionID)
        guard case .success = itemResult, case .success = revisionResult else { return false }
        return true
    }

    /// Re-queues ready revisions that are durable locally but absent from the outbound queue.
    ///
    /// Publication is otherwise queued only at the instant a preparation completes, so any
    /// enqueue that failed then stays unqueued forever: the revision cannot be re-derived by
    /// re-preparing it either, because the same text and settings derive the same immutable
    /// revision ID and `saveReadyRevision` rejects a second media path for it. Reconciling
    /// from durable local state before an upload is what makes the queue recoverable, and it
    /// matches W-INV-007's rule that local state, not CloudKit, is the source of truth.
    ///
    /// Membership is checked rather than sync status so a partially queued item repairs
    /// itself, and a revision whose media file is gone is skipped instead of failing the
    /// whole upload.
    private func queueUnpublishedReadyRevisions() async -> Bool {
        guard let store, syncLifecycle != nil else { return false }
        guard let articles = try? await store.articles() else { return false }
        let state = try? await store.syncRepositoryState()
        let queued = Set((state?.pendingChanges.map(\.recordID) ?? []) + Array(state?.remoteAcknowledgedRecordIDs ?? []))
        var didQueue = false
        for article in articles where !article.isDeleted {
            guard let stored = try? await store.readyRevision(for: article.itemID),
                  FileManager.default.fileExists(atPath: stored.mediaURL.path),
                  let bytes = try? Data(contentsOf: stored.mediaURL),
                  let chunkedFile = try? AudioChunking.chunk(bytes),
                  let revisionRecordID = try? WiltedRecordID.revision(article.itemID, stored.revision.revisionID) else { continue }
            let chunkRecordIDs = chunkedFile.manifest.chunks.compactMap {
                try? WiltedRecordID.revisionChunk(article.itemID, stored.revision.revisionID, index: $0.index)
            }
            let expected = Set([revisionRecordID] + chunkRecordIDs)
            guard !expected.isSubset(of: queued) else { continue }
            didQueue = await queuePreparedPublication(itemID: article.itemID, chunkedFile: chunkedFile) || didQueue
        }
        let hasSendablePending = (try? await store.syncRepositoryState())?.sendableChanges.isEmpty == false
        return didQueue || hasSendablePending
    }

    private func queueCurrentPlaybackCheckpoint() async {
        guard let store, let syncLifecycle, let playbackItemID = playback?.itemID,
              let playbackRevisionID = playback?.revisionID,
              let state = try? await store.playbackState(for: playbackItemID, revisionID: playbackRevisionID) else { return }
        let sidecar = try? await store.playbackSidecar(for: playbackItemID, revisionID: playbackRevisionID)
        let opaque = sidecar.map {
            WiltedOpaqueSidecar(changeTag: $0.changeTag, encodedSystemFields: $0.encodedSystemFields)
        }
        _ = await syncLifecycle.queuePlayback(state, sidecar: opaque)
    }

    /// Removes an article from the library.
    ///
    /// Marks the stored article deleted and records a local tombstone, which
    /// is what `refresh()` and the sync repository both already read. The
    /// library had no removal path at all, so anything prepared once —
    /// including a stray fixture row written before fixture mode moved to a
    /// temporary directory — stayed on screen permanently.
    ///
    /// Local only. Publishing the tombstone to CloudKit rides the existing
    /// pending-change path and is not triggered from here.
    func removeArticle(_ article: WiltedMacArticle) {
#if canImport(WiltedProducer)
        guard let store else { return }
        if selectedArticleID == article.id {
            selectedArticleID = nil
            isNowPlaying = false
            currentTranscript = nil
        }
        Task { [weak self] in
            guard let self else { return }
            guard let itemID = try? ItemID(rawValue: article.id) else { return }
            guard let stored = try? await store.articles().first(where: { $0.itemID == itemID }) else { return }
            guard let deleted = try? Article(
                itemID: stored.itemID, canonicalURL: stored.canonicalURL, title: stored.title,
                source: stored.source, author: stored.author, publishedTime: stored.publishedTime,
                createdAt: stored.createdAt, isDeleted: true
            ) else { return }
            try? await store.save(article: deleted)
            // Keyed by item, deliberately. `record(tombstone:)` upserts on `id`,
            // and this is the only path in the producer that writes one, so
            // removing the same article twice leaves one row rather than two.
            let tombstone = LocalLibraryTombstone(
                id: itemID.rawValue,
                itemID: itemID,
                requestedAt: Timestamp(Date())
            )
            try? await store.record(tombstone: tombstone)
            self.refresh()
        }
#endif
    }

    /// Fetches and stores the transcript for an already-prepared article.
    ///
    /// Transcript persistence shipped on 2026-08-23; anything prepared before
    /// that has audio and no text, and re-preparing cannot fix it because the
    /// revision ID is derived from the same content and `saveReadyRevision`
    /// refuses to re-point an existing revision. The text is re-extracted from
    /// the canonical URL and saved against the existing revision, so no new
    /// revision, media file, or synthesis run is created.
    func backfillCurrentTranscript() {
#if canImport(WiltedProducer)
        guard !isBackfillingTranscript, let store, let article = currentArticle else { return }
        isBackfillingTranscript = true
        transcriptBackfillStatus = "Fetching article text…"
        Task { [weak self] in
            guard let self else { return }
            defer { self.isBackfillingTranscript = false }
            guard let itemID = try? ItemID(rawValue: article.id),
                  let revision = try? await store.readyRevision(for: itemID) else {
                self.transcriptBackfillStatus = "This article has no saved audio to attach text to."
                return
            }
            do {
                let extracted = try await NativeArticleExtractor().extract(article.url) { stage, _ in
                    Task { @MainActor [weak self] in
                        self?.transcriptBackfillStatus = "Fetching article text: \(stage.rawValue)"
                    }
                }
                let oversized = extracted.body.utf8.count > Transcript.maximumTextUTF8Bytes
                let transcript = try Transcript(
                    itemID: itemID,
                    revisionID: revision.revision.revisionID,
                    availability: oversized ? .oversized : .available,
                    text: oversized ? nil : extracted.body,
                    updatedAt: Timestamp(Date())
                )
                try await store.save(transcript: transcript)
                await self.loadTranscript(itemID: itemID, revisionID: revision.revision.revisionID)
                self.transcriptBackfillStatus = oversized
                    ? "The article text is too large to store."
                    : nil
            } catch {
                // Named, not swallowed: the reader has to know whether to retry.
                self.transcriptBackfillStatus = Self.backfillFailureMessage(error)
            }
        }
#endif
    }

    /// A sentence a reader can act on, never a raw error dump.
    ///
    /// `ArticleExtractionError` already writes for people, so it passes through.
    /// Transport failures are matched by code rather than rendered: a `URLError`
    /// only has readable `localizedDescription` when URLSession populated it, and
    /// otherwise falls back to `The operation couldn't be completed.
    /// (NSURLErrorDomain error -1009.)`. Everything unmatched collapses to one
    /// generic line, because printing a domain and code into the player is the
    /// same defect as printing `1743` for a duration.
    static func backfillFailureMessage(_ error: Error) -> String {
#if canImport(WiltedProducer)
        if let extraction = error as? ArticleExtractionError, let text = extraction.errorDescription {
            return text
        }
#endif
        if let url = error as? URLError {
            switch url.code {
            case .notConnectedToInternet, .networkConnectionLost:
                return "Wilted could not reach the article. Check your connection and try again."
            case .timedOut:
                return "The article server did not respond in time. Try again."
            case .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed:
                return "Wilted could not reach that site."
            default:
                break
            }
        }
        return "Could not fetch the article text. Check the link and try again."
    }

    /// Reloads the preparation run history behind the Processor destination.
    func refreshProcessorRuns() {
#if canImport(WiltedProducer)
        guard let store else { return }
        Task { [weak self] in
            guard let self else { return }
            guard let runs = try? await store.preparationRuns() else { return }
            let titles = Dictionary(
                uniqueKeysWithValues: ((try? await store.articles()) ?? [])
                    .map { ($0.itemID.rawValue, ($0.title, $0.source)) }
            )
            self.processorRuns = runs.map { run in
                let known = titles[run.itemID.rawValue]
                let outcome: WiltedMacProcessorRun.Outcome = if !run.isTerminal {
                    .running
                } else {
                    switch run.outcome {
                    case .succeeded: .succeeded
                    case .cancelled: .cancelled
                    default: .failed
                    }
                }
                return WiltedMacProcessorRun(
                    id: run.requestID,
                    // A run that failed before extraction never learned a
                    // title, so the item identity is all there is to name it.
                    title: known?.0 ?? "Unknown article",
                    source: known?.1 ?? run.itemID.rawValue,
                    stage: run.stage.rawValue,
                    detail: run.failure?.message ?? run.detail,
                    fraction: run.fraction,
                    outcome: outcome,
                    updatedAt: run.updatedAt.date
                )
            }
        }
#endif
    }

    private func refresh() {
        guard let store else { return }
        Task { [weak self] in
            guard let self else { return }
            guard let stored = try? await store.articles() else { return }
            var values: [WiltedMacArticle] = []
            for article in stored where !article.isDeleted {
                let revision = try? await store.readyRevision(for: article.itemID)
                values.append(WiltedMacArticle(
                    id: article.itemID.rawValue, title: article.title, source: article.source,
                    url: article.canonicalURL, isReady: revision != nil,
                    durationSeconds: revision?.revision.durationSeconds
                ))
            }
            self.articles = values
        }
    }

    private func installFixture(ready: Bool, preparing: Bool = false) {
        if preparing {
            let url = URL(string: "https://example.test/wilted-preparing-fixture")!
            guard let itemID = try? ItemID.derive(from: url) else { return }
            articles = [WiltedMacArticle(
                id: itemID.rawValue, title: "Preparing article", source: "Example source",
                url: url, isReady: false, durationSeconds: nil
            )]
            return
        }
        guard ready, let store else { return }
        let url = URL(string: "https://example.test/wilted-fixture")!
        guard let itemID = try? ItemID.derive(from: url),
              let article = try? Article(
                itemID: itemID, canonicalURL: url, title: "Fixture article", source: "Example source",
                createdAt: Timestamp(Date())
              ),
              let revisionID = try? RevisionID(rawValue: "fixture-revision"),
              let revision = try? AudioRevision(
                itemID: itemID, revisionID: revisionID, durationSeconds: 120, byteCount: 1,
                contentHash: "sha256:\(String(repeating: "0", count: 64))", mediaType: "audio/mp4",
                createdAt: Timestamp(Date()), schemaVersion: 1
              ) else { return }
        let mediaURL = URL(fileURLWithPath: "/tmp/wilted-fixture.m4a")
        fixtureRevision = StoredAudioRevision(revision: revision, mediaURL: mediaURL)
        let fixtureTranscript = try? Transcript(
            itemID: itemID,
            revisionID: revisionID,
            availability: .available,
            text: "This fixture transcript proves saved article text stays readable while listening.",
            updatedAt: Timestamp(Date())
        )
        articles = [WiltedMacArticle(
            id: itemID.rawValue, title: article.title, source: article.source,
            url: article.canonicalURL, isReady: true, durationSeconds: revision.durationSeconds
        )]
        Task {
            try? await store.save(article: article)
            if let fixtureTranscript {
                try? await store.saveReadyRevision(revision, mediaURL: mediaURL, transcript: fixtureTranscript)
            } else {
                try? await store.saveReadyRevision(revision, mediaURL: mediaURL)
            }
        }
    }

    private func seek(by seconds: TimeInterval) {
        guard let playback else { return }
        Task { [weak self] in
            guard let self else { return }
            do {
                try await playback.seek(by: seconds)
                self.isPlaying = playback.isPlaying
                self.refreshPlaybackReadout()
                await self.queueCurrentPlaybackCheckpoint()
            } catch { self.reportAudioRouteFault("Playback is unavailable.") }
        }
    }

    private static func stateDirectory(fixtureMode: Bool) -> URL {
        if fixtureMode {
            return FileManager.default.temporaryDirectory
                .appendingPathComponent(
                    "wilted-ui-fixture-\(ProcessInfo.processInfo.processIdentifier)", isDirectory: true
                )
        }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("Wilted", isDirectory: true)
    }
#endif
}

#if canImport(WiltedProducer)
@MainActor
private final class WiltedFixturePlaybackBackend: PlaybackBackend {
    var duration: TimeInterval = 120
    var currentTime: TimeInterval = 0
    var isPlaying = false
    func load(url: URL) throws { _ = url }
    func play() -> Bool { isPlaying = true; return true }
    func pause() { isPlaying = false }
    func stop() { isPlaying = false }
}
#endif
