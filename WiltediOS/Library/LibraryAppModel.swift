import Combine
import Foundation
import WiltedDomain
import WiltedLibrary

/// What a recovering account gives back: a fresh store for the new account, plus the
/// stream that announces an account change needing review.
struct LibraryAccountRecovery: Sendable {
    let quarantineEvents: AsyncStream<Void>
    /// Discards everything tied to the previous account and returns an empty store.
    let recover: @Sendable () async throws -> any LibraryStore
}

/// Owns the iPhone's library replica: fetches on launch, foreground, pull-to-refresh and
/// silent push, and exposes queue-ordered rows plus the Mac's last checkpoint per entry. The
/// phone lists only what the Mac has prepared; `visibleRows` is that Larder in the play order, after filter
/// and search.
/// The iPhone never writes library state; the Mac is the single writer.
@MainActor
final class LibraryAppModel: ObservableObject {
    /// Every entry the Mac has queued, in its order, prepared or not. The list shows `visibleRows`.
    @Published private(set) var queued: [LibraryRow] = [] {
        didSet { logicalEpisodeRowsDirty = true }
    }
    /// Entries whose media offer from the Mac says the audio is prepared: `ready` (fetchable now) or
    /// `available` (prepared on the Mac; asking for it starts the upload).
    @Published private(set) var readyOffers: Set<ItemID> = []
    private(set) var cachedDisplayIDs: Set<ItemID> = []
    var completedDisplayRows: [LibraryRow]?
    var completedDisplayContent: LibrarySnapshot? {
        didSet {
            completedDisplayGroupsByMember = LibraryRowBuilder.associationsByMember(in: completedDisplayContent)
        }
    }
    private(set) var completedDisplayGroupsByMember: [ItemID: LibraryEpisodeAssociation] = [:]
    private var displayContext: (generation: UInt64, admissionRevision: UInt64)?
    @Published var filter: LibraryFilter = .all
    /// Which kind the Larder shows; kept across launches. A stored value this build does not know reads as All.
    @Published var kindFilter: LibraryKindFilter = .all {
        didSet { if kindFilter != oldValue { preferences.set(kindFilter.rawValue, forKey: LibraryKindFilter.storageKey) } }
    }
    @Published var searchText = ""
    /// The most authoritative record per entry from any device other than this one.
    @Published private(set) var checkpoints: [ItemID: ObservedPlayback] = [:] {
        didSet { logicalEpisodeRowsDirty = true }
    }
    /// In-progress episodes (position past the start, not completed) from this phone, the Mac and any
    /// other device, with when each was last played. Every listing puts these first.
    @Published private(set) var progress: [ItemID: EpisodeProgress] = [:]
    /// Episodes played to their end but not marked completed, with when; they list and auto-continue as completed.
    @Published private(set) var finished: [ItemID: Date] = [:]
    /// Episodes that played out on this phone since launch, with when. The feed's length can differ from
    /// the file's, so a position at the file's end is not always at the feed's end; this is exact.
    var playedOut: [ItemID: Date] = [:]
    @Published private(set) var isRefreshing = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var lastSynchronizedAt: Date?
    /// Successful local mirror installation, even if transport token acknowledgement later failed.
    @Published private(set) var lastCacheCommittedAt: Date?
    /// Account-associated author evidence; never describes exact displayed snapshot equality.
    @Published private(set) var lastObservedPublication: LibraryPublication?
    @Published private(set) var accountQuarantined = false
    /// On-demand audio state per entry; an entry with no value is `.available`. Written by
    /// `LibraryAppModel+Media`, which owns the request, download, verify and cache flow.
    @Published var media: [ItemID: LibraryMediaState] = [:]
    /// True once the Mac has linked this device (`LibraryAppModel+DeviceLink`): until then it has not
    /// read this device's requests, so the Larder offers no download. Kept across launches; never cleared
    /// by a failed read, only by an account change.
    @Published var deviceLinked = false
    /// This phone's own lifetime totals, shown in Settings. Never synced.
    let phoneStats: LibraryPhoneStatsStore
    /// What "Continue from Mac" would do right now; nil when no other device outranks this one.
    /// Written by `LibraryAppModel+Handoff`.
    @Published var continuation: LibraryContinuation?
    /// Why the phone stopped or could not hand over, in words; nil when there is nothing to say.
    @Published var handoffMessage: String?
    /// Decisions sent to the Mac and not yet settled; written by `LibraryAppModel+Decisions`.
    /// They only shape the display; the phone never writes library state. Unsent ones are saved in the outbox.
    @Published var decisions: [PendingDecision] = [] {
        didSet { episodeProjectionDirty = true; persistOutbox() }
    }
    /// Why a decision was rolled back, per entry, in words.
    @Published var decisionNotices: [ItemID: String] = [:]
    /// Adds sent to the Mac (a podcast to follow, an article to add) and not yet cleared; written by
    /// `LibraryAppModel+Add`. Kept apart from `decisions`: an add names an item the Mac does not hold yet.
    /// Unsent ones are saved in the outbox.
    @Published var adds: [PendingAdd] = [] {
        didSet { persistOutbox() }
    }
    /// Why the last add was not sent, in words; nil when it was.
    @Published var addNotice: String?
    /// The add actions the Mac says it applies (`supportedIntentActions`); nil until read.
    @Published var macAddActions: Set<String>?
    /// True when the last read of the Mac's published actions failed.
    @Published var macAddCheckFailed = false
    /// What is typed in the Add sheet, kept so closing the sheet does not lose it.
    @Published var addDraft = ""

