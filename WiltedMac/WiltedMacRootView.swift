import AppKit
import SwiftUI

enum WiltedMacStartupAccessibility {
    static let loading = "wilted-mac-startup-loading"
    static let recovery = "wilted-mac-startup-recovery"
}

/// The producer window.
///
/// One sidebar of permanent destinations, and exactly one of them filling the
/// detail region. The previous composition rendered the Library surface
/// unconditionally and merely *appended* a player pane, so selecting a
/// destination changed nothing, the sidebar repeated the article list the
/// detail already showed, and "Add an article" stayed in the middle of the
/// window no matter what was selected. Owner acceptance rejected that on
/// 2026-08-25. Playback no longer needs to sit beside the producer surface to
/// stay reachable: the bottom rail persists beneath every work destination.
struct WiltedMacRootView: View {
    @Bindable private var model: WiltedMacModel
    @Environment(\.colorScheme) private var colorScheme

    init(model: WiltedMacModel) {
        _model = Bindable(model)
    }

    var body: some View {
        Group {
            switch model.startupState {
            case .loading:
                startupLoading
            case .ready:
                readyRoot
            case let .failed(failure):
                startupRecovery(failure)
            }
        }
        .task {
            model.startStoreBootstrap()
        }
    }

    private var readyRoot: some View {
        NavigationSplitView {
            // No `selection:` binding on purpose. The rows are buttons that set
            // the destination themselves, and a List that also tracks selection
            // draws AppKit's blue capsule underneath the leaf-tinted row
            // background -- two highlights on the same row. The selected state
            // is carried by the row background and text colour, and announced
            // to accessibility by the isSelected trait below.
            List {
                ForEach(WiltedMacNavigation.allCases) { destination in
                    let isSelected = model.selectedNavigation == destination
                    Button {
                        model.selectedNavigation = destination
                    } label: {
                        Label(destination.title, symbol: destination.symbolName)
                            .foregroundStyle(
                                isSelected
                                    ? WiltedTheme.color(.primaryText, scheme: colorScheme)
                                    : WiltedTheme.color(.secondaryText, scheme: colorScheme)
                            )
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(.plain)
                    .contentShape(Rectangle())
                    .listRowBackground(
                        isSelected
                            ? WiltedTheme.color(.wiltedLeaf, scheme: colorScheme).opacity(0.24)
                            : Color.clear
                    )
                    .accessibilityIdentifier("wilted-navigation-\(destination.rawValue)")
                    .accessibilityAddTraits(isSelected ? [.isSelected] : [])
                }
            }
            // The sidebar carries a page-token background rather than the
            // default AppKit material. It matches the rest of the palette, and
            // the material was additionally invisible to offscreen rendering,
            // which is why the navigation column recorded as a blank rectangle
            // in every Mac pixel baseline.
            .scrollContentBackground(.hidden)
            .background(WiltedTheme.color(.page, scheme: colorScheme))
            .navigationSplitViewColumnWidth(min: 180, ideal: 200, max: 260)
            .navigationTitle("Wilted")
            .accessibilityIdentifier("wilted-mac-sidebar")
        } detail: {
            VStack(spacing: 0) {
                Group {
                    switch model.selectedNavigation {
                    case .library:
                        WiltedMacLibraryView(model: model)
                    case .feeds:
                        WiltedMacFeedsView(model: model)
                    case .processor:
                        WiltedMacProcessorView(model: model)
                    case .settings:
                        WiltedMacSettingsView(model: model)
                    }
                }
                Divider()
                WiltedMacCompactPlayer(model: model)
            }
        }
        .tint(WiltedTheme.color(.wiltedLeaf, scheme: colorScheme))
        .toolbar { wordmark }
        // Three names for the same thing sat in one toolbar: the mark, the
        // window title beside it, and the destination heading below. macOS 26
        // draws the title as its own toolbar item, which `titleVisibility`
        // no longer suppresses, so remove the item where the API exists and
        // keep the AppKit fallback for macOS 14.
        .wiltedRemovingToolbarTitle()
        .background(WiltedWindowTitleHider())
        .accessibilityIdentifier("wilted-mac-root")
    }

    private var startupLoading: some View {
        VStack(spacing: WiltedTheme.Spacing.medium) {
            ProgressView("Opening and updating your larder…")
                .accessibilityLabel("Opening and updating your larder")
            Text("Your saved library stays in place while Wilted checks its format.")
                .font(WiltedTheme.font(.body))
                .foregroundStyle(WiltedTheme.color(.secondaryText, scheme: colorScheme))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(WiltedTheme.color(.page, scheme: colorScheme))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(WiltedMacStartupAccessibility.loading)
    }

    private func startupRecovery(_ failure: WiltedMacStartupFailure) -> some View {
        VStack(alignment: .leading, spacing: WiltedTheme.Spacing.medium) {
            Label("Your larder needs attention", systemImage: "exclamationmark.triangle")
                .font(WiltedTheme.font(.display))
                .foregroundStyle(WiltedTheme.color(.primaryText, scheme: colorScheme))
            Text(failure.message)
                .font(WiltedTheme.font(.body))
                .foregroundStyle(WiltedTheme.color(.secondaryText, scheme: colorScheme))
            if let detail = failure.detail {
                Text(detail)
                    .font(WiltedTheme.font(.utility))
                    .foregroundStyle(WiltedTheme.color(.secondaryText, scheme: colorScheme))
                    .textSelection(.enabled)
                    .accessibilityIdentifier("wilted-mac-startup-error-detail")
            }
            if let retainedURL = failure.retainedV5StoreURL {
                Text("A retained V5 recovery copy is available at:")
                    .font(WiltedTheme.font(.body))
                Text(retainedURL.path)
                    .font(WiltedTheme.font(.utility))
                    .textSelection(.enabled)
                    .accessibilityIdentifier("wilted-mac-retained-v5-location")
                Button("Show Recovery Copy in Finder") {
                    model.presentRetainedV5Store()
                }
                .accessibilityIdentifier("wilted-mac-show-retained-v5")
            }
            if failure.canRetry {
                Button("Retry Opening Larder") {
                    model.retryStoreBootstrap()
                }
                .accessibilityIdentifier("wilted-mac-startup-retry")
            } else {
                Text("Retry limit reached. Keep the recovery copy and relaunch Wilted before trying again.")
                    .font(WiltedTheme.font(.utility))
                    .foregroundStyle(WiltedTheme.color(.secondaryText, scheme: colorScheme))
            }
        }
        .frame(maxWidth: 640, alignment: .leading)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(WiltedTheme.Spacing.section)
        .background(WiltedTheme.color(.page, scheme: colorScheme))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(WiltedMacStartupAccessibility.recovery)
    }

    /// The wordmark states the brand at the top of the window. macOS 26 gives
    /// every toolbar item a glass capsule, which reads as a stray button
    /// behind letterforms that already have their own silhouette, so the
    /// shared background is opted out of where the API exists.
    @ToolbarContentBuilder
    private var wordmark: some ToolbarContent {
        if #available(macOS 26.0, *) {
            ToolbarItem(placement: .navigation) {
                WiltedWordmark(height: 16)
            }
            .sharedBackgroundVisibility(.hidden)
        } else {
            ToolbarItem(placement: .navigation) {
                WiltedWordmark(height: 16)
            }
        }
    }
}

private extension View {
    @ViewBuilder
    func wiltedRemovingToolbarTitle() -> some View {
        if #available(macOS 15.0, *) {
            toolbar(removing: .title)
        } else {
            self
        }
    }
}

