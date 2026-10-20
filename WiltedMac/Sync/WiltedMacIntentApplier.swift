import Foundation
import OSLog
import WiltedDomain
import WiltedLibrary

#if canImport(WiltedProducer)
import WiltedProducer
#endif

private let applierLog = Logger(subsystem: "com.zerodelta.wilted", category: "MacIntentApplier")

enum WiltedMacDatedDecisionResult { case applied, superseded, failed, notApplicable }

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
    func applyOwnerIntent(_ intent: LibraryIntent) async -> WiltedMacDatedDecisionResult?
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
    /// Classifies `url` and, when it is a podcast feed with audio, subscribes through the model's
    /// subscription intake; answers what became of it. Persists nothing unless it answers `.added`.
    func subscribeFeed(_ url: URL) async -> WiltedMacAddResult
    /// Classifies `url` and, when it is not a feed, starts the single-article path; answers what
    /// became of it. `.added` means the Mac accepted the article and began preparing it.
    func addArticleLink(_ url: URL) async -> WiltedMacAddResult
}

extension WiltedMacDecisionHost {
    func applyOwnerIntent(_ intent: LibraryIntent) async -> WiltedMacDatedDecisionResult? { nil }
}

/// What the Mac's add path concluded for one phone `subscribe` or `addArticle` request.
enum WiltedMacAddResult: Equatable, Sendable {
    case added
    case alreadyFollowed
    case alreadyAdded
    case notAPodcastFeed
    case isAFeed
    case noAudio
    case failed
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

    /// Writes the book's bytes to its file and reports whether the folder sync is certain.
    typealias Writer = @Sendable (Data, URL) throws -> DurableFile.ReplacementResult

    private let fileURL: URL?
    private let now: @Sendable () -> Date
    private let writeBytes: Writer
    private var entries: [String: Entry] = [:]

    /// `fileURL` nil keeps the book in memory only (tests). `write` is replaced only by tests
    /// that inject a failed save.
    init(
        fileURL: URL?, now: @escaping @Sendable () -> Date = { Date() },
        write: @escaping Writer = { try DurableFile.replace($0, to: $1) }
    ) {
        self.fileURL = fileURL
        self.now = now
        self.writeBytes = write
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
        try persist(entries.merging([outcome.intentID: Entry(outcome: outcome, published: published)]) { _, new in new })
    }

    func markPublished(_ intentID: String) throws {
        guard var entry = entries[intentID], !entry.published else { return }
        entry.published = true
        try persist(entries.merging([intentID: entry]) { _, new in new })
    }

    /// Saves the book and adopts `next` whenever the replacement landed. A directory sync that
    /// stays uncertain after the primitive's retry is logged: the outcome is on disk for a clean
    /// restart, and a power loss may lose it, but it is not a failed save.
    private func persist(_ next: [String: Entry]) throws {
        let cutoff = now().addingTimeInterval(-Self.retention)
        let kept = next.filter { $0.value.outcome.decidedAt > cutoff }
        if let fileURL {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(Stored(entries: kept))
            let result = try writeBytes(data, fileURL)
            if case let .replacedDirectorySyncUncertain(failure) = result {
                applierLog.warning("Intent outcome book landed but its folder sync is uncertain: \(failure.description, privacy: .public)")
            }
        }
        entries = kept
    }
}

// MARK: - Applier

