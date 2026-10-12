import AppKit
import SwiftUI
import WiltedDomain

// MARK: - Feeds

enum WiltedMacFeedHistoryAccessibilityID {
    static func restoreSkipped(_ episodeID: String) -> String { "wilted-feeds-restore-skipped-\(episodeID)" }
    static func restoreRemoved(_ episodeID: String) -> String { "wilted-feeds-restore-removed-\(episodeID)" }
}

struct WiltedMacFeedRenameInteraction {
    private(set) var drafts: [String: WiltedMacFeedRenameDraft] = [:]

    mutating func begin(_ subscription: WiltedMacSubscription) {
        var draft = WiltedMacFeedRenameDraft()
        draft.begin(subscription)
        drafts[subscription.id] = draft
    }

    mutating func update(_ feedID: String, text: String) {
        guard var draft = drafts[feedID] else { return }
        draft.text = text
        drafts[feedID] = draft
    }

    mutating func cancel(_ feedID: String) {
        guard var draft = drafts[feedID] else { return }
        draft.cancel()
        drafts.removeValue(forKey: feedID)
    }

    /// Removes the editor synchronously; the caller starts async persistence after this returns.
    mutating func submit(_ feedID: String) -> String? {
        guard var draft = drafts[feedID], draft.beginSaving() else { return nil }
        drafts.removeValue(forKey: feedID)
        return draft.text
    }

    mutating func restoreFailure(_ subscription: WiltedMacSubscription, text: String, error: String) {
        var draft = WiltedMacFeedRenameDraft()
        draft.begin(subscription)
        draft.text = text
        draft.finish(error: error)
        drafts[subscription.id] = draft
    }
}

/// Feed upkeep on one page: what arrived, and what the app does with each
/// followed feed -- refresh it, hide it, or drop it. Following a new show is
/// the Add sheet's job, opened from the toolbar.
struct WiltedMacFeedsView: View {
    @Bindable private var model: WiltedMacModel
    @Environment(\.colorScheme) private var colorScheme
    private var selectedFeedEpisodeIDs: Set<String> {
        get { model.navigationState.selectedFeedEpisodeIDs }
        nonmutating set { model.navigationState.selectedFeedEpisodeIDs = newValue }
    }
    @State private var feedRemoval = WiltedMacRemovalFlow()
    @State private var feedRenameInteraction = WiltedMacFeedRenameInteraction()
    @FocusState private var focusedFeedID: String?
    @State private var presentedSheet: Sheet?
    @State private var policyBoard: WiltedMacFeedPolicyBoard

    private enum Sheet: Identifiable {
        case details(String)
        case history

        var id: String {
            switch self {
            case let .details(feedID): "details-\(feedID)"
            case .history: "history"
            }
        }
    }