/// Hides the window's title text while leaving the title itself set.
///
/// The wordmark already says "Wilted" in the toolbar, so drawing the word
/// again as text beside it reads as a duplicate. Clearing `navigationTitle`
/// does not work — an empty window title falls back to the bundle name — and
/// the declarative `toolbar(removing: .title)` is macOS 15+, while this target
/// ships to macOS 14. Hiding the title keeps it available to the Window menu,
/// Mission Control, and window-restoration, which an empty string would not.
private struct WiltedWindowTitleHider: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { NSView(frame: .zero) }

    func updateNSView(_ view: NSView, context: Context) {
        // `window` is nil until the view joins the hierarchy, which happens
        // after this first runs, so defer the lookup by one turn of the loop.
        DispatchQueue.main.async {
            view.window?.titleVisibility = .hidden
        }
    }
}

/// Every destination opens with its own name, at one weight, in one place.
/// Three different title treatments across the two apps is what let a
/// composer heading pass for a destination heading.
private struct WiltedMacDestination<Content: View>: View {
    @Environment(\.colorScheme) private var colorScheme
    let title: String
    let identifier: String
    @ViewBuilder let content: Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: WiltedTheme.Spacing.xLarge) {
                Text(title)
                    .font(WiltedTheme.font(.display))
                    .foregroundStyle(WiltedTheme.color(.primaryText, scheme: colorScheme))
                content
            }
            .frame(maxWidth: 760, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(WiltedTheme.Spacing.section)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(WiltedTheme.color(.page, scheme: colorScheme))
        .accessibilityIdentifier(identifier)
    }
}

// MARK: - Library

private struct WiltedMacLibraryView: View {
    @Bindable private var model: WiltedMacModel
    @Environment(\.colorScheme) private var colorScheme

    init(model: WiltedMacModel) {
        _model = Bindable(model)
    }

    var body: some View {
        WiltedMacDestination(title: WiltedScreenCopy.library, identifier: "wilted-mac-library-detail") {
            composer

            WiltedMacPodcastOperationMessage(model: model)

            if let preparation = model.preparation {
                WiltedMacPreparationView(model: model, preparation: preparation)
            }

            if model.libraryItems.isEmpty {
                ContentUnavailableView {
                    Label(
                        model.librarySearchQuery.isEmpty ? WiltedScreenCopy.libraryEmpty : "No matching Larder items",
                        symbol: model.librarySearchQuery.isEmpty ? WiltedSymbol.larder.rawValue : "magnifyingglass"
                    )
                } description: {
                    Text(model.librarySearchQuery.isEmpty
                        ? WiltedScreenCopy.libraryEmptyDetailProducer
                        : "Try another search or filter.")
                }
                .accessibilityIdentifier("wilted-mac-empty-state")
            } else {
                VStack(alignment: .leading, spacing: WiltedTheme.Spacing.medium) {
                    // The order control belongs to the list it orders. On its
                    // own card it was a near-empty band of chrome between the
                    // add box and the items.
                    HStack(spacing: WiltedTheme.Spacing.medium) {
                        Text("Saved articles and episodes")
                            .font(WiltedTheme.font(.title))
                            .foregroundStyle(WiltedTheme.color(.primaryText, scheme: colorScheme))
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Picker("Order", selection: $model.libraryOrder) {
                            ForEach(WiltedMacLibraryOrder.allCases) { order in Text(order.rawValue).tag(order) }
                        }
                        .labelsHidden()
                        .frame(width: 110)
                        .accessibilityIdentifier("wilted-library-order")
                    }
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(model.libraryItems.enumerated()), id: \.element.id) { index, item in
                            if index > 0 { Divider() }
                            Group {
                                switch item {
                                case .article(let article):
                                    WiltedMacArticleRow(model: model, article: article)
                                case .episode(let episode):
                                    WiltedMacEpisodeRow(model: model, episode: episode)
                                }
                            }
                            .background(
                                model.selectedLibraryItemID == item.id
                                    ? WiltedTheme.color(.wiltedLeaf, scheme: colorScheme).opacity(0.16)
                                    : Color.clear
                            )
                            .onTapGesture { model.selectLibraryItem(item.id) }
                        }
                    }
                    .wiltedCard(colorScheme)
                }
            }
        }
        .searchable(text: $model.librarySearchQuery, prompt: "Search articles and episodes")
        .searchScopes($model.libraryFilter) {
            ForEach(WiltedMacLibraryFilter.allCases) { filter in
                Text(filter.rawValue).tag(filter)
            }
        }
    }

    /// One box for both kinds of address.
    ///
    /// It is a card inside Library, not the page itself: as the page's own
    /// heading it read as an unrelated form sitting where the library was
    /// supposed to be. The status line below the field is not decoration --
    /// classifying an address can take a network round trip, and a button that
    /// pauses without saying so reads as a broken one.
    private var composer: some View {
        VStack(alignment: .leading, spacing: WiltedTheme.Spacing.medium) {
            Text(WiltedScreenCopy.addLinkTitle)
                .font(WiltedTheme.font(.title))
                .foregroundStyle(WiltedTheme.color(.primaryText, scheme: colorScheme))
            Text(WiltedScreenCopy.addLinkDetail)
                .font(WiltedTheme.font(.body))
                .foregroundStyle(WiltedTheme.color(.secondaryText, scheme: colorScheme))
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: WiltedTheme.Spacing.medium) {
                WiltedMacLinkField(text: $model.urlDraft)
                Button(WiltedScreenCopy.addLink) {
                    model.addPastedLink()
                }
                .keyboardShortcut(.return)
                .accessibilityIdentifier("wilted-add-link")
            }
            if let status = model.linkDraftStatus {
                Text(status)
                    .font(WiltedTheme.font(.utility))
                    .foregroundStyle(WiltedTheme.color(.secondaryText, scheme: colorScheme))
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("wilted-link-status")
            }
            if let advertised = model.advertisedFeed {
                advertisedFeedOffer(advertised)
            }
        }
        .wiltedCard(colorScheme)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("wilted-mac-composer")
    }

    /// The page that was just saved publishes a feed. Following it is a
    /// separate decision, so it is offered as an action rather than taken.
    private func advertisedFeedOffer(_ feedURL: URL) -> some View {
        HStack(spacing: WiltedTheme.Spacing.medium) {
            Text("That page publishes a feed at \(feedURL.host ?? feedURL.absoluteString).")
                .font(WiltedTheme.font(.utility))
                .foregroundStyle(WiltedTheme.color(.secondaryText, scheme: colorScheme))
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button("Subscribe") { model.subscribeToAdvertisedFeed() }
                .accessibilityIdentifier("wilted-advertised-feed-subscribe")
            Button("Not Now") { model.dismissAdvertisedFeed() }
                .accessibilityIdentifier("wilted-advertised-feed-dismiss")
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("wilted-advertised-feed")
    }
}

// MARK: - Feeds

/// Feed upkeep, on its own page.
///
/// Subscribing happens in Larder's one add box; this page is what the app does
/// with a feed once it is followed -- refresh it, hide it, or drop it.
private struct WiltedMacFeedsView: View {
    @Bindable private var model: WiltedMacModel
    @Environment(\.colorScheme) private var colorScheme

    init(model: WiltedMacModel) {
        _model = Bindable(model)
    }

    var body: some View {
        WiltedMacDestination(title: WiltedScreenCopy.feeds, identifier: "wilted-mac-feeds-detail") {
            feedManagement
        }
    }

