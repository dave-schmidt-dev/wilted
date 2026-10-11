import WiltedLibrary
import AppKit
import SwiftUI
import WiltedDomain

extension WiltedMacLarderView {
    /// The group filter chips, each carrying the count of the rows it jumps
    /// to. "All waiting" is the unfiltered selection when no search is active;
    /// under a search it is the matching set, so the count and the rows agree.
    func filterBar(colorScheme: ColorScheme) -> some View {
        VStack(alignment: .leading, spacing: WiltedTheme.Spacing.xSmall) {
            WiltedMacFlowLayout {
                filterChip(nil, label: "All waiting", count: model.larderItemCount(in: nil), colorScheme: colorScheme)
                ForEach(WiltedMacLarderGroup.allCases) { group in
                    filterChip(group, label: group.displayName, count: model.larderEpisodes(in: group).count + model.larderArticles(in: group).count, colorScheme: colorScheme)
                }
            }
            WiltedMacFlowLayout {
                bulkAction(
                    "Download all new (\(model.larderDownloadableEpisodes.count))",
                    identifier: "wilted-larder-download-all",
                    actionable: model.larderDownloadableEpisodes,
                    inFlight: model.larderDownloadsInFlight,
                    inFlightVerb: "Downloading", colorScheme: colorScheme
                ) { model.downloadAllAvailableLarderEpisodes() }
                bulkAction(
                    "Prepare all now (\(model.larderPreparableEpisodes.count))",
                    identifier: "wilted-larder-prepare-all",
                    actionable: model.larderPreparableEpisodes,
                    inFlight: model.larderPreparationsInFlight,
                    inFlightVerb: "Preparing", colorScheme: colorScheme
                ) { model.prepareAllDownloadedLarderEpisodes() }
            }
            .buttonStyle(.bordered)
            // A bulk action that covered rows the reader cannot see would be
            // the same defect as Skip deleting media: the control says what it
            // will do, and while a search is on it says it will not run.
            if model.isSearchingLarder {
                Text("Search active — bulk actions are off until you clear it.")
                    .wiltedFont(.utility)
                    .foregroundStyle(WiltedTheme.color(.secondaryText, scheme: colorScheme))
                    .accessibilityIdentifier("wilted-larder-search-suppresses-bulk")
            }
        }
        .controlSize(.small)
    }

