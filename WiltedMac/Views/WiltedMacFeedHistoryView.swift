import SwiftUI

enum WiltedMacFeedHistoryStatus: String, CaseIterable, Identifiable {
    case skipped = "Skipped"
    case removed = "Removed"

    var id: String { rawValue }
}

struct WiltedMacFeedHistoryRecord: Identifiable, Equatable {
    let id: String
    let feedID: String?
    let feedTitle: String?
    let presentation: WiltedMacEpisodePresentation
    let status: WiltedMacFeedHistoryStatus
    let changedAt: Date?
}

/// Search and page state stays independent of the Feeds inbox selection and scroll anchor.
struct WiltedMacFeedHistoryQuery {
    enum StatusFilter: String, CaseIterable, Identifiable {
        case all = "All statuses"
        case skipped = "Skipped"
        case removed = "Removed"

        var id: String { rawValue }
        var status: WiltedMacFeedHistoryStatus? {
            switch self {
            case .all: nil
            case .skipped: .skipped
            case .removed: .removed
            }
        }
    }

    static let pageSize = 25
    var searchText = ""
    var feedID: String?
    var statusFilter: StatusFilter = .all
    var pageIndex = 0

    func filtered(_ records: [WiltedMacFeedHistoryRecord], onlyFeedID: String? = nil) -> [WiltedMacFeedHistoryRecord] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        return records.filter { record in
            if let onlyFeedID, record.feedID != onlyFeedID { return false }
            if onlyFeedID == nil, let feedID, record.feedID != feedID { return false }
            if let status = statusFilter.status, record.status != status { return false }
            guard !query.isEmpty else { return true }
            return [record.presentation.title, record.presentation.showLabel, record.feedTitle ?? "", record.status.rawValue]
                .contains { $0.localizedCaseInsensitiveContains(query) }
        }
    }

    func pageCount(in records: [WiltedMacFeedHistoryRecord], onlyFeedID: String? = nil) -> Int {
        max(1, (filtered(records, onlyFeedID: onlyFeedID).count + Self.pageSize - 1) / Self.pageSize)
    }

    func page(in records: [WiltedMacFeedHistoryRecord], onlyFeedID: String? = nil) -> [WiltedMacFeedHistoryRecord] {
        let matches = filtered(records, onlyFeedID: onlyFeedID)
        let start = min(pageIndex, max(0, pageCount(in: records, onlyFeedID: onlyFeedID) - 1)) * Self.pageSize
        return Array(matches.dropFirst(start).prefix(Self.pageSize))
    }
}

/// Searchable, filtered history shared by the global Off the list page and feed details.
struct WiltedMacFeedHistoryView: View {
    let model: WiltedMacModel
    var feedID: String? = nil
    @Environment(\.colorScheme) private var colorScheme
    @State private var query = WiltedMacFeedHistoryQuery()

