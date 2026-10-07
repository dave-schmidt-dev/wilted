import AppKit
import SwiftUI
import WiltedDomain

extension WiltedMacLarderView {
    /// The group filter chips, each carrying the count of the rows it jumps
    /// to. "All waiting" is the unfiltered selection when no search is active;
    /// under a search it is the matching set, so the count and the rows agree.
    var filterBar: some View {
        VStack(alignment: .leading, spacing: WiltedTheme.Spacing.xSmall) {
            WiltedMacFlowLayout {
                filterChip(nil, label: "All waiting", count: model.larderSearchResults.count)
                ForEach(WiltedMacLarderGroup.allCases) { group in
                    filterChip(group, label: group.displayName, count: model.larderEpisodes(in: group).count)
                }
                bulkAction(
                    "Download all new (\(model.larderDownloadableEpisodes.count))",
                    identifier: "wilted-larder-download-all",
                    actionable: model.larderDownloadableEpisodes,
                    inFlight: model.larderDownloadsInFlight,
                    inFlightVerb: "Downloading"
                ) {
                    model.downloadAllAvailableLarderEpisodes()
                }
                bulkAction(
                    "Prepare all now (\(model.larderPreparableEpisodes.count))",
                    identifier: "wilted-larder-prepare-all",
                    actionable: model.larderPreparableEpisodes,
                    inFlight: model.larderPreparationsInFlight,
                    inFlightVerb: "Preparing"
                ) {
                    model.prepareAllDownloadedLarderEpisodes()
                }
            }
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
        inFlightVerb: String, action: @escaping () -> Void
    ) -> some View {
        if !inFlight.isEmpty {
            HStack(spacing: WiltedTheme.Spacing.xSmall) {
                ProgressView()
                    .controlSize(.small)
                Text("\(inFlightVerb) \(inFlight.count)…")
                    .wiltedFont(.utility)
                    .foregroundStyle(WiltedTheme.color(.secondaryText, scheme: colorScheme))
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

    private func filterChip(_ group: WiltedMacLarderGroup?, label: String, count: Int) -> some View {
        let selected = model.larderFilter == group
        return Button {
            model.larderFilter = group
        } label: {
            Text("\(label) \(count)")
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
        case .downloaded:
            bulkAction(
                "Prepare all now \(model.larderPreparableEpisodes.count)",
                identifier: "wilted-larder-group-prepare-all",
                actionable: model.larderPreparableEpisodes,
                inFlight: model.larderPreparationsInFlight,
                inFlightVerb: "Preparing"
            ) {
                model.prepareAllDownloadedLarderEpisodes()
            }
        case .available:
            bulkAction(
                "Download all \(model.larderDownloadableEpisodes.count)",
                identifier: "wilted-larder-group-download-all",
                actionable: model.larderDownloadableEpisodes,
                inFlight: model.larderDownloadsInFlight,
                inFlightVerb: "Downloading"
            ) {
                model.downloadAllAvailableLarderEpisodes()
            }
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

    /// The selected presentation sections. Status owns the lifecycle actions;
    /// Feed and Date are neutral views over the same durable listening order.
    @ViewBuilder var groupList: some View {
        let sections = WiltedMacEpisodePresentationSections.displaySections(
            model.larderSections(),
            grouping: model.larderGrouping,
            sort: model.larderSort,
            isDeferredForOffPeak: { model.isDeferredForOffPeak($0) }
        )
        let numbering = WiltedMacEpisodePresentationSections.visibleNumbering(sections)
        let total = numbering.count
        if model.larderFilteredEpisodes.isEmpty {
            Label(model.isSearchingLarder
                  ? (model.isSearchingTranscripts ? "Still reading transcripts…" : "No episodes match this search.")
                  : emptyLarderCopy, symbol: .larder)
                .wiltedFont(.body)
                .foregroundStyle(WiltedTheme.color(.secondaryText, scheme: colorScheme))
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("wilted-larder-empty")
        } else {
            VStack(alignment: .leading, spacing: WiltedTheme.Spacing.large) {
                ForEach(sections) { section in
                    VStack(alignment: .leading, spacing: WiltedTheme.Spacing.small) {
                        HStack(alignment: .firstTextBaseline) {
                            Text(section.title)
                                .wiltedFont(.title)
                                .foregroundStyle(WiltedTheme.color(.primaryText, scheme: colorScheme))
                            Text("\(section.episodes.count)")
                                .wiltedFont(.utility)
                                .foregroundStyle(WiltedTheme.color(.secondaryText, scheme: colorScheme))
                                .accessibilityIdentifier(larderSectionCountIdentifier(section))
                            Spacer()
                            if let detail = section.detail {
                                Text(detail)
                                    .wiltedFont(.utility)
                                    .foregroundStyle(WiltedTheme.color(.secondaryText, scheme: colorScheme))
                            }
                            if let group = section.statusGroup {
                                groupActions(group)
                            }
                        }
                        VStack(alignment: .leading, spacing: 0) {
                            ForEach(Array(section.episodes.enumerated()), id: \.element.id) { index, episode in
                                if index > 0 { Divider() }
                                let position = numbering.positions[episode.id, default: index + 1]
                                larderRow(
                                    episode,
                                    position: position,
                                    count: total,
                                    showsGroupName: section.statusGroup == nil
                                )
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

    private var emptyLarderPolicyCopy: String {
        switch model.automationSettings.downloadPolicy {
        case .manual:
            "Nothing is in Larder. Keep an episode from Feeds, then download it."
        case .newestOnePerEnabledFeed, .newestThreePerEnabledFeed, .allNewlyAdmittedUpToTwenty:
            "Nothing is in Larder. Kept episodes download according to the automatic download setting."
        }
    }

    private var emptyLarderCopy: String {
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

    /// Articles are saved listening that is not part of the episode queue; the
    /// Larder is their way in and out now that the Larder is gone. Kept as a
    /// trailing section rather than a fourth group: the three groups are the
    /// episode steps, and an article has none of them.
    var articlesSection: some View {
        VStack(alignment: .leading, spacing: WiltedTheme.Spacing.small) {
            HStack {
                Text("Articles")
                    .wiltedFont(.title)
                    .foregroundStyle(WiltedTheme.color(.primaryText, scheme: colorScheme))
                Spacer()
                addArticleButton
            }
            if !model.larderSearchArticleResults.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(model.larderSearchArticleResults.enumerated()), id: \.element.id) { index, article in
                        if index > 0 { Divider() }
                        WiltedMacArticleRow(model: model, article: article)
                    }
                }
                .wiltedCard(colorScheme)
            }
        }
        // The container goes on the section, not on the VStack that holds the
        // rows. A `.contain` element directly around rows that are themselves
        // `.contain` swallows them: the children are hoisted into the parent
        // and the per-row identifiers never reach the tree. The Larder's own
        // groups already use this shape, which is why `wilted-larder-row-` is
        // queryable and `wilted-article-row-` was not.
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("wilted-larder-articles")
    }

}

/// Presentation-only row grouping for the Larder. It never changes the
/// durable queue, the model's sort fallback, or lifecycle eligibility.
enum WiltedMacEpisodePresentationSections {
    struct VisibleNumbering {
        let positions: [String: Int]
        let count: Int
    }

    /// Continuous visible ordinals across the actual rendered sections.
    /// Only presentation changes: durable queue order and episode values stay intact.
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
        calendar: Calendar = .autoupdatingCurrent,
        now: Date = Date(),
        isDeferredForOffPeak: (String) -> Bool = { _ in false }
    ) -> [WiltedMacLarderSection] {
        let active = sections.flatMap(\.episodes).filter { episode in
            episode.downloadState.isInFlight
                || (episode.preparationState.isRunning && !isDeferredForOffPeak(episode.id))
        }
        let activeIDs = Set(active.map(\.id))
        let remaining = sections.compactMap { section -> WiltedMacLarderSection? in
            let episodes = presentationOrder(
                section.episodes.filter { !activeIDs.contains($0.id) }, sort: sort
            )
            guard !episodes.isEmpty else { return nil }
            return WiltedMacLarderSection(
                id: section.id, title: section.title, detail: section.detail,
                statusGroup: section.statusGroup, episodes: episodes
            )
        }
        let content = grouping == .date
            ? publicationDateSections(remaining.flatMap(\.episodes), calendar: calendar, now: now)
            : remaining
        guard !active.isEmpty else { return content }
        return [WiltedMacLarderSection(
            id: "active-work", title: "Active work", detail: "download or preparation in progress",
            statusGroup: nil, episodes: active
        )] + content
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

    /// `releasedAt` stays the legacy sort/grouping fallback, but a section
    /// header describes only the feed's actual optional publication date.
    /// Unknown facts are collected last rather than borrowing intake time.
    static func publicationDateSections(
        _ episodes: [WiltedMacEpisode], calendar: Calendar, now: Date
    ) -> [WiltedMacLarderSection] {
        var dated: [(date: Date, episodes: [WiltedMacEpisode])] = []
        var unknown: [WiltedMacEpisode] = []
        for episode in episodes {
            guard let publishedAt = episode.publishedAt else {
                unknown.append(episode)
                continue
            }
            let date = calendar.startOfDay(for: publishedAt)
            if let index = dated.firstIndex(where: { calendar.isDate($0.date, inSameDayAs: date) }) {
                dated[index].episodes.append(episode)
            } else {
                dated.append((date, [episode]))
            }
        }
        let known = dated.map { value in
            WiltedMacLarderSection(
                id: "publication-date-\(value.date.timeIntervalSinceReferenceDate)",
                title: publicationDateTitle(value.date, calendar: calendar, now: now), detail: nil,
                statusGroup: nil, episodes: value.episodes
            )
        }
        guard !unknown.isEmpty else { return known }
        return known + [WiltedMacLarderSection(
            id: "publication-date-unknown", title: "Unknown publication date", detail: nil,
            statusGroup: nil, episodes: unknown
        )]
    }

    private static func publicationDateTitle(_ date: Date, calendar: Calendar, now: Date) -> String {
        if calendar.isDate(date, inSameDayAs: now) { return "Today" }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now),
           calendar.isDate(date, inSameDayAs: yesterday) { return "Yesterday" }
        return date.formatted(date: .abbreviated, time: .omitted)
    }
}