    /// Refresh belongs to the list it refreshes. On its own card it was one
    /// button in a wide empty band, the same defect the Larder order control
    /// had before it moved into the list header.
    private var refreshHeader: some View {
        HStack(spacing: WiltedTheme.Spacing.medium) {
            // Not "Podcast feeds" again: that is the page's own heading now.
            Text("Subscriptions")
                .font(WiltedTheme.font(.title))
                .foregroundStyle(WiltedTheme.color(.primaryText, scheme: colorScheme))
                .frame(maxWidth: .infinity, alignment: .leading)
            if model.isRefreshingPodcasts {
                ProgressView().controlSize(.small).accessibilityIdentifier("wilted-podcast-refresh-progress")
                Button("Cancel Refresh") { model.cancelPodcastRefresh() }
                    .accessibilityIdentifier("wilted-podcast-refresh-cancel")
            } else {
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
            refreshHeader
            Text(WiltedScreenCopy.feedsPolicy)
                .font(WiltedTheme.font(.body))
                .foregroundStyle(WiltedTheme.color(.secondaryText, scheme: colorScheme))
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("wilted-podcast-feeds-policy")
            if model.withheldPodcastEpisodeCount > 0 {
                Text(model.withheldPodcastEpisodeCount == 1
                     ? "1 older episode stayed in its feed."
                     : "\(model.withheldPodcastEpisodeCount) older episodes stayed in their feeds.")
                    .font(WiltedTheme.font(.utility))
                    .foregroundStyle(WiltedTheme.color(.secondaryText, scheme: colorScheme))
                    .accessibilityIdentifier("wilted-podcast-feeds-withheld")
            }
            if model.subscriptions.isEmpty {
                Text(WiltedScreenCopy.feedsEmptyDetail)
                    .font(WiltedTheme.font(.body))
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
            if !model.dismissedEpisodes.isEmpty {
                Divider()
                Text("Removed")
                    .font(WiltedTheme.font(.title))
                    .foregroundStyle(WiltedTheme.color(.primaryText, scheme: colorScheme))
                    .accessibilityIdentifier("wilted-podcast-removed-title")
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(model.dismissedEpisodes.enumerated()), id: \.element.id) { index, dismissal in
                        if index > 0 { Divider() }
                        dismissedRow(dismissal)
                    }
                }
                .accessibilityIdentifier("wilted-podcast-removed")
            }
            WiltedMacPodcastOperationMessage(model: model)
        }
        .wiltedCard(colorScheme)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(WiltedScreenCopy.feedsIdentifier)
    }

    /// What one feed currently contributes, in words rather than a bare count,
    /// because "1 episodes" in a shipping window reads as a defect.
    private static func feedCountSummary(_ subscription: WiltedMacSubscription) -> String {
        let noun = subscription.episodeCount == 1 ? "episode" : "episodes"
        return subscription.enabled
            ? "\(subscription.episodeCount) \(noun) in Larder"
            : "\(subscription.episodeCount) \(noun) kept, hidden from Larder"
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
                    .font(WiltedTheme.font(.body))
                    .foregroundStyle(WiltedTheme.color(.primaryText, scheme: colorScheme))
                Text(subscription.feedURL.host ?? subscription.feedURL.absoluteString)
                    .font(WiltedTheme.font(.utility))
                    .foregroundStyle(WiltedTheme.color(.secondaryText, scheme: colorScheme))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(Self.feedCountSummary(subscription))
                    .font(WiltedTheme.font(.utility))
                    .foregroundStyle(WiltedTheme.color(.secondaryText, scheme: colorScheme))
                    .accessibilityIdentifier("wilted-podcast-feed-count-\(subscription.id)")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Toggle("Show in Larder", isOn: Binding(
                get: { subscription.enabled },
                set: { model.setSubscription(subscription, enabled: $0) }
            ))
            .labelsHidden()
            .accessibilityLabel("Show \(subscription.title) in Larder")
            .accessibilityIdentifier("wilted-podcast-feed-enabled-\(subscription.id)")
            Button("Unsubscribe") { model.unsubscribe(subscription) }
                .accessibilityIdentifier("wilted-podcast-feed-unsubscribe-\(subscription.id)")
        }
        .padding(.vertical, WiltedTheme.Spacing.small)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("wilted-podcast-feed-row-\(subscription.id)")
    }

    private func dismissedRow(_ dismissal: WiltedMacDismissedEpisode) -> some View {
        HStack(spacing: WiltedTheme.Spacing.medium) {
            VStack(alignment: .leading, spacing: WiltedTheme.Spacing.xSmall) {
                Text(dismissal.title)
                    .font(WiltedTheme.font(.body))
                    .foregroundStyle(WiltedTheme.color(.primaryText, scheme: colorScheme))
                Text(dismissal.feedTitle ?? "Feed unavailable")
                    .font(WiltedTheme.font(.utility))
                    .foregroundStyle(WiltedTheme.color(.secondaryText, scheme: colorScheme))
                if dismissal.hasPreparationHistory {
                    Text("Prep history available")
                        .font(WiltedTheme.font(.utility))
                        .foregroundStyle(WiltedTheme.color(.secondaryText, scheme: colorScheme))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Button("Restore") { model.restoreEpisode(dismissal) }
                .accessibilityLabel("Restore \(dismissal.title)")
                .accessibilityIdentifier("wilted-podcast-restore-\(dismissal.id)")
        }
        .padding(.vertical, WiltedTheme.Spacing.small)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("wilted-podcast-removed-row-\(dismissal.id)")
    }
}

/// The running report for the last podcast action.
///
/// Downloads and preparation are reported from Larder and refreshes from Feeds,
/// so both pages render it. Only one destination is on screen at a time, which
/// keeps the identifier unique.
private struct WiltedMacPodcastOperationMessage: View {
    let model: WiltedMacModel
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        if let message = model.podcastOperationMessage {
            Text(message)
                .font(WiltedTheme.font(.utility))
                .foregroundStyle(WiltedTheme.color(.secondaryText, scheme: colorScheme))
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("wilted-podcast-operation-message")
        }
    }
}

/// A tokenized field border replaces macOS's system-blue focus treatment.
struct WiltedMacLinkField: View {
    @Binding var text: String
    let focusedOverride: Bool?
    @FocusState private var isFocused: Bool
    @Environment(\.colorScheme) private var colorScheme

    init(text: Binding<String>, focusedOverride: Bool? = nil) {
        _text = text
        self.focusedOverride = focusedOverride
    }

    var body: some View {
        TextField("https://example.com/article-or-feed", text: $text)
            .textFieldStyle(.plain)
            .font(WiltedTheme.font(.body))
            .padding(.horizontal, WiltedTheme.Spacing.medium)
            .frame(minHeight: WiltedTheme.Spacing.minimumTouchTarget)
            .background(
                WiltedTheme.color(.page, scheme: colorScheme),
                in: RoundedRectangle(cornerRadius: WiltedTheme.Radius.control)
            )
            .overlay(
                RoundedRectangle(cornerRadius: WiltedTheme.Radius.control)
                    .stroke(
                        isFocused || focusedOverride == true
                            ? WiltedTheme.color(.wiltedLeaf, scheme: colorScheme)
                            : WiltedTheme.color(.steel, scheme: colorScheme),
                        lineWidth: isFocused || focusedOverride == true ? 2 : 1
                    )
            )
            .focused($isFocused)
            .accessibilityIdentifier("wilted-link-url")
    }
}

