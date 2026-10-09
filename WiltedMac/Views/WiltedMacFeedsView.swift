import AppKit
import SwiftUI
import WiltedDomain

// MARK: - Feeds

/// Feed upkeep on one page: what arrived, and what the app does with each
/// followed feed -- refresh it, hide it, or drop it. Following a new show is
/// the Add sheet's job, opened from the toolbar.
struct WiltedMacFeedsView: View {
    @Bindable private var model: WiltedMacModel
    @Environment(\.colorScheme) private var colorScheme
    /// Kept on the model, so leaving Feeds and coming back (or relaunching) finds both as they were.
    private var isOffListExpanded: Bool {
        get { model.navigationState.isOffListExpanded }
        nonmutating set { model.navigationState.isOffListExpanded = newValue }
    }
    private var selectedFeedEpisodeIDs: Set<String> {
        get { model.navigationState.selectedFeedEpisodeIDs }
        nonmutating set { model.navigationState.selectedFeedEpisodeIDs = newValue }
    }
    @State private var feedRemoval = WiltedMacRemovalFlow()
    @State private var policyBoard: WiltedMacFeedPolicyBoard

    init(model: WiltedMacModel, policyBoard: WiltedMacFeedPolicyBoard? = nil) {
        _model = Bindable(model)
        _policyBoard = State(initialValue: policyBoard ?? WiltedMacFeedPolicyBoard(model: model))
    }

    var body: some View {
        WiltedMacDestination(
            title: WiltedScreenCopy.feeds, identifier: "wilted-mac-feeds-detail",
            scrollAnchor: model.scrollAnchor(for: .feeds)
        ) {
            VStack(alignment: .leading, spacing: WiltedTheme.Spacing.small) {
                refreshHeader
                // The one place an operation's message and its Undo appear.
                WiltedMacPodcastOperationMessage(model: model)
            }
            .id("feeds-refresh")
            inbox.id("feeds-inbox")
            feedManagement.id("feeds-subscriptions")
            restorableEpisodes.id("feeds-off-list")
        }
    }

    /// Reversing the one decision Feeds owns lives here. Skipped (retired) and
    /// removed (dismissed) rows both survive in the store under the same
    /// removal column, so both restore directly from the row with no network
    /// involved -- there is no feed to check either way.
    @ViewBuilder private var restorableEpisodes: some View {
        if !model.skippedFeedEpisodes.isEmpty || !model.dismissedEpisodes.isEmpty {
            VStack(alignment: .leading, spacing: WiltedTheme.Spacing.medium) {
                Button {
                    isOffListExpanded.toggle()
                } label: {
                    HStack {
                        Label("Off the list", systemImage: isOffListExpanded ? "chevron.down" : "chevron.right")
                            .wiltedFont(.title)
                        Spacer()
                        Text("\(model.skippedFeedEpisodes.count + model.dismissedEpisodes.count)")
                            .wiltedFont(.utility)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(WiltedTheme.color(.primaryText, scheme: colorScheme))
                .accessibilityLabel("Off the list, \(model.skippedFeedEpisodes.count + model.dismissedEpisodes.count) episodes")
                .accessibilityIdentifier("wilted-feeds-off-list-toggle")
                if isOffListExpanded {
                    VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(model.skippedFeedEpisodes.enumerated()), id: \.element.id) { index, episode in
                        if index > 0 { Divider() }
                        restorableRow(
                            presentation: episode.presentation,
                            detail: "Skipped",
                            identifier: "wilted-feeds-restore-skipped-\(episode.id)",
                            isPending: model.pendingFeedDecisionIDs.contains(episode.id),
                            failed: model.failedFeedDecisionIDs.contains(episode.id)
                        ) {
                            model.restoreSkippedFeedEpisode(episode)
                        }
                    }
                    ForEach(Array(model.dismissedEpisodes.enumerated()), id: \.element.id) { index, dismissal in
                        if index > 0 || !model.skippedFeedEpisodes.isEmpty { Divider() }
                        restorableRow(
                            presentation: dismissal.presentation,
                            detail: "Removed",
                            identifier: "wilted-feeds-restore-removed-\(dismissal.id)", isPending: false, failed: false
                        ) {
                            model.restoreEpisode(dismissal)
                        }
                    }
                    }
                    .wiltedCard(colorScheme)
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("wilted-feeds-restorable")
                }
            }
        }
    }