    /// Why iCloud calls are paused (rate limited, unavailable) and until when; nil while they run.
    /// Set by the shared `TransportGate`, cleared by the next call that succeeds. Written by
    /// `LibraryAppModel+Throttle`.
    @Published var throttleState: TransportGateState?

    /// True while a refresh runs after the gate's wait has passed: the banner shows "Retrying now…"
    /// with an activity indicator instead of the old time. Written by `LibraryAppModel+ThrottleRetry`.
    @Published var throttleRetrying = false
    /// When the next retry is scheduled, once the gate's own time has passed without the retry
    /// clearing it (a probe that failed for another reason). Nil while the gate's `retryAt` is the time.
    var throttleAttemptAt: Date?
    /// The scheduled retry; replaced whenever the gate closes again, cancelled when it reopens.
    var throttleRetryTask: Task<Void, Never>?
    /// Waits for the retry time; injected so tests run without waiting.
    let throttleSleep: @Sendable (TimeInterval) async throws -> Void

    /// The line for the Sync status when `throttleState` is set, in words: the time while waiting
    /// ("iCloud is rate limiting sync. Retrying at 11:26:30."), "Retrying now…" while retrying, and
    /// never a time that has passed. Nil while nothing is paused.
    var throttleNotice: String? {
        throttleState?.noticeWithResumeTime(now: now(), retrying: throttleRetrying, attemptAt: throttleAttemptAt)
    }

    /// Wraps the transport this model was given, so every call the phone makes (refresh, handoff,
    /// media, decisions) goes through one gate.
    let transport: any LibraryTransport
    let throttleGate: TransportGate
    let deviceID: String
    /// "iPad" or "iPhone"; the model family only, which is all the Mac is told and the notice says.
    let deviceKind: String
    /// The newest device link and the announcement bookkeeping; owned by `LibraryAppModel+DeviceLink`.
    let deviceLinkState = LibraryDeviceLinkState()
    let now: @Sendable () -> Date
    let mediaCache: any LibraryMediaCache
    let mediaTiming: LibraryMediaTiming
    /// This device's side of live handoff; the only writer of its playback records.
    let coordinator: HandoffCoordinator
    let handoffTiming: LibraryHandoffTiming
    let decisionTiming: LibraryDecisionTiming
    /// The mirrored content as last fetched, before any optimistic overlay.
    var decisionContent = LibrarySnapshot() {
        didSet { episodeAssociationsDirty = true; episodeProjectionDirty = true }
    }
    var episodeAssociationsDirty = true
    var episodeProjectionDirty = true
    var episodeAssociationGroups: [LibraryEpisodeAssociation] = []
    var episodeGroupsByMember: [ItemID: LibraryEpisodeAssociation] = [:]
    var projectedEpisodeGroupsByMember: [ItemID: LibraryEpisodeAssociation] = [:]
    var projectedEpisodeContent = LibrarySnapshot()
    var logicalEpisodeRowsDirty = true
    var projectedLogicalEpisodeRows: [LibraryRow] = []
    var projectedLogicalRowsByID: [ItemID: LibraryRow] = [:]
    var episodeAssociationResolutionCount = 0

