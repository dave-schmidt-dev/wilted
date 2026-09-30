import Combine
import Foundation
import WiltedDomain
import WiltedLibrary

/// What a recovering account gives back: a fresh store for the new account, plus the
/// stream that announces an account change needing review.
struct LibraryAccountRecovery: Sendable {
    let quarantineEvents: AsyncStream<Void>
    /// Discards everything tied to the previous account and returns an empty store.
    let recover: @Sendable () async -> any LibraryStore
}

/// Owns the iPhone's library replica: fetches on launch, foreground, pull-to-refresh and
/// silent push, and exposes queue-ordered rows plus the Mac's last checkpoint per entry. The
/// phone lists only what the Mac has prepared; `visibleRows` is that Larder after sort, filter
/// and search.
/// The iPhone never writes library state; the Mac is the single writer.
@MainActor
final class LibraryAppModel: ObservableObject {
    /// Every entry the Mac has queued, in its order, prepared or not. The list shows `visibleRows`.
    @Published private(set) var queued: [LibraryRow] = []
    /// Entries whose media offer from the Mac says the audio is prepared: `ready` (fetchable now) or
    /// `available` (prepared on the Mac; asking for it starts the upload).
    @Published private(set) var readyOffers: Set<ItemID> = []
    /// Larder ordering, remembered across launches. `custom` is the Mac's queue order.
    @Published var sort: LibrarySortOrder {
        didSet { if sort != oldValue { preferences.set(sort.rawValue, forKey: LibrarySortOrder.preferenceKey) } }
    }
    @Published var filter: LibraryFilter = .all
    @Published var searchText = ""
    /// The most authoritative record per entry from any device other than this one.
    @Published private(set) var checkpoints: [ItemID: ObservedPlayback] = [:]
    @Published private(set) var isRefreshing = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var lastSynchronizedAt: Date?
    @Published private(set) var accountQuarantined = false
    /// On-demand audio state per entry; an entry with no value is `.available`. Written by
    /// `LibraryAppModel+Media`, which owns the request, download, verify and cache flow.
    @Published var media: [ItemID: LibraryMediaState] = [:]
    /// The Mac's lifetime statistics as last read; nil until the Mac has published. Read-only here.
    @Published var lifetimeStats: LibraryStats?
    /// When a Mac last wrote a device record, by the server clock; shown in Settings.
    @Published var macLastSeenAt: Date?
    /// What "Continue from Mac" would do right now; nil when no other device outranks this one.
    /// Written by `LibraryAppModel+Handoff`.
    @Published var continuation: LibraryContinuation?
    /// Why the phone stopped or could not hand over, in words; nil when there is nothing to say.
    @Published var handoffMessage: String?
    /// Decisions sent to the Mac and not yet settled; written by `LibraryAppModel+Decisions`.
    /// They only shape the display; the phone never writes library state.
    @Published var decisions: [PendingDecision] = []
    /// Why a decision was rolled back, per entry, in words.
    @Published var decisionNotices: [ItemID: String] = [:]