    // W-INV-001: a bulk press moves the rows it counted into the in-flight set, so the
    // control shows progress until the last of them settles. While rows remain that
    // nothing has started (new arrivals, failed downloads), the button stays beside the
    // progress so they can still be started.
    @ViewBuilder private func bulkAction(
        _ title: String, identifier: String,
        actionable: [WiltedMacEpisode], inFlight: [WiltedMacEpisode],
        inFlightVerb: String, colorScheme: ColorScheme, action: @escaping () -> Void
    ) -> some View {
        if !inFlight.isEmpty {
            HStack(spacing: WiltedTheme.Spacing.xSmall) {
                ProgressView().controlSize(.small)
                Text("\(inFlightVerb) \(inFlight.count)…")
                    .wiltedFont(.utility)
                    .foregroundStyle(WiltedTheme.color(.secondaryText, scheme: colorScheme))
                    .fixedSize()
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("\(identifier)-progress")
        }
        if !actionable.isEmpty {
            Button(title, action: action)
                .disabled(model.isSearchingLarder)
                .accessibilityIdentifier(identifier)
        } else if inFlight.isEmpty {
            Button(title, action: action)
                .disabled(true)
                .accessibilityIdentifier(identifier)
        }
    }

    private func filterChip(_ group: WiltedMacLarderGroup?, label: String, count: Int, colorScheme: ColorScheme) -> some View {
        let selected = model.larderFilter == group
        return Button {
            model.larderFilter = group
        } label: {
            HStack(spacing: WiltedTheme.Spacing.xSmall) {
                Text(label)
                Text("\(count)")
                    .accessibilityIdentifier(group.map { group in
                        "wilted-larder-\(group.rawValue.lowercased())-count"
                    } ?? "wilted-larder-all-count")
            }
                .wiltedFont(.utility)
                .lineLimit(1)
                .fixedSize()
                .foregroundStyle(
                    selected
                        ? WiltedTheme.color(.primaryText, scheme: colorScheme)
                        : WiltedTheme.color(.secondaryText, scheme: colorScheme)
                )
                .padding(.horizontal, WiltedTheme.Spacing.small)
                .padding(.vertical, 4)
        }
        .buttonStyle(.plain)
        .background(
            selected ? WiltedTheme.color(.wiltedLeaf, scheme: colorScheme).opacity(0.24) : Color.clear,
            in: Capsule()
        )
        .accessibilityIdentifier("wilted-larder-filter-\(group?.rawValue.lowercased() ?? "all")")
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }

    /// A group's own bulk action and its non-destructive Larder removal.
    @ViewBuilder private func groupActions(_ group: WiltedMacLarderGroup) -> some View {
        switch group {
        case .playable:
            Button("Play the first") {
                if let first = model.larderEpisodes(in: .playable).first(where: { !model.isEpisodeFinished($0) }) {
                    model.playLarderEpisode(first)
                }
            }
            .disabled(model.larderEpisodes(in: .playable).allSatisfy { model.isEpisodeFinished($0) }
                      || model.isSearchingLarder)
            .accessibilityIdentifier("wilted-larder-play-first")
        case .downloaded, .available:
            EmptyView()
        }
        Button(model.larderGroupClearLabel(group)) {
            model.clearLarderGroup(group)
        }
        .disabled(model.isSearchingLarder)
        .help("Removes these rows from Larder without deleting audio, prepared cuts, transcripts, or listening history.")
        .accessibilityHint("Does not delete audio, prepared cuts, transcripts, or listening history.")
        .accessibilityLabel("\(model.larderGroupClearLabel(group)) in \(group.displayName)")
        .accessibilityIdentifier(groupClearIdentifier(group))
    }

    /// Literal identifiers, not an interpolation: the release gate greps the
    /// view source for each one.
    private func groupClearIdentifier(_ group: WiltedMacLarderGroup) -> String {
        switch group {
        case .playable: "wilted-larder-clear-ready"
        case .downloaded: "wilted-larder-clear-downloaded"
        case .available: "wilted-larder-clear-available"
        }
    }

    func sectionHelp(_ section: WiltedMacLarderSection, detail: String) -> WiltedMacHelpContent {
        WiltedMacHelpContent(title: section.title, text: detail)
    }

    /// The selected presentation sections. Status owns the lifecycle actions;
    /// Feed and Date are neutral views over the same durable listening order.
    @ViewBuilder var groupList: some View {
        let sections = WiltedMacEpisodePresentationSections.displaySections(
            model.larderSections(),
            grouping: model.larderGrouping,
            sort: model.larderSort,
            direction: model.larderSortDirection,
            isDeferredForOffPeak: { model.isDeferredForOffPeak($0) }
        )
        let numbering = WiltedMacEpisodePresentationSections.visibleNumbering(sections)
        let total = numbering.count
        if model.larderFilteredItems.isEmpty {
            Label(model.isSearchingLarder
                  ? (model.isSearchingTranscripts ? "Still reading transcripts…" : "Nothing matches this search.")
                  : emptyLarderCopy, symbol: .larder)
                .wiltedFont(.body)
                .foregroundStyle(WiltedTheme.color(.secondaryText, scheme: colorScheme))
                .padding(.vertical, WiltedTheme.Spacing.small)
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("wilted-larder-empty")
        } else {
            VStack(alignment: .leading, spacing: WiltedTheme.Spacing.large) {
                ForEach(sections) { section in
                    VStack(alignment: .leading, spacing: WiltedTheme.Spacing.small) {
                        groupHeader(section, colorScheme: colorScheme)
                        VStack(alignment: .leading, spacing: 0) {
                            ForEach(Array(section.items.enumerated()), id: \.element.id) { index, item in
                                if index > 0 { Divider() }
                                itemRow(item, index: index, section: section, numbering: numbering, total: total)
                            }
                        }
                        .wiltedCard(colorScheme)
                    }
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier(larderSectionIdentifier(section))
                    .id("larder-section-\(section.id)")
                }
                tailDropTarget
            }
            .scrollTargetLayout()
        }
    }

    /// One row of the grouped list: an article, or an episode or book with its queue position.
    @ViewBuilder private func itemRow(
        _ item: WiltedMacLibraryItem, index: Int, section: WiltedMacLarderSection,
        numbering: WiltedMacEpisodePresentationSections.VisibleNumbering, total: Int
    ) -> some View {
        switch item {
        case .article(let article):
            WiltedMacArticleRow(model: model, article: article)
                .contextMenu { WiltedMacAddToPlaylistMenu(model: model, entryID: article.id) }
        case .episode(let episode), .audiobook(let episode):
            larderRow(
                episode,
                position: numbering.positions[episode.id, default: index + 1],
                count: total,
                showsGroupName: section.statusGroup == nil
            )
        }
    }

    private var emptyLarderPolicyCopy: String {
        switch model.automationSettings.downloadPolicy {
        case .manual:
            "Nothing is in Larder. Keep an episode from Feeds, then download it."
        case .newestOnePerEnabledFeed, .newestThreePerEnabledFeed, .allNewlyAdmittedUpToTwenty:
            "Nothing is in Larder. Kept episodes download according to the automatic download setting."
        }
    }

    private var emptyLarderCopy: String {
        if model.larderKind != .all && model.larderFilter == nil { return "Nothing of this kind is in Larder." }
        if model.larderFilter == .downloaded { return emptyDownloadedCopy }
        return model.larderWaitingEpisodes.isEmpty ? emptyLarderPolicyCopy : "No episode is in this group right now."
    }

    private var emptyDownloadedCopy: String {
        model.automationSettings.downloadEverythingOnLarder
            ? "Downloaded audio is empty. Kept episodes download automatically in Larder."
            : "Downloaded audio is empty. Keep an episode, then download it here."
    }

    /// Status keeps its established automation identifiers; the two new
    /// presentation modes use section identities that cannot collide with it.
    private func larderSectionIdentifier(_ section: WiltedMacLarderSection) -> String {
        if let group = section.statusGroup {
            return "wilted-larder-group-\(group.rawValue.lowercased())"
        }
        return "wilted-larder-section-\(section.id)"
    }

    /// The shipping group header, also rendered directly to prove complete labels at real widths.
    func groupHeader(_ section: WiltedMacLarderSection, colorScheme: ColorScheme) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .firstTextBaseline) {
                sectionHeading(section, colorScheme: colorScheme)
                if let group = section.statusGroup {
                    groupActions(group).buttonStyle(.bordered).controlSize(.small)
                }
            }
            .fixedSize(horizontal: true, vertical: false)
            VStack(alignment: .leading, spacing: WiltedTheme.Spacing.small) {
                sectionHeading(section, colorScheme: colorScheme)
                if let group = section.statusGroup {
                    WiltedMacFlowLayout { groupActions(group) }
                        .buttonStyle(.bordered).controlSize(.small)
                }
            }
        }
    }

    private func sectionHeading(_ section: WiltedMacLarderSection, colorScheme: ColorScheme) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(section.title)
                .wiltedFont(.title)
                .foregroundStyle(WiltedTheme.color(.primaryText, scheme: colorScheme))
            // Status counts belong to the filter chips; active totals are the progress facts above.
            if section.statusGroup == nil && section.id != "active-work" {
                Text("\(section.items.count)")
                    .wiltedFont(.utility)
                    .foregroundStyle(WiltedTheme.color(.secondaryText, scheme: colorScheme))
                    .accessibilityIdentifier(larderSectionCountIdentifier(section))
            }
            Spacer()
            if let detail = section.detail {
                WiltedMacHelpButton(content: sectionHelp(section, detail: detail),
                    identifier: "wilted-larder-section-help-\(section.id)")
            }
        }
    }

    private func larderSectionCountIdentifier(_ section: WiltedMacLarderSection) -> String {
        if let group = section.statusGroup {
            return "wilted-larder-\(group.rawValue.lowercased())-count"
        }
        return "wilted-larder-section-\(section.id)-count"
    }

    /// The strip below the last row is a real destination: a drop here appends
    /// the dragged entry. A payload that is not one of the Larder's episodes is
    /// refused and the order left alone.
    private var tailDropTarget: some View {
        VStack(spacing: 2) {
            Rectangle()
                .fill(WiltedTheme.color(.wiltedLeaf, scheme: colorScheme))
                .frame(height: 2)
                .opacity(dropTargetID == Self.tailDropTargetID ? 1 : 0)
                .accessibilityHidden(true)
            HStack(spacing: WiltedTheme.Spacing.small) {
                Image(systemName: "arrow.down.to.line")
                    .accessibilityHidden(true)
                Text("Drop here to move to the end")
            }
        }
        .wiltedFont(.utility)
        .foregroundStyle(WiltedTheme.color(.secondaryText, scheme: colorScheme))
        .frame(maxWidth: .infinity, minHeight: 28)
        .contentShape(Rectangle())
        .dropDestination(for: String.self) { draggedIDs, _ in
            model.dropLarderEpisodes(draggedIDs, before: nil)
        } isTargeted: { targeted in
            dropTargetID = targeted ? Self.tailDropTargetID : nil
        }
        .accessibilityIdentifier("wilted-larder-drop-tail")
    }

    private static let tailDropTargetID = "__larder_tail__"
}

