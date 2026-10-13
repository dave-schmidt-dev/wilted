import SwiftUI
import WiltedProducer

/// What History calls a row. Retirement records both a manual skip and a
/// finished episode, so the label follows completion, not the stored removal.
/// A skip a feed rule made says so, so a wrong rule skip is easy to find.
enum WiltedMacFeedHistoryStatus: String, CaseIterable, Identifiable {
    case played = "Played"
    case skipped = "Skipped"
    case skippedByRule = "Skipped by rule"

    var id: String { rawValue }
}

struct WiltedMacFeedHistoryRecord: Identifiable, Equatable {
    /// The stored removal behind a row. Restore and its identifier follow
    /// this, never the label: a played row restores exactly like a skipped one.
    enum Kind: Equatable {
        case retired
        /// A legacy dismissal. Nothing writes these now; old rows still restore.
        case dismissed
    }

    let id: String
    let feedID: String?
    let feedTitle: String?
    let presentation: WiltedMacEpisodePresentation
    let kind: Kind
    let status: WiltedMacFeedHistoryStatus
    let changedAt: Date?
}

extension WiltedMacFeedHistoryRecord {
    /// One store History row as History draws it. The store decides the
    /// status: a completed episode reads Played; otherwise a feed rule's skip
    /// decision reads Skipped by rule, and anything else reads Skipped.
    init(row: LocalLibraryStore.HistoryRow, feedTitle: String?) {
        let status: WiltedMacFeedHistoryStatus = switch row.status {
        case .played: .played
        case .skipped: .skipped
        case .skippedByRule: .skippedByRule
        }
        self.init(
            id: row.episodeID.rawValue,
            feedID: row.feedID.rawValue,
            feedTitle: feedTitle,
            presentation: WiltedMacEpisodePresentation(
                title: row.title, showTitle: feedTitle, publishedAt: row.publishedTime?.date,
                sourceDurationSeconds: row.durationSeconds, playableDurationSeconds: nil
            ),
            kind: row.removalKind == .retired ? .retired : .dismissed,
            status: status,
            changedAt: row.retiredAt?.date
        )
    }

    /// Sends this row's Restore through the model, unchanged: it writes a
    /// manual Keep, so a feed rule never skips the episode again. The episode
    /// is found where it always was: a retired row in the model's episodes, a
    /// dismissal in its dismissed list. A row neither holds (a disabled feed's
    /// episode, say) restores through the store's removal-agnostic restore,
    /// which records the same manual Keep. Returns the model tasks the Restore
    /// started, so the caller can reload once the write commits.
    @MainActor
    func requestRestore(through model: WiltedMacModel) -> [Task<Void, Never>] {
        switch kind {
        case .retired:
            if let episode = model.episodes.first(where: { $0.id == id }) {
                let before = Set(model.subscriptionWriteTasks.keys)
                model.restoreSkippedFeedEpisode(episode)
                return model.subscriptionWriteTasks.filter { !before.contains($0.key) }.map(\.value)
            }
        case .dismissed:
            if let dismissal = model.dismissedEpisodes.first(where: { $0.id == id }) {
                model.restoreEpisode(dismissal)
                return model.podcastRestoreTasks[id].map { [$0] } ?? []
            }
        }
        model.restoreEpisode(storeRestoreDismissal)
        return model.podcastRestoreTasks[id].map { [$0] } ?? []
    }

    /// The row as a dismissal, for a Restore whose episode the model does not
    /// hold in memory. The store's restore clears either removal kind.
    var storeRestoreDismissal: WiltedMacDismissedEpisode {
        WiltedMacDismissedEpisode(
            id: id, feedID: feedID, title: presentation.title, feedTitle: feedTitle,
            publishedAt: presentation.publishedAt, sourceDurationSeconds: presentation.sourceDurationSeconds,
            dismissedAt: changedAt ?? Date(), hasPreparationHistory: false
        )
    }
}

