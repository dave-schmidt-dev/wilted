import CryptoKit
import Foundation
import SwiftData
import WiltedDomain

extension LocalLibraryStore {
    /// Every recorded preparation attempt, newest first.
    ///
    /// A run that emitted no terminal status is reported as non-terminal at
    /// whatever stage it last reached, rather than being dropped. A process
    /// that died mid-synthesis is exactly the run a reader most wants to see.
    public func preparationRuns(limit: Int = 200) throws -> [PreparationRunSummary] {
        let context = ModelContext(container)
        return try allPreparationRunSummaries(in: context).prefix(max(0, limit)).map { $0 }
    }

    /// Every recorded preparation attempt, newest first, with no cap.
    ///
    /// `preparationRuns(limit:)`'s cap exists for Prep's display list, not
    /// for correctness -- a caller that needs every subscribed episode's
    /// evidence (the Larder projection) reads this directly instead of
    /// passing an unbounded `limit`, which would otherwise make the display
    /// cap's own default meaningless as a contract.
    private func allPreparationRunSummaries(in context: ModelContext) throws -> [PreparationRunSummary] {
        let decoder = JSONDecoder()
        var byRequest: [String: [PreparationJournalEntry]] = [:]
        for record in try context.fetch(FetchDescriptor<LocalLibrarySchemaV3Models.PreparationRecord>()) {
            // Pipeline invalidation markers are durable scheduling state, not
            // preparation attempts. Keeping them out of run history also
            // prevents bootstrap from closing a pending marker as an
            // interrupted preparation and showing a phantom failed job.
            guard !record.requestID.hasPrefix(Self.forcedRedownloadRequestPrefix),
                  !record.requestID.hasPrefix(Self.resetPreparationRequestPrefix) else { continue }
            guard let status = try? decoder.decode(PreparationStatus.self, from: record.statusData),
                  let itemID = try? ItemID(rawValue: record.itemID) else { continue }
            byRequest[record.requestID + (status.attempt.map { "|" + $0.key } ?? ""), default: []].append(
                PreparationJournalEntry(id: record.id, itemID: itemID, requestID: record.requestID, status: status)
            )
        }
        return byRequest.compactMap { _, entries -> PreparationRunSummary? in
            let ordered = entries.sorted(by: preparationEntryPrecedes)
            guard let first = ordered.first, let last = ordered.last else { return nil }
            let terminal = ordered.last(where: { $0.status.terminal })?.status
            let representative = terminal ?? last.status
            return PreparationRunSummary(
                requestID: last.requestID,
                itemID: last.itemID,
                startedAt: first.status.emittedAt,
                updatedAt: last.status.emittedAt,
                stage: representative.stage,
                detail: representative.detail,
                fraction: representative.fraction,
                isTerminal: terminal != nil,
                outcome: terminal?.terminalResult?.outcome,
                failure: terminal?.terminalResult?.error,
                entries: ordered
            )
        }
        .sorted { $0.updatedAt.date > $1.updatedAt.date }
    }

    /// One batched, indexed read of everything the Larder projection needs.
    ///
    /// `loadLibrary` used to call `readyRevision(for:)`,
    /// `playbackState(for:revisionID:)`, `transcript(for:revisionID:)`,
    /// `preparationOutcome(for:revisionID:)`, `listeningState(for:)`, and
    /// `retiredAt(for:)` once per article/episode, each of those doing its
    /// own unfiltered full-table fetch -- a full-table scan repeated once per
    /// item per field. This fetches each table exactly once and hands back
    /// indexed dictionaries, so the read cost stays flat as the library
    /// grows.
    public struct PodcastLibrarySnapshot: Sendable {
        public let articles: [Article]
        public let episodes: [PodcastEpisode]
        public let feeds: [ItemID: PodcastFeed]
        public let subscriptions: [PodcastSubscription]
        /// Ordered membership and current item from the same non-suspending actor read.
        public let podcastQueue: PodcastQueueState
        public let downloads: [ItemID: PodcastDownload]
        public let readyRevisions: [ItemID: StoredAudioRevision]
        /// Keyed `"itemID|revisionID"`, matching every other composite-keyed table in this store.
        public let playbackStates: [String: PlaybackState]
        public let transcripts: [String: Transcript]
        public let preparationOutcomes: [String: PodcastPreparationOutcome]
        public let listeningStates: [ItemID: PodcastListeningState]
        /// The owner's latest keep/skip decision per episode; the store keeps
        /// one row per episode, so later writes replace earlier ones.
        public let episodeDecisions: [ItemID: EpisodeDecisionRecord]
        public let retiredAtByEpisode: [ItemID: Timestamp]
        /// Which removal kind, if any, wrote `retiredAtByEpisode`'s
        /// timestamp -- what distinguishes a retired row from a dismissed one
        /// once both survive as episode rows.
        public let removalKindByEpisode: [ItemID: PodcastEpisodeRemovalKind]
        /// Every recorded preparation run, uncapped -- see `allPreparationRunSummaries`.
        public let preparationRuns: [PreparationRunSummary]
        /// Followed article feeds, by title. Not in `feeds`, which holds podcast feeds only.
        public let articleFeeds: [ArticleFeed]
        /// The feed each feed-saved article came from; a hand-added article has no entry.
        public let feedIDByArticle: [ItemID: ItemID]
        /// Every audiobook volume, removed ones included (`isRemoved`).
        public let audiobooks: [StoredAudiobook]
    }