/// Presentation-only row grouping for the Larder. It never changes the
/// durable queue, the model's sort fallback, or lifecycle eligibility.
///
/// Rows are podcast episodes, audiobooks and articles. The fixed status order is Ready, Active
/// work, Downloaded, Not downloaded; the sort applies within each group.
enum WiltedMacEpisodePresentationSections {
    struct VisibleNumbering {
        let positions: [String: Int]
        let count: Int
    }

    /// Continuous visible ordinals across the actual rendered sections.
    /// Only presentation changes: durable queue order and episode values stay intact. Articles are
    /// not in the queue, so they carry no ordinal.
    static func visibleNumbering(_ sections: [WiltedMacLarderSection]) -> VisibleNumbering {
        let episodes = sections.flatMap(\.episodes)
        let positions = Dictionary(uniqueKeysWithValues: episodes.enumerated().map {
            ($0.element.id, $0.offset + 1)
        })
        return VisibleNumbering(positions: positions, count: episodes.count)
    }

    static func displaySections(
        _ sections: [WiltedMacLarderSection],
        grouping: WiltedMacLarderGrouping,
        sort: WiltedMacLarderSort = .custom,
        direction: WiltedMacLarderSortDirection = .ascending,
        calendar: Calendar = .autoupdatingCurrent,
        now: Date = Date(),
        isDeferredForOffPeak: (String) -> Bool = { _ in false }
    ) -> [WiltedMacLarderSection] {
        func isActive(_ item: WiltedMacLibraryItem) -> Bool {
            switch item {
            case .article(let article): !article.isReady
            case .audiobook: false
            case .episode(let episode):
                episode.downloadState.isInFlight
                    || (episode.preparationState.isRunning && !isDeferredForOffPeak(episode.id))
            }
        }
        let active = sections.flatMap(\.items).filter(isActive)
        let activeIDs = Set(active.map(\.id))
        let remaining = sections.compactMap { section -> WiltedMacLarderSection? in
            let rows = presentationOrder(
                section.items.filter { !activeIDs.contains($0.id) }, sort: sort, direction: direction
            )
            guard !rows.isEmpty else { return nil }
            return WiltedMacLarderSection(
                id: section.id, title: section.title, detail: section.detail,
                statusGroup: section.statusGroup, items: rows
            )
        }
        let content = grouping == .date
            ? publicationDateSections(remaining.flatMap(\.items), calendar: calendar, now: now)
            : remaining
        guard !active.isEmpty else { return content }
        let activeSection = WiltedMacLarderSection(
            id: "active-work", title: "Active work", detail: "download or preparation in progress",
            statusGroup: nil, items: active
        )
        // Status keeps its lifecycle order: Ready, then work in progress, then what still needs a step.
        guard grouping == .status else { return [activeSection] + content }
        let readyEnd = content.firstIndex { $0.statusGroup == .playable }.map { $0 + 1 } ?? 0
        return Array(content[..<readyEnd]) + [activeSection] + Array(content[readyEnd...])
    }