    let transport: any LibraryTransport
    let deviceID: String
    let now: @Sendable () -> Date
    let mediaCache: any LibraryMediaCache
    let mediaTiming: LibraryMediaTiming
    /// This device's side of live handoff; the only writer of its playback records.
    let coordinator: HandoffCoordinator
    let handoffTiming: LibraryHandoffTiming
    let decisionTiming: LibraryDecisionTiming
    /// The mirrored content as last fetched, before any optimistic overlay.
    var decisionContent = LibrarySnapshot()
    /// Entries some device has started, from the last device-record fetch.
    var startedEntries: Set<ItemID> = []
    var decisionPoll: Task<Void, Never>?
    /// Mutable handoff bookkeeping, owned by `LibraryAppModel+Handoff`.
    let handoffState = LibraryHandoffState()
    /// Entry durations from the last sync, to clamp a resumed position.
    var entryDurations: [ItemID: Double] = [:]
    /// One live request per entry; the run id lets a cancelled run detect that it was replaced.
    var mediaRuns: [ItemID: LibraryMediaRun] = [:]
    /// Verified files that still need their `mediaCached` acknowledgement sent to the Mac.
    var unacknowledgedMedia: [ItemID: RevisionID] = [:]
    /// Transcripts for audio on the phone, keyed by entry; each is for the cached revision.
    @Published var transcripts: [ItemID: LibraryTranscript] = [:]
    /// One load per entry, so a cancelled or replaced load can never write for its successor.
    var transcriptRuns: [ItemID: LibraryTranscriptRun] = [:]
    /// The revision whose missing transcript was already re-requested this session.
    var transcriptRetried: [ItemID: RevisionID] = [:]
    let clockFormat: LibraryClockFormat
    private let preferences: UserDefaults
    private let recovery: LibraryAccountRecovery?
    private var store: any LibraryStore
    private var reconciler: LibraryReconciler
    private var refreshTask: Task<Void, Never>?
    private var refreshRequested = false
    private var started = false

    init(
        transport: any LibraryTransport,
        store: any LibraryStore = InMemoryLibraryStore(),
        deviceID: String,
        recovery: LibraryAccountRecovery? = nil,
        mediaCache: (any LibraryMediaCache)? = nil,
        mediaTiming: LibraryMediaTiming = LibraryMediaTiming(),
        handoffTiming: LibraryHandoffTiming = LibraryHandoffTiming(),
        decisionTiming: LibraryDecisionTiming = LibraryDecisionTiming(),
        preferences: UserDefaults = .standard,
        now: @escaping @Sendable () -> Date = { Date() },
        timeZone: TimeZone = .current
    ) {
        self.transport = transport
        self.mediaCache = mediaCache ?? FileMediaCache(rootURL: FileMediaCache.defaultRoot())
        self.mediaTiming = mediaTiming
        self.handoffTiming = handoffTiming
        self.decisionTiming = decisionTiming
        self.coordinator = HandoffCoordinator(
            transport: transport, deviceID: deviceID, clock: now, sleep: handoffTiming.settleSleep)
        self.preferences = preferences
        self.sort = LibrarySortOrder.stored(in: preferences)
        self.store = store
        self.deviceID = deviceID
        self.recovery = recovery
        self.now = now
        self.clockFormat = LibraryClockFormat(timeZone: timeZone)
        self.reconciler = LibraryReconciler(transport: transport, store: store)
    }

    /// Launch entry point: watches for account changes once, then fetches.
    func start() async {
        if !started {
            started = true
            if let events = recovery?.quarantineEvents {
                Task { [weak self] in
                    for await _ in events { self?.accountQuarantined = true }
                }
            }
        }
        await refresh()
    }

    /// Fetches now. Calls made while a fetch is running share it and queue exactly one rerun,
    /// so a burst of pushes never runs overlapping syncs.
    func refresh() async {
        if let running = refreshTask {
            refreshRequested = true
            await running.value
            return
        }
        let task = Task { [weak self] in
            repeat {
                guard let self else { return }
                self.refreshRequested = false
                await self.performRefresh()
            } while self?.refreshRequested == true
            self?.refreshTask = nil
        }
        refreshTask = task
        await task.value
    }

    /// A silent push arrived; returns true when the visible library changed.
    func handleSilentPush() async -> Bool {
        // The mirror and offers, not the filtered view: a push's answer must not depend on search or filter.
        let before = (queued, readyOffers)
        await refresh()
        return before != (queued, readyOffers)
    }

    /// Discards the quarantined account's replica and starts from an empty one.
    func recoverFromAccountChange() async {
        guard let recovery else { return }
        let fresh = await recovery.recover()
        store = fresh
        reconciler = LibraryReconciler(transport: transport, store: fresh)
        accountQuarantined = false
        queued = []
        readyOffers = []
        checkpoints = [:]
        lifetimeStats = nil
        macLastSeenAt = nil
        continuation = nil
        discardDecisionsAfterAccountChange()
        await discardMediaAfterAccountChange()
        await refresh()
    }

