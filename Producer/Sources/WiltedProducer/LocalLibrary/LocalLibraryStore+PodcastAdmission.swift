import CryptoKit
import Foundation
import SwiftData
import WiltedDomain
import WiltedSync

extension LocalLibraryStore {
    /// Which horizon a feed load is admitted against.
    ///
    /// `backfill` is the load that creates the subscription; `incremental` is
    /// every later refresh.
    public enum PodcastEpisodeAdmission: Sendable {
        case backfill
        case incremental
    }

    public struct PodcastEpisodeAdmissionResult: Equatable, Sendable {
        public let saved: [ItemID]
        /// IDs inserted by this exact admission, excluding rows refreshed in place.
        public let newlyAdmitted: [ItemID]
        public let skipped: Int
    }

    /// Persists only the episodes a subscribed feed should surface.
    ///
    /// Subscribing to a podcast must not empty its whole back catalogue into the
    /// Larder: a single feed in the 2026-08-31 survey carried 2,870 episodes. An
    /// episode is stored when Wilted already knows it -- so nothing already in
    /// the Larder can be evicted by this rule -- or when it published on or
    /// after the feed's admission horizon.
    ///
    /// The horizon is the subscription's own `subscribedAt` on a refresh, so
    /// every genuinely new episode arrives and nothing older does. On the load
    /// that creates the subscription it reaches back
    /// `podcastSubscriptionBackfillWindow`, and always admits at least
    /// `podcastSubscriptionMinimumBackfill` episodes, so subscribing to an
    /// infrequent podcast does not present an empty feed.
    ///
    /// An episode with no published date never clears a horizon, in either
    /// direction. Without a date there is no evidence it is new, and admitting
    /// undated items on refresh would leak an undated back catalogue a refresh
    /// at a time -- while admitting all of them on backfill would leak the same
    /// catalogue in one go. Undated episodes reach the Larder only through the
    /// `podcastSubscriptionMinimumBackfill` top-up, which is bounded. The cost
    /// is that a feed publishing no dates at all stalls at that count; every
    /// feed in the 2026-08-31 survey dates its episodes, and the withheld count
    /// on the Feeds card makes the stall visible rather than silent.
    ///
    /// Episodes whose feed has no subscription are saved unconditionally: the
    /// caller loaded a feed Wilted does not follow, and there is no horizon to
    /// judge them against.
    @discardableResult
    public func savePodcastEpisodes(
        _ episodes: [PodcastEpisode],
        admission: PodcastEpisodeAdmission
    ) throws -> PodcastEpisodeAdmissionResult {
        // One admission path, not two. A claiming limit of zero is exactly this
        // call, and keeping a second hand-written copy of the admit-and-upsert
        // sequence is how the two drift apart.
        try admitPodcastEpisodes(episodes, admission: admission, claimingNewest: 0).admission
    }

    /// What one admission claimed for automatic download.
    public struct PodcastAutomationAdmissionResult: Equatable, Sendable {
        public let admission: PodcastEpisodeAdmissionResult
        /// Episodes this call moved to `queued`. An episode that already has a
        /// download record is never claimed, so a manual transfer in flight
        /// keeps the state it is in.
        public let claimed: [ItemID]
    }

    /// Admits a feed's episodes and claims a bounded newest-first subset for
    /// automatic download in one save.
    ///
    /// Admitting and then enqueuing in two saves has a crash window that either
    /// loses the newly admitted set or replays it: the episode rows land, the
    /// process dies, and the next launch cannot tell which of them were new,
    /// because being new is a property of that one admission and nothing else
    /// records it. Claiming inside the same transaction closes the window --
    /// the rows and their claims are both durable or neither is.
    ///
    /// The claim is the download record itself rather than a parallel table.
    /// Automation must not restate download truth the store already owns, and a
    /// separate claim row is one more thing that can disagree with it.
    ///
    /// A `limit` of zero admits and claims nothing, which is what a manual
    /// download policy asks for, and `.backfill` claims nothing whatever the
    /// limit: subscribing is not a request to download a back catalogue.
    public func admitPodcastEpisodes(
        _ episodes: [PodcastEpisode],
        admission: PodcastEpisodeAdmission,
        claimingNewest limit: Int,
        claimedAt: Timestamp = Timestamp(Date())
    ) throws -> PodcastAutomationAdmissionResult {
        guard !episodes.isEmpty else {
            return PodcastAutomationAdmissionResult(
                admission: PodcastEpisodeAdmissionResult(saved: [], newlyAdmitted: [], skipped: 0),
                claimed: []
            )
        }
        let context = ModelContext(container)
        let existing = Set(
            try context.fetch(FetchDescriptor<LocalLibrarySchemaV13Models.PodcastEpisodeRecord>()).map(\.id)
        )
        let admitted = try admittedPodcastEpisodes(episodes, admission: admission, in: context)
        try upsertPodcastEpisodes(admitted, in: context)
        let newlyAdmitted = admitted.filter { !existing.contains($0.itemID.rawValue) }
        var claimed: [ItemID] = []
        // Backfill never claims, whatever the caller asks for. Subscribing is
        // not a request to download a back catalogue, and refusing here means a
        // future caller cannot make it one by passing a limit.
        if limit > 0, admission == .incremental {
            let tracked = Set(
                try context.fetch(FetchDescriptor<LocalLibrarySchemaV10Models.PodcastDownloadRecord>())
                    .map(\.episodeID)
            )
            // Newest first, so a capped policy takes the episodes a listener
            // would reach for rather than whichever order the feed parsed in.
            let eligible = Self.newestFirst(newlyAdmitted.filter { !tracked.contains($0.itemID.rawValue) })
            for episode in eligible.prefix(limit) {
                let claim = try PodcastDownload(episodeID: episode.itemID, status: .queued, updatedAt: claimedAt)
                context.insert(LocalLibrarySchemaV10Models.PodcastDownloadRecord(claim))
                claimed.append(episode.itemID)
            }
        }
        try context.save()
        return PodcastAutomationAdmissionResult(
            admission: PodcastEpisodeAdmissionResult(
                saved: admitted.map(\.itemID),
                newlyAdmitted: newlyAdmitted.map(\.itemID),
                skipped: episodes.count - admitted.count
            ),
            claimed: claimed
        )
    }