    /// Newest keeps unknown feed publication facts after known facts while it
    /// presents each existing status or feed section. It deliberately does
    /// not rewrite the model's durable comparator or merge lifecycle sections.
    static func presentationOrder(
        _ episodes: [WiltedMacEpisode], sort: WiltedMacLarderSort
    ) -> [WiltedMacEpisode] {
        guard sort == .newest else { return episodes }
        return episodes.filter { $0.publishedAt != nil }
            + episodes.filter { $0.publishedAt == nil }
    }

    /// One section's rows in order. Without articles the queue order the model already holds is kept
    /// (the legacy rule above). With articles, which have no queue position, a calculated sort orders
    /// every row together; Listening order keeps the queued rows first and the articles after them,
    /// newest first.
    static func presentationOrder(
        _ items: [WiltedMacLibraryItem], sort: WiltedMacLarderSort,
        direction: WiltedMacLarderSortDirection = .ascending
    ) -> [WiltedMacLibraryItem] {
        let hasArticle = items.contains { if case .article = $0 { true } else { false } }
        guard hasArticle else {
            let episodes = items.compactMap { item -> WiltedMacEpisode? in
                switch item { case .episode(let value), .audiobook(let value): value; case .article: nil }
            }
            return presentationOrder(episodes, sort: sort).map(WiltedMacLibraryItem.init(episode:))
        }
        guard sort.canonical != .custom else {
            let queued = items.filter { if case .article = $0 { false } else { true } }
            let articles = items.filter { if case .article = $0 { true } else { false } }
            return queued + articles.sorted { $0.date > $1.date }
        }
        return items.sorted { precedes($0, $1, sort: sort, direction: direction) }
    }