    private func restorableRow(
        presentation: WiltedMacEpisodePresentation,
        detail: String,
        identifier: String,
        isPending: Bool,
        failed: Bool,
        action: @escaping () -> Void
    ) -> some View {
        HStack(spacing: WiltedTheme.Spacing.medium) {
            VStack(alignment: .leading, spacing: 2) {
                Text(presentation.title)
                    .wiltedFont(.body)
                    .foregroundStyle(WiltedTheme.color(.primaryText, scheme: colorScheme))
                    .lineLimit(1)
                WiltedMacEpisodeMetadata(
                    presentation: presentation,
                    lifecycleLabel: detail,
                    identifier: identifier.replacingOccurrences(of: "restore", with: "metadata")
                )
                if isPending {
                    HStack(spacing: WiltedTheme.Spacing.xSmall) {
                        ProgressView().controlSize(.small)
                        Text("Restoring…")
                    }
                    .wiltedFont(.utility)
                    .foregroundStyle(WiltedTheme.color(.secondaryText, scheme: colorScheme))
                    .accessibilityIdentifier(identifier.replacingOccurrences(of: "restore", with: "pending"))
                } else if failed {
                    Text("Could not restore. Try again.")
                        .wiltedFont(.utility)
                        .foregroundStyle(WiltedTheme.color(.secondaryText, scheme: colorScheme))
                        .accessibilityIdentifier(identifier.replacingOccurrences(of: "restore", with: "failed"))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Button("Restore", action: action)
                .disabled(isPending)
                .accessibilityLabel("Restore \(presentation.title)")
                .accessibilityIdentifier(identifier)
        }
        .padding(.vertical, WiltedTheme.Spacing.small)
    }

    /// The inbox: every episode that arrived and is not waiting yet.
    ///
    /// Feeds asks one question, so a row carries one answer each -- Keep or
    /// Skip -- and nothing else. The download, the preparation and the play
    /// all belong to the Larder, where the episode waits once kept.
    @ViewBuilder private var inbox: some View {
        let visible = model.feedsEpisodes
        let visibleIDs = Set(visible.map(\.id))
        let selected = visible.filter { selectedFeedEpisodeIDs.contains($0.id) }
        let waitingIDs = policyBoard.waitingEpisodeIDs.intersection(visibleIDs)
        VStack(alignment: .leading, spacing: WiltedTheme.Spacing.medium) {
            HStack {
                Text("New episodes")
                    .wiltedFont(.title)
                    .foregroundStyle(WiltedTheme.color(.primaryText, scheme: colorScheme))
                Spacer()
                Text("\(visible.count)")
                    .wiltedFont(.utility)
                    .foregroundStyle(WiltedTheme.color(.secondaryText, scheme: colorScheme))
                    .accessibilityIdentifier("wilted-feeds-count")
            }
            if visible.isEmpty {
                Text("Nothing new. Every episode from your feeds is already in Larder.")
                    .wiltedFont(.body)
                    .foregroundStyle(WiltedTheme.color(.secondaryText, scheme: colorScheme))
                    .accessibilityIdentifier("wilted-feeds-empty")
            } else {
                if !waitingIDs.isEmpty {
                    // Said once for the whole list; each waiting row carries its own tag.
                    Text("Wilted never removes an existing, playing or part-heard episode to make room.")
                        .wiltedFont(.utility)
                        .foregroundStyle(WiltedTheme.color(.secondaryText, scheme: colorScheme))
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("wilted-feeds-waiting-note")
                }
                HStack(spacing: WiltedTheme.Spacing.small) {
                    WiltedMacFeedsSelectionControl(
                        state: selected.isEmpty ? .off : (selected.count == visible.count ? .on : .mixed),
                        identifier: "wilted-feeds-select-all"
                    ) {
                        selectedFeedEpisodeIDs = selected.count == visible.count ? [] : visibleIDs
                    }
                    Text("\(selected.count) selected")
                        .wiltedFont(.utility)
                        .foregroundStyle(WiltedTheme.color(.secondaryText, scheme: colorScheme))
                    Spacer()
                    Button("Keep selected") { model.decideFeedEpisodes(.keep, episodes: selected) }
                        .disabled(selected.isEmpty || selected.contains { model.pendingFeedDecisionIDs.contains($0.id) })
                        .accessibilityIdentifier("wilted-feeds-keep-selected")
                    Button("Skip selected") { model.decideFeedEpisodes(.skip, episodes: selected) }
                        .disabled(selected.isEmpty || selected.contains { model.pendingFeedDecisionIDs.contains($0.id) })
                        .accessibilityIdentifier("wilted-feeds-skip-selected")
                }
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(visible.enumerated()), id: \.element.id) { index, episode in
                        if index > 0 { Divider() }
                        WiltedMacFeedsEpisodeRow(
                            model: model, episode: episode,
                            isSelected: selectedFeedEpisodeIDs.contains(episode.id),
                            isWaitingForSpace: waitingIDs.contains(episode.id),
                            setSelected: { selected in
                                if selected { selectedFeedEpisodeIDs.insert(episode.id) }
                                else { selectedFeedEpisodeIDs.remove(episode.id) }
                            }
                        )
                    }
                }
                .wiltedCard(colorScheme)
                // Deliberately bare, like the Larder's group cards. An
                // accessibility identifier here publishes the card as a
                // container element, and a container placed directly around
                // rows that are themselves `.contain` hoists their children
                // into it -- the per-row `wilted-feeds-row-` identifiers then
                // never reach the tree. Dropping `.contain` alone was not
                // enough; the identifier creates the container on its own.
            }
        }
        .onChange(of: visibleIDs) { _, currentVisibleIDs in
            selectedFeedEpisodeIDs.formIntersection(currentVisibleIDs)
        }
    }