    /// Claims one episode for download, or reports that something already holds it.
    ///
    /// Manual and automatic entry points race: the listener presses Download on
    /// the episode an app-open refresh just admitted. Both would otherwise reach
    /// the download coordinator, which writes its queued record unconditionally,
    /// and the episode would transfer twice. This is the serialisation point --
    /// the insert happens only when no download record exists, and the store
    /// actor makes the check and the insert one step.
    ///
    /// How much existing state blocks a new claim.
    public enum PodcastDownloadClaimScope: Sendable {
        /// Automation: any download record at all means the episode is spoken
        /// for. A completed, failed, or cancelled transfer is a decision
        /// already made, and re-running it is the listener's call.
        case untouched
        /// A deliberate request: only a transfer in flight blocks it, so
        /// retrying a failure from the row still works.
        case notInFlight
    }

    /// Claims one episode for download, or reports that something already holds it.
    ///
    /// Manual and automatic entry points race: the listener presses Download on
    /// the episode an app-open refresh just admitted. Both would otherwise reach
    /// the download coordinator, which writes its queued record unconditionally,
    /// and the episode would transfer twice. This is the serialisation point --
    /// the insert happens only when the scope allows, and the store actor makes
    /// the check and the insert one step.
    @discardableResult
    public func claimPodcastDownload(
        episodeID: ItemID,
        scope: PodcastDownloadClaimScope = .untouched,
        at claimedAt: Timestamp = Timestamp(Date())
    ) throws -> Bool {
        let context = ModelContext(container)
        let records = try context.fetch(FetchDescriptor<LocalLibrarySchemaV10Models.PodcastDownloadRecord>())
        let existing = records.first(where: { $0.episodeID == episodeID.rawValue })
        switch scope {
        case .untouched:
            guard existing == nil else { return false }
        case .notInFlight:
            let inFlight = existing.flatMap { PodcastDownloadStatus(rawValue: $0.status) }
                .map { $0 == .queued || $0 == .downloading } ?? false
            guard !inFlight else { return false }
        }
        let claim = try PodcastDownload(episodeID: episodeID, status: .queued, updatedAt: claimedAt)
        if let existing {
            existing.status = claim.status.rawValue
            existing.bytesReceived = 0
            existing.expectedByteCount = nil
            existing.localURL = nil
            existing.contentHash = nil
            existing.updatedAt = claimedAt.date
            existing.failureKind = nil
        } else {
            context.insert(LocalLibrarySchemaV10Models.PodcastDownloadRecord(claim))
        }
        try context.save()
        return true
    }

    /// Claims that outlived the process that made them.
    ///
    /// A launch reconciles against this rather than against anything automation
    /// persisted separately: `queued` is claimed and not started, `downloading`
    /// is a transfer with no process behind it any more. Both are resumable, and
    /// the store is the only thing that knows which episodes they are.
    public func unfinishedPodcastDownloads() throws -> [PodcastDownload] {
        try downloads().filter { $0.status == .queued || $0.status == .downloading }
    }

    /// Failures a relaunch should retry without asking the user.
    ///
    /// Distinct from `unfinishedPodcastDownloads()`: those rows never reached
    /// a terminal state, these did and were classified `.retryable` by the
    /// coordinator's final catch. A `.terminal` failure is excluded on
    /// purpose — it needs user action, not another automatic attempt.
    public func resumablePodcastDownloads() throws -> [PodcastDownload] {
        try downloads().filter { $0.status == .failed && $0.failureKind == .retryable }
    }

