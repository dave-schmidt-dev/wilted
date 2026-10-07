import Foundation
import OSLog
import WiltedDomain
import WiltedLibrary

#if canImport(WiltedProducer)
import WiltedProducer
#endif

private let applierLog = Logger(subsystem: "com.zerodelta.wilted", category: "MacIntentApplier")

// MARK: - Host

/// What the Mac knows about one entry, as far as a phone decision is concerned.
enum WiltedMacDecisionEntryState: Equatable, Sendable {
    case unknown
    /// On the Mac's lists: `queued` when it holds a Larder slot, `started` when listening began.
    case live(queued: Bool, started: Bool)
    case retired
    case dismissed
}

/// The Mac model's decision surface. Each mutating call goes through the model's existing
/// method (so preparation withdrawal, download-on-keep, playback stop and the in-memory refresh
/// all happen), waits for that method's durable work, and answers whether the entry ended in the
/// requested state. Nothing here writes producer state directly (W-INV-005).
@MainActor
protocol WiltedMacDecisionHost: AnyObject {
    func decisionState(of entryID: ItemID) -> WiltedMacDecisionEntryState
    /// The full Larder order, including entries the phone does not see.
    var decisionQueue: [ItemID] { get }
    func keepEntry(_ entryID: ItemID) async -> Bool
    func skipEntry(_ entryID: ItemID) async -> Bool
    func markEntryDone(_ entryID: ItemID) async -> Bool
    /// Takes a queued entry off the Larder through the row's Remove from Larder; true once it is off.
    func removeEntryFromLarder(_ entryID: ItemID) async -> Bool
    func restoreEntry(_ entryID: ItemID) async -> Bool
    /// Moves within the full queue by the index API (`to` is a post-removal index); true once
    /// the queue reads `resulting`.
    func moveQueueEntry(from source: Int, to destination: Int, resulting: [ItemID]) async -> Bool
}

// MARK: - Outcome book

/// Durable record of the outcome the Mac reached for each decision intent, and whether it
/// reached the transport. It exists so a crash between applying an intent and publishing its
/// answer neither re-applies the intent (the ledger prevents that) nor leaves the phone waiting
/// forever: the saved outcome is republished. An outcome is immutable, so a republish is safe.
actor WiltedMacIntentOutcomeBook {
    static let retention: TimeInterval = 30 * 24 * 60 * 60

    struct Entry: Codable, Equatable, Sendable {
        var outcome: IntentOutcome
        var published: Bool
    }

    private struct Stored: Codable {
        var version = 1
        var entries: [String: Entry]
    }

    private let fileURL: URL?
    private let now: @Sendable () -> Date
    private var entries: [String: Entry] = [:]

    /// `fileURL` nil keeps the book in memory only (tests).
    init(fileURL: URL?, now: @escaping @Sendable () -> Date = { Date() }) {
        self.fileURL = fileURL
        self.now = now
        if let fileURL, let data = try? Data(contentsOf: fileURL) {
            if let stored = try? JSONDecoder().decode(Stored.self, from: data) {
                entries = stored.entries
            } else {
                let aside = fileURL.appendingPathExtension("corrupt")
                try? FileManager.default.removeItem(at: aside)
                try? FileManager.default.moveItem(at: fileURL, to: aside)
                applierLog.error("Intent outcome book was unreadable and was set aside")
            }
        }
        let cutoff = now().addingTimeInterval(-Self.retention)
        entries = entries.filter { $0.value.outcome.decidedAt > cutoff }
    }

    func entry(for intentID: String) -> Entry? { entries[intentID] }

    func save(_ outcome: IntentOutcome, published: Bool) throws {
        try write(entries.merging([outcome.intentID: Entry(outcome: outcome, published: published)]) { _, new in new })
    }

    func markPublished(_ intentID: String) throws {
        guard var entry = entries[intentID], !entry.published else { return }
        entry.published = true
        try write(entries.merging([intentID: entry]) { _, new in new })
    }

    private func write(_ next: [String: Entry]) throws {
        let cutoff = now().addingTimeInterval(-Self.retention)
        let kept = next.filter { $0.value.outcome.decidedAt > cutoff }
        if let fileURL {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(Stored(entries: kept)).write(to: fileURL, options: .atomic)
        }
        entries = kept
    }
}

// MARK: - Applier

/// Applies the phone's decision intents (`keep`, `skip`, `markDone`, `removeFromLarder`, `restore`, `reorder`) on the
/// Mac and answers each with an `IntentOutcome`.
///
/// An intent id goes into the ledger before anything is applied, so it is applied at most once
/// even across a restart. An intent older than `IntentRetention.maximumAge` is answered `expired`
/// and not applied; an entry the Mac does not know is answered `unknownEntry`; a state the
/// decision cannot apply to is `notApplicable`; a model call that did not take is `failed`. The
/// outcome is saved, then published; when publishing fails `apply` throws so the sink retries,
/// and the retry republishes the saved outcome without applying again.
///
/// The poller hands over intents one at a time, in order, so reorders see earlier keeps.
@MainActor
final class WiltedMacIntentApplier {
    private weak var host: (any WiltedMacDecisionHost)?
    private let ledger: WiltedMacIntentLedger
    private let book: WiltedMacIntentOutcomeBook
    private let transport: any LibraryTransport
    private let now: @Sendable () -> Date
    private let onApplied: (@MainActor () -> Void)?