    /// Entries some device has started, from the last device-record fetch.
    var startedEntries: Set<ItemID> = [] {
        didSet { logicalEpisodeRowsDirty = true }
    }
    /// The phone's one sync tick and what its rounds track; owned by `LibraryAppModel+SyncTick`.
    let tickState = LibraryTickState()
    /// Mutable handoff bookkeeping, owned by `LibraryAppModel+Handoff`.
    let handoffState = LibraryHandoffState()
    /// Which start command owns playback right now, owned by `LibraryPlaybackCommand`.
    let commandState = LibraryStartCommandState()
    /// The start the listener is waiting on, or the one that just failed; nil when neither.
    @Published var playbackCommand: LibraryPlaybackCommandStatus?
    /// Entry durations from the last sync, to clamp a resumed position.
    var entryDurations: [ItemID: Double] = [:]
    /// One live request per entry; the run id lets a cancelled run detect that it was replaced.
    var mediaRuns: [ItemID: LibraryMediaRun] = [:]
    /// Verified files whose `mediaCached` acknowledgement the Mac does not have yet, with the one intent
    /// every retry sends. Saved in the outbox.
    var unacknowledgedMedia: [ItemID: LibraryIntent] = [:] {
        didSet { persistOutbox() }
    }
    /// The unsent intents on disk; owned by `LibraryAppModel+Outbox`.
    let outboxState: LibraryOutboxState
    var mediaRevocations: Set<ItemID> = []
    @Published var undoableCompletion: ItemID?
    /// Transcripts for audio on the phone, keyed by entry; each is for the cached revision.
    @Published var transcripts: [ItemID: LibraryTranscript] = [:]
    /// One load per entry, so a cancelled or replaced load can never write for its successor.
    var transcriptRuns: [ItemID: LibraryTranscriptRun] = [:]
    /// When a revision's missing transcript was last re-requested this session, to space retries.
    var transcriptRetried: [ItemID: (revision: RevisionID, at: Date)] = [:]
    let clockFormat: LibraryClockFormat
    let preferences: UserDefaults
    private let recovery: LibraryAccountRecovery?
    var playbackStoreIdentity: ObjectIdentifier { ObjectIdentifier(store as AnyObject) }
    func mediaStoreState() async -> LibraryStoreState { await store.state() }
    func mediaAdmissionFailed(_ message: String) { errorMessage = message }
    private var store: any LibraryStore
    private var reconciler: LibraryReconciler
    private var refreshTask: Task<Void, Never>?
    var hasPendingRefresh: Bool { refreshTask != nil }
    private var refreshRequested = false
    private(set) var started = false
    @Published private(set) var localStateLoaded = false