/// Applies the phone's decision intents (`keep`, `skip`, `markDone`, `removeFromLarder`, `restore`, `reorder`,
/// `subscribe`, `addArticle`) on the Mac and answers each with an `IntentOutcome`.
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
    /// Reasons for the add-flow rejections; the phone shows any text it does not know as opaque.
    static let reasonAlreadyFollowed = "alreadyFollowed"
    static let reasonAlreadyAdded = "alreadyAdded"
    static let reasonNotAPodcastFeed = "notAPodcastFeed"
    static let reasonIsAFeed = "isAFeed"
    static let reasonNoAudio = "noAudio"

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

        if case .unsupported = intent.action { return try rejected(IntentOutcome.reasonUnsupportedAction) }
        guard let host else { return try rejected(IntentOutcome.reasonFailed) }
        // Their entry IDs name items the Mac does not hold yet, so they must not reach the
        // unknownEntry check below.
        switch intent.action {
        case let .subscribe(feedURL):
            switch await host.subscribeFeed(feedURL) {
            case .added: return try applied()
            case .alreadyFollowed, .alreadyAdded: return try rejected(Self.reasonAlreadyFollowed)
            case .notAPodcastFeed, .isAFeed: return try rejected(Self.reasonNotAPodcastFeed)
            case .noAudio: return try rejected(Self.reasonNoAudio)
            case .failed: return try rejected(IntentOutcome.reasonFailed)
            }
        case let .addArticle(url):
            switch await host.addArticleLink(url) {
            case .added: return try applied()
            case .alreadyAdded, .alreadyFollowed: return try rejected(Self.reasonAlreadyAdded)
            case .isAFeed, .notAPodcastFeed, .noAudio: return try rejected(Self.reasonIsAFeed)
            case .failed: return try rejected(IntentOutcome.reasonFailed)
            }
        default: break
        }
        let entryID = intent.action.entryID
        if let dated = await host.applyOwnerIntent(intent) {
            switch dated {
            case .applied: return try applied()
            case .superseded: return try rejected("superseded")
            case .failed: return try rejected(IntentOutcome.reasonFailed)
            case .notApplicable: return try rejected(IntentOutcome.reasonNotApplicable)
            }
        }
        let state = host.decisionState(of: entryID)
        if state == .unknown {
            // Only Remove can be satisfied by a terminal durable row that
            // has already left the live projection. Other unknown actions fail.
            if case .removeFromLarder = intent.action, await host.removeEntryFromLarder(entryID) {
                return try applied()
            }
            return try rejected(IntentOutcome.reasonUnknownEntry)
        }
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
            case .retired: return try result(await host.skipEntry(entryID))
            // A queued entry is one the Mac kept; Skip belongs to New only.
            case .live(queued: false, _): return try result(await host.skipEntry(entryID))
            default: return try rejected(notApplicable)
            }
        case .markDone:
            switch state {
            case .retired: return try result(await host.markEntryDone(entryID))
            // The listening may have happened on the phone, which the Mac's own saved position
            // cannot show, so any live entry the phone marks done is completed here.
            case .live: return try result(await host.markEntryDone(entryID))
            default: return try rejected(notApplicable)
            }
        case .removeFromLarder:
            switch state {
            case .live(queued: true, _): return try result(await host.removeEntryFromLarder(entryID))
            // Already off the Larder, retired or not: the phone's aim is met.
            case .live(queued: false, _), .retired, .dismissed: return try result(await host.removeEntryFromLarder(entryID))
            default: return try rejected(notApplicable)
            }
        case .restore:
            return try result(await host.restoreEntry(entryID))
        case let .reorder(_, afterEntryID):
            guard case .live(queued: true, _) = state,
                  let move = Self.queueMove(of: entryID, after: afterEntryID, in: host.decisionQueue) else {
                return try rejected(notApplicable)
            }
            if let change = move.change {
                return try result(await host.moveQueueEntry(from: change.from, to: change.to, resulting: change.resulting))
            }
            guard let index = host.decisionQueue.firstIndex(of: entryID) else { return try rejected(notApplicable) }
            return try result(await host.moveQueueEntry(from: index, to: index, resulting: host.decisionQueue))
        case .unsupported:
            return try rejected(IntentOutcome.reasonUnsupportedAction)
        case .requestMedia, .mediaCached, .subscribe, .addArticle:
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
    private static let subscribeSlotWaitLimit = 40
    private static let decisionMovePoll: Duration = .milliseconds(50)

    /// Carry the phone's original owner-choice time through the store's atomic guards.
    func applyOwnerIntent(_ intent: LibraryIntent) async -> WiltedMacDatedDecisionResult? {
        let id = intent.action.entryID
        if case let .reorder(_, after) = intent.action, episodeAssociations[id.rawValue] != nil {
            let members = logicalMemberIDs(id.rawValue)
            let queue = decisionQueue
            let moving = queue.filter { members.contains($0.rawValue) }
            guard !moving.isEmpty else { return .notApplicable }
            var rest = queue.filter { !members.contains($0.rawValue) }
            let insertion: Int
            if let after {
                let anchors = logicalMemberIDs(after.rawValue)
                guard anchors.isDisjoint(with: members), let index = rest.lastIndex(where: { anchors.contains($0.rawValue) }) else { return .notApplicable }
                insertion = index + 1
            } else { insertion = 0 }
            rest.insert(contentsOf: moving, at: insertion)
            // The model's queue replacement retains all raw slots and current selection.
            guard let playback, let state = try? PodcastQueueState(episodeIDs: rest,
                currentEpisodeID: currentPodcastEpisodeID.flatMap { try? ItemID(rawValue: $0) }) else { return .failed }
            do { try await playback.replacePodcastQueue(state); await refreshPodcastQueueState(); return .applied }
            catch { return .failed }
        }
        let choice: EpisodeDecision
        switch intent.action {
        case .keep, .restore: choice = .keep
        case .skip, .markDone, .removeFromLarder: choice = .skip
        default: return nil
        }
        guard let store else { return .failed }
        do {
            let value = EpisodeDecisionRecord(episodeID: id, decision: choice, source: .manual,
                                             decidedAt: Timestamp(intent.createdAt))
            guard try await store.episodeDecisionWouldApply(value) else { return .superseded }
            if case .removeFromLarder = intent.action,
               let removal = try await store.removalKind(for: id), removal == .retired || removal == .dismissed {
                let acknowledged = await recordTerminalRemove(id, at: value.decidedAt)
                return acknowledged ? .applied : .failed
            }
            // Durable terminal proof does not require a decodable live/feed row.
            guard try await store.podcastEpisode(for: id) != nil else { return nil }
            let state = decisionState(of: id)
            if state == .unknown { return nil }
            switch intent.action {
            case .keep:
                guard case .live = state, let display = episodes.first(where: { $0.id == id.rawValue }),
                      let row = backingEpisode(for: display) else { return .notApplicable }
                await awaitingDecisionWriters { decideFeedEpisodes(.keep, episodes: [row], at: value.decidedAt) }
            case .restore:
                _ = try await store.restoreEpisode(id, at: intent.createdAt, recordLiveOwnerChoice: true)
                hiddenEpisodeIDs.subtract(logicalMemberIDs(id.rawValue))
                await refreshPodcastQueueState()
                await reloadLibraryRows()
            case .skip, .markDone, .removeFromLarder:
                if case .dismissed = state { return .notApplicable }
                if case .retired = state {
                    let result = try await store.save(episodeDecision: value)
                    return result == .superseded ? .superseded : .applied
                }
                guard let row = episodes.first(where: { $0.id == id.rawValue }) else { return .failed }
                if case .skip = intent.action, case .live(queued: false, _) = state {
                    await awaitingDecisionWriters { decideFeedEpisodes(.skip, episodes: [row], at: value.decidedAt) }
                } else {
                    await awaitingDecisionWriters { finishEpisodes([row], at: value.decidedAt) }
                }
            default: return nil
            }
            if !(try await store.episodeDecisionWouldApply(value)) { return .superseded }
            let saved = try await store.podcastEpisodeLogicalState(for: id)
            guard saved?.manualDecidedAt == value.decidedAt, saved?.manualDecision == choice else { return .failed }
            return .applied
        } catch { return .failed }
    }

    func decisionState(of entryID: ItemID) -> WiltedMacDecisionEntryState {
        let raw = entryID.rawValue
        if let association = episodeAssociations[raw], association.isSupported {
            if association.isTerminal { return .retired }
            let members = logicalMemberIDs(raw)
            return .live(queued: !members.isDisjoint(with: podcastQueueIDs),
                         started: episodes.contains { members.contains($0.id) && hasStartedEpisode($0) })
        }
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
        guard podcastQueueIDs.contains(entryID.rawValue), let store else { return false }
        return await recordOwnerDecision(.keep, for: entryID.rawValue, store: store)
    }

    func skipEntry(_ entryID: ItemID) async -> Bool {
        if case .live(queued: false, _) = decisionState(of: entryID),
           let episode = episodes.first(where: { $0.id == entryID.rawValue }), !episode.isAudiobook {
            await awaitingDecisionWriters { skipFeedEpisode(episode) }
            return decisionState(of: entryID) == .retired
        }
        return await markEntryDone(entryID)
    }

    func markEntryDone(_ entryID: ItemID) async -> Bool {
        guard let episode = episodes.first(where: { $0.id == entryID.rawValue }), !episode.isAudiobook else { return false }
        if decisionState(of: entryID) == .retired {
            guard let store else { return false }
            // Duplicate finish commands must preserve the receipt's exact
            // post-decision. New intent chronology is handled separately.
            do {
                let decision = try await store.episodeDecision(for: entryID)
                guard try await store.removalKind(for: entryID) == .retired else { return false }
                if decision?.source == .manual, decision?.decision == .skip { return true }
            } catch { return false }
            return await recordOwnerDecision(.skip, for: episode.id, store: store)
        }
        await awaitingDecisionWriters { skipEpisode(episode) }
        return decisionState(of: entryID) == .retired
    }

    func removeEntryFromLarder(_ entryID: ItemID) async -> Bool {
        guard let episode = episodes.first(where: { $0.id == entryID.rawValue }) else {
            // A late Remove can outlive the live-row projection. A durable
            // terminal record is already off the Larder; unknown IDs are not.
            return await recordTerminalRemove(entryID)
        }
        if !episode.isAudiobook {
            guard let store else { return false }
            do {
                if let removal = try await store.removalKind(for: entryID),
                   removal == .retired || removal == .dismissed { return await recordTerminalRemove(entryID) }
            } catch { return false }
            return await markEntryDone(entryID)
        }
        if podcastQueueIDs.contains(entryID.rawValue) {
            await awaitingDecisionWriters { removeEpisodeFromUpNext(entryID.rawValue) }
        }
        guard !podcastQueueIDs.contains(entryID.rawValue), let store else { return false }
        return await recordOwnerDecision(.skip, for: entryID.rawValue, store: store)
    }

    private func recordTerminalRemove(_ entryID: ItemID, at: Timestamp = Timestamp(Date())) async -> Bool {
        guard let store else { return false }
        do {
            let decision = try await store.episodeDecision(for: entryID)
            guard let removal = try await store.removalKind(for: entryID),
                  removal == .retired || removal == .dismissed else { return false }
            // Repeated finish preserves receipt post-state and its timestamp.
            // A policy exclusion or legacy terminal fact still needs owner provenance.
            if decision?.source == .manual, decision?.decision == .skip { return true }
            return await recordOwnerDecision(.skip, for: entryID.rawValue, store: store, at: at)
        } catch { return false }
    }

    func restoreEntry(_ entryID: ItemID) async -> Bool {
        let raw = entryID.rawValue
        switch decisionState(of: entryID) {
        case .retired:
            guard let episode = episodes.first(where: { $0.id == raw }) else { return false }
            await awaitingDecisionWriters { restoreSkippedFeedEpisode(episode) }
            if case .live = decisionState(of: entryID) { return true }
            return false
        case .dismissed:
            guard let dismissal = dismissedEpisodes.first(where: { $0.id == raw }) else { return false }
            restoreEpisode(dismissal)
            await podcastRestoreTasks[raw]?.value
        default:
            break
        }
        guard case .live = decisionState(of: entryID), let store else { return false }
        return await recordOwnerDecision(.keep, for: raw, store: store)
    }

    func moveQueueEntry(from source: Int, to destination: Int, resulting: [ItemID]) async -> Bool {
        guard decisionQueue.indices.contains(source), let store else { return false }
        let movedID = decisionQueue[source]
        let wanted = resulting.map(\.rawValue)
        if podcastQueueIDs != wanted {
            // A phone reorder is an explicit custom order; a calculated sort would redraw it away.
            larderSort = .custom
            moveEpisodeInUpNext(from: source, to: destination)
            for _ in 0..<Self.decisionMoveAttempts {
                if podcastQueueIDs == wanted { break }
                try? await Task.sleep(for: Self.decisionMovePoll)
            }
        }
        guard podcastQueueIDs == wanted else { return false }
        return await recordOwnerDecision(.keep, for: movedID.rawValue, store: store)
    }

    func subscribeFeed(_ url: URL) async -> WiltedMacAddResult {
        guard let feedID = try? ItemID.derivePodcastFeed(from: url), store != nil else { return .failed }
        let kind: PastedLinkKind
        do { kind = try await pastedLinkClassifier.classify(url) } catch { return .failed }
        guard case .podcastFeed = kind else { return .notAPodcastFeed }
        if subscriptions.contains(where: { $0.id == feedID.rawValue }) { return .alreadyFollowed }
        // The intake takes the single fetch slot; wait for a running refresh rather than lose the request.
        // Loop, because another request can take the slot before this continuation resumes. The model is
        // @MainActor, so nothing runs between the loop's exit and the intake start below.
        var waits = 0
        while let running = podcastRefreshTask {
            waits += 1
            guard waits <= Self.subscribeSlotWaitLimit else { return .failed }
            await running.value
        }
        // A competing request may have followed this feed while we waited.
        if subscriptions.contains(where: { $0.id == feedID.rawValue }) { return .alreadyFollowed }
        let before = subscriptions.count
        podcastFeedDraftStatus = nil
        let priorRequestID = podcastSubscriptionRequestID
        startPodcastSubscriptionIntake(url)
        // An intake that declined leaves no request ID; never read another request's outcome as ours.
        guard let requestID = podcastSubscriptionRequestID, requestID != priorRequestID,
              let task = podcastRefreshTask else { return .failed }
        await task.value
        if podcastFeedDraftStatus == PodcastFeedHasNoAudio.message { return .noAudio }
        if subscriptions.count > before { return .added }
        // A repeat of a followed feed whose redirect gave it another canonical ID lands here too.
        if podcastFeedDraftStatus?.hasPrefix("Already following") == true { return .alreadyFollowed }
        return .failed
    }

    func addArticleLink(_ url: URL) async -> WiltedMacAddResult {
        guard let articleID = try? ItemID.derive(from: url) else { return .failed }
        let kind: PastedLinkKind
        do { kind = try await pastedLinkClassifier.classify(url) } catch { return .failed }
        switch kind {
        case .podcastFeed, .podcastCatalogShow: return .isAFeed
        case .article, .articleAdvertisingFeed: break
        }
        if articles.contains(where: { $0.id == articleID.rawValue }) { return .alreadyAdded }
        // The article path replaces a run in flight; a phone request must not cancel the owner's work.
        guard !articlePreparationIsPending else { return .failed }
        let draft = urlDraft
        urlDraft = url.absoluteString
        addArticle()
        urlDraft = draft
        return articlePreparationIsPending ? .added : .failed
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
