import Combine
import Foundation
import WiltedDomain
import WiltedLibrary

/// One Larder row, already resolved to display strings.
struct LibraryRow: Identifiable, Equatable, Sendable {
    let id: ItemID
    let title: String
    let showTitle: String
    let durationText: String?
    let removal: LibraryRemoval
    /// When the Mac removed the entry; nil while live or when the Mac did not publish it.
    let removedAt: Date?
    let publishedAt: Date
    /// "Retired on Mac" or "Dismissed on Mac"; nil while the entry is live.
    let removalText: String?
    /// "Paused on Mac at mm:ss (as of hh:mm)" from the Mac's last checkpoint for this entry.
    let checkpointText: String?
}

/// How the removed section is ordered, always newest first.
enum LibraryRemovedSort: String, CaseIterable, Identifiable, Sendable {
    /// When the Mac retired or dismissed the entry; entries without a date sort last.
    case decisionDate
    case publicationDate

    var id: String { rawValue }

    var title: String {
        switch self {
        case .decisionDate: "Decision date"
        case .publicationDate: "Publication date"
        }
    }
}

/// What a recovering account gives back: a fresh store for the new account, plus the
/// stream that announces an account change needing review.
struct LibraryAccountRecovery: Sendable {
    let quarantineEvents: AsyncStream<Void>
    /// Discards everything tied to the previous account and returns an empty store.
    let recover: @Sendable () async -> any LibraryStore
}

/// Owns the iPhone's library replica: fetches on launch, foreground, pull-to-refresh and
/// silent push, and exposes queue-ordered rows plus the Mac's last checkpoint per entry.
/// The iPhone never writes library state; the Mac is the single writer.
@MainActor
final class LibraryAppModel: ObservableObject {
    @Published private(set) var queued: [LibraryRow] = []
    /// Retired or dismissed entries the Mac no longer queues.
    @Published private(set) var removed: [LibraryRow] = []
    /// Ordering of `removed`; changing it re-sorts in place without a fetch.
    @Published var removedSort: LibraryRemovedSort = .decisionDate {
        didSet { if removedSort != oldValue { removed = LibraryRowBuilder.sorted(removed, by: removedSort) } }
    }
    /// The most authoritative record per entry from any device other than this one.
    @Published private(set) var checkpoints: [ItemID: ObservedPlayback] = [:]
    @Published private(set) var isRefreshing = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var lastSynchronizedAt: Date?
    @Published private(set) var accountQuarantined = false

    private let transport: any LibraryTransport
    private let deviceID: String
    private let now: @Sendable () -> Date
    private let clockFormat: LibraryClockFormat
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
        now: @escaping @Sendable () -> Date = { Date() },
        timeZone: TimeZone = .current
    ) {
        self.transport = transport
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
        let before = queued + removed
        await refresh()
        return before != queued + removed
    }

    /// Discards the quarantined account's replica and starts from an empty one.
    func recoverFromAccountChange() async {
        guard let recovery else { return }
        let fresh = await recovery.recover()
        store = fresh
        reconciler = LibraryReconciler(transport: transport, store: fresh)
        accountQuarantined = false
        queued = []
        removed = []
        checkpoints = [:]
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
        if let records = try? await transport.fetchDeviceRecords() {
            checkpoints = Self.checkpoints(from: records, excluding: deviceID)
        }
        let content = await store.state().content
        (queued, removed) = LibraryRowBuilder.rows(
            content: content, checkpoints: checkpoints, clock: clockFormat, removedSort: removedSort)
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

/// Fixed-format clock and duration text, so labels do not shift with the device locale.
struct LibraryClockFormat: Sendable {
    let timeZone: TimeZone

    func clock(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: date)
    }

    /// `mm:ss`, or `h:mm:ss` from one hour up.
    static func duration(_ seconds: Double) -> String {
        let total = Int(max(0, seconds).rounded(.down))
        let (hours, minutes, secs) = (total / 3600, total % 3600 / 60, total % 60)
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, secs)
            : String(format: "%02d:%02d", minutes, secs)
    }
}

/// Pure projection from mirrored content to rows.
enum LibraryRowBuilder {
    /// Queued entries in slot order, then removed entries that have no slot.
    static func rows(
        content: LibrarySnapshot,
        checkpoints: [ItemID: ObservedPlayback],
        clock: LibraryClockFormat,
        removedSort: LibraryRemovedSort = .decisionDate
    ) -> (queued: [LibraryRow], removed: [LibraryRow]) {
        func row(_ entry: LibraryEntry) -> LibraryRow {
            LibraryRow(
                id: entry.id,
                title: entry.title,
                showTitle: content.sources[entry.sourceID]?.title ?? "Unknown show",
                durationText: entry.durationSeconds.map(LibraryClockFormat.duration),
                removal: entry.removal,
                removedAt: entry.removedAt,
                publishedAt: entry.publishedAt,
                removalText: removalText(entry.removal),
                checkpointText: checkpoints[entry.id].map { checkpointText($0, clock: clock) }
            )
        }
        let queued = content.queue.compactMap { content.entries[$0.entryID] }.map(row)
        let removed = content.entries.values
            .filter { $0.removal != .none && content.slots[$0.id] == nil }
            .map(row)
        return (queued, sorted(removed, by: removedSort))
    }

    /// Newest first by the chosen date. Decision order puts rows with no `removedAt` after
    /// dated ones, then falls back to publication date; the id breaks every remaining tie.
    static func sorted(_ rows: [LibraryRow], by sort: LibraryRemovedSort) -> [LibraryRow] {
        rows.sorted { lhs, rhs in
            if sort == .decisionDate, lhs.removedAt != rhs.removedAt {
                guard let left = lhs.removedAt else { return false }
                guard let right = rhs.removedAt else { return true }
                return left > right
            }
            if lhs.publishedAt != rhs.publishedAt { return lhs.publishedAt > rhs.publishedAt }
            return lhs.id.rawValue > rhs.id.rawValue
        }
    }

    static func removalText(_ removal: LibraryRemoval) -> String? {
        switch removal {
        case .none: nil
        case .retired: "Retired on Mac"
        case .dismissed: "Dismissed on Mac"
        }
    }

    static func checkpointText(_ observed: ObservedPlayback, clock: LibraryClockFormat) -> String {
        let state = observed.record.isPlaying ? "Playing" : "Paused"
        let position = LibraryClockFormat.duration(observed.record.positionSeconds)
        return "\(state) on Mac at \(position) (as of \(clock.clock(observed.serverModifiedAt)))"
    }
}