    /// Creates a subscription once without moving its original admission horizon.
    ///
    /// Equivalent canonical feed URLs derive the same feed ID, so repeated manual
    /// or automatic admission returns `false` and leaves the existing row intact.
    @discardableResult
    public func subscribeIfNeeded(_ subscription: PodcastSubscription) throws -> Bool {
        let context = ModelContext(container)
        let records = try context.fetch(FetchDescriptor<LocalLibrarySchemaV6Models.PodcastSubscriptionRecord>())
        guard !records.contains(where: { $0.feedID == subscription.feedID.rawValue }) else { return false }
        context.insert(LocalLibrarySchemaV6Models.PodcastSubscriptionRecord(subscription))
        try context.save()
        return true
    }

    private func admittedPodcastEpisodes(
        _ episodes: [PodcastEpisode],
        admission: PodcastEpisodeAdmission,
        in context: ModelContext
    ) throws -> [PodcastEpisode] {
        let dismissed = Set(
            try context.fetch(FetchDescriptor<LocalLibrarySchemaV13Models.PodcastEpisodeRecord>())
                .filter { $0.removalKind == PodcastEpisodeRemovalKind.dismissed.rawValue }
                .map(\.id)
        )
        let candidates = episodes.filter { !dismissed.contains($0.itemID.rawValue) }
        guard !candidates.isEmpty else { return [] }
        let subscriptions = try context.fetch(FetchDescriptor<LocalLibrarySchemaV6Models.PodcastSubscriptionRecord>())
        let horizons = Dictionary(
            subscriptions.map { ($0.feedID, Self.admissionHorizon(subscribedAt: $0.subscribedAt, admission: admission)) },
            uniquingKeysWith: { first, _ in first }
        )
        let existing = Set(
            try context.fetch(FetchDescriptor<LocalLibrarySchemaV13Models.PodcastEpisodeRecord>()).map(\.id)
        )
        var admitted: [PodcastEpisode] = []
        for (feedID, group) in Dictionary(grouping: candidates, by: \.feedID.rawValue) {
            guard let horizon = horizons[feedID] else {
                admitted.append(contentsOf: group)
                continue
            }
            var kept = group.filter { episode in
                if existing.contains(episode.itemID.rawValue) { return true }
                guard let published = episode.publishedTime?.date else { return false }
                return published >= horizon
            }
            if admission == .backfill, kept.count < Self.podcastSubscriptionMinimumBackfill {
                let keptIDs = Set(kept.map(\.itemID.rawValue))
                kept.append(contentsOf: Self.newestFirst(group)
                    .filter { !keptIDs.contains($0.itemID.rawValue) }
                    .prefix(Self.podcastSubscriptionMinimumBackfill - kept.count))
            }
            admitted.append(contentsOf: kept)
        }
        return admitted
    }

    private func upsertPodcastEpisodes(
        _ episodes: [PodcastEpisode], in context: ModelContext
    ) throws {
        let records = try context.fetch(FetchDescriptor<LocalLibrarySchemaV13Models.PodcastEpisodeRecord>())
        var byID = Dictionary(records.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for episode in episodes {
            if let record = byID[episode.itemID.rawValue] {
                try Self.apply(episode, to: record)
            } else {
                let record = try LocalLibrarySchemaV13Models.PodcastEpisodeRecord(episode)
                context.insert(record)
                byID[episode.itemID.rawValue] = record
            }
        }
    }

    /// How far back the load that creates a subscription reaches.
    public static let podcastSubscriptionBackfillWindow: TimeInterval = 30 * 24 * 60 * 60
    /// The floor under that window, so an infrequent podcast is never empty.
    public static let podcastSubscriptionMinimumBackfill = 5

    /// A feed's episodes newest first, undated ones last.
    ///
    /// Ties keep the order the feed gave. That matters because Swift's sort is
    /// not stable: a group whose episodes share a date -- or carry no date at
    /// all -- would otherwise be shuffled, and the backfill top-up would admit
    /// an arbitrary handful instead of the ones the feed lists first.
    private static func newestFirst(_ episodes: [PodcastEpisode]) -> [PodcastEpisode] {
        episodes.enumerated().sorted { lhs, rhs in
            switch (lhs.element.publishedTime?.date, rhs.element.publishedTime?.date) {
            case let (left?, right?) where left != right: return left > right
            case (nil, .some): return false
            case (.some, nil): return true
            default: return lhs.offset < rhs.offset
            }
        }.map(\.element)
    }

    private static func admissionHorizon(subscribedAt: Date, admission: PodcastEpisodeAdmission) -> Date {
        switch admission {
        case .backfill: subscribedAt.addingTimeInterval(-podcastSubscriptionBackfillWindow)
        case .incremental: subscribedAt
        }
    }

}