    init(
        transport: any LibraryTransport,
        store: any LibraryStore = InMemoryLibraryStore(),
        deviceID: String,
        deviceKind: String? = nil,
        recovery: LibraryAccountRecovery? = nil,
        mediaCache: (any LibraryMediaCache)? = nil,
        mediaTiming: LibraryMediaTiming = LibraryMediaTiming(),
        handoffTiming: LibraryHandoffTiming = LibraryHandoffTiming(),
        decisionTiming: LibraryDecisionTiming = LibraryDecisionTiming(),
        preferences: UserDefaults = .standard,
        ownPositionsURL: URL? = nil,
        outboxURL: URL? = nil,
        now: @escaping @Sendable () -> Date = { Date() },
        timeZone: TimeZone = .current,
        throttleSleep: @escaping @Sendable (TimeInterval) async throws -> Void = { try await Task.sleep(for: .seconds($0)) }
    ) {
        self.throttleSleep = throttleSleep
        let relay = LibraryThrottleRelay()
        let gate = TransportGate(clock: now, onChange: { state in
            Task { @MainActor in relay.model?.throttleChanged(state) }
        })
        let transport = ThrottledLibraryTransport(wrapping: transport, gate: gate)
        self.throttleGate = gate
        self.transport = transport
        self.mediaCache = mediaCache ?? FileMediaCache(rootURL: FileMediaCache.defaultRoot())
        self.mediaTiming = mediaTiming
        self.handoffTiming = handoffTiming
        self.decisionTiming = decisionTiming
        self.coordinator = HandoffCoordinator(
            transport: transport, deviceID: deviceID, clock: now, sleep: handoffTiming.settleSleep)
        self.preferences = preferences
        handoffState.ownPositionStore = LibraryOwnPositionStore(url: ownPositionsURL)
        self.outboxState = LibraryOutboxState(outbox: LibraryIntentOutbox(url: outboxURL))
        self.phoneStats = LibraryPhoneStatsStore(defaults: preferences)
        self.store = store
        self.deviceID = deviceID
        self.deviceKind = deviceKind ?? Self.currentDeviceKind
        self.recovery = recovery
        self.now = now
        self.clockFormat = LibraryClockFormat(timeZone: timeZone)
        self.reconciler = LibraryReconciler(transport: transport, store: store)
        kindFilter = LibraryKindFilter.stored(preferences.string(forKey: LibraryKindFilter.storageKey))
        relay.model = self
        restoreOutbox()
    }

    /// Launch entry point: watches for account changes once, then fetches.
    func start() async {
        if !started {
            started = true
            if let events = recovery?.quarantineEvents {
                Task { [weak self] in
                    for await _ in events {
                        guard let self else { return }
                        self.accountQuarantined = true
                        await self.loadLocalState()
                    }
                }
            }
        }
        await loadLocalState()
        // The first sync is a full one; with the tick running it also restarts the 30 s timer.
        tickState.forceFull = true
        await updateSyncTick()
        await pullToRefresh()
    }

    /// Shows the persisted library, then the audio already on the phone, with no network call: a launch with no
    /// signal still lists and plays what is downloaded (W-INV-040). `start()`'s sync then sends acknowledgements.
    func loadLocalState() async {
        let saved = await store.state()
        verifyOutboxOwner(saved.ownerToken)
        restoreDeviceLink(owner: saved.ownerToken)
        applyStoreMetadata(saved)
        _ = await bindMediaOwner()
        displayContext = (await transport.operationGeneration(), saved.displayAdmissionRevision)
        let content = saved.content
        entryDurations = content.entries.compactMapValues(\.durationSeconds)
        decisionContent = content
        // The phone's own last positions, so an offline launch resumes where it left off.
        if handoffState.ownPositions.isEmpty {
            let saved = handoffState.ownPositionStore.load()
            let own = saved.positions.filter { $0.value.record.deviceID == deviceID }
            handoffState.unpublished = saved.unpublished.filter { own[$0.key] != nil }
            handoffState.ownPositions = own
            handoffState.savedCheckpoints = saved.checkpoints.filter { $0.value.record.deviceID != deviceID }
            if checkpoints.isEmpty { checkpoints = handoffState.savedCheckpoints }
        }
        rebuildRows()
        await refreshMediaFromCache(acknowledging: false)
        localStateLoaded = true
    }

    /// Fetches now. Calls made while a fetch is running share it and queue exactly one rerun,
    /// so a burst of pushes never runs overlapping syncs.
    func refresh(_ plan: LibraryRefreshPlan = .full) async {
        if let running = refreshTask {
            // A round of the tick joins the running fetch; only a full one asks for another pass.
            if plan.isFull { refreshRequested = true }
            await running.value
            return
        }
        let task = Task { [weak self] in
            var next = plan
            repeat {
                guard let self else { return }
                self.refreshRequested = false
                await self.performRefresh(next)
                next = .full
            } while self?.refreshRequested == true
            self?.objectWillChange.send()
            self?.refreshTask = nil
        }
        objectWillChange.send()
        refreshTask = task
        await task.value
    }