    /// The model's calculated-sort comparator, applied to any row kind. Unknown lengths and dates sort
    /// last in either direction.
    private static func precedes(
        _ lhs: WiltedMacLibraryItem, _ rhs: WiltedMacLibraryItem,
        sort: WiltedMacLarderSort, direction: WiltedMacLarderSortDirection
    ) -> Bool {
        let ascending = (sort.legacyDirection ?? direction) == .ascending
        switch sort.canonical {
        case .length, .age:
            let isLength = sort.canonical == .length
            let left = isLength ? lhs.progress.duration : knownDate(lhs)?.timeIntervalSince1970
            let right = isLength ? rhs.progress.duration : knownDate(rhs)?.timeIntervalSince1970
            switch (left, right) {
            case let (left?, right?) where left != right:
                // Age ascending means younger first; length ascending means shortest first.
                return isLength ? (ascending ? left < right : left > right) : (ascending ? left > right : left < right)
            case (nil, .some): return false
            case (.some, nil): return true
            default: break
            }
        case .alphabetical:
            let comparison = LibrarySortKey.title(lhs.title).localizedStandardCompare(LibrarySortKey.title(rhs.title))
            if comparison != .orderedSame { return comparison == (ascending ? .orderedAscending : .orderedDescending) }
        default: break
        }
        return lhs.id < rhs.id
    }

    /// The factual date of a row: a feed's publication date, or when an article was saved.
    private static func knownDate(_ item: WiltedMacLibraryItem) -> Date? {
        switch item {
        case .article(let value): value.createdAt
        case .episode(let value), .audiobook(let value): value.publishedAt
        }
    }

    /// `releasedAt` stays the legacy sort/grouping fallback, but a section
    /// header describes only the feed's actual optional publication date.
    /// Unknown facts are collected last rather than borrowing intake time.
    static func publicationDateSections(
        _ items: [WiltedMacLibraryItem], calendar: Calendar, now: Date
    ) -> [WiltedMacLarderSection] {
        var dated: [(date: Date, items: [WiltedMacLibraryItem])] = []
        var unknown: [WiltedMacLibraryItem] = []
        for item in items {
            guard let publishedAt = knownDate(item) else {
                unknown.append(item)
                continue
            }
            let date = calendar.startOfDay(for: publishedAt)
            if let index = dated.firstIndex(where: { calendar.isDate($0.date, inSameDayAs: date) }) {
                dated[index].items.append(item)
            } else {
                dated.append((date, [item]))
            }
        }
        let known = dated.map { value in
            WiltedMacLarderSection(
                id: "publication-date-\(value.date.timeIntervalSinceReferenceDate)",
                title: publicationDateTitle(value.date, calendar: calendar, now: now), detail: nil,
                statusGroup: nil, items: value.items
            )
        }
        guard !unknown.isEmpty else { return known }
        return known + [WiltedMacLarderSection(
            id: "publication-date-unknown", title: "Unknown publication date", detail: nil,
            statusGroup: nil, items: unknown
        )]
    }

    private static func publicationDateTitle(_ date: Date, calendar: Calendar, now: Date) -> String {
        if calendar.isDate(date, inSameDayAs: now) { return "Today" }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now),
           calendar.isDate(date, inSameDayAs: yesterday) { return "Yesterday" }
        return date.formatted(date: .abbreviated, time: .omitted)
    }
}