private struct WiltedMacPreparationView: View {
    let model: WiltedMacModel
    let preparation: WiltedMacPreparation
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: WiltedTheme.Spacing.medium) {
            HStack {
                Text(preparation.phase.title)
                    .font(WiltedTheme.font(.title))
                    .foregroundStyle(WiltedTheme.color(.primaryText, scheme: colorScheme))
                Spacer()
                if preparation.cancellable {
                    Button("Cancel") { model.cancelPreparation() }
                        .accessibilityIdentifier("wilted-cancel-preparation")
                }
            }
            if let fraction = preparation.fraction {
                ProgressView(value: fraction)
                    .tint(WiltedTheme.color(.progress, scheme: colorScheme))
                    .accessibilityIdentifier("wilted-preparation-progress")
                    .accessibilityValue("\(Int(fraction * 100)) percent")
            } else {
                ProgressView()
                    .tint(WiltedTheme.color(.progress, scheme: colorScheme))
                    .accessibilityIdentifier("wilted-preparation-progress")
            }
            Text(preparation.detail)
                .font(WiltedTheme.font(.utility))
                .foregroundStyle(WiltedTheme.color(.secondaryText, scheme: colorScheme))
                .accessibilityIdentifier("wilted-preparation-detail")
        }
        .wiltedCard(colorScheme)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("wilted-preparation")
    }
}

private struct WiltedMacArticleRow: View {
    let model: WiltedMacModel
    let article: WiltedMacArticle
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(spacing: WiltedTheme.Spacing.medium) {
            WiltedProduceTile(symbol: .lettuce, size: 56)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(article.title)
                    .font(WiltedTheme.font(.body))
                    .foregroundStyle(WiltedTheme.color(.primaryText, scheme: colorScheme))
                    .lineLimit(1)
                    .truncationMode(.tail)
                // Source and length on one line. Three stacked lines and a
                // card each meant four articles filled the window; a library
                // is a list to scan, not a page to read.
                Text(metaLine)
                    .font(WiltedTheme.font(.utility))
                    .foregroundStyle(
                        article.isReady
                            ? WiltedTheme.color(.secondaryText, scheme: colorScheme)
                            : WiltedStatusTone.active.color(colorScheme)
                    )
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if article.isReady {
                Button(WiltedScreenCopy.openPlayer) {
                    model.openNowPlaying(for: article)
                }
                .accessibilityIdentifier("wilted-open-now-playing")
            }

            Menu {
                Button("Remove", role: .destructive) { model.removeArticle(article) }
            } label: {
                Image(systemName: "ellipsis")
                    .accessibilityLabel("More actions for \(article.title)")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .accessibilityIdentifier("wilted-article-actions-\(article.id)")
        }
        .padding(.vertical, WiltedTheme.Spacing.small)
        .contentShape(Rectangle())
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("wilted-article-row-\(article.id)")
    }

    /// `text.npr.org · 28:56`, plus **Preparing** while the row has no button.
    ///
    /// A ready row already carries **Open Now Playing**, so spelling out
    /// *Ready to play* beside it repeats the same fact. A preparing row has no
    /// control at all, so its word stays.
    private var metaLine: String {
        var parts = [article.source]
        if let seconds = article.durationSeconds, seconds > 0 {
            parts.append(WiltedDuration.clock(seconds))
        }
        if !article.isReady { parts.append("Preparing") }
        return parts.joined(separator: " · ")
    }
}

