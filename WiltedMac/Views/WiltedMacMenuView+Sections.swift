import AppKit
import SwiftUI
import WiltedDomain

extension WiltedMacMenuView {
    /// The group filter chips, each carrying the count of the rows it jumps
    /// to. "All waiting" is the unfiltered selection when no search is active;
    /// under a search it is the matching set, so the count and the rows agree.
    var filterBar: some View {
        VStack(alignment: .leading, spacing: WiltedTheme.Spacing.xSmall) {
            HStack(spacing: WiltedTheme.Spacing.small) {
                filterChip(nil, label: "All waiting", count: model.menuSearchResults.count)
                ForEach(WiltedMacMenuGroup.allCases) { group in
                    filterChip(group, label: group.displayName, count: model.menuEpisodes(in: group).count)
                }
                Spacer()
                bulkAction(
                    "Download all new (\(model.menuDownloadableEpisodes.count))",
                    identifier: "wilted-menu-download-all",
                    actionable: model.menuDownloadableEpisodes,
                    inFlight: model.menuDownloadsInFlight,
                    inFlightVerb: "Downloading"
                ) {
                    model.downloadAllAvailableMenuEpisodes()
                }
                bulkAction(
                    "Prepare all now (\(model.menuPreparableEpisodes.count))",
                    identifier: "wilted-menu-prepare-all",
                    actionable: model.menuPreparableEpisodes,
                    inFlight: model.menuPreparationsInFlight,
                    inFlightVerb: "Preparing"
                ) {
                    model.prepareAllDownloadedMenuEpisodes()
                }
            }
            // A bulk action that covered rows the reader cannot see would be
            // the same defect as Skip deleting media: the control says what it
            // will do, and while a search is on it says it will not run.
            if model.isSearchingMenu {
                Text("Search active — bulk actions are off until you clear it.")
                    .wiltedFont(.utility)
                    .foregroundStyle(WiltedTheme.color(.secondaryText, scheme: colorScheme))
                    .accessibilityIdentifier("wilted-menu-search-suppresses-bulk")
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
                .disabled(model.isSearchingMenu)
                .accessibilityIdentifier(identifier)
        } else if inFlight.isEmpty {
            Button(title, action: action)
                .disabled(true)
                .accessibilityIdentifier(identifier)
        }
    }

    private func filterChip(_ group: WiltedMacMenuGroup?, label: String, count: Int) -> some View {
        let selected = model.menuFilter == group
        return Button {
            model.menuFilter = group
        } label: {
            Text("\(label) \(count)")
                .wiltedFont(.utility)
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
        .accessibilityIdentifier("wilted-menu-filter-\(group?.rawValue.lowercased() ?? "all")")
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }

    /// A group's own bulk action and its non-destructive Larder removal.
    @ViewBuilder private func groupActions(_ group: WiltedMacMenuGroup) -> some View {
        switch group {
        case .playable:
            Button("Play the first") {
                if let first = model.menuEpisodes(in: .playable).first(where: { !model.isEpisodeFinished($0) }) {
                    model.playEpisode(first)
                }
            }
            .disabled(model.menuEpisodes(in: .playable).allSatisfy { model.isEpisodeFinished($0) }
                      || model.isSearchingMenu)
            .accessibilityIdentifier("wilted-menu-play-first")
        case .downloaded:
            bulkAction(
                "Prepare all now \(model.menuPreparableEpisodes.count)",
                identifier: "wilted-menu-group-prepare-all",
                actionable: model.menuPreparableEpisodes,
                inFlight: model.menuPreparationsInFlight,
                inFlightVerb: "Preparing"
            ) {
                model.prepareAllDownloadedMenuEpisodes()
            }
        case .available:
            bulkAction(
                "Download all \(model.menuDownloadableEpisodes.count)",
                identifier: "wilted-menu-group-download-all",
                actionable: model.menuDownloadableEpisodes,
                inFlight: model.menuDownloadsInFlight,
                inFlightVerb: "Downloading"
            ) {
                model.downloadAllAvailableMenuEpisodes()
            }
        }
        Button(model.menuGroupClearLabel(group)) {
            model.clearMenuGroup(group)
        }
        .disabled(model.isSearchingMenu)
        .help("Removes these rows from Larder without deleting audio, prepared cuts, transcripts, or listening history.")
        .accessibilityHint("Does not delete audio, prepared cuts, transcripts, or listening history.")
        .accessibilityLabel("\(model.menuGroupClearLabel(group)) in \(group.displayName)")
        .accessibilityIdentifier(groupClearIdentifier(group))
    }

    /// Literal identifiers, not an interpolation: the release gate greps the
    /// view source for each one.
    private func groupClearIdentifier(_ group: WiltedMacMenuGroup) -> String {
        switch group {
        case .playable: "wilted-menu-clear-ready"
        case .downloaded: "wilted-menu-clear-downloaded"
        case .available: "wilted-menu-clear-available"
        }
    }

    /// The selected presentation sections. Status owns the lifecycle actions;
    /// Feed and Date are neutral views over the same durable listening order.
    @ViewBuilder var groupList: some View {
        let sections = model.menuSections()
        let total = model.menuWaitingEpisodes.count
        if model.menuFilteredEpisodes.isEmpty {
            Text(model.isSearchingMenu
                 ? (model.isSearchingTranscripts ? "Still reading transcripts…" : "No episodes match this search.")
                 : (model.menuWaitingEpisodes.isEmpty
                    ? "Nothing is in Larder. Keep an episode from Feeds."
                    : "No episode is in this group right now."))
                .wiltedFont(.body)
                .foregroundStyle(WiltedTheme.color(.secondaryText, scheme: colorScheme))
                .accessibilityIdentifier("wilted-menu-empty")
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
                                .accessibilityIdentifier(menuSectionCountIdentifier(section))
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
                                let position = (model.menuWaitingEpisodes.firstIndex(of: episode) ?? index) + 1
                                menuRow(
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
                    .accessibilityIdentifier(menuSectionIdentifier(section))
                }
                tailDropTarget
            }
        }
    }

    /// Status keeps its established automation identifiers; the two new
    /// presentation modes use section identities that cannot collide with it.
    private func menuSectionIdentifier(_ section: WiltedMacMenuSection) -> String {
        if let group = section.statusGroup {
            return "wilted-menu-group-\(group.rawValue.lowercased())"
        }
        return "wilted-menu-section-\(section.id)"
    }

    private func menuSectionCountIdentifier(_ section: WiltedMacMenuSection) -> String {
        if let group = section.statusGroup {
            return "wilted-menu-\(group.rawValue.lowercased())-count"
        }
        return "wilted-menu-section-\(section.id)-count"
    }

    /// The strip below the last row is a real destination: a drop here appends
    /// the dragged entry. A payload that is not one of the Menu's episodes is
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
            guard let draggedID = draggedIDs.first else { return false }
            return model.moveMenuEpisodeToEnd(draggedID)
        } isTargeted: { targeted in
            dropTargetID = targeted ? Self.tailDropTargetID : nil
        }
        .accessibilityIdentifier("wilted-menu-drop-tail")
    }

    private static let tailDropTargetID = "__menu_tail__"

    /// Articles are saved listening that is not part of the episode queue; the
    /// Menu is their way in and out now that the Larder is gone. Kept as a
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
            if !model.menuSearchArticleResults.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(model.menuSearchArticleResults.enumerated()), id: \.element.id) { index, article in
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
        // and the per-row identifiers never reach the tree. The Menu's own
        // groups already use this shape, which is why `wilted-menu-row-` is
        // queryable and `wilted-article-row-` was not.
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("wilted-menu-articles")
    }

}
