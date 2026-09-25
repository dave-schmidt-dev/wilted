import AppKit
import SwiftUI
import WiltedDomain

// MARK: - Feeds

/// Subscribing, and feed upkeep, on one page.
///
/// Subscribing used to happen in Larder's single add box, which asked the
/// listener to paste a feed into a control labelled for articles. This page now
/// owns the decision: its composer takes the feed, and the list below is what
/// the app does with it once followed -- refresh it, hide it, or drop it.
struct WiltedMacFeedsView: View {
    @Bindable private var model: WiltedMacModel
    @Environment(\.colorScheme) private var colorScheme
    @State private var isOffListExpanded = false

    init(model: WiltedMacModel) {
        _model = Bindable(model)
    }

    var body: some View {
        WiltedMacDestination(title: WiltedScreenCopy.feeds, identifier: "wilted-mac-feeds-detail") {
            refreshHeader
            Text("New episodes from your subscriptions are undecided. Refresh only admits metadata; Keep moves an episode to Larder, where its next step becomes available.")
                .wiltedFont(.body)
                .foregroundStyle(WiltedTheme.color(.secondaryText, scheme: colorScheme))
                .fixedSize(horizontal: false, vertical: true)
            addFeedControl
            inbox
            restorableEpisodes
            feedManagement
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
                            title: episode.title,
                            detail: "Skipped",
                            identifier: "wilted-feeds-restore-skipped-\(episode.id)"
                        ) {
                            model.restoreSkippedFeedEpisode(episode)
                        }
                    }
                    ForEach(Array(model.dismissedEpisodes.enumerated()), id: \.element.id) { index, dismissal in
                        if index > 0 || !model.skippedFeedEpisodes.isEmpty { Divider() }
                        restorableRow(
                            title: dismissal.title,
                            detail: "Removed",
                            identifier: "wilted-feeds-restore-removed-\(dismissal.id)"
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
        title: String, detail: String, identifier: String, action: @escaping () -> Void
    ) -> some View {
        HStack(spacing: WiltedTheme.Spacing.medium) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .wiltedFont(.body)
                    .foregroundStyle(WiltedTheme.color(.primaryText, scheme: colorScheme))
                    .lineLimit(1)
                Text(detail)
                    .wiltedFont(.utility)
                    .foregroundStyle(WiltedTheme.color(.secondaryText, scheme: colorScheme))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Button("Restore", action: action)
                .accessibilityLabel("Restore \(title)")
                .accessibilityIdentifier(identifier)
        }
        .padding(.vertical, WiltedTheme.Spacing.small)
    }