    private func performRefresh() async {
        isRefreshing = true
        defer { isRefreshing = false }
        switch await reconciler.synchronize() {
        case .success:
            errorMessage = nil
            lastSynchronizedAt = now()
        case let .failure(error):
            errorMessage = Self.message(for: error)
        }
        let records = try? await transport.fetchDeviceRecords()
        if let records {
            checkpoints = Self.checkpoints(from: records, excluding: deviceID)
            macLastSeenAt = Self.macLastSeen(from: records, excluding: deviceID)
        }
        // A failed read keeps the last known offers: a flaky fetch must not empty the Larder.
        if let offers = try? await transport.mediaOffers() {
            readyOffers = Set(offers.filter(\.isPrepared).map(\.entryID))
        }
        let content = await store.state().content
        entryDurations = content.entries.compactMapValues(\.durationSeconds)
        decisionContent = content
        if let records { startedEntries = Self.startedEntries(from: records) }
        rebuildRows()
        await refreshMediaFromCache()
        if let records { await updateContinuation(from: records) }
        await resolveDecisions()
        await refreshStats()
    }

    /// Projects the fetched content, with unsettled decisions laid over it, into queue-ordered rows.
    func rebuildRows() {
        let visible = LibraryDecisionOverlay.apply(decisions, to: decisionContent)
        queued = LibraryRowBuilder.rows(
            content: visible, checkpoints: checkpoints, clock: clockFormat, started: startedEntries)
    }

    /// Queued entries the phone can play or fetch: a ready or available offer, a transfer under way, or audio
    /// already cached.
    var preparedIDs: (offered: Set<ItemID>, onPhone: Set<ItemID>) {
        let inFlight = Set(media.filter { $0.value.isInFlight }.keys)
        let onPhone = Set(media.filter { $0.value == .onPhone }.keys)
        return (readyOffers.union(inFlight), onPhone)
    }

    /// The Larder as listed: prepared rows only, narrowed by filter and search, ordered by `sort`.
    var visibleRows: [LibraryRow] {
        let ids = preparedIDs
        return LibraryListing.rows(
            queued, offered: ids.offered, onPhone: ids.onPhone, sort: sort, filter: filter, query: searchText)
    }

    /// How many queued entries are prepared, before any filter or search; tells an empty Larder
    /// from an empty result.
    var preparedCount: Int {
        let ids = preparedIDs
        return LibraryListing.prepared(queued, offered: ids.offered, onPhone: ids.onPhone).count
    }

    /// Drag reorder edits the Mac's own order, so it needs that order shown whole.
    var canReorder: Bool { sort.allowsReorder && filter == .all && searchText.trimmingCharacters(in: .whitespaces).isEmpty }

    /// Entries any device, this one included, has played past the start.
    static func startedEntries(from records: LibraryDeviceRecords) -> Set<ItemID> {
        Set((records.nowPlaying + records.progress).filter { $0.record.positionSeconds > 0 }.map(\.record.entryID))
    }

    /// The winning record per entry among every device except this one, across both
    /// playback channels, ranked by `HandoffResolver` (epoch, then server date).
    static func checkpoints(from records: LibraryDeviceRecords, excluding deviceID: String) -> [ItemID: ObservedPlayback] {
        let others = (records.nowPlaying + records.progress).filter { $0.record.deviceID != deviceID }
        return Dictionary(grouping: others, by: { $0.record.entryID }).compactMapValues(HandoffResolver.winner(among:))
    }

    private static func message(for error: Error) -> String {
        switch error {
        case LibraryTransportError.transport(let text): return text
        case LibraryTransportError.superseded: return "iCloud account changed. Sync was cancelled."
        default: return "Sync failed: \(error.localizedDescription)"
        }
    }
}
