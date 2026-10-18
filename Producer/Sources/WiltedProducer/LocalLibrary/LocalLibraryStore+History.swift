import Foundation
import SwiftData
import WiltedDomain
import WiltedLibrary

private typealias HistoryEpisodeRecord = LocalLibrarySchemaV13Models.PodcastEpisodeRecord
private typealias HistoryListeningRecord = LocalLibrarySchemaV10Models.PodcastListeningRecord
private typealias HistoryDecisionRecord = LocalLibrarySchemaV16Models.EpisodeDecisionRecord

/// How a History predicate treats the completed-episode identifier set.
private enum HistoryCompletionMembership {
    /// No status filter: completion is not consulted.
    case any
    /// Only rows whose identifier is in the completed set.
    case completed([String])
    /// Only rows whose identifier is not in the completed set.
    case notCompleted([String])
}

extension LocalLibraryStore {
    /// Why a removed episode left its feed, as History shows it.
    public enum HistoryStatus: String, Codable, Equatable, Sendable {
        /// The listener finished the episode: its listening record carries a
        /// completion. Takes precedence over every skip classification.
        case played
        /// Removed without being finished, by hand or by policy.
        case skipped
        /// Removed without being finished, and the episode's decision record
        /// says a feed rule skipped it.
        case skippedByRule
    }

    /// Which History rows a page should contain.
    public enum HistoryStatusFilter: String, Codable, Equatable, Sendable {
        /// Only `HistoryStatus.played` rows.
        case played
        /// Every row that is not played: `skipped` and `skippedByRule`.
        case skipped
    }

    /// One removed episode, carrying what History renders and restores.
    public struct HistoryRow: Equatable, Sendable {
        /// The episode to restore.
        public let episodeID: ItemID
        /// The stored episode title.
        public let title: String
        /// The feed the episode belongs to.
        public let feedID: ItemID
        /// When the feed published the episode; nil when the feed did not say,
        /// and always nil for a legacy dismissal placeholder.
        public let publishedTime: Timestamp?
        /// Episode artwork published with the feed, when present.
        public let artworkURL: URL?
        /// The duration the feed published for the enclosure, if any.
        public let durationSeconds: Double?
        /// When the removal was recorded, whichever kind wrote it.
        public let retiredAt: Timestamp?
        /// Which removal the row carries; a dismissal is the stronger one.
        public let removalKind: PodcastEpisodeRemovalKind
        /// Played or skipped, derived from completion and the decision record.
        public let status: HistoryStatus
        /// The skipping rule, present only when `status` is `.skippedByRule`.
        public let ruleID: UUID?

        /// Creates a History row. `artworkURL` defaults to nil for callers
        /// constructing rows from older data sources.
        public init(
            episodeID: ItemID,
            title: String,
            feedID: ItemID,
            publishedTime: Timestamp?,
            durationSeconds: Double?,
            retiredAt: Timestamp?,
            removalKind: PodcastEpisodeRemovalKind,
            status: HistoryStatus,
            ruleID: UUID?,
            artworkURL: URL? = nil
        ) {
            self.episodeID = episodeID
            self.title = title
            self.feedID = feedID
            self.publishedTime = publishedTime
            self.durationSeconds = durationSeconds
            self.retiredAt = retiredAt
            self.removalKind = removalKind
            self.status = status
            self.ruleID = ruleID
            self.artworkURL = artworkURL
        }
    }

    /// One page of History plus the size of the whole filtered set.
    public struct HistoryPage: Equatable, Sendable {
        /// At most `limit` rows in the requested order; Custom defaults to newest removal first.
        public let rows: [HistoryRow]
        /// How many rows match the feed, search, and status filter in total.
        public let total: Int
        /// The offset the page starts at, after clamping a negative request to zero.
        public let offset: Int
    }