    /// A silent push arrived; returns true when the visible library changed.
    func handleSilentPush() async -> Bool {
        // The mirror and offers, not the filtered view: a push's answer must not depend on search or filter.
        let before = (queued, readyOffers)
        if tickState.tick != nil {
            // The tick reads the state in its next round; a round now only if one is due.
            tickState.forceFull = true
            guard await tickState.tick?.requestSoon() == true else { return false }
        } else {
            await refresh()
        }
        return before != (queued, readyOffers)
    }

    /// Discards the quarantined account's replica and starts from an empty one.
    func recoverFromAccountChange() async {
        guard let recovery else { return }
        let fresh: any LibraryStore
        do { fresh = try await recovery.recover() }
        catch {
            accountQuarantined = true
            errorMessage = "Account recovery failed. The saved library is still held."
            return
        }
        store = fresh
        reconciler = LibraryReconciler(transport: transport, store: fresh)
        accountQuarantined = false
        queued = []
        readyOffers = []
        cachedDisplayIDs = []
        displayContext = nil
        checkpoints = [:]
        handoffState.savedCheckpoints = [:]
        handoffState.ownPositions = [:]
        continuation = nil
        completedDisplayRows = nil
        completedDisplayContent = nil
        discardDecisionsAfterAccountChange()
        discardAddsAfterAccountChange()
        await discardMediaAfterAccountChange()
        discardDeviceLinkAfterAccountChange()
        await refresh()
    }