    /// The inbox: every episode that arrived and is not waiting yet.
    ///
    /// Feeds asks one question, so a row carries one answer each -- Keep or
    /// Skip -- and nothing else. The download, the preparation and the play
    /// all belong to the Menu, where the episode waits once kept.
    @ViewBuilder private var inbox: some View {
        VStack(alignment: .leading, spacing: WiltedTheme.Spacing.medium) {
            HStack {
                Text("New episodes")
                    .wiltedFont(.title)
                    .foregroundStyle(WiltedTheme.color(.primaryText, scheme: colorScheme))
                Spacer()
                Text("\(model.feedsEpisodes.count)")
                    .wiltedFont(.utility)
                    .foregroundStyle(WiltedTheme.color(.secondaryText, scheme: colorScheme))
                    .accessibilityIdentifier("wilted-feeds-count")
            }
            if model.feedsEpisodes.isEmpty {
                Text("Nothing new. Every episode from your feeds is already in Larder.")
                    .wiltedFont(.body)
                    .foregroundStyle(WiltedTheme.color(.secondaryText, scheme: colorScheme))
                    .accessibilityIdentifier("wilted-feeds-empty")
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(model.feedsEpisodes.enumerated()), id: \.element.id) { index, episode in
                        if index > 0 { Divider() }
                        WiltedMacFeedsEpisodeRow(model: model, episode: episode)
                    }
                }
                .wiltedCard(colorScheme)
                // Deliberately bare, like the Menu's group cards. An
                // accessibility identifier here publishes the card as a
                // container element, and a container placed directly around
                // rows that are themselves `.contain` hoists their children
                // into it -- the per-row `wilted-feeds-row-` identifiers then
                // never reach the tree. Dropping `.contain` alone was not
                // enough; the identifier creates the container on its own.
            }
        }
    }

    /// Subscribing behind a button, matching the Larder's Add article. The
    /// composer keeps its own identifier so what the popover holds is the same
    /// element it was when it sat on the page.
    private var addFeedControl: some View {
        HStack {
            Spacer()
            Button {
                model.isPresentingSubscribeComposer = true
            } label: {
                Label(WiltedScreenCopy.subscribeToPodcast, systemImage: "plus")
            }
            .accessibilityIdentifier("wilted-add-feed-button")
            .popover(isPresented: $model.isPresentingSubscribeComposer, arrowEdge: .bottom) {
                subscribeComposer
                    .frame(width: 460)
                    .padding(WiltedTheme.Spacing.large)
                    .background(WiltedTheme.color(.card, scheme: colorScheme))
            }
        }
    }

    /// The subscription composer.
    ///
    /// Classifying an address needs the document, so Subscribe can sit on a
    /// network round trip. The progress control and its Cancel are the reason
    /// that pause reads as work rather than as a button that did nothing.
    private var subscribeComposer: some View {
        VStack(alignment: .leading, spacing: WiltedTheme.Spacing.medium) {
            Text(WiltedScreenCopy.subscribeToPodcastDetail)
                .wiltedFont(.body)
                .foregroundStyle(WiltedTheme.color(.secondaryText, scheme: colorScheme))
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: WiltedTheme.Spacing.medium) {
                WiltedMacLinkField(
                    text: $model.podcastFeedDraft,
                    placeholder: "https://example.com/podcast/feed.xml",
                    identifier: "wilted-podcast-feed-url"
                )
                if model.isCheckingPodcastSubscription {
                    ProgressView().controlSize(.small)
                        .accessibilityIdentifier("wilted-podcast-subscribe-progress")
                    Button("Cancel") { model.cancelPodcastSubscriptionCheck() }
                        .accessibilityIdentifier("wilted-podcast-subscribe-cancel")
                } else {
                    Button("Subscribe") { model.addPodcastFeedDraft() }
                        .keyboardShortcut(.return)
                        .accessibilityIdentifier("wilted-podcast-subscribe")
                }
            }
            if let status = model.podcastFeedDraftStatus {
                Text(status)
                    .wiltedFont(.utility)
                    .foregroundStyle(WiltedTheme.color(.secondaryText, scheme: colorScheme))
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("wilted-podcast-subscribe-status")
            }
            if let advertised = model.advertisedFeed {
                WiltedMacAdvertisedFeedOffer(
                    model: model, feedURL: advertised, identifier: "wilted-podcast-advertised-feed"
                )
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("wilted-podcast-subscribe-composer")
    }

    /// Feeds owns its refresh action at the page header, ahead of either list.
    /// The same location remains live while network work is in flight.
    private var refreshHeader: some View {
        HStack(spacing: WiltedTheme.Spacing.medium) {
            Text("Feeds")
                .wiltedFont(.title)
                .foregroundStyle(WiltedTheme.color(.primaryText, scheme: colorScheme))
                .frame(maxWidth: .infinity, alignment: .leading)
            if model.isRefreshingPodcasts {
                ProgressView().controlSize(.small).accessibilityIdentifier("wilted-podcast-refresh-progress")
                Text("Refreshing")
                    .wiltedFont(.utility)
                    .foregroundStyle(WiltedTheme.color(.secondaryText, scheme: colorScheme))
                Button("Cancel") { model.cancelPodcastRefresh() }
                    .accessibilityIdentifier("wilted-podcast-refresh-cancel")
            } else {
                Text("Last updated: \(model.lastPodcastRefreshText)")
                    .wiltedFont(.utility)
                    .foregroundStyle(WiltedTheme.color(.secondaryText, scheme: colorScheme))
                    .accessibilityIdentifier("wilted-podcast-last-updated")
                Button("Refresh") { model.refreshPodcastFeeds() }
                    .accessibilityIdentifier("wilted-podcast-refresh")
            }
        }
    }

    /// The subscription list itself, a per-feed switch, and unsubscribe. The
    /// card also states the refresh and download policy, because an app with no
    /// schedule at all should say so rather than let its absence read as a
    /// setting the reader cannot find.
    private var feedManagement: some View {
        VStack(alignment: .leading, spacing: WiltedTheme.Spacing.medium) {
            Text("Subscriptions")
                .wiltedFont(.title)
                .foregroundStyle(WiltedTheme.color(.primaryText, scheme: colorScheme))
            Text(WiltedScreenCopy.feedsPolicy)
                .wiltedFont(.body)
                .foregroundStyle(WiltedTheme.color(.secondaryText, scheme: colorScheme))
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("wilted-podcast-feeds-policy")
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
            WiltedMacPodcastOperationMessage(model: model)
        }
        .wiltedCard(colorScheme)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(WiltedScreenCopy.feedsIdentifier)
    }

    /// What one feed currently contributes, in words rather than a bare count,
    /// because "1 episodes" in a shipping window reads as a defect.
    ///
    /// `count` comes from `WiltedMacModel.larderEpisodeCount(forFeedID:)`, the
    /// same visible set every waiting and inbox row draws from, not the raw
    /// snapshot count on the subscription -- that one includes retired and
    /// hidden records no list draws.
    private static func feedCountSummary(_ subscription: WiltedMacSubscription, count: Int) -> String {
        let noun = count == 1 ? "episode" : "episodes"
        return subscription.enabled
            ? "\(count) \(noun) from this feed"
            : "\(count) \(noun) kept, hidden"
    }

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
                Text(Self.feedCountSummary(
                    subscription,
                    count: model.larderEpisodeCount(forFeedID: subscription.id)
                ))
                .wiltedFont(.utility)
                .foregroundStyle(WiltedTheme.color(.secondaryText, scheme: colorScheme))
                .accessibilityIdentifier("wilted-podcast-feed-count-\(subscription.id)")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Toggle("Show episodes", isOn: Binding(
                get: { subscription.enabled },
                set: { model.setSubscription(subscription, enabled: $0) }
            ))
            .labelsHidden()
            .accessibilityLabel("Show episodes from \(subscription.title)")
            .accessibilityIdentifier("wilted-podcast-feed-enabled-\(subscription.id)")
            Button("Unsubscribe") { model.unsubscribe(subscription) }
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