    /// `onApplied` runs after a decision changed the Mac's state, to trigger a republish.
    init(
        host: any WiltedMacDecisionHost, ledger: WiltedMacIntentLedger, book: WiltedMacIntentOutcomeBook,
        transport: any LibraryTransport, now: @escaping @Sendable () -> Date = { Date() },
        onApplied: (@MainActor () -> Void)? = nil
    ) {
        self.host = host
        self.ledger = ledger
        self.book = book
        self.transport = transport
        self.now = now
        self.onApplied = onApplied
    }

    /// Applies one decision intent; other intents are ignored.
    func apply(_ intent: LibraryIntent) async throws {
        guard intent.action.isDecision else { return }
        if let saved = await book.entry(for: intent.id) {
            if !saved.published { try await publish(saved.outcome) }
            return
        }
        let at = now()
        let outcome: IntentOutcome
        if let expired = try IntentRetention.expiryOutcome(for: intent, now: at) {
            outcome = expired
        } else if try await ledger.recordIfNew(intent.id) {
            outcome = try await decide(intent, at: at)
        } else {
            // An earlier run began this intent and never saved an answer, so whether it took effect
            // is unknown. It is not applied again; the phone reads the next publish for the truth.
            applierLog.error("Intent \(intent.id, privacy: .public) was begun earlier without an outcome")
            outcome = try .rejected(for: intent, reason: IntentOutcome.reasonFailed, at: at)
        }
        try await book.save(outcome, published: false)
        if outcome.isApplied { onApplied?() }
        try await publish(outcome)
    }

    private func publish(_ outcome: IntentOutcome) async throws {
        try await transport.publishIntentOutcome(outcome)
        try await book.markPublished(outcome.intentID)
    }

    // MARK: - Decisions

    private func decide(_ intent: LibraryIntent, at: Date) async throws -> IntentOutcome {
        func applied() throws -> IntentOutcome { try .applied(for: intent, at: at) }
        func rejected(_ reason: String) throws -> IntentOutcome { try .rejected(for: intent, reason: reason, at: at) }
        func result(_ took: Bool) throws -> IntentOutcome { try took ? applied() : rejected(IntentOutcome.reasonFailed) }

        guard let host else { return try rejected(IntentOutcome.reasonFailed) }
        let entryID = intent.action.entryID
        let state = host.decisionState(of: entryID)
        if state == .unknown { return try rejected(IntentOutcome.reasonUnknownEntry) }
        let notApplicable = IntentOutcome.reasonNotApplicable

        switch intent.action {
        case .keep:
            switch state {
            // A queued entry is still sent through the model: the phone's Keep is the
            // owner's own decision, and it turns a policy-kept entry into a manual one.
            case .live: return try result(await host.keepEntry(entryID))
            default: return try rejected(notApplicable)
            }
        case .skip:
            switch state {
            case .retired: return try applied()
            // A queued entry is one the Mac kept; Skip belongs to New only.
            case .live(queued: false, _): return try result(await host.skipEntry(entryID))
            default: return try rejected(notApplicable)
            }
        case .markDone:
            switch state {
            case .retired: return try applied()
            // The listening may have happened on the phone, which the Mac's own saved position
            // cannot show, so any live entry the phone marks done is completed here.
            case .live: return try result(await host.markEntryDone(entryID))
            default: return try rejected(notApplicable)
            }
        case .removeFromLarder:
            switch state {
            case .live(queued: true, _): return try result(await host.removeEntryFromLarder(entryID))
            // Already off the Larder, retired or not: the phone's aim is met.
            case .live(queued: false, _), .retired: return try applied()
            default: return try rejected(notApplicable)
            }
        case .restore:
            switch state {
            case .live: return try applied()
            default: return try result(await host.restoreEntry(entryID))
            }
        case let .reorder(_, afterEntryID):
            guard case .live(queued: true, _) = state,
                  let move = Self.queueMove(of: entryID, after: afterEntryID, in: host.decisionQueue) else {
                return try rejected(notApplicable)
            }
            guard let move = move.change else { return try applied() }
            return try result(await host.moveQueueEntry(from: move.from, to: move.to, resulting: move.resulting))
        case .requestMedia, .mediaCached:
            return try rejected(notApplicable)
        }
    }

    struct QueueMove: Equatable {
        struct Change: Equatable {
            var from: Int
            var to: Int
            var resulting: [ItemID]
        }
        /// Nil when the entry already sits where it was asked to go.
        var change: Change?
    }