    /// Returns one page of removed episodes, newest removal first by default.
    ///
    /// A row is an episode of `feedID` (of any feed when `feedID` is nil)
    /// whose `removalKind` is `retired` or `dismissed`; an episode still on
    /// the shelf never appears. Rows are
    /// ordered by `retiredAt` descending, ties broken by episode identifier
    /// in ascending lexical order when `sort` is `.custom`, so consecutive
    /// pages neither overlap nor skip a row while the library is unchanged.
    /// Calculated sorts scan scalar metadata in stable batches before slicing
    /// a page; full History rows are hydrated only for that page.
    ///
    /// The feed, removal, and search conditions are one SwiftData predicate:
    /// `total` comes from `fetchCount` and the rows from `fetchOffset` /
    /// `fetchLimit` on that predicate, so a page never materialises the
    /// episode table. Search is a case- and diacritic-insensitive title
    /// contains (`localizedStandardContains`), which SwiftData evaluates in
    /// the store on macOS 14; surrounding whitespace is ignored and a blank
    /// search means no search.
    ///
    /// Completion lives in the listening table, which has no relationship to
    /// the episode table, so a predicate cannot join it. A status filter is
    /// therefore resolved with the identifiers of completed listening records
    /// (identifiers only, read only when `status` is non-nil) captured into
    /// the same predicate as an `IN` / `NOT IN` condition. Counting and paging
    /// stay in the store, so `total`, `offset`, and `limit` are exact for the
    /// filtered set; the extra read is bounded by the number of completed
    /// episodes, not by the episode table. Without a status filter nothing
    /// outside the page is read.
    ///
    /// Completion and the decision record are then joined only for the
    /// identifiers on the page. A completed episode is `.played`; otherwise
    /// a `skip` decision whose source is `rule` makes it `.skippedByRule`
    /// (carrying that rule's identifier); anything else is `.skipped`.
    ///
    /// - Parameters:
    ///   - feedID: The feed whose History is read, or nil for every feed's.
    ///   - search: Optional title text to match; `nil` or blank matches every title.
    ///   - status: `.played`, `.skipped` (rule skips included), or `nil` for every row.
    ///   - sort: Shared episode sort. `.custom` preserves History's existing
    ///     newest-removal-first order.
    ///   - direction: Direction for calculated sorts; `.custom` preserves its
    ///     existing order regardless of direction.
    ///   - offset: Rows to skip before the page; negative values read as zero.
    ///   - limit: Maximum rows on the page; zero or negative returns no rows
    ///     but still reports `total`.
    /// - Returns: The page and the filtered total.
    /// - Throws: A SwiftData fetch error.
    public func historyPage(
        feedID: ItemID?,
        search: String? = nil,
        status: HistoryStatusFilter? = nil,
        sort: LibraryEpisodeOrdering.Sort = .custom,
        direction: LibraryEpisodeOrdering.Direction = .ascending,
        offset: Int = 0,
        limit: Int
    ) throws -> HistoryPage {
        let context = ModelContext(container)
        let start = max(0, offset)
        let trimmed = search?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let needle = trimmed.isEmpty ? nil : trimmed

        let membership: HistoryCompletionMembership
        switch status {
        case nil:
            membership = .any
        case .played?:
            let completed = try Self.completedEpisodeIdentifiers(in: context)
            guard !completed.isEmpty else { return HistoryPage(rows: [], total: 0, offset: start) }
            membership = .completed(completed)
        case .skipped?:
            let completed = try Self.completedEpisodeIdentifiers(in: context)
            membership = completed.isEmpty ? .any : .notCompleted(completed)
        }

        let predicate = Self.historyPredicate(feed: feedID?.rawValue, needle: needle, membership: membership)
        let total = try context.fetchCount(FetchDescriptor<HistoryEpisodeRecord>(predicate: predicate))
        // A `fetchLimit` of zero means "no limit" to the store, so a
        // non-positive limit must return before it reaches the descriptor.
        guard limit > 0, start < total else { return HistoryPage(rows: [], total: total, offset: start) }

        let records: [HistoryEpisodeRecord]
        if sort == .custom {
            var descriptor = FetchDescriptor<HistoryEpisodeRecord>(
                predicate: predicate,
                sortBy: [
                    SortDescriptor(\.retiredAt, order: .reverse),
                    SortDescriptor(\.id, comparator: .lexical),
                ]
            )
            descriptor.fetchOffset = start
            descriptor.fetchLimit = limit
            records = try context.fetch(descriptor)
        } else {
            let pageIDs = try historyOrderedPageIDs(
                matching: predicate,
                total: total,
                offset: start,
                limit: limit,
                sort: sort,
                direction: direction,
                in: context
            )
            guard !pageIDs.isEmpty else { return HistoryPage(rows: [], total: total, offset: start) }
            let selectedIDs = pageIDs
            let selected = try context.fetch(FetchDescriptor<HistoryEpisodeRecord>(
                predicate: #Predicate { selectedIDs.contains($0.id) }
            ))
            let byID = Dictionary(uniqueKeysWithValues: selected.map { ($0.id, $0) })
            records = pageIDs.compactMap { byID[$0] }
        }
        let rows = try Self.historyRows(for: records, in: context)
        return HistoryPage(rows: rows, total: total, offset: start)
    }

    /// Joins completion and rule decisions for one page's records only.
    private static func historyRows(
        for records: [HistoryEpisodeRecord],
        in context: ModelContext
    ) throws -> [HistoryRow] {
        let pageIDs = records.map(\.id)
        guard !pageIDs.isEmpty else { return [] }
        let completedOnPage = Set(try context.fetch(FetchDescriptor<HistoryListeningRecord>(
            predicate: #Predicate { pageIDs.contains($0.id) && $0.completedAt != nil }
        )).map(\.id))
        let skip = EpisodeDecision.skip.rawValue
        let rule = EpisodeDecisionSource.rule.rawValue
        let ruleSkips = try context.fetch(FetchDescriptor<HistoryDecisionRecord>(
            predicate: #Predicate { pageIDs.contains($0.episodeID) && $0.decision == skip && $0.source == rule }
        ))
        let ruleByEpisode = Dictionary(
            ruleSkips.map { ($0.episodeID, $0.ruleID) }, uniquingKeysWith: { first, _ in first }
        )

        return records.compactMap { record in
            guard let episodeID = try? ItemID(rawValue: record.id),
                  let feedID = try? ItemID(rawValue: record.feedID),
                  let kind = record.removalKind.flatMap(PodcastEpisodeRemovalKind.init(rawValue:)) else { return nil }
            let status: HistoryStatus
            var ruleID: UUID?
            if completedOnPage.contains(record.id) {
                status = .played
            } else if let skippingRule = ruleByEpisode[record.id] {
                status = .skippedByRule
                ruleID = skippingRule
            } else {
                status = .skipped
            }
            return HistoryRow(
                episodeID: episodeID, title: record.title, feedID: feedID,
                publishedTime: record.publishedTime.map(Timestamp.init), durationSeconds: record.durationSeconds,
                retiredAt: record.retiredAt.map(Timestamp.init), removalKind: kind,
                status: status, ruleID: ruleID,
                artworkURL: record.artworkURL.flatMap(URL.init(string:))
            )
        }
    }