    private func performRefresh(_ plan: LibraryRefreshPlan) async {
        if !localStateLoaded { await loadLocalState() }
        let priorQueue = Set(decisionContent.queue.map(\.entryID))
        let roundStore = store, roundReconciler = reconciler
        let generation = await transport.operationGeneration()
        // A relaunch restores the engine without an account event, so the saved library's owner is unverified
        // until something checks it; the first check below would otherwise stop every round of this launch.
        // A check that finds another account moves the generation, so this round still stops.
        if await roundStore.state().ownerToken != nil, await transport.verifiedOwnerToken() == nil {
            await transport.verifyOwner()
        }
        var reportedStop = false
        func current() async -> Bool {
            let liveGeneration = await transport.operationGeneration()
            let state = await roundStore.state()
            let owner = await transport.verifiedOwnerToken()
            let finalGeneration = await transport.operationGeneration()
            let stop = LibraryRoundStop.check(
                cancelled: Task.isCancelled, generationMatches: liveGeneration == generation && finalGeneration == generation,
                savedOwner: state.ownerToken, verifiedOwner: owner, reviewHold: state.reviewHold, quarantined: accountQuarantined,
                sameStore: ObjectIdentifier(store as AnyObject) == ObjectIdentifier(roundStore as AnyObject))
            if let stop, !reportedStop { reportedStop = true; stop.log() }
            return stop == nil
        }
        guard await current() else { return }
        if plan.readsState && plan.readsOffers {
            do { try await roundStore.beginDisplayRefresh(transport: transport, expectedGeneration: generation) }
            catch { errorMessage = Self.message(for: error); return }
        }
        guard await current() else { return }
        let startingState = await roundStore.state()
        guard await current() else { return }
        applyStoreMetadata(startingState)
        if plan.showsProgress { isRefreshing = true }
        let isRetry = throttleIsDue
        if isRetry { throttleRetrying = true }
        defer { if plan.showsProgress { isRefreshing = false }; if isRetry { throttleRetrying = false } }
        var failure: (any Error)?
        if plan.readsState {
            if case let .failure(error) = await roundReconciler.synchronize() { failure = error }
            guard await current() else { return }
        }
        var options: LibraryPollOptions = [.deviceRecords, .deviceLink]
        if plan.readsOffers { options.insert(.offers) }
        if !decisions.isEmpty || hasAddAwaitingAnswer { options.insert(.outcomes) }
        let beforePoll = await roundStore.state()
        guard await current() else { return }
        var polled: LibraryPollResult?
        do {
            let result = try await transport.poll(options)
            let owner = await transport.verifiedOwnerToken()
            guard await current(), beforePoll.ownerToken == nil || beforePoll.ownerToken == owner else { return }
            // The link and the announcement come first: the offer steps below can end the round early,
            // and a phone whose link waited behind them stayed "Connecting to your Mac" for good.
            applyPolledDeviceLink(result, owner: beforePoll.ownerToken)
            await announceDeviceIfNeeded(linkRead: result.deviceLinkRead)
            guard await current() else { return }
            if let offers = result.offers {
                try await roundStore.recordDisplayOffers(offers, transport: transport,
                    expectedGeneration: generation, expectedRevision: beforePoll.revision)
                guard await current() else { return }
                if let context = await bindMediaOwner() {
                    guard await applyMediaOffers(offers, context: context) else { return }
                }
                noteOffers(offers); readyOffers = Set(offers.filter(\.isPrepared).map(\.entryID))
                for entryID in readyOffers where media[entryID] == .notPrepared { media[entryID] = nil }
            }
            polled = result
        } catch { if failure == nil { failure = error } }
        guard await current() else { return }
        if failure == nil, plan.readsState && plan.readsOffers {
            do {
                let revision = await roundStore.state().revision
                guard await current() else { return }
                try await roundStore.completeDisplayRefresh(transport: transport, expectedGeneration: generation, expectedRevision: revision)
            } catch { failure = error }
        }
        let saved = await roundStore.state()
        guard await current() else { return }
        applyStoreMetadata(saved)
        if let context = await bindMediaOwner() {
            guard await revokeRemovedQueueMedia(previous: priorQueue, current: Set(saved.content.queue.map(\.entryID)), content: saved.content, context: context) else { return }
        }
        displayContext = (generation, saved.displayAdmissionRevision)
        entryDurations = saved.content.entries.compactMapValues(\.durationSeconds)
        decisionContent = saved.content
        if let records = polled?.records {
            checkpoints = Self.checkpoints(from: records, excluding: deviceID)
            handoffState.savedCheckpoints = checkpoints
            var own = Self.ownPositions(from: records, deviceID: deviceID)
            for entryID in handoffState.unpublished.keys {
                if let local = handoffState.ownPositions[entryID] { own[entryID] = local }
            }
            handoffState.ownPositions = own; startedEntries = Self.startedEntries(from: records)
        }
        rebuildRows(); await refreshMediaFromCache()
        guard await current() else { return }
        if let records = polled?.records {
            await updateContinuation(from: records)
            guard await current() else { return }
            await observeHandoff(records)
            guard await current() else { return }
        }
        await resolveDecisions(outcomes: polled?.outcomes ?? [])
        await resolveAdds(outcomes: polled?.outcomes ?? [])
        guard await current() else { return }
        if let failure {
            if !(failure is TransportThrottled) { LibraryRoundStop.logFailure(failure) }
            errorMessage = failure is TransportThrottled ? nil : Self.message(for: failure)
        }
        else if plan.readsState { errorMessage = nil; lastSynchronizedAt = now() }
        // A quiet offer-only success cannot clear an unresolved library-state failure.
    }

    private func applyStoreMetadata(_ saved: LibraryStoreState) {
        outboxOwnerChanged(saved.ownerToken)
        accountQuarantined = accountQuarantined || saved.reviewHold
        cachedDisplayIDs = saved.displayPreparedIDs ?? []
        if saved.ownerToken != nil, saved.displayRefreshPending, let content = saved.completedDisplay {
            completedDisplayContent = content
            let ids = saved.completedDisplayPreparedIDs ?? []
            completedDisplayRows = LibraryRowBuilder.rows(content: content, checkpoints: checkpoints, clock: clockFormat, started: startedEntries).filter { ids.contains($0.id) }
        } else { completedDisplayRows = nil; completedDisplayContent = nil }
        lastCacheCommittedAt = saved.cacheCommittedAt
        lastObservedPublication = saved.ownerToken == nil ? nil : saved.observedPublication
        if saved.reviewHoldPersistenceFailed {
            errorMessage = "Account review is required. The hold could not be saved; keep sync paused."
        }
    }