    /// Publication retains export metadata and media proof without loading display-only payloads.
    public enum PodcastLibrarySnapshotProfile: Sendable, Equatable {
        case full
        case publication
    }

    public func podcastLibrarySnapshot(profile: PodcastLibrarySnapshotProfile = .full) throws -> PodcastLibrarySnapshot {
        let context = ModelContext(container)

        podcastLibrarySnapshotFetchCount += 1
        let articleValues = try articles()

        podcastLibrarySnapshotFetchCount += 1
        let episodeRecords = try context.fetch(FetchDescriptor<LocalLibrarySchemaV13Models.PodcastEpisodeRecord>())
            .sorted { ($0.publishedTime ?? $0.createdAt) > ($1.publishedTime ?? $1.createdAt) }
        let links = try episodeLinks(in: context)
        let episodeValues = episodeRecords.compactMap { Self.decodePodcastEpisode($0, link: links[$0.id]) }
        var retiredAtByEpisode: [ItemID: Timestamp] = [:]
        var removalKindByEpisode: [ItemID: PodcastEpisodeRemovalKind] = [:]
        for record in episodeRecords {
            guard let itemID = try? ItemID(rawValue: record.id), let retiredAt = record.retiredAt else { continue }
            retiredAtByEpisode[itemID] = Timestamp(retiredAt)
            if let kind = record.removalKind.flatMap(PodcastEpisodeRemovalKind.init(rawValue:)) {
                removalKindByEpisode[itemID] = kind
            }
        }

        podcastLibrarySnapshotFetchCount += 1
        let feeds = Dictionary(uniqueKeysWithValues: try podcastFeeds().map { ($0.itemID, $0) })

        podcastLibrarySnapshotFetchCount += 1
        let subscriptionValues = try subscriptions()

        podcastLibrarySnapshotFetchCount += 1
        let podcastQueue = try podcastQueueState()

        podcastLibrarySnapshotFetchCount += 1
        let downloads = Dictionary(uniqueKeysWithValues: try self.downloads().map { ($0.episodeID, $0) })

        podcastLibrarySnapshotFetchCount += 1
        let readyRevisions = Dictionary(
            uniqueKeysWithValues: try newestReadyRevisionsByItemID(in: context).compactMap { itemIDRaw, revision -> (ItemID, StoredAudioRevision)? in
                guard let itemID = try? ItemID(rawValue: itemIDRaw) else { return nil }
                return (itemID, revision)
            }
        )

        podcastLibrarySnapshotFetchCount += 1
        var playbackStates: [String: PlaybackState] = [:]
        for record in try context.fetch(FetchDescriptor<LocalLibrarySchemaV3Models.PlaybackRecord>()) {
            guard let itemID = try? ItemID(rawValue: record.itemID), let revisionID = try? RevisionID(rawValue: record.revisionID),
                  let state = try? PlaybackState(
                      itemID: itemID, revisionID: revisionID, sessionID: record.sessionID, sequence: record.sequence,
                      positionSeconds: record.positionSeconds, durationSeconds: record.durationSeconds, completed: record.completed,
                      intent: PlaybackIntent(rawValue: record.intent) ?? .progress, deviceID: record.deviceID,
                      encodedCloudKitRecordSystemFields: record.encodedCloudKitRecordSystemFields, updatedAt: Timestamp(record.updatedAt)
                  ) else { continue }
            playbackStates["\(record.itemID)|\(record.revisionID)"] = state
        }

        var transcripts: [String: Transcript] = [:]
        if profile == .full {
            podcastLibrarySnapshotFetchCount += 1
            for record in try context.fetch(FetchDescriptor<LocalLibrarySchemaV7Models.TranscriptRecord>()) {
                guard let transcript = try? decodeTranscript(record) else { continue }
                transcripts["\(record.itemID)|\(record.revisionID)"] = transcript
            }
        }

        podcastLibrarySnapshotFetchCount += 1
        var preparationOutcomes: [String: PodcastPreparationOutcome] = [:]
        for record in try context.fetch(FetchDescriptor<LocalLibrarySchemaV10Models.PodcastPreparationOutcomeRecord>()) {
            guard let episodeID = try? ItemID(rawValue: record.episodeID), let revisionID = try? RevisionID(rawValue: record.revisionID),
                  let eligibility = PodcastPreparationEligibility(rawValue: record.eligibility) else { continue }
            preparationOutcomes["\(record.episodeID)|\(record.revisionID)"] = PodcastPreparationOutcome(
                episodeID: episodeID, revisionID: revisionID, policyDigest: record.policyDigest,
                pipelineFingerprint: record.pipelineFingerprint, semanticVersion: record.semanticVersion,
                producedAt: Timestamp(record.producedAt), eligibility: eligibility,
                invalidationRuleID: record.invalidationRuleID
            )
        }

        podcastLibrarySnapshotFetchCount += 1
        var listeningStates: [ItemID: PodcastListeningState] = [:]
        for record in try context.fetch(FetchDescriptor<LocalLibrarySchemaV10Models.PodcastListeningRecord>()) {
            guard let episodeID = try? ItemID(rawValue: record.id) else { continue }
            listeningStates[episodeID] = PodcastListeningState(
                episodeID: episodeID, completedAt: record.completedAt.map(Timestamp.init),
                lastRevisionID: record.lastRevisionID.flatMap { try? RevisionID(rawValue: $0) },
                updatedAt: Timestamp(record.updatedAt)
            )
        }

        podcastLibrarySnapshotFetchCount += 1
        var episodeDecisions: [ItemID: EpisodeDecisionRecord] = [:]
        for record in try context.fetch(FetchDescriptor<LocalLibrarySchemaV16Models.EpisodeDecisionRecord>()) {
            guard let episodeID = try? ItemID(rawValue: record.episodeID),
                  let decision = EpisodeDecision(rawValue: record.decision),
                  let source = EpisodeDecisionSource(rawValue: record.source) else { continue }
            episodeDecisions[episodeID] = EpisodeDecisionRecord(
                episodeID: episodeID, decision: decision, source: source,
                ruleID: record.ruleID, decidedAt: Timestamp(record.decidedAt)
            )
        }

        var preparationRuns: [PreparationRunSummary] = []
        if profile == .full {
            podcastLibrarySnapshotFetchCount += 1
            preparationRuns = try allPreparationRunSummaries(in: context)
        }

        podcastLibrarySnapshotFetchCount += 1
        let articleFeedValues = try articleFeeds()

        podcastLibrarySnapshotFetchCount += 1
        var feedIDByArticle: [ItemID: ItemID] = [:]
        for record in try context.fetch(FetchDescriptor<LocalLibrarySchemaV17Models.ArticleRecord>()) {
            guard let feedRaw = record.feedID, let articleID = try? ItemID(rawValue: record.id),
                  let feedID = try? ItemID(rawValue: feedRaw) else { continue }
            feedIDByArticle[articleID] = feedID
        }

        podcastLibrarySnapshotFetchCount += 1
        let audiobookValues = try audiobooks()

        return PodcastLibrarySnapshot(
            articles: articleValues, episodes: episodeValues, feeds: feeds, subscriptions: subscriptionValues,
            podcastQueue: podcastQueue,
            downloads: downloads, readyRevisions: readyRevisions, playbackStates: playbackStates,
            transcripts: transcripts, preparationOutcomes: preparationOutcomes, listeningStates: listeningStates,
            episodeDecisions: episodeDecisions,
            retiredAtByEpisode: retiredAtByEpisode, removalKindByEpisode: removalKindByEpisode,
            preparationRuns: preparationRuns, articleFeeds: articleFeedValues,
            feedIDByArticle: feedIDByArticle, audiobooks: audiobookValues
        )
    }

}