    var body: some View {
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

    private var records: [WiltedMacFeedHistoryRecord] {
        let skipped = model.skippedFeedEpisodes.map { episode in
            WiltedMacFeedHistoryRecord(
                id: episode.id, feedID: episode.feedID, feedTitle: episode.feedTitle,
                presentation: episode.presentation, status: .skipped, changedAt: episode.retiredAt
            )
        }
        let skippedIDs = Set(skipped.map(\.id))
        let removed = model.dismissedEpisodes.filter { !skippedIDs.contains($0.id) }.map { dismissal in
            WiltedMacFeedHistoryRecord(
                id: dismissal.id, feedID: dismissal.feedID, feedTitle: dismissal.feedTitle,
                presentation: dismissal.presentation, status: .removed, changedAt: dismissal.dismissedAt
            )
        }
        return (skipped + removed).sorted { left, right in
            switch (left.changedAt, right.changedAt) {
            case let (leftDate?, rightDate?):
                if leftDate != rightDate { return leftDate > rightDate }
                return left.id < right.id
            case (_?, nil): return true
            case (nil, _?): return false
            case (nil, nil): return left.id < right.id
            }
        }
    }

    private var filteredRecords: [WiltedMacFeedHistoryRecord] {
        query.filtered(records, onlyFeedID: feedID)
    }

    private var visibleRecords: [WiltedMacFeedHistoryRecord] {
        query.page(in: records, onlyFeedID: feedID)
    }

    @ViewBuilder
    private func historyContent(onlyFeedID: String?) -> some View {
        VStack(alignment: .leading, spacing: WiltedTheme.Spacing.medium) {
            if onlyFeedID != nil {
                Text("Episode history").wiltedFont(.title)
            }
            WiltedMacPodcastOperationMessage(model: model)
            controls(onlyFeedID: onlyFeedID)
            if visibleRecords.isEmpty {
                Text(filteredRecords.isEmpty ? "No matching history." : "No history to show.")
                    .wiltedFont(.body)
                    .foregroundStyle(WiltedTheme.color(.secondaryText, scheme: colorScheme))
                    .accessibilityIdentifier("wilted-feed-history-empty")
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(visibleRecords.enumerated()), id: \.element.id) { index, record in
                        if index > 0 { Divider() }
                        historyRow(record)
                    }
                }
                .wiltedCard(colorScheme)
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("wilted-feed-history-rows")
                pageControls(onlyFeedID: onlyFeedID)
            }
        }
        .onChange(of: query.searchText) { _, _ in query.pageIndex = 0 }
        .onChange(of: query.feedID) { _, _ in query.pageIndex = 0 }
        .onChange(of: query.statusFilter) { _, _ in query.pageIndex = 0 }
        .onChange(of: filteredRecords.count) { _, count in
            let lastPage = max(0, (count - 1) / WiltedMacFeedHistoryQuery.pageSize)
            query.pageIndex = min(query.pageIndex, lastPage)
        }
    }

    @ViewBuilder
    private func controls(onlyFeedID: String?) -> some View {
        VStack(alignment: .leading, spacing: WiltedTheme.Spacing.small) {
            TextField("Search history", text: $query.searchText)
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel("Search feed history")
                .accessibilityIdentifier("wilted-feed-history-search")
            HStack(spacing: WiltedTheme.Spacing.medium) {
                if onlyFeedID == nil {
                    Picker("Feed", selection: $query.feedID) {
                        Text("All feeds").tag(String?.none)
                        ForEach(feedChoices, id: \.id) { feed in
                            Text(feed.title).tag(Optional(feed.id))
                        }
                    }
                    .pickerStyle(.menu)
                    .accessibilityLabel("Filter history by feed")
                    .accessibilityIdentifier("wilted-feed-history-feed-filter")
                }
                Picker("Status", selection: $query.statusFilter) {
                    ForEach(WiltedMacFeedHistoryQuery.StatusFilter.allCases) { filter in
                        Text(filter.rawValue).tag(filter)
                    }
                }
                .pickerStyle(.menu)
                .accessibilityLabel("Filter history by status")
                .accessibilityIdentifier("wilted-feed-history-status-filter")
                Spacer()
            }
        }
    }

    private var feedChoices: [(id: String, title: String)] {
        let names = Dictionary(records.compactMap { record -> (String, String)? in
            guard let feedID = record.feedID else { return nil }
            return (feedID, record.feedTitle ?? "Feed")
        }, uniquingKeysWith: { first, _ in first })
        return names.map { (id: $0.key, title: $0.value) }.sorted {
            $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
        }
    }

    private func historyRow(_ record: WiltedMacFeedHistoryRecord) -> some View {
        let isPending = model.pendingFeedDecisionIDs.contains(record.id) || model.podcastRestoreTasks[record.id] != nil
        let failed = model.failedFeedDecisionIDs.contains(record.id)
        let restoreIdentifier = record.status == .skipped
            ? WiltedMacFeedHistoryAccessibilityID.restoreSkipped(record.id)
            : WiltedMacFeedHistoryAccessibilityID.restoreRemoved(record.id)
        return HStack(alignment: .top, spacing: WiltedTheme.Spacing.medium) {
            VStack(alignment: .leading, spacing: WiltedTheme.Spacing.xSmall) {
                HStack {
                    Text(record.presentation.title)
                        .wiltedFont(.body)
                        .foregroundStyle(WiltedTheme.color(.primaryText, scheme: colorScheme))
                        .lineLimit(1)
                    Spacer(minLength: WiltedTheme.Spacing.small)
                    Text(record.status.rawValue)
                        .wiltedFont(.utility)
                        .foregroundStyle(WiltedTheme.color(.secondaryText, scheme: colorScheme))
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

    private func restore(_ record: WiltedMacFeedHistoryRecord) {
        switch record.status {
        case .skipped:
            if let episode = model.skippedFeedEpisodes.first(where: { $0.id == record.id }) {
                model.restoreSkippedFeedEpisode(episode)
            }
        case .removed:
            if let dismissal = model.dismissedEpisodes.first(where: { $0.id == record.id }) {
                model.restoreEpisode(dismissal)
            }
        }
    }

    private func pageControls(onlyFeedID: String?) -> some View {
        let total = filteredRecords.count
        let pageCount = query.pageCount(in: records, onlyFeedID: onlyFeedID)
        let first = query.pageIndex * WiltedMacFeedHistoryQuery.pageSize + 1
        let last = min(first + WiltedMacFeedHistoryQuery.pageSize - 1, total)
        return HStack {
            Text("Showing \(first)–\(last) of \(total)")
                .wiltedFont(.utility)
                .foregroundStyle(WiltedTheme.color(.secondaryText, scheme: colorScheme))
                .accessibilityIdentifier("wilted-feed-history-range")
            Spacer()
            Button("Previous") { query.pageIndex = max(0, query.pageIndex - 1) }
                .disabled(query.pageIndex == 0)
                .accessibilityIdentifier("wilted-feed-history-previous")
            Text("Page \(query.pageIndex + 1) of \(pageCount)")
                .wiltedFont(.utility)
                .accessibilityIdentifier("wilted-feed-history-page")
            Button("Next") { query.pageIndex = min(pageCount - 1, query.pageIndex + 1) }
                .disabled(query.pageIndex + 1 >= pageCount)
                .accessibilityIdentifier("wilted-feed-history-next")
        }
    }
}