    /// Projects the fetched content, with unsettled decisions laid over it, into queue-ordered rows.
    func rebuildRows() {
        refreshEpisodeProjection()
        let visible = projectedEpisodeContent
        queued = LibraryRowBuilder.rows(
            content: visible, checkpoints: checkpoints, clock: clockFormat, started: startedEntries)
        refreshProgress()
    }

    /// Recomputes `progress` from every device's records and what the player has loaded.
    func refreshProgress() { refreshProgress(playingEntry: handoffState.player?.item?.entryID) }

    func refreshProgress(playingEntry: ItemID?) {
        refreshEpisodeProjection()
        let completed = Set(projectedEpisodeContent.listening.filter { $0.value.isCompleted }.keys)
        let player = handoffState.player
        let playing = playingEntry.map { (id: $0, position: player?.position ?? 0, isPlaying: player?.isPlaying ?? false) }
        let next = InProgressOrdering.progress(
            checkpoints: checkpoints, ownPositions: handoffState.ownPositions, completed: completed,
            durations: entryDurations, nowPlaying: playing, now: now().addingTimeInterval(handoffState.clockOffset))
        if next != progress { progress = next }
        // Playing an episode again takes it out of the played-out set; its new position decides from here.
        if let loaded = player?.item?.entryID, player?.status != .ended { playedOut[loaded] = nil }
        var ended = InProgressOrdering.finished(
            checkpoints: checkpoints, ownPositions: handoffState.ownPositions, completed: completed,
            durations: entryDurations, nowPlaying: playing, now: now().addingTimeInterval(handoffState.clockOffset))
        for (id, at) in playedOut where !completed.contains(id) { ended[id] = max(ended[id] ?? .distantPast, at) }
        if ended != finished { finished = ended }
    }

    /// Stops listing `entryID` until a refresh sees the Mac offer it again.
    func dropOffer(_ entryID: ItemID) {
        readyOffers.remove(entryID)
        cachedDisplayIDs.remove(entryID)
        guard let context = displayContext else { return }
        let store = store, transport = transport
        let identity = ObjectIdentifier(store as AnyObject)
        Task { [weak self] in
            do {
                try await store.removeDisplayOffer(entryID, transport: transport,
                    expectedGeneration: context.generation, expectedDisplayRevision: context.admissionRevision)
                guard let self, ObjectIdentifier(self.store as AnyObject) == identity,
                      self.displayContext?.generation == context.generation,
                      self.displayContext?.admissionRevision == context.admissionRevision else { return }
                self.cachedDisplayIDs.remove(entryID)
            } catch {
                guard let self, ObjectIdentifier(self.store as AnyObject) == identity,
                      self.displayContext?.generation == context.generation,
                      self.displayContext?.admissionRevision == context.admissionRevision else { return }
                self.errorMessage = Self.message(for: error)
            }
        }
    }

    /// The winning record per entry among every device except this one, across both
    /// playback channels, ranked by `HandoffResolver` (epoch, then server date).
    static func checkpoints(from records: LibraryDeviceRecords, excluding deviceID: String) -> [ItemID: ObservedPlayback] {
        let others = (records.nowPlaying + records.progress).filter { $0.record.deviceID != deviceID }
        return Dictionary(grouping: others, by: { $0.record.entryID }).compactMapValues(HandoffResolver.winner(among:))
    }

    /// This device's own progress record per entry, as the server last held it.
    static func ownPositions(from records: LibraryDeviceRecords, deviceID: String) -> [ItemID: ObservedPlayback] {
        Dictionary(
            records.progress.filter { $0.record.deviceID == deviceID }.map { ($0.record.entryID, $0) },
            uniquingKeysWith: { first, _ in first })
    }

    private static func message(for error: Error) -> String {
        switch error {
        case LibraryTransportError.transport(let text): return text
        case LibraryTransportError.superseded: return "iCloud account changed. Sync was cancelled."
        default: return "Sync failed: \(error.localizedDescription)"
        }
    }
}
