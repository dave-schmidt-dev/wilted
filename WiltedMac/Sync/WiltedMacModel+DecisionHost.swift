import Foundation
import WiltedDomain
import WiltedLibrary

#if canImport(WiltedProducer)
import WiltedProducer

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
        guard (try? ItemID.derivePodcastFeed(from: url)) != nil, store != nil else { return .failed }
        let kind: PastedLinkKind
        do { kind = try await pastedLinkClassifier.classify(url) } catch { return .failed }
        guard case .podcastFeed = kind else { return .notAPodcastFeed }
        return await subscribeClassifiedFeed(url)
    }

    func addLink(_ url: URL) async -> WiltedMacAddResult {
        let kind: PastedLinkKind
        do { kind = try await pastedLinkClassifier.classify(url) } catch { return .failed }
        switch kind {
        case .podcastFeed:
            return await subscribeClassifiedFeed(url)
        case let .podcastCatalogShow(show):
            return await subscribeClassifiedFeed(show.feedURL)
        case .article, .articleAdvertisingFeed:
            return await addClassifiedArticle(url)
        }
    }

    private func subscribeClassifiedFeed(_ url: URL) async -> WiltedMacAddResult {
        guard let feedID = try? ItemID.derivePodcastFeed(from: url), store != nil else { return .failed }
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
        if articles.contains(where: { $0.id == articleID.rawValue }) { return .alreadyAdded }
        let kind: PastedLinkKind
        do { kind = try await pastedLinkClassifier.classify(url) } catch { return .failed }
        switch kind {
        case .podcastFeed, .podcastCatalogShow: return .isAFeed
        case .article, .articleAdvertisingFeed: return await startClassifiedArticle(url)
        }
    }

    private func addClassifiedArticle(_ url: URL) async -> WiltedMacAddResult {
        guard let articleID = try? ItemID.derive(from: url) else { return .failed }
        if articles.contains(where: { $0.id == articleID.rawValue }) { return .alreadyAdded }
        return await startClassifiedArticle(url)
    }

    private func startClassifiedArticle(_ url: URL) async -> WiltedMacAddResult {
        // The article path replaces a run in flight; a phone request must not cancel the owner's work.
        guard !articlePreparationIsPending else { return .failed }
        let draft = urlDraft
        urlDraft = url.absoluteString
        let started = addArticle()
        urlDraft = draft
        return started ? .added : .failed
    }

    /// Runs a model method that starts durable work and waits for the writers it registered, then
    /// for any feed decision still in flight for the same entry (a repeated request is not admitted).
    func awaitingDecisionWriters(_ start: () -> Void) async {
        let before = Set(subscriptionWriteTasks.keys)
        start()
        let mine = subscriptionWriteTasks.filter { !before.contains($0.key) }.map(\.value)
        for task in mine { await task.value }
        if let token = feedDecisionWriteTailToken, let tail = subscriptionWriteTasks[token] { await tail.value }
    }
}
#endif