/// Searchable, filtered history shared by the global Off the list page and feed
/// details. It renders one store page at a time from its loader; search and
/// page state stay independent of the Feeds inbox selection and scroll anchor.
struct WiltedMacFeedHistoryView: View {
    let model: WiltedMacModel
    var feedID: String?
    @Environment(\.colorScheme) private var colorScheme
    @State private var loader: WiltedMacFeedHistoryLoader

    /// `loader` lets a test hand in a loader whose page is already loaded.
    init(model: WiltedMacModel, feedID: String? = nil, loader: WiltedMacFeedHistoryLoader? = nil) {
        self.model = model
        self.feedID = feedID
        _loader = State(initialValue: loader ?? WiltedMacFeedHistoryLoader())
    }

    /// Restarts the load when the scope changes or the store becomes available.
    private struct LoadKey: Hashable {
        let feedID: String?
        let hasStore: Bool
    }

    var body: some View {
        Group {
            if let feedID {
                historyContent(onlyFeedID: feedID)
            } else {
                WiltedMacDestination(
                    title: "History",
                    identifier: "wilted-mac-feed-history",
                    contentWidth: 760
                ) {
                    historyContent(onlyFeedID: nil)
                }
                .frame(minWidth: 620, minHeight: 520)
            }
        }
        .task(id: LoadKey(feedID: feedID, hasStore: model.store != nil)) {
            if model.store != nil { loader.useStore(of: model) }
            await loader.start(feedID: feedID)
        }
    }

    /// The page's rows, titled by the subscriptions the model already holds.
    private var records: [WiltedMacFeedHistoryRecord] {
        let titles = Dictionary(model.subscriptions.map { ($0.id, $0.title) }, uniquingKeysWith: { first, _ in first })
        return loader.rows.map { WiltedMacFeedHistoryRecord(row: $0, feedTitle: titles[$0.feedID.rawValue]) }
    }

    private var emptyMessage: String {
        if loader.loadFailed { return "History could not be loaded." }
        if !loader.hasLoaded { return "Loading history…" }
        return loader.isFiltered ? "No matching history." : "No history to show."
    }