    /// Converts the phone's entry-relative request (just after `after`, or the front when nil) to
    /// the model's index move against the full queue, whose `to` is a post-removal index. Nil when
    /// the entry or its anchor is not in the queue.
    static func queueMove(of entryID: ItemID, after anchor: ItemID?, in queue: [ItemID]) -> QueueMove? {
        guard let source = queue.firstIndex(of: entryID) else { return nil }
        var rest = queue
        rest.remove(at: source)
        let destination: Int
        if let anchor {
            guard let index = rest.firstIndex(of: anchor) else { return nil }
            destination = index + 1
        } else {
            destination = 0
        }
        var resulting = rest
        resulting.insert(entryID, at: destination)
        guard resulting != queue else { return QueueMove(change: nil) }
        return QueueMove(change: .init(from: source, to: destination, resulting: resulting))
    }
}

#if canImport(WiltedProducer)
// MARK: - Decision host

/// The phone's decisions run through the model's existing methods, each awaited to its durable
/// end, so the answer to the phone reflects what the Mac actually holds afterwards.
extension WiltedMacModel: WiltedMacDecisionHost {
    private static let decisionMoveAttempts = 80
    private static let decisionMovePoll: Duration = .milliseconds(50)

    func decisionState(of entryID: ItemID) -> WiltedMacDecisionEntryState {
        let raw = entryID.rawValue
        if let episode = episodes.first(where: { $0.id == raw }) {
            switch episode.removalKind {
            case .retired?: return .retired
            case .dismissed?: return .dismissed
            case nil: return .live(queued: podcastQueueIDs.contains(raw), started: hasStartedEpisode(episode))
            }
        }
        return dismissedEpisodes.contains { $0.id == raw } ? .dismissed : .unknown
    }

    var decisionQueue: [ItemID] { podcastQueueIDs.compactMap { try? ItemID(rawValue: $0) } }

    func keepEntry(_ entryID: ItemID) async -> Bool {
        guard let episode = episodes.first(where: { $0.id == entryID.rawValue }) else { return false }
        await awaitingDecisionWriters { keepEpisode(episode) }
        return podcastQueueIDs.contains(entryID.rawValue)
    }

    func skipEntry(_ entryID: ItemID) async -> Bool {
        guard let episode = episodes.first(where: { $0.id == entryID.rawValue }) else { return false }
        await awaitingDecisionWriters { skipFeedEpisode(episode) }
        return decisionState(of: entryID) == .retired
    }

    func markEntryDone(_ entryID: ItemID) async -> Bool {
        guard let episode = episodes.first(where: { $0.id == entryID.rawValue }) else { return false }
        await awaitingDecisionWriters { skipEpisode(episode, requireStarted: false) }
        return decisionState(of: entryID) == .retired
    }

    func removeEntryFromLarder(_ entryID: ItemID) async -> Bool {
        // The Larder row's own Remove from Larder: it takes the entry off the queue and keeps it.
        await awaitingDecisionWriters { removeEpisodeFromUpNext(entryID.rawValue) }
        return !podcastQueueIDs.contains(entryID.rawValue)
    }

    func restoreEntry(_ entryID: ItemID) async -> Bool {
        let raw = entryID.rawValue
        switch decisionState(of: entryID) {
        case .retired:
            guard let episode = episodes.first(where: { $0.id == raw }) else { return false }
            await awaitingDecisionWriters { restoreSkippedFeedEpisode(episode) }
        case .dismissed:
            guard let dismissal = dismissedEpisodes.first(where: { $0.id == raw }) else { return false }
            restoreEpisode(dismissal)
            await podcastRestoreTasks[raw]?.value
        default:
            break
        }
        if case .live = decisionState(of: entryID) { return true }
        return false
    }

    func moveQueueEntry(from source: Int, to destination: Int, resulting: [ItemID]) async -> Bool {
        let wanted = resulting.map(\.rawValue)
        // A phone reorder is an explicit custom order; a calculated sort would redraw it away.
        larderSort = .custom
        moveEpisodeInUpNext(from: source, to: destination)
        for _ in 0..<Self.decisionMoveAttempts {
            if podcastQueueIDs == wanted { return true }
            try? await Task.sleep(for: Self.decisionMovePoll)
        }
        return podcastQueueIDs == wanted
    }

    /// Runs a model method that starts durable work and waits for the writers it registered, then
    /// for any feed decision still in flight for the same entry (a repeated request is not admitted).
    private func awaitingDecisionWriters(_ start: () -> Void) async {
        let before = Set(subscriptionWriteTasks.keys)
        start()
        let mine = subscriptionWriteTasks.filter { !before.contains($0.key) }.map(\.value)
        for task in mine { await task.value }
        if let token = feedDecisionWriteTailToken, let tail = subscriptionWriteTasks[token] { await tail.value }
    }
}
#endif