    /// The root passes its window-long board, which the details sheet and rules editor share.
    /// A board built here serves only headless tests that render Feeds on its own.
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
        .sheet(item: $presentedSheet) { sheet in
            VStack(spacing: 0) {
                HStack {
                    Spacer()
                    Button("Done") { presentedSheet = nil }
                        .keyboardShortcut(.cancelAction)
                        .accessibilityIdentifier("wilted-feed-sheet-done")
                }
                .padding(.horizontal, WiltedTheme.Spacing.large)
                .padding(.top, WiltedTheme.Spacing.small)

                switch sheet {
                case let .details(feedID):
                    if let subscription = model.subscriptions.first(where: { $0.id == feedID }) {
                        WiltedMacFeedDetailsView(model: model, board: policyBoard, subscription: subscription)
                    }
                case .history:
                    WiltedMacFeedHistoryView(model: model)
                }
            }
        }
    }

    /// The count keeps the established Off the list entry point while the
    /// history page handles search, filtering, paging, and Restore.
    @ViewBuilder private var restorableEpisodes: some View {
        if !model.skippedFeedEpisodes.isEmpty || !model.dismissedEpisodes.isEmpty {
            VStack(alignment: .leading, spacing: WiltedTheme.Spacing.medium) {
                Button { presentedSheet = .history } label: {
                    HStack {
                        Label("Off the list", systemImage: "clock.arrow.circlepath")
                            .wiltedFont(.title)
                        Spacer()
                        Text("\(model.skippedFeedEpisodes.count + model.dismissedEpisodes.count)")
                            .wiltedFont(.utility)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(WiltedTheme.color(.primaryText, scheme: colorScheme))
                .accessibilityLabel("Off the list, \(model.skippedFeedEpisodes.count + model.dismissedEpisodes.count) episodes. Open history")
                .accessibilityIdentifier("wilted-feeds-off-list-toggle")
            }
        }
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
        let articles = model.feedsOfferedArticles
        VStack(alignment: .leading, spacing: WiltedTheme.Spacing.medium) {
            HStack {
                Text("New episodes")
                    .wiltedFont(.title)
                    .foregroundStyle(WiltedTheme.color(.primaryText, scheme: colorScheme))
                Spacer()
                Text("\(visible.count + articles.count)")
                    .wiltedFont(.utility)
                    .foregroundStyle(WiltedTheme.color(.secondaryText, scheme: colorScheme))
                    .accessibilityIdentifier("wilted-feeds-count")
            }
            if visible.isEmpty && articles.isEmpty {
                Text("No new episodes.")
                    .wiltedFont(.body)
                    .foregroundStyle(WiltedTheme.color(.secondaryText, scheme: colorScheme))
                    .accessibilityIdentifier("wilted-feeds-empty")
            }
            if !visible.isEmpty {
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
            // Posts of followed article feeds that no rule or policy decided: the same Keep and Skip.
            if !articles.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(articles.enumerated()), id: \.element.id) { index, article in
                        if index > 0 { Divider() }
                        WiltedMacFeedsArticleRow(model: model, article: article)
                    }
                }
                .wiltedCard(colorScheme)
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
            if model.isRefreshingPodcasts || model.automaticFeedRefreshInFlight {
                ProgressView().controlSize(.small).accessibilityIdentifier("wilted-podcast-refresh-progress")
                Text("Refreshing")
                    .wiltedFont(.utility)
                    .foregroundStyle(WiltedTheme.color(.secondaryText, scheme: colorScheme))
                // Cancel stops a manual refresh only; Settings stops an automatic pass.
                if model.isRefreshingPodcasts {
                    Button("Cancel") { model.cancelPodcastRefresh() }
                        .accessibilityIdentifier("wilted-podcast-refresh-cancel")
                }
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
            if let message = policyBoard.loadFailureMessage {
                HStack(alignment: .firstTextBaseline, spacing: WiltedTheme.Spacing.small) {
                    Label(message, systemImage: "exclamationmark.triangle")
                        .wiltedFont(.utility)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("wilted-feed-capacity-error")
                    Spacer(minLength: WiltedTheme.Spacing.small)
                    Button("Retry") { Task { await policyBoard.retryReload() } }
                        .disabled(!policyBoard.canRetry)
                        .accessibilityIdentifier("wilted-feed-capacity-retry")
                }
            }
            WiltedMacRemovalStatusLine(flow: feedRemoval, model: model)
        }
        .wiltedRemovalConfirmation(feedRemoval, model: model)
        .wiltedCard(colorScheme)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(WiltedScreenCopy.feedsIdentifier)
        // The board keeps each feed's stored policy across visits. Each visit, and each change to
        // the list of feeds, refreshes it in the background; reload publishes only when it finishes.
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
                if let draft = feedRenameInteraction.drafts[subscription.id] {
                    TextField("Feed name", text: Binding(
                        get: { feedRenameInteraction.drafts[subscription.id]?.text ?? draft.text },
                        set: { feedRenameInteraction.update(subscription.id, text: $0) }
                    ))
                        .wiltedFont(.body)
                        .textFieldStyle(.roundedBorder)
                        .focused($focusedFeedID, equals: subscription.id)
                        .onAppear { focusedFeedID = subscription.id }
                        .onSubmit { submitFeedName(subscription) }
                        .onExitCommand { cancelFeedName(subscription.id) }
                        .accessibilityLabel("Name for \(subscription.publisherTitle ?? subscription.title)")
                        .accessibilityIdentifier("wilted-podcast-feed-name-editor-\(subscription.id)")
                    if let error = draft.error {
                        Text(error).wiltedFont(.utility).foregroundStyle(.red)
                    }
                } else {
                    HStack(spacing: WiltedTheme.Spacing.xSmall) {
                        Button { presentedSheet = .details(subscription.id) } label: {
                            Text(subscription.title)
                                .wiltedFont(.body)
                                .foregroundStyle(WiltedTheme.color(.primaryText, scheme: colorScheme))
                        }
                        .buttonStyle(.plain)
                        .help("Show feed details")
                        .accessibilityLabel("Details for \(subscription.title)")
                        .accessibilityIdentifier("wilted-podcast-feed-name-\(subscription.id)")
                        Button { beginFeedName(subscription) } label: {
                            Image(systemName: "pencil")
                                .accessibilityHidden(true)
                                .frame(minWidth: 24, minHeight: 24)
                        }
                        .buttonStyle(.borderless)
                        .help("Rename feed")
                        .disabled(model.isFeedWritePending(subscription.id))
                        .accessibilityLabel("Rename \(subscription.title)")
                        .accessibilityIdentifier("wilted-podcast-feed-rename-\(subscription.id)")
                    }
                }
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
            Button { feedRemoval.request(.feed(subscription)) } label: {
                Image(systemName: "trash")
            }
            .help("Unsubscribe")
            .accessibilityLabel("Unsubscribe from \(subscription.title)")
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

    @MainActor private func beginFeedName(_ subscription: WiltedMacSubscription) {
        feedRenameInteraction.begin(subscription)
        focusedFeedID = subscription.id
    }

    @MainActor private func cancelFeedName(_ feedID: String) {
        guard feedRenameInteraction.drafts[feedID] != nil else { return }
        feedRenameInteraction.cancel(feedID)
        if focusedFeedID == feedID { focusedFeedID = nil }
    }

    @MainActor private func submitFeedName(_ subscription: WiltedMacSubscription) {
        guard let submittedName = feedRenameInteraction.submit(subscription.id) else { return }
        focusedFeedID = nil
        Task {
            do {
                try await model.renameSubscription(subscription, to: submittedName)
            } catch {
                feedRenameInteraction.restoreFailure(
                    subscription, text: submittedName,
                    error: "\(subscription.title) could not be renamed. Try again."
                )
                focusedFeedID = subscription.id
            }
        }
    }

}

/// One inbox row. The buttons are the enum, in declaration order, so the row
/// cannot grow a third action without changing the one list the tests read.
/// Its title opens the episode's show notes, so the listener can decide based
/// on what the episode is about.