    /// Identifiers of every episode with a recorded completion, read without
    /// the rest of the listening record. The single definition of "played"
    /// shared by the status filter and the per-row status.
    private static func completedEpisodeIdentifiers(in context: ModelContext) throws -> [String] {
        var descriptor = FetchDescriptor<HistoryListeningRecord>(predicate: #Predicate { $0.completedAt != nil })
        descriptor.propertiesToFetch = [\.id]
        return try context.fetch(descriptor).map(\.id)
    }

    /// Builds the History predicate. Each combination is its own literal
    /// `#Predicate` rather than one predicate with captured flags, so every
    /// variant SwiftData sees is a plain conjunction it can translate. A nil
    /// `feed` drops the feed condition: every feed's History.
    private static func historyPredicate(
        feed: String?,
        needle: String?,
        membership: HistoryCompletionMembership
    ) -> Predicate<HistoryEpisodeRecord> {
        guard let feed else { return everyFeedHistoryPredicate(needle: needle, membership: membership) }
        let retired: String? = PodcastEpisodeRemovalKind.retired.rawValue
        let dismissed: String? = PodcastEpisodeRemovalKind.dismissed.rawValue
        switch (needle, membership) {
        case (nil, .any):
            return #Predicate {
                $0.feedID == feed && ($0.removalKind == retired || $0.removalKind == dismissed)
            }
        case let (term?, .any):
            return #Predicate {
                $0.feedID == feed && ($0.removalKind == retired || $0.removalKind == dismissed)
                    && $0.title.localizedStandardContains(term)
            }
        case let (nil, .completed(ids)):
            return #Predicate {
                $0.feedID == feed && ($0.removalKind == retired || $0.removalKind == dismissed)
                    && ids.contains($0.id)
            }
        case let (term?, .completed(ids)):
            return #Predicate {
                $0.feedID == feed && ($0.removalKind == retired || $0.removalKind == dismissed)
                    && $0.title.localizedStandardContains(term) && ids.contains($0.id)
            }
        case let (nil, .notCompleted(ids)):
            return #Predicate {
                $0.feedID == feed && ($0.removalKind == retired || $0.removalKind == dismissed)
                    && !ids.contains($0.id)
            }
        case let (term?, .notCompleted(ids)):
            return #Predicate {
                $0.feedID == feed && ($0.removalKind == retired || $0.removalKind == dismissed)
                    && $0.title.localizedStandardContains(term) && !ids.contains($0.id)
            }
        }
    }

    /// The all-feeds History predicates: the same six variants as
    /// `historyPredicate(feed:needle:membership:)` without the feed condition.
    private static func everyFeedHistoryPredicate(
        needle: String?,
        membership: HistoryCompletionMembership
    ) -> Predicate<HistoryEpisodeRecord> {
        let retired: String? = PodcastEpisodeRemovalKind.retired.rawValue
        let dismissed: String? = PodcastEpisodeRemovalKind.dismissed.rawValue
        switch (needle, membership) {
        case (nil, .any):
            return #Predicate { $0.removalKind == retired || $0.removalKind == dismissed }
        case let (term?, .any):
            return #Predicate {
                ($0.removalKind == retired || $0.removalKind == dismissed) && $0.title.localizedStandardContains(term)
            }
        case let (nil, .completed(ids)):
            return #Predicate {
                ($0.removalKind == retired || $0.removalKind == dismissed) && ids.contains($0.id)
            }
        case let (term?, .completed(ids)):
            return #Predicate {
                ($0.removalKind == retired || $0.removalKind == dismissed)
                    && $0.title.localizedStandardContains(term) && ids.contains($0.id)
            }
        case let (nil, .notCompleted(ids)):
            return #Predicate {
                ($0.removalKind == retired || $0.removalKind == dismissed) && !ids.contains($0.id)
            }
        case let (term?, .notCompleted(ids)):
            return #Predicate {
                ($0.removalKind == retired || $0.removalKind == dismissed)
                    && $0.title.localizedStandardContains(term) && !ids.contains($0.id)
            }
        }
    }
}