private struct WiltedMacEpisodeRow: View {
    let model: WiltedMacModel
    let episode: WiltedMacEpisode
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(spacing: WiltedTheme.Spacing.medium) {
            artwork
            VStack(alignment: .leading, spacing: 2) {
                Text(episode.title)
                    .font(WiltedTheme.font(.body))
                    .foregroundStyle(WiltedTheme.color(.primaryText, scheme: colorScheme))
                    .lineLimit(1)
                Text("\(episode.feedTitle) · \(relativeAge)")
                    .font(WiltedTheme.font(.utility))
                    .foregroundStyle(WiltedTheme.color(.secondaryText, scheme: colorScheme))
                    .lineLimit(1)
                Text(episode.summary)
                    .font(WiltedTheme.font(.utility))
                    .foregroundStyle(WiltedTheme.color(.secondaryText, scheme: colorScheme))
                    .lineLimit(2)
                Text(progressLabel)
                    .font(WiltedTheme.font(.utility))
                    .foregroundStyle(WiltedTheme.color(.secondaryText, scheme: colorScheme))
                if let preparation = episode.preparationState.label {
                    Text(preparation)
                        .font(WiltedTheme.font(.utility))
                        .foregroundStyle(WiltedTheme.color(.secondaryText, scheme: colorScheme))
                        .accessibilityIdentifier("wilted-episode-preparation-\(episode.id)")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            downloadControl
            Menu {
                // Redoing a good preparation is rare, so it lives here rather
                // than as a row button; a failed one is retried from Prep,
                // next to the reason it failed.
                if case .prepared = episode.preparationState {
                    Button("Prepare again") { model.prepareEpisode(episode) }
                }
                Button("Remove from Larder", role: .destructive) { model.removeEpisode(episode) }
            } label: {
                Image(systemName: "ellipsis").accessibilityLabel("More actions for \(episode.title)")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .accessibilityIdentifier("wilted-episode-actions-\(episode.id)")
        }
        .padding(.vertical, WiltedTheme.Spacing.small)
        .contentShape(Rectangle())
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(model.selectedLibraryItemID == episode.id ? .isSelected : [])
        .accessibilityIdentifier("wilted-episode-row-\(episode.id)")
    }

    @ViewBuilder private var artwork: some View {
        if let url = episode.artworkURL {
            AsyncImage(url: url) { phase in
                if let image = phase.image { image.resizable().scaledToFill() }
                else if phase.error != nil { fallbackArtwork }
                else { ProgressView().accessibilityLabel("Loading artwork for \(episode.title)") }
            }
            .frame(width: 56, height: 56).clipped()
            .accessibilityLabel("Artwork for \(episode.title)")
        } else { fallbackArtwork }
    }

    private var fallbackArtwork: some View {
        WiltedProduceTile(symbol: .cabbage, size: 56)
            .accessibilityLabel("Podcast artwork unavailable for \(episode.title)")
    }

    @ViewBuilder private var downloadControl: some View {
        switch episode.downloadState {
        case .notDownloaded:
            Button("Download") { model.downloadEpisode(episode) }
                .accessibilityIdentifier("wilted-episode-download-\(episode.id)")
        case .queued:
            Button("Cancel") { model.cancelEpisodeDownload(episode) }
                .accessibilityLabel("Cancel queued download for \(episode.title)")
        case .downloading(let received, let expected):
            VStack {
                if let expected, expected > 0 { ProgressView(value: Double(received), total: Double(expected)) }
                else { ProgressView() }
                Button("Cancel") { model.cancelEpisodeDownload(episode) }
            }
            .frame(width: 86)
            .accessibilityIdentifier("wilted-episode-download-progress-\(episode.id)")
        case .completed:
            HStack {
                Button("Play") { model.playEpisode(episode) }
                    .accessibilityIdentifier("wilted-episode-play-\(episode.id)")
                Button("Up Next") { model.addEpisodeToUpNext(episode) }
                    .accessibilityIdentifier("wilted-episode-up-next-\(episode.id)")
                preparationControl
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Available offline")
            .accessibilityIdentifier("wilted-episode-offline-\(episode.id)")
        case .failed, .cancelled:
            Button("Retry") { model.retryEpisodeDownload(episode) }
                .accessibilityIdentifier("wilted-episode-retry-\(episode.id)")
        }
    }

    /// Preparation runs itself after a download. Prepare is for the episode
    /// that arrived before it existed. A failed run is retried on Prep, where
    /// the reason is; a good one is redone from the row's menu.
    @ViewBuilder private var preparationControl: some View {
        switch episode.preparationState {
        case .preparing:
            Button("Stop") { model.cancelEpisodePreparation(episode) }
                .accessibilityLabel("Stop preparing \(episode.title)")
                .accessibilityIdentifier("wilted-episode-preparation-cancel-\(episode.id)")
        case .notPrepared:
            Button("Prepare") { model.prepareEpisode(episode) }
                .accessibilityLabel("Remove advertisements and sync the transcript for \(episode.title)")
                .accessibilityIdentifier("wilted-episode-prepare-\(episode.id)")
        case .prepared, .failed:
            EmptyView()
        }
    }

    private var relativeAge: String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter.localizedString(for: episode.releasedAt, relativeTo: Date())
    }

    private var progressLabel: String {
        guard let duration = episode.durationSeconds else { return "Duration unavailable" }
        if episode.playbackSeconds > 0 {
            return WiltedDuration.progress(position: episode.playbackSeconds, duration: duration)
        }
        return WiltedDuration.clock(duration)
    }
}

// MARK: - Processor

/// Visibility into the preparation pipeline.
///
/// The producer runs one preparation at a time and journals every status it
/// emits, but nothing read that journal back: a run that failed while the
/// window was closed left no trace a reader could find, and the only evidence
/// preparation had ever happened was whether an article appeared in Library.
/// This lists what is running now and every attempt that came before it.
private struct WiltedMacProcessorView: View {
    let model: WiltedMacModel
    @Environment(\.colorScheme) private var colorScheme
    /// Runs whose log is open. Per run rather than a page-wide switch: the
    /// reader opens the one they are asking about.
    @State private var openLogs: Set<String> = []

    /// Podcast runs still going. Article runs are `model.preparation`.
    private var activeRuns: [WiltedMacProcessorRun] {
        model.processorRuns.filter { $0.isPodcast && $0.outcome == .running }
    }

    private var recentRuns: [WiltedMacProcessorRun] {
        model.processorRuns.filter { !($0.isPodcast && $0.outcome == .running) }
    }

    private var hasActiveArticle: Bool {
        if let preparation = model.preparation, !preparation.phase.isTerminal { return true }
        return false
    }

    var body: some View {
        WiltedMacDestination(title: WiltedScreenCopy.processor, identifier: "wilted-mac-processor-detail") {
            VStack(alignment: .leading, spacing: WiltedTheme.Spacing.medium) {
                Text("Active")
                    .font(WiltedTheme.font(.title))
                    .foregroundStyle(WiltedTheme.color(.primaryText, scheme: colorScheme))
                if let preparation = model.preparation, !preparation.phase.isTerminal {
                    WiltedMacPreparationView(model: model, preparation: preparation)
                }
                ForEach(activeRuns) { run in
                    activeRunCard(run)
                }
                if !hasActiveArticle && activeRuns.isEmpty {
                    Text("Nothing is preparing. Add an article in Larder to start a run.")
                        .font(WiltedTheme.font(.body))
                        .foregroundStyle(WiltedTheme.color(.secondaryText, scheme: colorScheme))
                        .accessibilityIdentifier("wilted-processor-idle")
                }
            }

            VStack(alignment: .leading, spacing: WiltedTheme.Spacing.medium) {
                HStack {
                    Text("Recent runs")
                        .font(WiltedTheme.font(.title))
                        .foregroundStyle(WiltedTheme.color(.primaryText, scheme: colorScheme))
                    Spacer()
                    Text(runCountLabel)
                        .font(WiltedTheme.font(.utility))
                        .foregroundStyle(WiltedTheme.color(.secondaryText, scheme: colorScheme))
                }
                if recentRuns.isEmpty {
                    Text("No preparation has been recorded on this Mac yet.")
                        .font(WiltedTheme.font(.body))
                        .foregroundStyle(WiltedTheme.color(.secondaryText, scheme: colorScheme))
                        .accessibilityIdentifier("wilted-processor-empty")
                } else {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(recentRuns.enumerated()), id: \.element.id) { index, run in
                            if index > 0 { Divider() }
                            runRow(run)
                        }
                    }
                    .wiltedCard(colorScheme)
                }
                if let message = model.processorOperationMessage {
                    Text(message)
                        .font(WiltedTheme.font(.utility))
                        .foregroundStyle(WiltedTheme.color(.secondaryText, scheme: colorScheme))
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("wilted-processor-operation-message")
                }
            }
        }
        .task {
            // Polled rather than pushed: the journal is written by the
            // coordinator's own actor and this destination has no hook into
            // it. One second matches the player's readout cadence.
            while !Task.isCancelled {
                model.refreshProcessorRuns()
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    private var runCountLabel: String {
        let count = recentRuns.count
        return "\(count) recorded"
    }

    /// A podcast run in progress: what it is doing now, a way to stop it,
    /// and the log if asked for.
    private func activeRunCard(_ run: WiltedMacProcessorRun) -> some View {
        VStack(alignment: .leading, spacing: WiltedTheme.Spacing.medium) {
            HStack {
                Image(WiltedSymbol.processor)
                    .font(WiltedTheme.font(.title))
                    .foregroundStyle(WiltedStatusTone.active.color(colorScheme))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(run.title)
                        .font(WiltedTheme.font(.title))
                        .foregroundStyle(WiltedTheme.color(.primaryText, scheme: colorScheme))
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Text(run.source)
                        .font(WiltedTheme.font(.utility))
                        .foregroundStyle(WiltedTheme.color(.secondaryText, scheme: colorScheme))
                        .lineLimit(1)
                }
                Spacer()
                logButton(run)
                Button("Stop") { model.cancelProcessorRun(run) }
                    .accessibilityLabel("Stop preparing \(run.title)")
                    .accessibilityIdentifier("wilted-processor-stop-\(run.id)")
            }
            if let fraction = run.fraction {
                ProgressView(value: fraction)
                    .tint(WiltedTheme.color(.progress, scheme: colorScheme))
                    .accessibilityValue("\(Int(fraction * 100)) percent")
            } else {
                ProgressView()
                    .tint(WiltedTheme.color(.progress, scheme: colorScheme))
            }
            Text(run.narrative)
                .font(WiltedTheme.font(.utility))
                .foregroundStyle(WiltedTheme.color(.secondaryText, scheme: colorScheme))
                .accessibilityIdentifier("wilted-processor-narrative-\(run.id)")
            if openLogs.contains(run.id) {
                eventLog(run)
            }
        }
        .wiltedCard(colorScheme)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("wilted-processor-active-\(run.id)")
    }

    private func runRow(_ run: WiltedMacProcessorRun) -> some View {
        VStack(alignment: .leading, spacing: WiltedTheme.Spacing.small) {
            HStack(alignment: .top, spacing: WiltedTheme.Spacing.medium) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(run.title)
                        .font(WiltedTheme.font(.body))
                        .foregroundStyle(WiltedTheme.color(.primaryText, scheme: colorScheme))
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Text(run.narrative)
                        .font(WiltedTheme.font(.utility))
                        .foregroundStyle(WiltedTheme.color(.secondaryText, scheme: colorScheme))
                        .lineLimit(openLogs.contains(run.id) ? nil : 2)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                VStack(alignment: .trailing, spacing: 2) {
                    // The word always carries the outcome; the tone only
                    // emphasises it (W-INV-010).
                    Text(run.outcomeLabel)
                        .font(WiltedTheme.font(.utility))
                        .foregroundStyle(run.tone.color(colorScheme))
                    Text(Self.stamp.string(from: run.updatedAt))
                        .font(WiltedTheme.font(.utility))
                        .foregroundStyle(WiltedTheme.color(.secondaryText, scheme: colorScheme))
                }
                HStack(spacing: WiltedTheme.Spacing.small) {
                    if run.isPodcast, run.outcome == .failed {
                        Button("Retry") { model.retryProcessorRun(run) }
                            .accessibilityLabel("Prepare \(run.title) again")
                            .accessibilityIdentifier("wilted-processor-retry-\(run.id)")
                    }
                    logButton(run)
                }
            }
            // Contained, not combined, like the Larder rows: the texts stay
            // reachable one by one, which is how they are tested.
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("wilted-processor-run-\(run.id)")
            if openLogs.contains(run.id) {
                eventLog(run)
            }
        }
        .padding(.vertical, WiltedTheme.Spacing.small)
    }

    private func logButton(_ run: WiltedMacProcessorRun) -> some View {
        let open = openLogs.contains(run.id)
        return Button(open ? "Hide log" : "Show log") {
            if open { openLogs.remove(run.id) } else { openLogs.insert(run.id) }
        }
        .accessibilityLabel(open ? "Hide the log for \(run.title)" : "Show the log for \(run.title)")
        .accessibilityIdentifier("wilted-processor-log-toggle-\(run.id)")
    }

    /// Every status the run journalled, in the pipeline's own words. The
    /// vocabulary is the worker's on purpose: this is the view for someone
    /// working out why a run did what it did.
    private func eventLog(_ run: WiltedMacProcessorRun) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            if run.events.isEmpty {
                Text("Nothing journalled yet.")
                    .font(WiltedTheme.font(.utility))
                    .foregroundStyle(WiltedTheme.color(.secondaryText, scheme: colorScheme))
            }
            ForEach(run.events) { event in
                HStack(alignment: .top, spacing: WiltedTheme.Spacing.small) {
                    Text(Self.clock.string(from: event.at))
                        .font(WiltedTheme.font(.utility).monospacedDigit())
                        .foregroundStyle(WiltedTheme.color(.secondaryText, scheme: colorScheme))
                    Text(event.line)
                        .font(WiltedTheme.font(.utility))
                        .foregroundStyle(WiltedTheme.color(.secondaryText, scheme: colorScheme))
                        .textSelection(.enabled)
                        .accessibilityIdentifier("wilted-processor-event-\(event.id)")
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("wilted-processor-log-\(run.id)")
    }

    private static let stamp: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()

    private static let clock: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()
}

// MARK: - Persistent Player
/// A fixed footer outside every destination's scroll view. It keeps playback
/// visible while the Larder moves and owns the complete local podcast surface.
struct WiltedMacCompactPlayer: View {
    private enum Expansion: Hashable {
        case transcript
        case notes
        case upNext
    }

    @Bindable var model: WiltedMacModel
    @Environment(\.colorScheme) private var colorScheme
    @State private var expansion: Expansion?
    @FocusState private var primaryTransportFocused: Bool
    @FocusState private var keyboardFocus: Expansion?
    @AccessibilityFocusState private var accessibilityFocus: Expansion?

    var body: some View {
        VStack(spacing: WiltedTheme.Spacing.small) {
            if model.hasCurrentPlayback {
                HStack(spacing: WiltedTheme.Spacing.medium) {
                artwork
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .lineLimit(1)
                        .font(WiltedTheme.font(.body))
                    Text(detail)
                        .lineLimit(1)
                        .font(WiltedTheme.font(.utility))
                        .foregroundStyle(WiltedTheme.color(.secondaryText, scheme: colorScheme))
                        .accessibilityLabel(detail)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                // Label hidden and width unconstrained: with both, an 82pt
                // picker showed "Speed" and clipped the value to a sliver.
                Picker("Speed", selection: Binding(
                    get: { model.playbackRate }, set: { model.setPlaybackRate($0) }
                )) {
                    ForEach([0.5, 0.75, 1, 1.25, 1.5, 2], id: \.self) {
                        Text("\($0, specifier: "%g")×").tag($0)
                    }
                }
                .labelsHidden()
                .fixedSize()
                .disabled(!model.hasCurrentPlayback)
                .accessibilityLabel("Speed")
                .accessibilityIdentifier("wilted-player-speed")

                Menu {
                    Button("Transcript") { open(.transcript) }
                    Button("Up Next") { open(.upNext) }
                } label: {
                    Image(systemName: "ellipsis")
                }
                .menuStyle(.borderlessButton)
                .accessibilityLabel("More playback options")
                .accessibilityIdentifier("wilted-player-overflow")
            }

            HStack(spacing: WiltedTheme.Spacing.medium) {
                transport("backward.end.fill", label: "Previous episode", id: "wilted-player-previous") {
                    model.previousPlayback()
                }
                .disabled(!model.canSelectPreviousEpisode)
                .keyboardShortcut(.leftArrow, modifiers: [.command, .shift])
                transport("gobackward.15", label: "Rewind 15 seconds", id: WiltedScreenCopy.playerRewindIdentifier) {
                    model.rewind()
                }
                .disabled(!model.hasCurrentPlayback)
                .keyboardShortcut(.leftArrow, modifiers: .command)
                transport(
                    model.isPlaying ? "pause.fill" : "play.fill",
                    label: model.isPlaying ? "Pause" : "Play",
                    id: WiltedScreenCopy.playerPlayPauseIdentifier
                ) {
                    model.togglePlayback()
                }
                .disabled(!model.hasCurrentPlayback)
                .focusable()
                .focused($primaryTransportFocused)
                .onKeyPress(.space) {
                    guard model.hasCurrentPlayback else { return .ignored }
                    model.togglePlayback()
                    return .handled
                }
                transport("goforward.30", label: "Skip forward 30 seconds", id: WiltedScreenCopy.playerForwardIdentifier) {
                    model.forward()
                }
                .disabled(!model.hasCurrentPlayback)
                .keyboardShortcut(.rightArrow, modifiers: .command)
                transport("forward.end.fill", label: "Next episode", id: "wilted-player-next") {
                    model.nextPlayback()
                }
                .disabled(!model.canSelectNextEpisode)
                .keyboardShortcut(.rightArrow, modifiers: [.command, .shift])
                Button("Restart") { model.restartPlayback() }
                    .disabled(!model.hasCurrentPlayback)
                    .keyboardShortcut("r", modifiers: .command)
                    .accessibilityIdentifier("wilted-player-restart")
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("wilted-player-keyboard-transports")

            HStack {
                Slider(value: Binding(
                    get: { model.playbackPositionSeconds }, set: { model.scrub(to: $0) }
                ), in: 0...max(1, model.playbackDurationSeconds)) {
                    Text("Playback position")
                }
                .disabled(!model.hasCurrentPlayback)
                .accessibilityLabel("Playback position")
                .accessibilityValue(model.playbackProgressSpokenLabel)
                .accessibilityIdentifier("wilted-player-scrubber")

                Text(model.playbackProgressLabel)
                    .font(WiltedTheme.font(.utility))

                expansionButton("Transcript", expansion: .transcript, id: "wilted-player-transcript")
                // Show notes belong to episodes; an article has its own text.
                if model.currentEpisode != nil {
                    expansionButton("Notes", expansion: .notes, id: "wilted-player-notes")
                }
                expansionButton("Up Next", expansion: .upNext, id: "wilted-player-up-next")

                Button("Recover audio") { model.recoverAudioRoute() }
                    .disabled(!model.hasCurrentPlayback || !model.audioRouteFault)
                    .accessibilityIdentifier("wilted-player-route-recovery")

                Image(systemName: "speaker.fill")
                    .accessibilityHidden(true)
                Slider(value: Binding(
                    get: { model.playbackVolume }, set: { model.setPlaybackVolume($0) }
                ), in: 0...1)
                .frame(width: 90)
                .disabled(!model.hasCurrentPlayback)
                .accessibilityLabel("Volume")
                .accessibilityIdentifier("wilted-player-volume")
            }

            Text(model.playbackStatusMessage)
                .font(WiltedTheme.font(.utility))
                .foregroundStyle(model.playbackStatusTone.color(colorScheme))
                .accessibilityIdentifier("wilted-player-status")

            if let expansion {
                Divider()
                expandedContent(expansion)
                    .frame(maxHeight: 170)
            }

            if let status = model.playbackOperationStatus {
                Text(status)
                    .font(WiltedTheme.font(.utility))
                    .accessibilityIdentifier("wilted-player-operation-status")
            }
                if let error = model.playbackError {
                    Text(error)
                        .font(WiltedTheme.font(.utility))
                        .foregroundStyle(WiltedTheme.color(.error, scheme: colorScheme))
                        .accessibilityIdentifier("wilted-player-recoverable-error")
                }
            } else {
                minimizedIdlePlayer
            }
        }
        .padding(.horizontal, WiltedTheme.Spacing.medium)
        .padding(.vertical, WiltedTheme.Spacing.small)
        .background(WiltedTheme.color(.card, scheme: colorScheme))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Playback rail")
        .accessibilityValue(expansion == nil ? "Collapsed" : "Expanded")
        .accessibilityIdentifier("wilted-compact-player")
        .onExitCommand {
            collapseExpansion()
        }
        .task(id: model.hasCurrentPlayback) {
            guard model.hasCurrentPlayback else { return }
            await Task.yield()
            if expansion == nil, keyboardFocus == nil {
                primaryTransportFocused = true
            }
            while !Task.isCancelled {
                model.refreshPlaybackReadout()
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    private var minimizedIdlePlayer: some View {
        HStack(spacing: WiltedTheme.Spacing.small) {
            Image(systemName: "play.circle")
                .font(WiltedTheme.font(.title))
                .foregroundStyle(WiltedTheme.color(.secondaryText, scheme: colorScheme))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text("Nothing is playing")
                    .font(WiltedTheme.font(.body))
                Text("Choose an episode or article from Larder to start playback.")
                    .font(WiltedTheme.font(.utility))
                    .foregroundStyle(WiltedTheme.color(.secondaryText, scheme: colorScheme))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Text("Minimized")
                .font(WiltedTheme.font(.utility))
                .foregroundStyle(WiltedTheme.color(.secondaryText, scheme: colorScheme))
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Nothing is playing")
        .accessibilityValue("Minimized")
        .accessibilityIdentifier("wilted-player-idle")
    }

    @ViewBuilder
    private func expansionButton(
        _ label: String,
        expansion target: Expansion,
        id: String
    ) -> some View {
        // The same button closes what it opened, and says so: the pane pushes
        // the list up rather than covering it, and nothing else on screen
        // explained how to get the room back.
        Button(expansion == target ? "Hide \(label)" : label) {
            toggle(target)
        }
        .focusable()
        .focused($keyboardFocus, equals: target)
        .onKeyPress(.space) {
            toggle(target)
            return .handled
        }
        .onKeyPress(.escape) {
            guard expansion != nil else { return .ignored }
            collapseExpansion()
            return .handled
        }
        .accessibilityFocused($accessibilityFocus, equals: target)
        .accessibilityValue(expansion == target ? "Expanded" : "Collapsed")
        .accessibilityIdentifier(id)
    }

    @ViewBuilder
    private func expandedContent(_ target: Expansion) -> some View {
        switch target {
        case .transcript:
            transcriptContent
                .accessibilityIdentifier("wilted-player-transcript-expanded")
        case .notes:
            notesContent
                .accessibilityIdentifier("wilted-player-notes-expanded")
        case .upNext:
            upNextContent
                .accessibilityIdentifier("wilted-player-up-next-expanded")
        }
    }

    @ViewBuilder private var transcriptContent: some View {
        let transcript = model.currentTranscript ?? .unavailable
        // A synchronised transcript owns its own scrolling: it has to move the
        // active line to the middle as the audio advances, which a parent
        // scroll view would fight.
        if model.hasCurrentPlayback, transcript.isSynchronized {
            VStack(alignment: .leading, spacing: WiltedTheme.Spacing.small) {
                Text(transcript.disclosureTitle)
                    .font(WiltedTheme.font(.utility))
                    .foregroundStyle(WiltedTheme.color(.secondaryText, scheme: colorScheme))
                    .accessibilityIdentifier("wilted-now-playing-transcript")
                WiltedSyncedTranscriptView(
                    cues: transcript.cues.map {
                        WiltedTranscriptCueLine(id: $0.id, startSeconds: $0.startSeconds, text: $0.text)
                    },
                    activeCueID: model.activeTranscriptCueID,
                    identifier: "wilted-now-playing-synced-transcript"
                ) { model.seekToTranscriptCue(transcript.cues[$0.id]) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            unsyncedTranscriptContent(transcript)
        }
    }

    private func unsyncedTranscriptContent(_ transcript: WiltedMacTranscript) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: WiltedTheme.Spacing.small) {
                if !model.hasCurrentPlayback {
                    Text(WiltedScreenCopy.nowPlayingEmptyDetailProducer)
                        .font(WiltedTheme.font(.body))
                } else {
                    WiltedTranscriptSection(
                        isReadable: transcript.isReadable,
                        title: transcript.disclosureTitle,
                        text: transcript.text,
                        unavailableLabel: model.currentEpisode == nil
                            ? transcript.unavailableLabel
                            : "Transcript unavailable. Prepare this episode to add one.",
                        identifier: "wilted-now-playing-transcript"
                    )
                    // Backfill fetches article text from the web; an episode's
                    // transcript comes from preparation instead.
                    if !transcript.isReadable, model.currentEpisode == nil {
                        Button(model.isBackfillingTranscript ? "Fetching transcript…" : "Fetch transcript") {
                            model.backfillCurrentTranscript()
                        }
                        .disabled(model.isBackfillingTranscript)
                        .accessibilityIdentifier("wilted-now-playing-fetch-transcript")
                    }
                    if let status = model.transcriptBackfillStatus {
                        Text(status)
                            .font(WiltedTheme.font(.utility))
                            .foregroundStyle(WiltedTheme.color(.secondaryText, scheme: colorScheme))
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("wilted-now-playing-transcript-status")
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var notesContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: WiltedTheme.Spacing.small) {
                Text("Show Notes")
                    .font(WiltedTheme.font(.title))
                if let notes = model.currentEpisode?.notes {
                    Text(Self.linkedNotes(notes))
                        .font(WiltedTheme.font(.body))
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("wilted-player-notes-text")
                } else {
                    Text("This episode's feed did not include show notes.")
                        .font(WiltedTheme.font(.body))
                        .foregroundStyle(WiltedTheme.color(.secondaryText, scheme: colorScheme))
                        .accessibilityIdentifier("wilted-player-notes-unavailable")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("wilted-player-notes-list")
    }

    /// Feed notes arrive as plain text with the URLs written out; make each
    /// one a link so a sponsor code or guest site is a click, not a copy.
    static func linkedNotes(_ notes: String) -> AttributedString {
        var text = AttributedString(notes)
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else {
            return text
        }
        let whole = NSRange(notes.startIndex..., in: notes)
        for match in detector.matches(in: notes, range: whole) {
            guard let url = match.url, let range = Range(match.range, in: notes),
                  let attributedRange = Range(range, in: text) else { continue }
            text[attributedRange].link = url
        }
        return text
    }

    private var upNextContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: WiltedTheme.Spacing.small) {
                Text("Up Next")
                    .font(WiltedTheme.font(.title))
                if model.podcastQueueIDs.isEmpty {
                    Text("Nothing queued")
                        .font(WiltedTheme.font(.body))
                        .foregroundStyle(WiltedTheme.color(.secondaryText, scheme: colorScheme))
                } else {
                    ForEach(Array(model.podcastQueueIDs.enumerated()), id: \.element) { index, episodeID in
                        let episodeTitle = queueTitle(for: episodeID)
                        let canRemove = Self.canRemoveFromUpNext(
                            episodeID: episodeID,
                            currentEpisodeID: model.currentPodcastEpisodeID
                        )
                        HStack {
                            Text(episodeTitle)
                                .lineLimit(1)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            Button("Remove") {
                                model.removeEpisodeFromUpNext(episodeID)
                            }
                            .disabled(!canRemove)
                            .accessibilityLabel("Remove \(episodeTitle) from Up Next")
                            .accessibilityValue(Self.upNextRemoveAccessibilityValue(canRemove: canRemove))
                            .accessibilityIdentifier("wilted-player-up-next-remove-\(episodeID)")
                            Button("Move Earlier") {
                                model.moveEpisodeInUpNext(from: index, to: index - 1)
                            }
                            .disabled(index == model.podcastQueueIDs.startIndex)
                            .accessibilityLabel("Move \(episodeTitle) earlier")
                            .accessibilityIdentifier("wilted-player-up-next-move-earlier-\(episodeID)")
                            Button("Move Later") {
                                model.moveEpisodeInUpNext(from: index, to: index + 1)
                            }
                            .disabled(index == model.podcastQueueIDs.index(before: model.podcastQueueIDs.endIndex))
                            .accessibilityLabel("Move \(episodeTitle) later")
                            .accessibilityIdentifier("wilted-player-up-next-move-later-\(episodeID)")
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("wilted-player-up-next-list")
    }

    @ViewBuilder
    private var artwork: some View {
        if let url = model.currentEpisode?.artworkURL {
            AsyncImage(url: url) { image in
                image.resizable().scaledToFill()
            } placeholder: {
                fallbackArtwork
            }
            .frame(width: 44, height: 44)
            .clipped()
        } else {
            fallbackArtwork
        }
    }

    private var fallbackArtwork: some View {
        WiltedProduceTile(symbol: model.currentEpisode == nil ? .lettuce : .cabbage, size: 44)
            .accessibilityLabel("Playback artwork unavailable")
    }

    private var title: String {
        model.currentEpisode?.title ?? model.currentArticle?.title ?? "Nothing is playing"
    }

    private var detail: String {
        if let episode = model.currentEpisode {
            return "\(episode.feedTitle) · \(episode.releasedAt.formatted(date: .abbreviated, time: .omitted))"
        }
        return model.currentArticle?.source ?? WiltedScreenCopy.nowPlayingEmptyDetailProducer
    }

    private func queueTitle(for episodeID: String) -> String {
        model.episodes.first(where: { $0.id == episodeID })?.title ?? "Saved episode"
    }

    static func canRemoveFromUpNext(episodeID: String, currentEpisodeID: String?) -> Bool {
        episodeID != currentEpisodeID
    }

    static func upNextRemoveAccessibilityValue(canRemove: Bool) -> String {
        canRemove ? "Available" : "Unavailable for the current episode"
    }

    private func open(_ target: Expansion) {
        expansion = target
    }

    private func toggle(_ target: Expansion) {
        if expansion == target {
            collapseExpansion()
        } else {
            expansion = target
            primaryTransportFocused = false
            Task { @MainActor in
                await Task.yield()
                keyboardFocus = target
            }
        }
    }

    private func collapseExpansion() {
        guard expansion != nil else { return }
        expansion = nil
    }

    private func transport(
        _ symbol: String,
        label: String,
        id: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .frame(width: 28, height: 28)
        }
        .buttonStyle(.borderless)
        .accessibilityLabel(label)
        .accessibilityIdentifier(id)
    }
}

// MARK: - Settings

/// Sync used to sit inside Library, above the article composer, which is both
/// the wrong altitude and out of step with the listener, where the same facts
/// live in Settings.
private struct WiltedMacSettingsView: View {
    let model: WiltedMacModel
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        WiltedMacDestination(title: WiltedScreenCopy.settings, identifier: "wilted-mac-settings") {
            syncCard
        }
    }

    private var syncCard: some View {
        WiltedSettingsCard(title: WiltedScreenCopy.sync) {
            WiltedSettingsRow(
                "Status",
                value: model.syncStatus.phase.rawValue.capitalized,
                identifier: "wilted-sync-status",
                tone: model.syncStatus.phase.tone
            )
            Divider()
            WiltedSettingsRow(
                "Detail",
                value: model.syncStatus.detail,
                identifier: "wilted-sync-detail"
            )
            Divider()
            WiltedSettingsRow(
                "Producer identity",
                value: model.syncObservability.producerIdentity.label,
                identifier: "wilted-sync-producer-identity"
            )
            Divider()
            WiltedSettingsRow("Last fetch", value: lastFetchLabel, identifier: "wilted-sync-last-fetch")
            Divider()
            WiltedSettingsRow("Last send", value: lastSendLabel, identifier: "wilted-sync-last-send")

            HStack(spacing: WiltedTheme.Spacing.small) {
                Button("Refresh") { model.refreshSync() }
                    .disabled(syncActionsDisabled)
                    .accessibilityIdentifier("wilted-sync-refresh")
                Button("Upload") { model.uploadPendingSync() }
                    .disabled(syncActionsDisabled)
                    .accessibilityIdentifier("wilted-sync-upload")
                if model.syncStatus.phase == .fetching
                    || model.syncStatus.phase == .sending
                    || model.syncStatus.phase == .staging {
                    Button("Cancel") { model.cancelSync() }
                        .accessibilityIdentifier("wilted-sync-cancel")
                }
            }
            .padding(.top, WiltedTheme.Spacing.xSmall)

            if model.syncStatus.phase == .quarantined {
                WiltedAccountRecoveryNotice(identifier: "wilted-sync-use-current-account") {
                    model.resetSyncAccount()
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("wilted-sync-controls")
    }

    private var syncActionsDisabled: Bool {
        model.syncStatus.phase == .disabled || model.syncStatus.phase == .quarantined
    }

    private var lastFetchLabel: String {
        model.syncObservability.lastSuccessfulFetchAt
            .map { $0.formatted(date: .abbreviated, time: .shortened) } ?? "Not yet"
    }

    private var lastSendLabel: String {
        model.syncObservability.lastSuccessfulSendAt
            .map { $0.formatted(date: .abbreviated, time: .shortened) } ?? "Not yet"
    }
}