    /// Feeds owns its refresh action at the page header, ahead of either list.
    /// The same location remains live while network work is in flight.
    private var refreshHeader: some View {
        HStack(spacing: WiltedTheme.Spacing.medium) {
            // The destination's own title is the page's one "Feeds" heading.
            Spacer()
            if model.isRefreshingPodcasts {
                ProgressView().controlSize(.small).accessibilityIdentifier("wilted-podcast-refresh-progress")
                Text("Refreshing")
                    .wiltedFont(.utility)
                    .foregroundStyle(WiltedTheme.color(.secondaryText, scheme: colorScheme))
                Button("Cancel") { model.cancelPodcastRefresh() }
                    .accessibilityIdentifier("wilted-podcast-refresh-cancel")
            } else {
                WiltedMacLastRefreshedLabel(model: model, identifier: "wilted-podcast-last-updated")
                Button("Refresh") { model.refreshPodcastFeeds() }
                    .accessibilityIdentifier("wilted-podcast-refresh")
            }
        }
    }

    /// The single refresh and Keep explanation belongs to Subscriptions.
    var refreshHelp: WiltedMacHelpContent {
        WiltedMacHelpContent(title: "Subscriptions", text: WiltedScreenCopy.feedsPolicy)
    }

    private var feedManagement: some View {
        VStack(alignment: .leading, spacing: WiltedTheme.Spacing.medium) {
            HStack {
                Text("Subscriptions")
                    .wiltedFont(.title)
                    .foregroundStyle(WiltedTheme.color(.primaryText, scheme: colorScheme))
                WiltedMacHelpButton(content: refreshHelp, identifier: "wilted-podcast-feeds-policy")
                Spacer()
            }
            if model.withheldPodcastEpisodeCount > 0 {
                Text(model.withheldPodcastEpisodeCount == 1
                     ? "1 older episode stayed in its feed."
                     : "\(model.withheldPodcastEpisodeCount) older episodes stayed in their feeds.")
                    .wiltedFont(.utility)
                    .foregroundStyle(WiltedTheme.color(.secondaryText, scheme: colorScheme))
                    .accessibilityIdentifier("wilted-podcast-feeds-withheld")
            }
            if model.subscriptions.isEmpty {
                Text(WiltedScreenCopy.feedsEmptyDetail)
                    .wiltedFont(.body)
                    .foregroundStyle(WiltedTheme.color(.secondaryText, scheme: colorScheme))
                    .accessibilityIdentifier("wilted-podcast-feeds-empty")
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(model.subscriptions.enumerated()), id: \.element.id) { index, subscription in
                        if index > 0 { Divider() }
                        feedRow(subscription)
                    }
                }
            }
            WiltedMacRemovalStatusLine(flow: feedRemoval, model: model)
        }
        .wiltedRemovalConfirmation(feedRemoval, model: model)
        .wiltedCard(colorScheme)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(WiltedScreenCopy.feedsIdentifier)
        // The board holds each feed's stored policy; reload when the list of feeds changes.
        .task(id: model.subscriptions.map(\.id)) { await policyBoard.reload() }
    }

    /// What one feed currently contributes, in words rather than a bare count,
    /// because "1 episodes" in a shipping window reads as a defect.
    /// One feed's row.
    ///
    /// The text column claims the remaining width with a frame rather than a
    /// `Spacer`, and the row aligns on centers rather than the first text
    /// baseline. Both matter: pairing a baseline-aligned `HStack` with a
    /// `Spacer` around a truncating `Text` column made `NSHostingView` layout
    /// stop converging, which hung the pixel-snapshot render indefinitely
    /// rather than failing.
    private func feedRow(_ subscription: WiltedMacSubscription) -> some View {
        HStack(spacing: WiltedTheme.Spacing.medium) {
            VStack(alignment: .leading, spacing: WiltedTheme.Spacing.xSmall) {
                Text(subscription.title)
                    .wiltedFont(.body)
                    .foregroundStyle(WiltedTheme.color(.primaryText, scheme: colorScheme))
                Text(subscription.feedURL.host ?? subscription.feedURL.absoluteString)
                    .wiltedFont(.utility)
                    .foregroundStyle(WiltedTheme.color(.secondaryText, scheme: colorScheme))
                    .lineLimit(1)
                    .truncationMode(.middle)
                WiltedMacFeedCapacityLabel(board: policyBoard, subscription: subscription)
                if let status = model.feedRowStatus(subscription.id) {
                    Text(status)
                        .wiltedFont(.utility)
                        .foregroundStyle(WiltedTheme.color(.secondaryText, scheme: colorScheme))
                        .accessibilityIdentifier("wilted-podcast-feed-status-\(subscription.id)")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Toggle("Show episodes", isOn: Binding(
                get: { subscription.enabled },
                set: { model.setSubscription(subscription, enabled: $0) }
            ))
            .labelsHidden()
            .disabled(model.isFeedWritePending(subscription.id))
            .accessibilityLabel("Show episodes from \(subscription.title)")
            .accessibilityIdentifier("wilted-podcast-feed-enabled-\(subscription.id)")
            WiltedMacFeedPolicyButton(board: policyBoard, subscription: subscription)
            Button("Unsubscribe…") { feedRemoval.request(.feed(subscription)) }
                .disabled(feedRemoval.isSaving || model.isFeedWritePending(subscription.id))
                .accessibilityIdentifier("wilted-podcast-feed-unsubscribe-\(subscription.id)")
        }
        .padding(.vertical, WiltedTheme.Spacing.small)
        // Subscribing to a feed already followed adds nothing, so the answer is
        // the existing row rather than an error the listener cannot act on.
        .background(
            model.selectedPodcastFeedID == subscription.id
                ? WiltedTheme.color(.wiltedLeaf, scheme: colorScheme).opacity(0.12)
                : Color.clear,
            in: RoundedRectangle(cornerRadius: WiltedTheme.Radius.control)
        )
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(model.selectedPodcastFeedID == subscription.id ? [.isSelected] : [])
        .accessibilityIdentifier("wilted-podcast-feed-row-\(subscription.id)")
    }

}

/// One inbox row. The buttons are the enum, in declaration order, so the row
/// cannot grow a third action without changing the one list the tests read.
/// Its title opens the episode's show notes, so the listener can decide based
/// on what the episode is about.