    @ViewBuilder
    private func historyContent(onlyFeedID: String?) -> some View {
        let records = records
        VStack(alignment: .leading, spacing: WiltedTheme.Spacing.medium) {
            if onlyFeedID != nil {
                Text("Episode history").wiltedFont(.title)
            }
            WiltedMacPodcastOperationMessage(model: model)
            controls(onlyFeedID: onlyFeedID)
            if records.isEmpty {
                Text(emptyMessage)
                    .wiltedFont(.body)
                    .foregroundStyle(WiltedTheme.color(.secondaryText, scheme: colorScheme))
                    .accessibilityIdentifier("wilted-feed-history-empty")
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(records.enumerated()), id: \.element.id) { index, record in
                        if index > 0 { Divider() }
                        historyRow(record)
                    }
                }
                .wiltedCard(colorScheme)
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("wilted-feed-history-rows")
                pageControls
            }
        }
    }

    @ViewBuilder
    private func controls(onlyFeedID: String?) -> some View {
        VStack(alignment: .leading, spacing: WiltedTheme.Spacing.small) {
            TextField("Search history", text: Binding(
                get: { loader.searchText }, set: { loader.setSearchText($0) }
            ))
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel("Search feed history")
                .accessibilityIdentifier("wilted-feed-history-search")
            HStack(spacing: WiltedTheme.Spacing.medium) {
                if onlyFeedID == nil {
                    Picker("Feed", selection: Binding(
                        get: { loader.feedFilter }, set: { loader.setFeedFilter($0) }
                    )) {
                        Text("All feeds").tag(String?.none)
                        ForEach(model.subscriptions) { feed in
                            Text(feed.title).tag(Optional(feed.id))
                        }
                    }
                    .pickerStyle(.menu)
                    .accessibilityLabel("Filter history by feed")
                    .accessibilityIdentifier("wilted-feed-history-feed-filter")
                }
                Picker("Status", selection: Binding(
                    get: { loader.statusFilter }, set: { loader.setStatusFilter($0) }
                )) {
                    ForEach(WiltedMacFeedHistoryLoader.StatusFilter.allCases) { filter in
                        Text(filter.rawValue).tag(filter)
                    }
                }
                .pickerStyle(.menu)
                .accessibilityLabel("Filter history by status")
                .accessibilityIdentifier("wilted-feed-history-status-filter")
                Spacer()
                if loader.isLoading {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityLabel("Loading history")
                        .accessibilityIdentifier("wilted-feed-history-loading")
                }
            }
        }
    }

    private func historyRow(_ record: WiltedMacFeedHistoryRecord) -> some View {
        let isPending = model.pendingFeedDecisionIDs.contains(record.id) || model.podcastRestoreTasks[record.id] != nil
            || loader.restoringIDs.contains(record.id)
        let failed = model.failedFeedDecisionIDs.contains(record.id)
        let restoreIdentifier = record.kind == .retired
            ? WiltedMacFeedHistoryAccessibilityID.restoreSkipped(record.id)
            : WiltedMacFeedHistoryAccessibilityID.restoreRemoved(record.id)
        return HStack(alignment: .top, spacing: WiltedTheme.Spacing.medium) {
            VStack(alignment: .leading, spacing: WiltedTheme.Spacing.xSmall) {
                HStack {
                    WiltedMacFeedHistoryTitle(model: model, record: record)
                    Spacer(minLength: WiltedTheme.Spacing.small)
                    Text(record.status.rawValue)
                        .wiltedFont(.utility)
                        .foregroundStyle(WiltedTheme.color(.secondaryText, scheme: colorScheme))
                        .accessibilityIdentifier("wilted-feed-history-status-\(record.id)")
                }
                WiltedMacEpisodeMetadata(
                    presentation: record.presentation,
                    lifecycleLabel: record.status.rawValue,
                    identifier: "wilted-feed-history-metadata-\(record.id)"
                )
                Text(record.changedAt?.formatted(date: .abbreviated, time: .shortened) ?? "Date not recorded")
                    .wiltedFont(.utility)
                    .foregroundStyle(WiltedTheme.color(.secondaryText, scheme: colorScheme))
                    .accessibilityIdentifier("wilted-feed-history-date-\(record.id)")
                if isPending {
                    Label("Restoring…", systemImage: "arrow.clockwise")
                        .wiltedFont(.utility)
                        .accessibilityIdentifier("wilted-feed-history-pending-\(record.id)")
                } else if failed {
                    Text("Could not restore. Try again.")
                        .wiltedFont(.utility)
                        .foregroundStyle(.red)
                        .accessibilityIdentifier("wilted-feed-history-failed-\(record.id)")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Button("Restore") { restore(record) }
                .disabled(isPending)
                .accessibilityLabel("Restore \(record.presentation.title)")
                .accessibilityIdentifier(restoreIdentifier)
        }
        .padding(.vertical, WiltedTheme.Spacing.small)
    }

    /// Restores through the model, then reloads the page once the write commits.
    private func restore(_ record: WiltedMacFeedHistoryRecord) {
        loader.restore(record, model: model)
    }

    private var pageControls: some View {
        let total = loader.total
        let pageSize = WiltedMacFeedHistoryLoader.pageSize
        let first = loader.shownOffset + 1
        let last = min(loader.shownOffset + loader.rows.count, total)
        return HStack {
            Text("Showing \(first)–\(last) of \(total)")
                .wiltedFont(.utility)
                .foregroundStyle(WiltedTheme.color(.secondaryText, scheme: colorScheme))
                .accessibilityIdentifier("wilted-feed-history-range")
            Spacer()
            Button("Previous") { loader.showPage(loader.pageIndex - 1) }
                .disabled(loader.pageIndex == 0)
                .accessibilityIdentifier("wilted-feed-history-previous")
            Text("Page \(loader.shownOffset / pageSize + 1) of \(loader.pageCount)")
                .wiltedFont(.utility)
                .accessibilityIdentifier("wilted-feed-history-page")
            Button("Next") { loader.showPage(loader.pageIndex + 1) }
                .disabled(loader.pageIndex + 1 >= loader.pageCount)
                .accessibilityIdentifier("wilted-feed-history-next")
        }
    }
}
